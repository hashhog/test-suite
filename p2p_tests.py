#!/usr/bin/env python3
"""P2P integration test suite for hashhog Bitcoin node implementations.

Uses an asyncio-based mock Bitcoin P2P peer to verify protocol behavior
across all 10 node implementations. Tests are run on regtest to allow
full control over block generation.

Usage:
    python3 p2p_tests.py [--nodes core,rustoshi,clearbit] [--timeout 30]
"""

import asyncio
import hashlib
import json
import os
import signal
import struct
import subprocess
import sys
import time
import traceback
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from regtest_miner import rpc_call, mine_blocks, sha256d

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

HASHHOG = os.environ.get("HASHHOG_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGTEST_DIR = "/tmp/hashhog-p2p-tests"
RESULTS_DIR = os.path.join(HASHHOG, "test-suite", "results")

# Regtest network magic
REGTEST_MAGIC = b"\xfa\xbf\xb5\xda"

# Service flags
NODE_NETWORK = 1
NODE_WITNESS = (1 << 3)

# Protocol version
PROTOCOL_VERSION = 70016

# RPC and P2P port assignments (31350-31359 RPC, 31450-31459 P2P)
NODE_CONFIGS = {
    "core": {
        "binary": f"{HASHHOG}/bitcoin-core/build/bin/bitcoind",
        "args": [
            "-regtest",
            "-datadir={datadir}",
            "-rpcport=31350",
            "-port=31450",
            "-server=1",
            "-listen=1",
            "-rpcuser=test",
            "-rpcpassword=test",
            "-txindex=1",
            "-printtoconsole=0",
            "-listenonion=0",
            "-bind=127.0.0.1:31450",
            "-rpcbind=127.0.0.1:31350",
            "-rpcallowip=127.0.0.0/8",
        ],
        "rpcport": 31350,
        "p2pport": 31450,
    },
    "rustoshi": {
        "binary": f"{HASHHOG}/rustoshi/target/release/rustoshi",
        "args": [
            "--network=regtest",
            "--datadir={datadir}",
            "--rpcbind=127.0.0.1:31351",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--port=31451",
            "--listen",
        ],
        "rpcport": 31351,
        "p2pport": 31451,
    },
    "clearbit": {
        "binary": f"{HASHHOG}/clearbit/zig-out/bin/clearbit",
        "args": [
            "--regtest",
            "--datadir={datadir}",
            "--rpcport=31352",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--port=31452",
            "--listen",
        ],
        "rpcport": 31352,
        "p2pport": 31452,
    },
    "blockbrew": {
        "binary": f"{HASHHOG}/blockbrew/blockbrew",
        "args": [
            "--regtest",
            "--datadir={datadir}",
            "--rpcport=31353",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--port=31453",
            "--listen",
        ],
        "rpcport": 31353,
        "p2pport": 31453,
    },
}

# Nodes to test (can be overridden via --nodes)
DEFAULT_NODES = ["core", "rustoshi", "clearbit"]


# ---------------------------------------------------------------------------
# Bitcoin P2P message encoding / decoding
# ---------------------------------------------------------------------------

def make_message(command: str, payload: bytes = b"") -> bytes:
    """Build a Bitcoin P2P message with header."""
    cmd_bytes = command.encode("ascii").ljust(12, b"\x00")
    length = struct.pack("<I", len(payload))
    checksum = sha256d(payload)[:4]
    return REGTEST_MAGIC + cmd_bytes + length + checksum + payload


def parse_message_header(data: bytes):
    """Parse a 24-byte message header. Returns (command, payload_len, checksum) or None."""
    if len(data) < 24:
        return None
    magic = data[:4]
    if magic != REGTEST_MAGIC:
        return None
    command = data[4:16].rstrip(b"\x00").decode("ascii", errors="replace")
    payload_len = struct.unpack("<I", data[16:20])[0]
    checksum = data[20:24]
    return command, payload_len, checksum


def make_version_payload(
    version: int = PROTOCOL_VERSION,
    services: int = NODE_NETWORK | NODE_WITNESS,
    timestamp: Optional[int] = None,
    recv_services: int = NODE_NETWORK | NODE_WITNESS,
    recv_ip: bytes = b"\x00" * 16,
    recv_port: int = 0,
    from_services: int = NODE_NETWORK | NODE_WITNESS,
    from_ip: bytes = b"\x00" * 16,
    from_port: int = 0,
    nonce: int = 0,
    user_agent: str = "/hashhog-p2p-test:0.1.0/",
    start_height: int = 0,
    relay: bool = True,
) -> bytes:
    """Build a version message payload."""
    if timestamp is None:
        timestamp = int(time.time())

    payload = struct.pack("<i", version)
    payload += struct.pack("<Q", services)
    payload += struct.pack("<q", timestamp)
    # addr_recv
    payload += struct.pack("<Q", recv_services)
    payload += recv_ip
    payload += struct.pack(">H", recv_port)
    # addr_from
    payload += struct.pack("<Q", from_services)
    payload += from_ip
    payload += struct.pack(">H", from_port)
    # nonce
    payload += struct.pack("<Q", nonce)
    # user_agent (var_str)
    ua_bytes = user_agent.encode("utf-8")
    payload += bytes([len(ua_bytes)]) + ua_bytes
    # start_height
    payload += struct.pack("<i", start_height)
    # relay
    payload += bytes([1 if relay else 0])
    return payload


def parse_version_payload(data: bytes) -> dict:
    """Parse a version message payload into a dict."""
    if len(data) < 46:
        return {"error": "too short"}
    result = {}
    result["version"] = struct.unpack("<i", data[0:4])[0]
    result["services"] = struct.unpack("<Q", data[4:12])[0]
    result["timestamp"] = struct.unpack("<q", data[12:20])[0]
    # addr_recv: 26 bytes (services 8 + ip 16 + port 2)
    result["recv_services"] = struct.unpack("<Q", data[20:28])[0]
    # addr_from: starts at 46
    if len(data) >= 80:
        result["from_services"] = struct.unpack("<Q", data[46:54])[0]
    if len(data) >= 80:
        result["nonce"] = struct.unpack("<Q", data[72:80])[0]
    # user_agent
    if len(data) > 80:
        ua_len = data[80]
        if len(data) > 81 + ua_len:
            result["user_agent"] = data[81:81 + ua_len].decode("utf-8", errors="replace")
            offset = 81 + ua_len
            if len(data) >= offset + 4:
                result["start_height"] = struct.unpack("<i", data[offset:offset + 4])[0]
            if len(data) >= offset + 5:
                result["relay"] = data[offset + 4] != 0
    return result


def make_sendcmpct_payload(announce: bool = False, version: int = 2) -> bytes:
    """Build a sendcmpct message payload."""
    return struct.pack("<B", 1 if announce else 0) + struct.pack("<Q", version)


def make_addr_payload(addrs: list) -> bytes:
    """Build an addr message payload.

    addrs: list of (timestamp, services, ip_bytes_16, port) tuples.
    """
    payload = bytes([len(addrs)])
    for ts, services, ip_bytes, port in addrs:
        payload += struct.pack("<I", ts)
        payload += struct.pack("<Q", services)
        payload += ip_bytes
        payload += struct.pack(">H", port)
    return payload


def make_inv_payload(items: list) -> bytes:
    """Build an inv/getdata message. items: list of (type_int, hash_bytes_32)."""
    payload = bytes([len(items)])
    for inv_type, inv_hash in items:
        payload += struct.pack("<I", inv_type)
        payload += inv_hash
    return payload


def make_getheaders_payload(
    version: int = PROTOCOL_VERSION,
    locator_hashes: list = None,
    hash_stop: bytes = b"\x00" * 32,
) -> bytes:
    """Build a getheaders message payload."""
    if locator_hashes is None:
        locator_hashes = []
    payload = struct.pack("<I", version)
    payload += bytes([len(locator_hashes)])
    for h in locator_hashes:
        payload += h
    payload += hash_stop
    return payload


def make_block_with_bad_pow(prev_hash_hex: str, height: int) -> bytes:
    """Create a minimal regtest block with intentionally bad PoW.

    Returns raw block bytes.
    """
    # Build a minimal block header
    version = struct.pack("<i", 0x20000000)
    prev_hash = bytes.fromhex(prev_hash_hex)[::-1]  # LE
    # Fake merkle root
    merkle_root = b"\xaa" * 32
    timestamp = struct.pack("<I", int(time.time()))
    # Regtest bits: 0x207fffff
    bits = struct.pack("<I", 0x207fffff)
    # Use a nonce that will NOT satisfy PoW (extremely unlikely to be valid)
    nonce = struct.pack("<I", 0xDEADBEEF)

    header = version + prev_hash + merkle_root + timestamp + bits + nonce

    # Build a minimal coinbase tx
    from regtest_miner import encode_coinbase_height, compact_size
    height_script = encode_coinbase_height(height)
    coinbase_script = height_script + b"\x00"

    tx = b""
    tx += struct.pack("<i", 2)  # version
    tx += b"\x01"  # 1 input
    tx += b"\x00" * 32  # null prevout
    tx += struct.pack("<I", 0xFFFFFFFF)
    tx += compact_size(len(coinbase_script)) + coinbase_script
    tx += struct.pack("<I", 0xFFFFFFFF)
    tx += b"\x01"  # 1 output
    tx += struct.pack("<q", 5000000000)  # 50 BTC
    tx += b"\x01\x51"  # OP_TRUE
    tx += struct.pack("<I", 0)  # locktime

    # Recompute merkle root from actual coinbase
    real_txid = sha256d(tx)
    header = version + prev_hash + real_txid + timestamp + bits + nonce

    # Verify this is indeed invalid PoW (hash > target for regtest)
    block_hash = sha256d(header)
    hash_int = int.from_bytes(block_hash, "little")
    # Regtest target for 0x207fffff
    target = 0x7fffff << (8 * (0x20 - 3))
    # If by some miracle it's valid, change the nonce
    if hash_int <= target:
        nonce = struct.pack("<I", 0xCAFEBABE)
        header = version + prev_hash + real_txid + timestamp + bits + nonce

    block = header + compact_size(1) + tx
    return block


# ---------------------------------------------------------------------------
# Mock P2P Peer (asyncio)
# ---------------------------------------------------------------------------

class MockPeer:
    """An asyncio-based mock Bitcoin P2P peer that connects to a node."""

    def __init__(self, host: str = "127.0.0.1", port: int = 0):
        self.host = host
        self.port = port
        self.reader: Optional[asyncio.StreamReader] = None
        self.writer: Optional[asyncio.StreamWriter] = None
        self.received_messages: list = []
        self._buf = b""
        self._connected = False
        self._read_task: Optional[asyncio.Task] = None

    async def connect(self, timeout: float = 10.0):
        """Open TCP connection to the node."""
        self.reader, self.writer = await asyncio.wait_for(
            asyncio.open_connection(self.host, self.port),
            timeout=timeout,
        )
        self._connected = True
        self._read_task = asyncio.create_task(self._read_loop())

    async def disconnect(self):
        """Close the connection."""
        self._connected = False
        if self._read_task and not self._read_task.done():
            self._read_task.cancel()
            try:
                await self._read_task
            except (asyncio.CancelledError, Exception):
                pass
        if self.writer:
            try:
                self.writer.close()
                await self.writer.wait_closed()
            except Exception:
                pass

    async def send(self, command: str, payload: bytes = b""):
        """Send a P2P message."""
        msg = make_message(command, payload)
        self.writer.write(msg)
        await self.writer.drain()

    async def send_version(self, **kwargs):
        """Send a version message."""
        payload = make_version_payload(**kwargs)
        await self.send("version", payload)

    async def send_verack(self):
        """Send a verack message."""
        await self.send("verack")

    async def wait_for_message(self, command: str, timeout: float = 15.0) -> Optional[dict]:
        """Wait until a message with the given command is received."""
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            for msg in self.received_messages:
                if msg["command"] == command:
                    return msg
            await asyncio.sleep(0.05)
        return None

    async def wait_for_any_message(self, timeout: float = 5.0) -> Optional[dict]:
        """Wait for any new message."""
        initial_count = len(self.received_messages)
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            if len(self.received_messages) > initial_count:
                return self.received_messages[-1]
            await asyncio.sleep(0.05)
        return None

    def get_messages(self, command: str) -> list:
        """Return all received messages with the given command."""
        return [m for m in self.received_messages if m["command"] == command]

    def clear_messages(self):
        """Clear received messages buffer."""
        self.received_messages.clear()

    @property
    def is_connected(self) -> bool:
        return self._connected and self.writer is not None and not self.writer.is_closing()

    async def _read_loop(self):
        """Background task: read and parse incoming messages."""
        try:
            while self._connected:
                # Read header (24 bytes)
                header_data = await asyncio.wait_for(
                    self.reader.readexactly(24), timeout=60.0
                )
                parsed = parse_message_header(header_data)
                if parsed is None:
                    continue
                command, payload_len, checksum = parsed

                # Read payload
                if payload_len > 0:
                    payload = await asyncio.wait_for(
                        self.reader.readexactly(payload_len), timeout=30.0
                    )
                else:
                    payload = b""

                # Verify checksum
                actual_checksum = sha256d(payload)[:4]
                if actual_checksum != checksum:
                    continue

                msg = {"command": command, "payload": payload, "time": time.time()}

                # Parse known message types
                if command == "version":
                    msg["parsed"] = parse_version_payload(payload)
                elif command == "sendcmpct" and len(payload) >= 9:
                    msg["parsed"] = {
                        "announce": payload[0] != 0,
                        "version": struct.unpack("<Q", payload[1:9])[0],
                    }
                elif command == "feefilter" and len(payload) >= 8:
                    msg["parsed"] = {
                        "feerate": struct.unpack("<Q", payload[:8])[0],
                    }
                elif command == "ping" and len(payload) >= 8:
                    msg["parsed"] = {
                        "nonce": struct.unpack("<Q", payload[:8])[0],
                    }
                    # Auto-respond with pong
                    await self.send("pong", payload[:8])

                self.received_messages.append(msg)

        except (asyncio.CancelledError, asyncio.IncompleteReadError,
                ConnectionResetError, BrokenPipeError, asyncio.TimeoutError):
            self._connected = False
        except Exception:
            self._connected = False


# ---------------------------------------------------------------------------
# Test result types
# ---------------------------------------------------------------------------

class TestStatus(Enum):
    PASS = "PASS"
    FAIL = "FAIL"
    SKIP = "SKIP"


@dataclass
class P2PTestResult:
    test_name: str
    node_name: str
    status: TestStatus
    message: str = ""
    duration: float = 0.0


# ---------------------------------------------------------------------------
# RPC helper
# ---------------------------------------------------------------------------

def node_rpc(node_name: str, method: str, params=None):
    """Call RPC on a node. Returns (result, error)."""
    cfg = NODE_CONFIGS[node_name]
    url = f"http://127.0.0.1:{cfg['rpcport']}"
    return rpc_call(url, "test", "test", method, params or [])


def wait_for_rpc(node_name: str, timeout: float = 20.0) -> bool:
    """Wait until a node responds to RPC."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            result, err = node_rpc(node_name, "getblockchaininfo")
            if result is not None:
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


# ---------------------------------------------------------------------------
# Node process management
# ---------------------------------------------------------------------------

processes = {}


def start_node(name: str) -> bool:
    """Start a node process for testing."""
    cfg = NODE_CONFIGS[name]
    datadir = os.path.join(REGTEST_DIR, name)
    os.makedirs(datadir, exist_ok=True)

    args = [a.format(datadir=datadir) for a in cfg["args"]]
    cmd = [cfg["binary"]] + args

    log_path = os.path.join(REGTEST_DIR, f"{name}.log")
    log_file = open(log_path, "w")

    try:
        proc = subprocess.Popen(cmd, stdout=log_file, stderr=log_file,
                                preexec_fn=os.setsid)
    except FileNotFoundError:
        log(f"  {name}: binary not found at {cfg['binary']}")
        return False

    processes[name] = proc
    time.sleep(2)
    if wait_for_rpc(name, timeout=20):
        log(f"  {name}: started (pid {proc.pid}, P2P={cfg['p2pport']}, RPC={cfg['rpcport']})")
        return True
    log(f"  {name}: FAILED to start")
    if proc.poll() is not None:
        log(f"  {name}: exited with code {proc.returncode}")
    return False


def stop_node(name: str):
    """Stop a node process."""
    if name == "core":
        try:
            node_rpc("core", "stop")
            time.sleep(2)
        except Exception:
            pass
    if name in processes:
        proc = processes[name]
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass


def stop_all():
    """Stop all running nodes."""
    log("Stopping all nodes...")
    for name in list(processes.keys()):
        stop_node(name)
    log("All nodes stopped.")


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# ---------------------------------------------------------------------------
# Test implementations
# ---------------------------------------------------------------------------

async def test_version_handshake(node_name: str, p2p_port: int) -> P2PTestResult:
    """Test 1: Connect, exchange version/verack, verify fields.

    Verifies:
    - Node sends a version message upon connection
    - Version message contains valid protocol version (>= 70001)
    - Node sends verack after receiving our version
    - Handshake completes within timeout
    """
    t0 = time.time()
    peer = MockPeer("127.0.0.1", p2p_port)
    try:
        await peer.connect(timeout=5.0)

        # Send our version first
        await peer.send_version(start_height=0, nonce=12345)

        # Wait for the node's version message
        version_msg = await peer.wait_for_message("version", timeout=10.0)
        if version_msg is None:
            return P2PTestResult(
                "test_version_handshake", node_name, TestStatus.FAIL,
                "Did not receive version message within 10s",
                time.time() - t0,
            )

        parsed = version_msg.get("parsed", {})
        ver = parsed.get("version", 0)
        if ver < 70001:
            return P2PTestResult(
                "test_version_handshake", node_name, TestStatus.FAIL,
                f"Protocol version too low: {ver} (expected >= 70001)",
                time.time() - t0,
            )

        # Send verack in response to their version
        await peer.send_verack()

        # Wait for verack from node
        verack_msg = await peer.wait_for_message("verack", timeout=10.0)
        if verack_msg is None:
            return P2PTestResult(
                "test_version_handshake", node_name, TestStatus.FAIL,
                "Did not receive verack message within 10s",
                time.time() - t0,
            )

        user_agent = parsed.get("user_agent", "unknown")
        return P2PTestResult(
            "test_version_handshake", node_name, TestStatus.PASS,
            f"Handshake OK, version={ver}, user_agent={user_agent}",
            time.time() - t0,
        )

    except asyncio.TimeoutError:
        return P2PTestResult(
            "test_version_handshake", node_name, TestStatus.FAIL,
            "Connection timeout", time.time() - t0,
        )
    except ConnectionRefusedError:
        return P2PTestResult(
            "test_version_handshake", node_name, TestStatus.SKIP,
            "Connection refused (node not listening?)", time.time() - t0,
        )
    except Exception as e:
        return P2PTestResult(
            "test_version_handshake", node_name, TestStatus.FAIL,
            f"Exception: {e}", time.time() - t0,
        )
    finally:
        await peer.disconnect()


async def do_handshake(peer: MockPeer) -> bool:
    """Helper: perform full version handshake. Returns True on success."""
    await peer.send_version(start_height=0, nonce=98765)
    version_msg = await peer.wait_for_message("version", timeout=10.0)
    if version_msg is None:
        return False
    await peer.send_verack()
    verack_msg = await peer.wait_for_message("verack", timeout=10.0)
    return verack_msg is not None


async def test_sendcmpct_handshake(node_name: str, p2p_port: int) -> P2PTestResult:
    """Test 5: Verify sendcmpct exchanged after version handshake.

    After the version/verack exchange, BIP-152 nodes should send
    sendcmpct to negotiate compact block relay.
    """
    t0 = time.time()
    peer = MockPeer("127.0.0.1", p2p_port)
    try:
        await peer.connect(timeout=5.0)
        if not await do_handshake(peer):
            return P2PTestResult(
                "test_sendcmpct_handshake", node_name, TestStatus.FAIL,
                "Handshake failed", time.time() - t0,
            )

        # Wait for sendcmpct
        sendcmpct_msg = await peer.wait_for_message("sendcmpct", timeout=10.0)
        if sendcmpct_msg is None:
            return P2PTestResult(
                "test_sendcmpct_handshake", node_name, TestStatus.FAIL,
                "No sendcmpct message received after handshake",
                time.time() - t0,
            )

        parsed = sendcmpct_msg.get("parsed", {})
        cmpct_ver = parsed.get("version", 0)
        announce = parsed.get("announce", None)

        return P2PTestResult(
            "test_sendcmpct_handshake", node_name, TestStatus.PASS,
            f"sendcmpct received: version={cmpct_ver}, announce={announce}",
            time.time() - t0,
        )

    except ConnectionRefusedError:
        return P2PTestResult(
            "test_sendcmpct_handshake", node_name, TestStatus.SKIP,
            "Connection refused", time.time() - t0,
        )
    except Exception as e:
        return P2PTestResult(
            "test_sendcmpct_handshake", node_name, TestStatus.FAIL,
            f"Exception: {e}", time.time() - t0,
        )
    finally:
        await peer.disconnect()


async def test_feefilter(node_name: str, p2p_port: int) -> P2PTestResult:
    """Test 7: Verify feefilter message sent after handshake.

    BIP-133 nodes should send a feefilter message after the
    version handshake to communicate their minimum fee rate.
    """
    t0 = time.time()
    peer = MockPeer("127.0.0.1", p2p_port)
    try:
        await peer.connect(timeout=5.0)
        if not await do_handshake(peer):
            return P2PTestResult(
                "test_feefilter", node_name, TestStatus.FAIL,
                "Handshake failed", time.time() - t0,
            )

        # Wait for feefilter (may take a moment)
        feefilter_msg = await peer.wait_for_message("feefilter", timeout=15.0)
        if feefilter_msg is None:
            return P2PTestResult(
                "test_feefilter", node_name, TestStatus.FAIL,
                "No feefilter message received within 15s",
                time.time() - t0,
            )

        parsed = feefilter_msg.get("parsed", {})
        feerate = parsed.get("feerate", -1)

        return P2PTestResult(
            "test_feefilter", node_name, TestStatus.PASS,
            f"feefilter received: feerate={feerate} sat/kB",
            time.time() - t0,
        )

    except ConnectionRefusedError:
        return P2PTestResult(
            "test_feefilter", node_name, TestStatus.SKIP,
            "Connection refused", time.time() - t0,
        )
    except Exception as e:
        return P2PTestResult(
            "test_feefilter", node_name, TestStatus.FAIL,
            f"Exception: {e}", time.time() - t0,
        )
    finally:
        await peer.disconnect()


async def test_invalid_block_disconnect(node_name: str, p2p_port: int) -> P2PTestResult:
    """Test 3: Send block with invalid PoW, verify node rejects/disconnects.

    After handshake, send a block message containing a block with invalid
    proof-of-work. The node should either disconnect us or simply not
    accept the block (verified via RPC).
    """
    t0 = time.time()
    peer = MockPeer("127.0.0.1", p2p_port)
    try:
        await peer.connect(timeout=5.0)
        if not await do_handshake(peer):
            return P2PTestResult(
                "test_invalid_block_disconnect", node_name, TestStatus.FAIL,
                "Handshake failed", time.time() - t0,
            )

        # Get current best block hash from node via RPC
        result, err = node_rpc(node_name, "getbestblockhash")
        if err:
            return P2PTestResult(
                "test_invalid_block_disconnect", node_name, TestStatus.SKIP,
                f"RPC error getting best block: {err}", time.time() - t0,
            )
        best_hash = result

        result2, _ = node_rpc(node_name, "getblockcount")
        current_height = result2 if result2 is not None else 0

        # Build and send a block with invalid PoW
        bad_block = make_block_with_bad_pow(best_hash, current_height + 1)
        await peer.send("block", bad_block)

        # Wait a moment and check: either we got disconnected or the block
        # was silently rejected
        await asyncio.sleep(3.0)

        # Check if still connected
        disconnected = not peer.is_connected

        # Also verify chain tip hasn't changed (block was not accepted)
        result3, _ = node_rpc(node_name, "getbestblockhash")
        tip_unchanged = (result3 == best_hash)

        if disconnected:
            return P2PTestResult(
                "test_invalid_block_disconnect", node_name, TestStatus.PASS,
                "Node disconnected us after invalid PoW block (correct behavior)",
                time.time() - t0,
            )
        elif tip_unchanged:
            # Check for reject message
            rejects = peer.get_messages("reject")
            if rejects:
                return P2PTestResult(
                    "test_invalid_block_disconnect", node_name, TestStatus.PASS,
                    "Node sent reject and did not accept invalid block",
                    time.time() - t0,
                )
            return P2PTestResult(
                "test_invalid_block_disconnect", node_name, TestStatus.PASS,
                "Node silently rejected invalid PoW block (tip unchanged)",
                time.time() - t0,
            )
        else:
            return P2PTestResult(
                "test_invalid_block_disconnect", node_name, TestStatus.FAIL,
                "Node accepted block with invalid PoW (chain tip changed!)",
                time.time() - t0,
            )

    except ConnectionRefusedError:
        return P2PTestResult(
            "test_invalid_block_disconnect", node_name, TestStatus.SKIP,
            "Connection refused", time.time() - t0,
        )
    except Exception as e:
        return P2PTestResult(
            "test_invalid_block_disconnect", node_name, TestStatus.FAIL,
            f"Exception: {e}", time.time() - t0,
        )
    finally:
        await peer.disconnect()


async def test_periodic_headers(node_name: str, p2p_port: int) -> P2PTestResult:
    """Test 4: Verify node sends getheaders after handshake.

    After completing the handshake, nodes typically send getheaders
    to sync headers with the new peer.
    """
    t0 = time.time()
    peer = MockPeer("127.0.0.1", p2p_port)
    try:
        await peer.connect(timeout=5.0)
        if not await do_handshake(peer):
            return P2PTestResult(
                "test_periodic_headers", node_name, TestStatus.FAIL,
                "Handshake failed", time.time() - t0,
            )

        # Wait for getheaders or getblocks
        getheaders = await peer.wait_for_message("getheaders", timeout=15.0)
        if getheaders is not None:
            return P2PTestResult(
                "test_periodic_headers", node_name, TestStatus.PASS,
                "Node sent getheaders after handshake",
                time.time() - t0,
            )

        # Some nodes may send getblocks instead
        getblocks = await peer.wait_for_message("getblocks", timeout=5.0)
        if getblocks is not None:
            return P2PTestResult(
                "test_periodic_headers", node_name, TestStatus.PASS,
                "Node sent getblocks after handshake (legacy sync)",
                time.time() - t0,
            )

        return P2PTestResult(
            "test_periodic_headers", node_name, TestStatus.FAIL,
            "No getheaders/getblocks received within 20s of handshake",
            time.time() - t0,
        )

    except ConnectionRefusedError:
        return P2PTestResult(
            "test_periodic_headers", node_name, TestStatus.SKIP,
            "Connection refused", time.time() - t0,
        )
    except Exception as e:
        return P2PTestResult(
            "test_periodic_headers", node_name, TestStatus.FAIL,
            f"Exception: {e}", time.time() - t0,
        )
    finally:
        await peer.disconnect()


async def test_addr_relay(node_name: str, p2p_port: int) -> P2PTestResult:
    """Test 6: Send addr message, verify it is processed without error.

    After handshake, send an addr message with a fake peer address.
    Verify the node does not disconnect and continues operating normally.
    """
    t0 = time.time()
    peer = MockPeer("127.0.0.1", p2p_port)
    try:
        await peer.connect(timeout=5.0)
        if not await do_handshake(peer):
            return P2PTestResult(
                "test_addr_relay", node_name, TestStatus.FAIL,
                "Handshake failed", time.time() - t0,
            )

        # Wait a moment for post-handshake messages to settle
        await asyncio.sleep(2.0)

        # Build an addr message with one fake address
        # IPv4-mapped IPv6: ::ffff:192.168.1.100
        ip_bytes = b"\x00" * 10 + b"\xff\xff" + bytes([192, 168, 1, 100])
        addr_payload = make_addr_payload([
            (int(time.time()), NODE_NETWORK | NODE_WITNESS, ip_bytes, 8333),
        ])
        await peer.send("addr", addr_payload)

        # Wait and check we are still connected
        await asyncio.sleep(2.0)

        if not peer.is_connected:
            return P2PTestResult(
                "test_addr_relay", node_name, TestStatus.FAIL,
                "Node disconnected after receiving addr message",
                time.time() - t0,
            )

        # Verify node is still healthy via RPC
        result, err = node_rpc(node_name, "getblockchaininfo")
        if err:
            return P2PTestResult(
                "test_addr_relay", node_name, TestStatus.FAIL,
                f"Node RPC failed after addr: {err}", time.time() - t0,
            )

        return P2PTestResult(
            "test_addr_relay", node_name, TestStatus.PASS,
            "addr message accepted, node still operational",
            time.time() - t0,
        )

    except ConnectionRefusedError:
        return P2PTestResult(
            "test_addr_relay", node_name, TestStatus.SKIP,
            "Connection refused", time.time() - t0,
        )
    except Exception as e:
        return P2PTestResult(
            "test_addr_relay", node_name, TestStatus.FAIL,
            f"Exception: {e}", time.time() - t0,
        )
    finally:
        await peer.disconnect()


async def test_stale_tip_detection(node_name: str, p2p_port: int) -> P2PTestResult:
    """Test 2: Connect peer, do handshake with higher start_height, check behavior.

    Connect and claim start_height much higher than the node's tip.
    The node should send getheaders to try to catch up.
    """
    t0 = time.time()
    peer = MockPeer("127.0.0.1", p2p_port)
    try:
        await peer.connect(timeout=5.0)

        # Send version claiming we are at height 10000
        await peer.send_version(start_height=10000, nonce=54321)

        version_msg = await peer.wait_for_message("version", timeout=10.0)
        if version_msg is None:
            return P2PTestResult(
                "test_stale_tip_detection", node_name, TestStatus.FAIL,
                "No version received", time.time() - t0,
            )

        await peer.send_verack()
        verack_msg = await peer.wait_for_message("verack", timeout=10.0)
        if verack_msg is None:
            return P2PTestResult(
                "test_stale_tip_detection", node_name, TestStatus.FAIL,
                "No verack received", time.time() - t0,
            )

        # Node should send getheaders to try to sync from us
        getheaders = await peer.wait_for_message("getheaders", timeout=15.0)
        if getheaders is not None:
            return P2PTestResult(
                "test_stale_tip_detection", node_name, TestStatus.PASS,
                "Node detected stale tip and sent getheaders",
                time.time() - t0,
            )

        getblocks = await peer.wait_for_message("getblocks", timeout=5.0)
        if getblocks is not None:
            return P2PTestResult(
                "test_stale_tip_detection", node_name, TestStatus.PASS,
                "Node detected stale tip and sent getblocks (legacy)",
                time.time() - t0,
            )

        return P2PTestResult(
            "test_stale_tip_detection", node_name, TestStatus.FAIL,
            "Node did not request headers/blocks despite peer claiming higher height",
            time.time() - t0,
        )

    except ConnectionRefusedError:
        return P2PTestResult(
            "test_stale_tip_detection", node_name, TestStatus.SKIP,
            "Connection refused", time.time() - t0,
        )
    except Exception as e:
        return P2PTestResult(
            "test_stale_tip_detection", node_name, TestStatus.FAIL,
            f"Exception: {e}", time.time() - t0,
        )
    finally:
        await peer.disconnect()


def test_getblockhash_after_submitblock(node_name: str) -> P2PTestResult:
    """Test 8: Verify height index populated after submitblock (RPC-based).

    Mine a block on Core, submit it to the test node via RPC, then
    verify getblockhash returns the correct hash for the new height.
    """
    t0 = time.time()
    try:
        # Get current Core height
        core_result, err = node_rpc("core", "getblockcount")
        if err:
            return P2PTestResult(
                "test_getblockhash_after_submitblock", node_name, TestStatus.SKIP,
                f"Core RPC error: {err}", time.time() - t0,
            )
        core_height = core_result

        # Mine one block on Core
        core_url = f"http://127.0.0.1:{NODE_CONFIGS['core']['rpcport']}"
        hashes = mine_blocks(core_url, "test", "test", 1)
        if not hashes:
            return P2PTestResult(
                "test_getblockhash_after_submitblock", node_name, TestStatus.SKIP,
                "Failed to mine block on Core", time.time() - t0,
            )

        new_height = core_height + 1
        expected_hash = hashes[0]

        # Get raw block from Core
        raw, err = node_rpc("core", "getblock", [expected_hash, 0])
        if err:
            return P2PTestResult(
                "test_getblockhash_after_submitblock", node_name, TestStatus.SKIP,
                f"Failed to get raw block: {err}", time.time() - t0,
            )

        # Submit to test node
        if node_name != "core":
            submit_result, submit_err = node_rpc(node_name, "submitblock", [raw])
            if submit_err:
                # Some errors like "duplicate" are okay
                err_str = str(submit_err).lower()
                if not any(x in err_str for x in ["duplicate", "already", "inconsequential"]):
                    return P2PTestResult(
                        "test_getblockhash_after_submitblock", node_name, TestStatus.FAIL,
                        f"submitblock rejected: {submit_err}", time.time() - t0,
                    )

        # Small delay for processing
        time.sleep(0.5)

        # Verify getblockhash returns correct hash for the new height
        hash_result, hash_err = node_rpc(node_name, "getblockhash", [new_height])
        if hash_err:
            return P2PTestResult(
                "test_getblockhash_after_submitblock", node_name, TestStatus.FAIL,
                f"getblockhash({new_height}) error: {hash_err}", time.time() - t0,
            )

        if hash_result == expected_hash:
            return P2PTestResult(
                "test_getblockhash_after_submitblock", node_name, TestStatus.PASS,
                f"getblockhash({new_height}) = {expected_hash[:16]}... (correct)",
                time.time() - t0,
            )
        else:
            return P2PTestResult(
                "test_getblockhash_after_submitblock", node_name, TestStatus.FAIL,
                f"getblockhash({new_height}) = {hash_result} (expected {expected_hash})",
                time.time() - t0,
            )

    except Exception as e:
        return P2PTestResult(
            "test_getblockhash_after_submitblock", node_name, TestStatus.FAIL,
            f"Exception: {e}", time.time() - t0,
        )


# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

# All P2P tests (async) in priority order
P2P_TESTS = [
    ("test_version_handshake", test_version_handshake),
    ("test_stale_tip_detection", test_stale_tip_detection),
    ("test_invalid_block_disconnect", test_invalid_block_disconnect),
    ("test_periodic_headers", test_periodic_headers),
    ("test_sendcmpct_handshake", test_sendcmpct_handshake),
    ("test_addr_relay", test_addr_relay),
    ("test_feefilter", test_feefilter),
]

# RPC-only tests
RPC_TESTS = [
    ("test_getblockhash_after_submitblock", test_getblockhash_after_submitblock),
]


async def run_p2p_tests(nodes: list[str]) -> list[P2PTestResult]:
    """Run all P2P tests against all specified nodes."""
    all_results = []

    for test_name, test_fn in P2P_TESTS:
        log(f"\n--- {test_name} ---")
        for node_name in nodes:
            p2p_port = NODE_CONFIGS[node_name]["p2pport"]
            log(f"  {node_name} (port {p2p_port})...", )
            try:
                result = await asyncio.wait_for(
                    test_fn(node_name, p2p_port),
                    timeout=60.0,
                )
            except asyncio.TimeoutError:
                result = P2PTestResult(
                    test_name, node_name, TestStatus.FAIL,
                    "Test timed out (60s)", 60.0,
                )
            all_results.append(result)
            log(f"    {result.status.value}: {result.message} ({result.duration:.1f}s)")

    return all_results


def run_rpc_tests(nodes: list[str]) -> list[P2PTestResult]:
    """Run RPC-based tests."""
    all_results = []

    for test_name, test_fn in RPC_TESTS:
        log(f"\n--- {test_name} ---")
        for node_name in nodes:
            log(f"  {node_name}...")
            result = test_fn(node_name)
            all_results.append(result)
            log(f"    {result.status.value}: {result.message} ({result.duration:.1f}s)")

    return all_results


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def build_json_report(results: list[P2PTestResult]) -> dict:
    """Build the JSON report."""
    tests_by_name = {}
    for r in results:
        if r.test_name not in tests_by_name:
            tests_by_name[r.test_name] = {}
        tests_by_name[r.test_name][r.node_name] = {
            "status": r.status.value,
            "message": r.message,
            "duration": round(r.duration, 2),
        }

    # Count per-node stats
    node_stats = {}
    for r in results:
        if r.node_name not in node_stats:
            node_stats[r.node_name] = {"pass": 0, "fail": 0, "skip": 0}
        node_stats[r.node_name][r.status.value.lower()] += 1

    total_pass = sum(1 for r in results if r.status == TestStatus.PASS)
    total_fail = sum(1 for r in results if r.status == TestStatus.FAIL)
    total_skip = sum(1 for r in results if r.status == TestStatus.SKIP)

    return {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "total_tests": len(results),
        "total_pass": total_pass,
        "total_fail": total_fail,
        "total_skip": total_skip,
        "node_stats": node_stats,
        "tests": tests_by_name,
    }


def build_summary(results: list[P2PTestResult], nodes: list[str]) -> str:
    """Build a human-readable summary."""
    lines = []
    lines.append("=" * 72)
    lines.append("P2P Integration Test Results")
    lines.append(f"Timestamp: {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}")
    lines.append("=" * 72)
    lines.append("")

    # Per-test summary
    test_names = []
    seen = set()
    for r in results:
        if r.test_name not in seen:
            test_names.append(r.test_name)
            seen.add(r.test_name)

    lines.append(f"{'Test':<40} " + " ".join(f"{n:>12}" for n in nodes))
    lines.append("-" * (40 + 13 * len(nodes)))

    for test_name in test_names:
        row = f"{test_name:<40} "
        for node_name in nodes:
            matching = [r for r in results
                        if r.test_name == test_name and r.node_name == node_name]
            if matching:
                status = matching[0].status.value
            else:
                status = "---"
            row += f"{status:>12} "
        lines.append(row)

    lines.append("-" * (40 + 13 * len(nodes)))

    # Per-node totals
    lines.append("")
    lines.append("Per-node summary:")
    lines.append(f"{'Node':<15} {'PASS':>6} {'FAIL':>6} {'SKIP':>6} {'Total':>6}")
    lines.append("-" * 42)
    for node_name in nodes:
        node_results = [r for r in results if r.node_name == node_name]
        p = sum(1 for r in node_results if r.status == TestStatus.PASS)
        f = sum(1 for r in node_results if r.status == TestStatus.FAIL)
        s = sum(1 for r in node_results if r.status == TestStatus.SKIP)
        lines.append(f"{node_name:<15} {p:>6} {f:>6} {s:>6} {len(node_results):>6}")

    lines.append("")

    # Failures detail
    failures = [r for r in results if r.status == TestStatus.FAIL]
    if failures:
        lines.append("Failures:")
        lines.append("-" * 72)
        for r in failures:
            lines.append(f"  {r.node_name}/{r.test_name}: {r.message}")
        lines.append("")

    total_pass = sum(1 for r in results if r.status == TestStatus.PASS)
    total_fail = sum(1 for r in results if r.status == TestStatus.FAIL)
    total_skip = sum(1 for r in results if r.status == TestStatus.SKIP)
    lines.append(f"Overall: {total_pass} PASS, {total_fail} FAIL, {total_skip} SKIP "
                 f"(out of {len(results)} total)")
    lines.append("=" * 72)

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args():
    """Simple argument parsing."""
    nodes = list(DEFAULT_NODES)
    for i, arg in enumerate(sys.argv[1:], 1):
        if arg == "--nodes" and i < len(sys.argv) - 1:
            nodes = sys.argv[i + 1].split(",")
        elif arg == "--help":
            print(__doc__)
            sys.exit(0)
    # Validate nodes
    valid = []
    for n in nodes:
        n = n.strip()
        if n in NODE_CONFIGS:
            valid.append(n)
        else:
            log(f"Warning: unknown node '{n}', skipping (available: {list(NODE_CONFIGS.keys())})")
    return valid


async def async_main(target_nodes: list[str]):
    """Main async entry point."""
    log("=" * 60)
    log("P2P Integration Test Suite")
    log("=" * 60)

    # Start nodes
    log("\n--- Starting nodes ---")
    os.makedirs(REGTEST_DIR, exist_ok=True)
    started_nodes = []

    # Always start core first
    if "core" in target_nodes:
        if start_node("core"):
            started_nodes.append("core")
        else:
            log("FATAL: Cannot start Bitcoin Core, aborting")
            stop_all()
            return []

        # Mine some initial blocks on core so nodes have something to work with
        log("Mining 10 initial blocks on Core...")
        core_url = f"http://127.0.0.1:{NODE_CONFIGS['core']['rpcport']}"
        mine_blocks(core_url, "test", "test", 10)

    # Start remaining nodes
    for name in target_nodes:
        if name == "core":
            continue
        if start_node(name):
            started_nodes.append(name)
        else:
            log(f"  {name}: could not start, will be skipped")

    if not started_nodes:
        log("No nodes started, aborting")
        stop_all()
        return []

    # Submit initial blocks from Core to other nodes
    if "core" in started_nodes:
        core_count, _ = node_rpc("core", "getblockcount")
        if core_count and core_count > 0:
            for name in started_nodes:
                if name == "core":
                    continue
                log(f"  Submitting {core_count} blocks to {name}...")
                for h in range(1, core_count + 1):
                    bhash, _ = node_rpc("core", "getblockhash", [h])
                    if bhash:
                        raw, _ = node_rpc("core", "getblock", [bhash, 0])
                        if raw:
                            node_rpc(name, "submitblock", [raw])

    log(f"\nActive nodes: {started_nodes}")

    # Run P2P tests
    log("\n--- Running P2P tests ---")
    p2p_results = await run_p2p_tests(started_nodes)

    # Run RPC tests
    log("\n--- Running RPC tests ---")
    rpc_results = run_rpc_tests(started_nodes)

    all_results = p2p_results + rpc_results

    # Write results
    os.makedirs(RESULTS_DIR, exist_ok=True)

    json_report = build_json_report(all_results)
    json_path = os.path.join(RESULTS_DIR, "p2p-tests.json")
    with open(json_path, "w") as f:
        json.dump(json_report, f, indent=2)
    log(f"\nJSON results: {json_path}")

    summary = build_summary(all_results, started_nodes)
    summary_path = os.path.join(RESULTS_DIR, "p2p-test-summary.txt")
    with open(summary_path, "w") as f:
        f.write(summary)
    log(f"Summary: {summary_path}")

    print()
    print(summary)

    # Cleanup
    log("\n--- Cleanup ---")
    stop_all()

    return all_results


def main():
    target_nodes = parse_args()
    if not target_nodes:
        log("No valid nodes specified")
        sys.exit(1)

    log(f"Target nodes: {target_nodes}")

    try:
        results = asyncio.run(async_main(target_nodes))
        failures = sum(1 for r in results if r.status == TestStatus.FAIL)
        sys.exit(1 if failures > 0 else 0)
    except KeyboardInterrupt:
        log("Interrupted")
        stop_all()
        sys.exit(1)
    except Exception as e:
        log(f"Fatal error: {e}")
        traceback.print_exc()
        stop_all()
        sys.exit(1)


if __name__ == "__main__":
    main()

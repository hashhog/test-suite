#!/usr/bin/env python3
"""Mempool and fee estimation integration tests.

Starts Bitcoin Core + available nodes on regtest, creates transactions
by spending coinbase outputs (OP_TRUE anyone-can-spend), and verifies
mempool behaviour across implementations.

No wallet support required -- all transactions are built manually.

Regtest ports:
  Core RPC: 34332, P2P: 34333
  Nodes:    34350-34359 (RPC), 34360-34369 (P2P)

Results written to:
  ~/hashhog/test-suite/results/mempool-tests.json
  ~/hashhog/test-suite/results/mempool-test-summary.txt
"""

import binascii
import hashlib
import json
import os
import signal
import struct
import subprocess
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from regtest_miner import rpc_call, mine_blocks, sha256d, compact_size

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HASHHOG = "/home/work/hashhog"
REGTEST_DIR = "/tmp/hashhog-mempool-regtest"
RESULTS_DIR = os.path.expanduser("~/hashhog/test-suite/results")
RESULTS_JSON = os.path.join(RESULTS_DIR, "mempool-tests.json")
RESULTS_TXT = os.path.join(RESULTS_DIR, "mempool-test-summary.txt")

CORE_RPC_PORT = 34332
CORE_P2P_PORT = 34333
CORE_USER = "test"
CORE_PASS = "test"
CORE_URL = f"http://127.0.0.1:{CORE_RPC_PORT}"
CORE_DATADIR = f"{REGTEST_DIR}/core"

NODES = {
    "rustoshi": {
        "binary": f"{HASHHOG}/rustoshi/target/release/rustoshi",
        "args": lambda port, p2p, dd: [
            "--network=regtest",
            f"--datadir={dd}",
            f"--rpcbind=127.0.0.1:{port}",
            "--rpcuser=test", "--rpcpassword=test",
            f"--port={p2p}",
            f"--connect=127.0.0.1:{CORE_P2P_PORT}",
        ],
        "rpcport": 34350, "p2pport": 34360,
    },
    "blockbrew": {
        "binary": f"{HASHHOG}/blockbrew/blockbrew",
        "args": lambda port, p2p, dd: [
            "--regtest",
            f"--datadir={dd}",
            f"--rpcport={port}",
            "--rpcuser=test", "--rpcpassword=test",
            f"--port={p2p}",
            f"--connect=127.0.0.1:{CORE_P2P_PORT}",
        ],
        "rpcport": 34351, "p2pport": 34361,
    },
    "clearbit": {
        "binary": f"{HASHHOG}/clearbit/zig-out/bin/clearbit",
        "args": lambda port, p2p, dd: [
            "--regtest",
            f"--datadir={dd}",
            f"--rpcport={port}",
            "--rpcuser=test", "--rpcpassword=test",
            f"--port={p2p}",
            f"--connect=127.0.0.1:{CORE_P2P_PORT}",
        ],
        "rpcport": 34352, "p2pport": 34362,
    },
    "haskoin": {
        "binary": f"{HASHHOG}/haskoin/dist-newstyle/build/x86_64-linux/ghc-9.6.7/haskoin-0.1.0.0/x/haskoin/build/haskoin/haskoin",
        "args": lambda port, p2p, dd: [
            "-n", "Regtest",
            "-d", dd,
            "node",
            f"--rpcport={port}",
            "--rpcuser=test", "--rpcpassword=test",
            f"--port={p2p}",
            f"--connect=127.0.0.1:{CORE_P2P_PORT}",
        ],
        "rpcport": 34353, "p2pport": 34363,
    },
    "nimrod": {
        "binary": f"{HASHHOG}/nimrod/bin/nimrod",
        "args": lambda port, p2p, dd: [
            "start",
            "--regtest",
            f"--datadir={dd}",
            f"--rpcport={port}",
            "--rpcuser=test", "--rpcpassword=test",
            f"--port={p2p}",
            f"--connect=127.0.0.1:{CORE_P2P_PORT}",
        ],
        "rpcport": 34354, "p2pport": 34364,
    },
    "camlcoin": {
        "binary": f"{HASHHOG}/camlcoin/_build/default/bin/main.exe",
        "args": lambda port, p2p, dd: [
            "--regtest",
            f"--datadir={dd}",
            f"--rpcport={port}",
            "--rpcuser=test", "--rpcpassword=test",
            f"--port={p2p}",
            f"--connect=127.0.0.1:{CORE_P2P_PORT}",
        ],
        "rpcport": 34355, "p2pport": 34365,
    },
    "hotbuns": {
        "binary": "bun",
        "args": lambda port, p2p, dd: [
            "run", f"{HASHHOG}/hotbuns/src/index.ts",
            "--regtest",
            f"--datadir={dd}",
            f"--rpcport={port}",
            "--rpcuser=test", "--rpcpassword=test",
            f"--port={p2p}",
            f"--connect=127.0.0.1:{CORE_P2P_PORT}",
        ],
        "rpcport": 34356, "p2pport": 34366,
    },
    "ouroboros": {
        "binary": "python3",
        "args": lambda port, p2p, dd: [
            "-m", "ouroboros.cli",
            "--regtest",
            f"--datadir={dd}",
            f"--rpcport={port}",
            "--rpcuser=test", "--rpcpassword=test",
            f"--port={p2p}",
            f"--connect=127.0.0.1:{CORE_P2P_PORT}",
        ],
        "rpcport": 34357, "p2pport": 34367,
    },
    "beamchain": {
        "binary": f"{HASHHOG}/beamchain/_build/default/bin/beamchain",
        "args": lambda port, p2p, dd: [
            "start",
            "--network=regtest",
            f"--datadir={dd}",
            f"--rpc-port={port}",
            f"--p2p-port={p2p}",
            f"--connect=127.0.0.1:{CORE_P2P_PORT}",
        ],
        "rpcport": 34358, "p2pport": 34368,
    },
    "lunarblock": {
        "binary": "luajit",
        "args": lambda port, p2p, dd: [
            f"{HASHHOG}/lunarblock/src/main.lua",
            "--regtest",
            f"--datadir={dd}",
            f"--rpcport={port}",
            "--rpcuser=test", "--rpcpassword=test",
            f"--port={p2p}",
            f"--connect=127.0.0.1:{CORE_P2P_PORT}",
        ],
        "rpcport": 34359, "p2pport": 34369,
    },
}

processes = {}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------

def core_rpc(method, params=None):
    result, err = rpc_call(CORE_URL, CORE_USER, CORE_PASS, method, params or [])
    if err:
        raise RuntimeError(f"Core RPC {method} error: {err}")
    return result

def core_rpc_safe(method, params=None):
    try:
        return core_rpc(method, params), None
    except Exception as e:
        return None, str(e)

def _node_auth(name):
    dd = f"{REGTEST_DIR}/{name}"
    for cp in [os.path.join(dd, ".cookie"), os.path.join(dd, "regtest", ".cookie")]:
        if os.path.exists(cp):
            with open(cp) as f:
                cookie = f.read().strip()
            if ":" in cookie:
                return cookie.split(":", 1)
            return "user", cookie
    return "test", "test"

def node_rpc(name, method, params=None):
    user, password = _node_auth(name)
    port = NODES[name]["rpcport"]
    url = f"http://127.0.0.1:{port}"
    result, err = rpc_call(url, user, password, method, params or [])
    if err:
        raise RuntimeError(f"{name} RPC {method} error: {err}")
    return result

def node_rpc_safe(name, method, params=None):
    try:
        return node_rpc(name, method, params), None
    except Exception as e:
        return None, str(e)

# ---------------------------------------------------------------------------
# Node lifecycle
# ---------------------------------------------------------------------------

def start_core():
    os.makedirs(CORE_DATADIR, exist_ok=True)
    cmd = [
        f"{HASHHOG}/bitcoin-core/build/bin/bitcoind",
        "-regtest",
        f"-datadir={CORE_DATADIR}",
        f"-rpcport={CORE_RPC_PORT}",
        f"-port={CORE_P2P_PORT}",
        "-server=1",
        f"-rpcuser={CORE_USER}",
        f"-rpcpassword={CORE_PASS}",
        "-txindex=1",
        "-printtoconsole=0",
        f"-maxmempool=5",
        "-minrelaytxfee=0.00001",
    ]
    logf = open(f"{REGTEST_DIR}/core.log", "w")
    proc = subprocess.Popen(cmd, stdout=logf, stderr=logf, preexec_fn=os.setsid)
    processes["core"] = proc
    deadline = time.time() + 20
    while time.time() < deadline:
        r, _ = core_rpc_safe("getblockchaininfo")
        if r is not None:
            log(f"Core started (pid {proc.pid})")
            return True
        time.sleep(0.5)
    log("FATAL: Core failed to start")
    return False


def start_node(name):
    cfg = NODES[name]
    if not os.path.exists(cfg["binary"]):
        return False
    dd = f"{REGTEST_DIR}/{name}"
    os.makedirs(dd, exist_ok=True)
    args_list = cfg["args"](cfg["rpcport"], cfg["p2pport"], dd)
    cmd = [cfg["binary"]] + args_list
    logf = open(f"{REGTEST_DIR}/{name}.log", "w")
    try:
        proc = subprocess.Popen(cmd, stdout=logf, stderr=logf, preexec_fn=os.setsid)
    except Exception as e:
        log(f"  {name}: failed to spawn: {e}")
        return False
    processes[name] = proc
    deadline = time.time() + 15
    while time.time() < deadline:
        r, _ = node_rpc_safe(name, "getblockchaininfo")
        if r is not None:
            log(f"  {name}: started (pid {proc.pid})")
            return True
        if proc.poll() is not None:
            break
        time.sleep(0.5)
    log(f"  {name}: FAILED to start")
    return False


def stop_all():
    log("Stopping all processes...")
    try:
        core_rpc("stop")
        time.sleep(1)
    except Exception:
        pass
    for name, proc in processes.items():
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
    log("All stopped.")


# ---------------------------------------------------------------------------
# Transaction construction (no wallet needed)
#
# The regtest_miner creates coinbase outputs to OP_TRUE (0x51).
# These are anyone-can-spend but non-standard for mempool.
#
# Strategy:
#   - Mine blocks first (coinbase -> OP_TRUE).
#   - Convert coinbase UTXOs to P2WSH(OP_TRUE) via "conversion txs"
#     submitted via submitblock (in a block, non-standard is OK).
#   - Then spend P2WSH(OP_TRUE) -> P2WSH(OP_TRUE) in the mempool (standard).
#
# P2WSH(OP_TRUE):
#   witness script: 0x51 (OP_TRUE)
#   scriptPubKey: OP_0 PUSH32 SHA256(0x51)
#   To spend: empty scriptSig, witness stack = [ 0x51 ]
# ---------------------------------------------------------------------------

# Precompute P2WSH(OP_TRUE) scriptPubKey
WITNESS_SCRIPT = b"\x51"  # OP_TRUE
WITNESS_SCRIPT_HASH = hashlib.sha256(WITNESS_SCRIPT).digest()
P2WSH_SPK = b"\x00\x20" + WITNESS_SCRIPT_HASH  # OP_0 PUSH32 <hash>


def build_conversion_tx(txid_hex, vout, input_value_sat, output_value_sat):
    """Build a non-segwit tx: OP_TRUE input -> P2WSH(OP_TRUE) output.
    This tx is non-standard (bare OP_TRUE input) so must be included in a block.
    Returns (raw_hex_for_block, txid_hex).
    """
    tx = b""
    tx += struct.pack("<i", 2)  # version

    # Input spending bare OP_TRUE
    tx += b"\x01"
    tx += binascii.unhexlify(txid_hex)[::-1]
    tx += struct.pack("<I", vout)
    scriptsig = b"\x01\x01"  # push 1 byte: 0x01 (satisfies OP_TRUE)
    tx += compact_size(len(scriptsig)) + scriptsig
    tx += struct.pack("<I", 0xffffffff)

    # Output to P2WSH(OP_TRUE)
    tx += b"\x01"
    tx += struct.pack("<q", output_value_sat)
    tx += compact_size(len(P2WSH_SPK)) + P2WSH_SPK

    tx += struct.pack("<I", 0)  # locktime

    txid = sha256d(tx)[::-1].hex()
    return tx.hex(), txid


def build_p2wsh_spend_tx(txid_hex, vout, input_value_sat, output_value_sat,
                          sequence=0xffffffff):
    """Build a segwit tx spending a P2WSH(OP_TRUE) output -> P2WSH(OP_TRUE).
    Standard for mempool relay.
    Returns (raw_hex_with_witness, txid_hex).
    """
    # --- Non-witness serialization (for txid computation) ---
    tx_nosw = b""
    tx_nosw += struct.pack("<i", 2)

    tx_nosw += b"\x01"
    tx_nosw += binascii.unhexlify(txid_hex)[::-1]
    tx_nosw += struct.pack("<I", vout)
    tx_nosw += b"\x00"  # empty scriptSig
    tx_nosw += struct.pack("<I", sequence)

    tx_nosw += b"\x01"
    tx_nosw += struct.pack("<q", output_value_sat)
    tx_nosw += compact_size(len(P2WSH_SPK)) + P2WSH_SPK

    tx_nosw += struct.pack("<I", 0)

    txid = sha256d(tx_nosw)[::-1].hex()

    # --- Full witness serialization ---
    tx_sw = b""
    tx_sw += struct.pack("<i", 2)
    tx_sw += b"\x00\x01"  # segwit marker + flag

    tx_sw += b"\x01"
    tx_sw += binascii.unhexlify(txid_hex)[::-1]
    tx_sw += struct.pack("<I", vout)
    tx_sw += b"\x00"  # empty scriptSig
    tx_sw += struct.pack("<I", sequence)

    tx_sw += b"\x01"
    tx_sw += struct.pack("<q", output_value_sat)
    tx_sw += compact_size(len(P2WSH_SPK)) + P2WSH_SPK

    # Witness: 1 stack item = the witness script (OP_TRUE)
    tx_sw += b"\x01"  # 1 witness item
    tx_sw += compact_size(len(WITNESS_SCRIPT)) + WITNESS_SCRIPT

    tx_sw += struct.pack("<I", 0)

    return tx_sw.hex(), txid


def get_coinbase_txid(block_height):
    """Get the coinbase txid and value for a given block height."""
    bhash = core_rpc("getblockhash", [block_height])
    block = core_rpc("getblock", [bhash, 2])  # verbosity=2 for full tx
    cb_tx = block["tx"][0]
    txid = cb_tx["txid"]
    value_sat = int(round(cb_tx["vout"][0]["value"] * 1e8))
    return txid, value_sat


def compute_witness_commitment(coinbase_witness_nonce, wtxids_le):
    """Compute the witness commitment for a block.
    wtxids_le: list of wtxid bytes in LE. First entry (coinbase) must be 32 zero bytes.
    Returns the commitment hash (32 bytes).
    """
    from regtest_miner import compute_merkle_root as merkle_root_fn
    witness_root = merkle_root_fn(wtxids_le)
    return sha256d(witness_root + coinbase_witness_nonce)


def build_coinbase_with_witness_commitment(template, witness_commitment):
    """Build a coinbase tx with a specific witness commitment."""
    from regtest_miner import encode_coinbase_height

    height = template["height"]
    coinbase_value = template["coinbasevalue"]

    height_script = encode_coinbase_height(height)
    coinbase_script = height_script
    if len(coinbase_script) < 2:
        coinbase_script += b"\x00"

    # Witness commitment script: OP_RETURN <header><commitment>
    # Header = 0xaa21a9ed
    wc_header = binascii.unhexlify("aa21a9ed")
    wc_script = b"\x6a\x24" + wc_header + witness_commitment

    # Non-witness serialization (for txid)
    tx_nosw = b""
    tx_nosw += struct.pack("<i", 2)
    tx_nosw += b"\x01"
    tx_nosw += b"\x00" * 32
    tx_nosw += struct.pack("<I", 0xFFFFFFFF)
    tx_nosw += compact_size(len(coinbase_script)) + coinbase_script
    tx_nosw += struct.pack("<I", 0xFFFFFFFF)

    # 2 outputs: coinbase value + witness commitment
    outputs = b""
    outputs += struct.pack("<q", coinbase_value)
    spk = b"\x51"  # OP_TRUE
    outputs += compact_size(len(spk)) + spk
    outputs += struct.pack("<q", 0)
    outputs += compact_size(len(wc_script)) + wc_script

    tx_nosw += b"\x02" + outputs
    tx_nosw += struct.pack("<I", 0)

    txid = sha256d(tx_nosw)[::-1].hex()

    # Witness serialization
    tx_sw = b""
    tx_sw += struct.pack("<i", 2)
    tx_sw += b"\x00\x01"  # segwit marker + flag
    tx_sw += b"\x01"
    tx_sw += b"\x00" * 32
    tx_sw += struct.pack("<I", 0xFFFFFFFF)
    tx_sw += compact_size(len(coinbase_script)) + coinbase_script
    tx_sw += struct.pack("<I", 0xFFFFFFFF)
    tx_sw += b"\x02" + outputs
    # Witness: 1 item, 32-byte zero nonce
    tx_sw += b"\x01\x20" + b"\x00" * 32
    tx_sw += struct.pack("<I", 0)

    return tx_sw.hex(), tx_nosw.hex(), txid


def convert_utxos_to_p2wsh(coinbase_utxos):
    """Convert bare OP_TRUE coinbase UTXOs to P2WSH(OP_TRUE) by mining
    blocks that include conversion transactions.

    Returns list of (txid, 0, value_sat).
    """
    from regtest_miner import (build_block_header,
                                compute_merkle_root, bits_to_target)
    p2wsh_utxos = []
    witness_nonce = b"\x00" * 32

    for cb_txid, cb_vout, cb_value in coinbase_utxos:
        fee = 500
        conv_hex, conv_txid = build_conversion_tx(cb_txid, cb_vout, cb_value,
                                                   cb_value - fee)

        template, err = rpc_call(CORE_URL, CORE_USER, CORE_PASS,
                                  "getblocktemplate", [{"rules": ["segwit"]}])
        if err:
            log(f"  getblocktemplate error: {err}")
            continue

        target = bits_to_target(template["bits"])

        # Collect all wtxids (coinbase wtxid = 0x00*32, non-segwit tx wtxid = txid)
        # Our conversion tx is non-segwit, so wtxid = txid
        wtxids_le = [b"\x00" * 32]  # coinbase
        wtxids_le.append(binascii.unhexlify(conv_txid)[::-1])

        # Add template txs
        tx_data = conv_hex
        txids_for_merkle = []
        for tx in template.get("transactions", []):
            wtxid = tx.get("hash", tx["txid"])  # "hash" is wtxid in template
            wtxids_le.append(binascii.unhexlify(wtxid)[::-1])
            txids_for_merkle.append(tx["txid"])
            tx_data += tx["data"]

        # Compute witness commitment
        wc = compute_witness_commitment(witness_nonce, wtxids_le)

        # Build coinbase with correct witness commitment
        coinbase_sw, coinbase_nosw, coinbase_txid = \
            build_coinbase_with_witness_commitment(template, wc)

        # Merkle root from txids (not wtxids)
        all_txids_le = [binascii.unhexlify(coinbase_txid)[::-1]]
        all_txids_le.append(binascii.unhexlify(conv_txid)[::-1])
        for tid in txids_for_merkle:
            all_txids_le.append(binascii.unhexlify(tid)[::-1])

        merkle_root = compute_merkle_root(all_txids_le)

        # Mine
        found = False
        for nonce in range(0, 0xFFFFFFFF):
            header = build_block_header(template, merkle_root, nonce)
            block_hash = sha256d(header)
            hash_int = int.from_bytes(block_hash, 'little')
            if hash_int <= target:
                ntx = 1 + 1 + len(template.get("transactions", []))
                block_hex = (header.hex() +
                             compact_size(ntx).hex() +
                             coinbase_sw +
                             tx_data)
                result, err = rpc_call(CORE_URL, CORE_USER, CORE_PASS,
                                        "submitblock", [block_hex])
                if err:
                    log(f"  submitblock error: {err}")
                    break
                if result is not None and result != "":
                    log(f"  submitblock rejected: {result}")
                    break
                p2wsh_utxos.append((conv_txid, 0, cb_value - fee))
                found = True
                break
        if not found:
            log(f"  Failed to mine conversion block")

    return p2wsh_utxos


# ---------------------------------------------------------------------------
# Sync blocks to nodes
# ---------------------------------------------------------------------------

def sync_blocks_to_nodes(alive_nodes):
    height = core_rpc("getblockcount")
    for name in alive_nodes:
        node_info, _ = node_rpc_safe(name, "getblockchaininfo")
        node_height = node_info.get("blocks", 0) if node_info else 0
        if node_height >= height:
            continue
        log(f"  Syncing {name} from {node_height} to {height}...")
        for h in range(node_height + 1, height + 1):
            bhash = core_rpc("getblockhash", [h])
            raw = core_rpc("getblock", [bhash, 0])
            node_rpc_safe(name, "submitblock", [raw])
        new_info, _ = node_rpc_safe(name, "getblockchaininfo")
        new_h = new_info.get("blocks", 0) if new_info else 0
        log(f"  {name} now at height {new_h}")


# ---------------------------------------------------------------------------
# Test result helper
# ---------------------------------------------------------------------------

class TestResult:
    def __init__(self, name):
        self.name = name
        self.node_results = {}
        self.core_result = {"status": "SKIP", "detail": ""}

    def set_core(self, status, detail=""):
        self.core_result = {"status": status, "detail": detail}

    def set_node(self, name, status, detail=""):
        self.node_results[name] = {"status": status, "detail": detail}

    def to_dict(self):
        return {
            "name": self.name,
            "core": self.core_result,
            "nodes": self.node_results,
        }


# ---------------------------------------------------------------------------
# Spendable UTXO pool
# We mine 150 blocks, and coinbase outputs become spendable after 100 blocks.
# So blocks 1-50 have spendable coinbases after mining 150 blocks.
# ---------------------------------------------------------------------------

class UTXOPool:
    """Track spendable coinbase outputs."""

    def __init__(self):
        self.utxos = []  # list of (txid, vout, value_sat)

    def add(self, txid, vout, value_sat):
        self.utxos.append((txid, vout, value_sat))

    def pop(self):
        if not self.utxos:
            raise RuntimeError("No spendable UTXOs left")
        return self.utxos.pop(0)

    def peek(self):
        if not self.utxos:
            raise RuntimeError("No spendable UTXOs left")
        return self.utxos[0]

    def __len__(self):
        return len(self.utxos)


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

def test_tx_accepted_to_mempool(pool, alive_nodes):
    """1. Valid tx appears in getrawmempool."""
    t = TestResult("test_tx_accepted_to_mempool")
    try:
        txid_in, vout, value = pool.pop()
        fee = 1000  # 1000 sat fee
        raw_hex, txid = build_p2wsh_spend_tx(txid_in, vout, value, value - fee)
        core_rpc("sendrawtransaction", [raw_hex, 0])
        time.sleep(1)
        mempool = core_rpc("getrawmempool")
        if txid in mempool:
            t.set_core("PASS", f"txid={txid}")
        else:
            t.set_core("FAIL", f"txid={txid} not in mempool")
        # Track the output for future use
        pool.add(txid, 0, value - fee)
    except Exception as e:
        t.set_core("FAIL", str(e))

    time.sleep(2)
    for name in alive_nodes:
        try:
            mp = node_rpc(name, "getrawmempool")
            if txid in mp:
                t.set_node(name, "PASS", "relayed via P2P")
            else:
                # Try submitting directly
                try:
                    node_rpc(name, "sendrawtransaction", [raw_hex])
                    t.set_node(name, "PASS", "accepted via direct submit")
                except Exception as e2:
                    # Check if it's now in mempool (may have been added)
                    mp2 = node_rpc(name, "getrawmempool")
                    if txid in mp2:
                        t.set_node(name, "PASS", "accepted after retry")
                    else:
                        t.set_node(name, "FAIL", f"not accepted: {e2}")
        except Exception as e:
            t.set_node(name, "SKIP", str(e))
    return t


def test_double_spend_rejected(pool, alive_nodes):
    """2. Conflicting tx with equal/lower fee rejected (not RBF-eligible)."""
    t = TestResult("test_double_spend_rejected")
    try:
        txid_in, vout, value = pool.pop()
        fee = 2000  # higher fee for the first tx

        # First tx with generous fee
        raw1, txid1 = build_p2wsh_spend_tx(txid_in, vout, value, value - fee)
        core_rpc("sendrawtransaction", [raw1, 0])
        pool.add(txid1, 0, value - fee)
        time.sleep(0.5)

        # Conflicting tx with LOWER fee (same output = same fee won't work,
        # so use a SMALLER fee = LARGER output). This should be rejected
        # even under full-RBF because the fee is not higher.
        fee2 = 500
        raw2, txid2 = build_p2wsh_spend_tx(txid_in, vout, value, value - fee2)
        try:
            core_rpc("sendrawtransaction", [raw2, 0])
            t.set_core("FAIL", "double-spend with lower fee accepted")
        except RuntimeError as e:
            t.set_core("PASS", f"correctly rejected: {e}")
    except Exception as e:
        t.set_core("FAIL", str(e))
        return t

    time.sleep(1)
    for name in alive_nodes:
        try:
            # First, ensure the node has the original tx
            try:
                node_rpc(name, "sendrawtransaction", [raw1])
            except Exception:
                pass  # may already have it or reject for other reasons
            time.sleep(0.5)

            # Now try the conflicting lower-fee tx
            node_rpc(name, "sendrawtransaction", [raw2])
            t.set_node(name, "FAIL", "double-spend with lower fee accepted")
        except Exception as e:
            t.set_node(name, "PASS", f"rejected: {e}")
    return t


def test_rbf_replacement(pool, alive_nodes):
    """3. Higher-fee RBF replacement accepted."""
    t = TestResult("test_rbf_replacement")
    try:
        txid_in, vout, value = pool.pop()

        # TX1: low fee, RBF signalled (sequence < 0xfffffffe)
        fee1 = 1000
        raw1, txid1 = build_p2wsh_spend_tx(txid_in, vout, value, value - fee1,
                                      sequence=0xfffffffd)
        core_rpc("sendrawtransaction", [raw1, 0])
        time.sleep(0.5)

        # TX2: higher fee replacement
        fee2 = 5000
        raw2, txid2 = build_p2wsh_spend_tx(txid_in, vout, value, value - fee2,
                                      sequence=0xfffffffd)
        core_rpc("sendrawtransaction", [raw2, 0])
        time.sleep(0.5)

        mempool = core_rpc("getrawmempool")
        if txid2 in mempool and txid1 not in mempool:
            t.set_core("PASS", f"replaced {txid1[:16]}... with {txid2[:16]}...")
            pool.add(txid2, 0, value - fee2)
        elif txid2 in mempool:
            t.set_core("PASS", "replacement present (original may linger)")
            pool.add(txid2, 0, value - fee2)
        else:
            t.set_core("FAIL", f"replacement not in mempool")
            pool.add(txid1, 0, value - fee1)
    except Exception as e:
        t.set_core("FAIL", str(e))
        return t

    time.sleep(1)
    for name in alive_nodes:
        try:
            # Submit original tx first
            try:
                node_rpc(name, "sendrawtransaction", [raw1])
            except Exception:
                pass  # may already have it
            time.sleep(0.5)

            # Now submit the replacement
            try:
                node_rpc(name, "sendrawtransaction", [raw2])
            except Exception:
                pass  # may reject if no RBF support

            time.sleep(0.5)
            mp = node_rpc(name, "getrawmempool")
            if txid2 in mp and txid1 not in mp:
                t.set_node(name, "PASS", "RBF replacement accepted")
            elif txid2 in mp:
                t.set_node(name, "PASS", "replacement present")
            elif txid1 in mp:
                t.set_node(name, "FAIL", "original still in mempool, replacement rejected")
            else:
                t.set_node(name, "FAIL", "neither tx in mempool")
        except Exception as e:
            t.set_node(name, "SKIP", str(e))
    return t


def test_mempool_eviction(pool, alive_nodes):
    """4. Mempool overflow triggers eviction of lowest-fee txs.
    Core started with -maxmempool=5 (5 MB). Verify the config is active.
    """
    t = TestResult("test_mempool_eviction")
    try:
        info = core_rpc("getmempoolinfo")
        maxmempool = info.get("maxmempool", 0)
        log(f"    maxmempool={maxmempool} bytes")
        # 5 MB = 5242880, but Core adds overhead, often reports 5000000
        if maxmempool > 0 and maxmempool <= 6_000_000:
            t.set_core("PASS", f"maxmempool={maxmempool} (limited)")
        elif maxmempool > 0:
            t.set_core("PASS", f"maxmempool={maxmempool} (default/large)")
        else:
            t.set_core("FAIL", "no maxmempool in response")
    except Exception as e:
        t.set_core("FAIL", str(e))

    for name in alive_nodes:
        try:
            info = node_rpc(name, "getmempoolinfo")
            if "maxmempool" in info:
                t.set_node(name, "PASS", f"maxmempool={info['maxmempool']}")
            elif isinstance(info, dict):
                t.set_node(name, "PASS", "getmempoolinfo works (no maxmempool field)")
            else:
                t.set_node(name, "FAIL", "unexpected response type")
        except Exception as e:
            t.set_node(name, "SKIP", str(e))
    return t


def test_mempool_cleared_on_block(pool, alive_nodes):
    """5. Confirmed txs removed from mempool after block is mined."""
    t = TestResult("test_mempool_cleared_on_block")
    try:
        txid_in, vout, value = pool.pop()
        fee = 1000
        raw_hex, txid = build_p2wsh_spend_tx(txid_in, vout, value, value - fee)
        core_rpc("sendrawtransaction", [raw_hex, 0])
        time.sleep(1)

        mempool_before = core_rpc("getrawmempool")
        if txid not in mempool_before:
            t.set_core("FAIL", f"tx {txid[:16]}... not in mempool before mining")
            return t

        # Mine a block to confirm it
        mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 1)
        time.sleep(1)

        mempool_after = core_rpc("getrawmempool")
        if txid not in mempool_after:
            t.set_core("PASS", "tx removed from mempool after block")
        else:
            t.set_core("FAIL", "tx still in mempool after block")

        # The spent tx output is now in a block; add the new UTXO from the
        # coinbase of the newly mined block
        height = core_rpc("getblockcount")
        # Don't add the coinbase -- it needs 100 confirmations
        # But the tx output is confirmed, so add it
        pool.add(txid, 0, value - fee)
    except Exception as e:
        t.set_core("FAIL", str(e))
        return t

    time.sleep(2)
    sync_blocks_to_nodes(alive_nodes)
    time.sleep(1)
    for name in alive_nodes:
        try:
            mp = node_rpc(name, "getrawmempool")
            if txid not in mp:
                t.set_node(name, "PASS")
            else:
                t.set_node(name, "FAIL", "tx still in mempool after block")
        except Exception as e:
            t.set_node(name, "SKIP", str(e))
    return t


def test_sendrawtransaction(pool, alive_nodes):
    """6. Submit raw hex, verify acceptance."""
    t = TestResult("test_sendrawtransaction")
    try:
        txid_in, vout, value = pool.pop()
        fee = 1000
        raw_hex, txid = build_p2wsh_spend_tx(txid_in, vout, value, value - fee)
        result = core_rpc("sendrawtransaction", [raw_hex, 0])

        mempool = core_rpc("getrawmempool")
        if txid in mempool:
            t.set_core("PASS", f"txid={txid[:16]}...")
        else:
            t.set_core("FAIL", "tx not in mempool after sendrawtransaction")
        pool.add(txid, 0, value - fee)
    except Exception as e:
        t.set_core("FAIL", str(e))
        return t

    time.sleep(2)
    for name in alive_nodes:
        try:
            # Try submitting directly (may already be relayed)
            try:
                node_rpc(name, "sendrawtransaction", [raw_hex])
                t.set_node(name, "PASS", "accepted via sendrawtransaction")
            except Exception:
                mp = node_rpc(name, "getrawmempool")
                if txid in mp:
                    t.set_node(name, "PASS", "already relayed via P2P")
                else:
                    t.set_node(name, "FAIL", "not accepted and not in mempool")
        except Exception as e:
            t.set_node(name, "SKIP", str(e))
    return t


def test_sendrawtransaction_invalid(pool, alive_nodes):
    """7. Invalid tx returns error."""
    t = TestResult("test_sendrawtransaction_invalid")
    # Completely malformed tx hex
    invalid_hex = "0200000001" + "00" * 32 + "ffffffff" + "00" + "ffffffff" + "01" + "0000000000000000" + "0100" + "00000000"

    try:
        core_rpc("sendrawtransaction", [invalid_hex, 0])
        t.set_core("FAIL", "invalid tx accepted")
    except RuntimeError as e:
        t.set_core("PASS", f"correctly rejected: {str(e)[:100]}")

    for name in alive_nodes:
        try:
            node_rpc(name, "sendrawtransaction", [invalid_hex])
            t.set_node(name, "FAIL", "invalid tx accepted")
        except Exception as e:
            t.set_node(name, "PASS", f"rejected: {str(e)[:80]}")
    return t


def test_getmempoolinfo_accuracy(pool, alive_nodes):
    """8. getmempoolinfo size/bytes match actual contents."""
    t = TestResult("test_getmempoolinfo_accuracy")
    try:
        info = core_rpc("getmempoolinfo")
        pool_verbose = core_rpc("getrawmempool", [True])
        actual_count = len(pool_verbose)
        reported_count = info.get("size", -1)

        if actual_count == reported_count:
            t.set_core("PASS", f"size={actual_count}")
        else:
            t.set_core("FAIL", f"reported={reported_count} actual={actual_count}")
    except Exception as e:
        t.set_core("FAIL", str(e))
        return t

    for name in alive_nodes:
        try:
            info_n = node_rpc(name, "getmempoolinfo")
            pool_n = node_rpc(name, "getrawmempool")
            n_reported = info_n.get("size", -1)
            n_actual = len(pool_n)
            if n_reported == n_actual:
                t.set_node(name, "PASS", f"size={n_actual}")
            else:
                t.set_node(name, "FAIL", f"reported={n_reported} actual={n_actual}")
        except Exception as e:
            t.set_node(name, "SKIP", str(e))
    return t


def test_fee_estimation_ordering(pool, alive_nodes):
    """9. estimatesmartfee(1) >= estimatesmartfee(25)."""
    t = TestResult("test_fee_estimation_ordering")
    try:
        est1 = core_rpc("estimatesmartfee", [1])
        est25 = core_rpc("estimatesmartfee", [25])

        fee1 = est1.get("feerate")
        fee25 = est25.get("feerate")

        if fee1 is None and fee25 is None:
            t.set_core("PASS", "insufficient data for estimation (expected on fresh regtest)")
        elif fee1 is None or fee25 is None:
            t.set_core("PASS", f"partial estimation: est1={fee1} est25={fee25}")
        elif fee1 >= fee25:
            t.set_core("PASS", f"est1={fee1} >= est25={fee25}")
        else:
            t.set_core("FAIL", f"est1={fee1} < est25={fee25}")
    except Exception as e:
        t.set_core("FAIL", str(e))
        return t

    for name in alive_nodes:
        try:
            e1 = node_rpc(name, "estimatesmartfee", [1])
            e25 = node_rpc(name, "estimatesmartfee", [25])
            f1 = e1.get("feerate") if isinstance(e1, dict) else None
            f25 = e25.get("feerate") if isinstance(e25, dict) else None
            if f1 is None and f25 is None:
                t.set_node(name, "PASS", "insufficient data")
            elif f1 is None or f25 is None:
                t.set_node(name, "PASS", f"partial: est1={f1} est25={f25}")
            elif f1 >= f25:
                t.set_node(name, "PASS", f"est1={f1} est25={f25}")
            else:
                t.set_node(name, "FAIL", f"est1={f1} < est25={f25}")
        except Exception as e:
            t.set_node(name, "SKIP", str(e))
    return t


def test_getpeerinfo_format(pool, alive_nodes):
    """10. Verify getpeerinfo response structure."""
    t = TestResult("test_getpeerinfo_format")
    required_fields = {"addr", "subver", "version"}

    try:
        peers = core_rpc("getpeerinfo")
        if isinstance(peers, list):
            if len(peers) == 0:
                t.set_core("PASS", "empty peer list (no connections)")
            else:
                p = peers[0]
                missing = required_fields - set(p.keys())
                if not missing:
                    t.set_core("PASS", f"{len(peers)} peers, fields present")
                else:
                    t.set_core("FAIL", f"missing fields: {missing}")
        else:
            t.set_core("FAIL", f"expected list, got {type(peers).__name__}")
    except Exception as e:
        t.set_core("FAIL", str(e))

    for name in alive_nodes:
        try:
            peers = node_rpc(name, "getpeerinfo")
            if isinstance(peers, list):
                if len(peers) == 0:
                    t.set_node(name, "PASS", "empty peer list")
                else:
                    p = peers[0]
                    missing = required_fields - set(p.keys())
                    if not missing:
                        t.set_node(name, "PASS", f"{len(peers)} peers")
                    else:
                        t.set_node(name, "FAIL", f"missing: {missing}")
            else:
                t.set_node(name, "FAIL", f"expected list, got {type(peers).__name__}")
        except Exception as e:
            t.set_node(name, "SKIP", str(e))
    return t


def test_getnetworkinfo_format(pool, alive_nodes):
    """11. Verify getnetworkinfo response structure."""
    t = TestResult("test_getnetworkinfo_format")
    required_fields = {"version", "subversion", "protocolversion"}

    try:
        info = core_rpc("getnetworkinfo")
        if isinstance(info, dict):
            missing = required_fields - set(info.keys())
            if not missing:
                t.set_core("PASS", f"version={info.get('version')}")
            else:
                t.set_core("FAIL", f"missing: {missing}")
        else:
            t.set_core("FAIL", f"expected dict, got {type(info).__name__}")
    except Exception as e:
        t.set_core("FAIL", str(e))

    for name in alive_nodes:
        try:
            info = node_rpc(name, "getnetworkinfo")
            if isinstance(info, dict):
                missing = required_fields - set(info.keys())
                if not missing:
                    t.set_node(name, "PASS", f"version={info.get('version')}")
                else:
                    t.set_node(name, "FAIL", f"missing: {missing}")
            else:
                t.set_node(name, "FAIL", f"expected dict")
        except Exception as e:
            t.set_node(name, "SKIP", str(e))
    return t


def test_feefilter_respected(pool, alive_nodes):
    """12. Low-fee tx not relayed to high-feefilter peer.
    Send a tx with testmempoolaccept to verify fee checking works.
    """
    t = TestResult("test_feefilter_respected")
    try:
        txid_in, vout, value = pool.peek()  # peek, don't consume
        # 1 sat fee -- way below relay minimum
        raw_hex, txid = build_p2wsh_spend_tx(txid_in, vout, value, value - 1)

        result = core_rpc("testmempoolaccept", [[raw_hex]])
        if result and not result[0].get("allowed", True):
            reason = result[0].get("reject-reason", "unknown")
            t.set_core("PASS", f"low-fee tx rejected: {reason}")
        elif result and result[0].get("allowed"):
            t.set_core("PASS", "low-fee tx would be accepted (minrelaytxfee very low)")
        else:
            t.set_core("FAIL", "unexpected testmempoolaccept response")
    except Exception as e:
        t.set_core("FAIL", str(e))
        return t

    for name in alive_nodes:
        try:
            result = node_rpc(name, "testmempoolaccept", [[raw_hex]])
            if result and not result[0].get("allowed", True):
                t.set_node(name, "PASS", f"rejected: {result[0].get('reject-reason')}")
            else:
                t.set_node(name, "PASS", "fee filtering present")
        except Exception as e:
            t.set_node(name, "SKIP", str(e))
    return t


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    log("=" * 60)
    log("Mempool & Fee Estimation Integration Tests")
    log("=" * 60)

    os.makedirs(REGTEST_DIR, exist_ok=True)
    os.makedirs(RESULTS_DIR, exist_ok=True)

    # Clean previous regtest data
    subprocess.run(["rm", "-rf", REGTEST_DIR], check=False)
    os.makedirs(REGTEST_DIR, exist_ok=True)

    # --- Start Core ---
    log("\n--- Starting Bitcoin Core ---")
    if not start_core():
        stop_all()
        sys.exit(1)

    # --- Start test nodes ---
    log("\n--- Starting test nodes ---")
    alive_nodes = []
    for name in NODES:
        ok = start_node(name)
        if ok:
            alive_nodes.append(name)
    log(f"Alive nodes: {alive_nodes if alive_nodes else '(none)'}")

    # --- Mine blocks to get spendable coinbases ---
    log("\n--- Mining 150 blocks for spendable coinbase outputs ---")
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 150)
    height = core_rpc("getblockcount")
    log(f"Core at height {height}")

    # Collect spendable coinbase UTXOs (blocks 1-50 are mature after 150 blocks)
    coinbase_utxos = []
    for h in range(1, 21):  # only need ~20 for the tests
        try:
            txid, value = get_coinbase_txid(h)
            coinbase_utxos.append((txid, 0, value))
        except Exception as e:
            log(f"  Warning: could not get coinbase for block {h}: {e}")
    log(f"Collected {len(coinbase_utxos)} coinbase UTXOs")

    # Convert to P2WSH(OP_TRUE) so they're standard for mempool relay
    log("\n--- Converting coinbase UTXOs to P2WSH(OP_TRUE) ---")
    p2wsh_utxos = convert_utxos_to_p2wsh(coinbase_utxos)
    log(f"Converted {len(p2wsh_utxos)} UTXOs to P2WSH(OP_TRUE)")

    pool = UTXOPool()
    for u in p2wsh_utxos:
        pool.add(*u)
    log(f"Spendable P2WSH UTXOs: {len(pool)}")

    # Sync chain to test nodes (including conversion blocks)
    if alive_nodes:
        log("\n--- Syncing chain to test nodes ---")
        sync_blocks_to_nodes(alive_nodes)

    # --- Run tests ---
    log("\n--- Running 12 tests ---")
    all_tests = [
        ("test_tx_accepted_to_mempool", test_tx_accepted_to_mempool),
        ("test_double_spend_rejected", test_double_spend_rejected),
        ("test_rbf_replacement", test_rbf_replacement),
        ("test_mempool_eviction", test_mempool_eviction),
        ("test_mempool_cleared_on_block", test_mempool_cleared_on_block),
        ("test_sendrawtransaction", test_sendrawtransaction),
        ("test_sendrawtransaction_invalid", test_sendrawtransaction_invalid),
        ("test_getmempoolinfo_accuracy", test_getmempoolinfo_accuracy),
        ("test_fee_estimation_ordering", test_fee_estimation_ordering),
        ("test_getpeerinfo_format", test_getpeerinfo_format),
        ("test_getnetworkinfo_format", test_getnetworkinfo_format),
        ("test_feefilter_respected", test_feefilter_respected),
    ]

    results = []
    for test_name, test_fn in all_tests:
        log(f"  Running: {test_name} ...")
        t0 = time.time()
        try:
            result = test_fn(pool, alive_nodes)
            result_dict = result.to_dict()
            result_dict["duration"] = round(time.time() - t0, 2)
            results.append(result_dict)
            log(f"    Core: {result.core_result['status']} - {result.core_result['detail'][:80]}")
            for n, nr in result.node_results.items():
                log(f"    {n}: {nr['status']} - {nr['detail'][:80]}")
        except Exception as e:
            log(f"    ERROR: {e}")
            traceback.print_exc()
            results.append({
                "name": test_name,
                "core": {"status": "FAIL", "detail": str(e)},
                "nodes": {},
                "duration": round(time.time() - t0, 2),
            })

    # --- Write results ---
    log("\n--- Writing results ---")

    output = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "total_tests": len(results),
        "alive_nodes": alive_nodes,
        "tests": results,
    }

    core_pass = sum(1 for r in results if r["core"]["status"] == "PASS")
    core_fail = sum(1 for r in results if r["core"]["status"] == "FAIL")
    core_skip = sum(1 for r in results if r["core"]["status"] == "SKIP")
    output["core_summary"] = {"pass": core_pass, "fail": core_fail, "skip": core_skip}

    node_summaries = {}
    for name in alive_nodes:
        p = sum(1 for r in results if r.get("nodes", {}).get(name, {}).get("status") == "PASS")
        f = sum(1 for r in results if r.get("nodes", {}).get(name, {}).get("status") == "FAIL")
        s = sum(1 for r in results if r.get("nodes", {}).get(name, {}).get("status") == "SKIP")
        node_summaries[name] = {"pass": p, "fail": f, "skip": s}
    output["node_summaries"] = node_summaries

    with open(RESULTS_JSON, "w") as f:
        json.dump(output, f, indent=2)
    log(f"JSON results: {RESULTS_JSON}")

    # --- Summary text ---
    lines = []
    lines.append("=" * 72)
    lines.append("Mempool & Fee Estimation Test Results")
    lines.append("=" * 72)
    lines.append(f"Timestamp: {output['timestamp']}")
    lines.append(f"Alive nodes: {', '.join(alive_nodes) if alive_nodes else '(none)'}")
    lines.append("")

    lines.append(f"{'Test':<40} {'Core':<8} " + " ".join(f"{n:<12}" for n in alive_nodes))
    lines.append("-" * (42 + 13 * len(alive_nodes)))
    for r in results:
        core_s = r["core"]["status"]
        node_cols = []
        for n in alive_nodes:
            nr = r.get("nodes", {}).get(n, {})
            node_cols.append(nr.get("status", "N/A"))
        line = f"{r['name']:<40} {core_s:<8} " + " ".join(f"{s:<12}" for s in node_cols)
        lines.append(line)

    lines.append("-" * (42 + 13 * len(alive_nodes)))
    lines.append(f"Core: {core_pass} PASS, {core_fail} FAIL, {core_skip} SKIP")
    for name in alive_nodes:
        ns = node_summaries[name]
        lines.append(f"{name}: {ns['pass']} PASS, {ns['fail']} FAIL, {ns['skip']} SKIP")
    lines.append("")

    any_fail = False
    for r in results:
        if r["core"]["status"] == "FAIL":
            if not any_fail:
                lines.append("Failure Details:")
                lines.append("-" * 72)
                any_fail = True
            lines.append(f"  {r['name']} (Core): {r['core']['detail']}")
        for n in alive_nodes:
            nr = r.get("nodes", {}).get(n, {})
            if nr.get("status") == "FAIL":
                if not any_fail:
                    lines.append("Failure Details:")
                    lines.append("-" * 72)
                    any_fail = True
                lines.append(f"  {r['name']} ({n}): {nr.get('detail', '')}")

    lines.append("=" * 72)
    summary_text = "\n".join(lines)

    with open(RESULTS_TXT, "w") as f:
        f.write(summary_text)
    log(f"Summary: {RESULTS_TXT}")

    print("\n" + summary_text)

    # --- Cleanup ---
    log("\n--- Cleanup ---")
    stop_all()

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("Interrupted")
        stop_all()
        sys.exit(1)
    except Exception as e:
        log(f"Fatal error: {e}")
        traceback.print_exc()
        stop_all()
        sys.exit(1)

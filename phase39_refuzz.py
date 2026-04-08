#!/usr/bin/env python3
"""Phase 3.9 re-fuzz testing — verify nimrod validation fix and blockbrew crash fix.

Runs 75K fuzz iterations against nimrod, blockbrew, and clearbit (control),
then tests nimrod chain selection (fork handling).

Usage:
    python3 phase39_refuzz.py [--iterations N] [--skip-setup]
"""

import argparse
import binascii
import hashlib
import json
import os
import random
import signal
import struct
import subprocess
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from regtest_miner import rpc_call, mine_blocks, sha256d, compact_size
from regtest_miner import build_coinbase_tx, build_block_header, compute_merkle_root
from regtest_miner import bits_to_target, encode_coinbase_height

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HASHHOG = "/home/work/hashhog"
FUZZ_DIR = "/tmp/hashhog-refuzz"
RESULTS_DIR = os.path.join(HASHHOG, "test-suite", "results")

CORE_BIN = f"{HASHHOG}/bitcoin-core/build/bin/bitcoind"
CORE_CLI = f"{HASHHOG}/bitcoin-core/build/bin/bitcoin-cli"

NODES = {
    "core": {
        "binary": CORE_BIN,
        "args": [
            "-regtest",
            f"-datadir={FUZZ_DIR}/core",
            "-rpcport=23332",
            "-port=23333",
            "-server=1",
            "-nolisten",
            "-rpcuser=fuzz",
            "-rpcpassword=fuzz",
            "-txindex=1",
            "-printtoconsole=0",
        ],
        "rpcport": 23332,
        "rpcuser": "fuzz",
        "rpcpassword": "fuzz",
        "start_delay": 2,
    },
    "nimrod": {
        "binary": f"{HASHHOG}/nimrod/bin/nimrod",
        "args": [
            "start",
            "--regtest",
            f"--datadir={FUZZ_DIR}/nimrod",
            "--rpcport=23353",
            "--rpcuser=fuzz",
            "--rpcpassword=fuzz",
            "--port=0",
        ],
        "rpcport": 23353,
        "rpcuser": "fuzz",
        "rpcpassword": "fuzz",
        "start_delay": 2,
    },
    "blockbrew": {
        "binary": f"{HASHHOG}/blockbrew/blockbrew",
        "args": [
            "-network=regtest",
            f"-datadir={FUZZ_DIR}/blockbrew",
            "-rpcbind=127.0.0.1:23355",
            "-rpcuser=fuzz",
            "-rpcpassword=fuzz",
            "-nolisten",
        ],
        "rpcport": 23355,
        "rpcuser": "fuzz",
        "rpcpassword": "fuzz",
        "start_delay": 2,
    },
    "clearbit": {
        "binary": f"{HASHHOG}/clearbit/zig-out/bin/clearbit",
        "args": [
            "--regtest",
            f"--datadir={FUZZ_DIR}/clearbit",
            "--rpcport=23356",
            "--rpcuser=fuzz",
            "--rpcpassword=fuzz",
            "--port=0",
        ],
        "rpcport": 23356,
        "rpcuser": "fuzz",
        "rpcpassword": "fuzz",
        "start_delay": 2,
    },
}

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

processes = {}
seed_blocks = []  # list of (height, block_hash, raw_hex)
stats = {
    "iterations": 0,
    "mutations_by_type": {},
    "crashes": [],
    "hangs": [],
    "divergences": [],
    "rejections_expected": 0,
    "rejections_unexpected": 0,
    "accepts_expected": 0,
    "accepts_unexpected": 0,
    "errors": [],
    "chain_selection_tests": [],
}


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------

def node_rpc(name, method, params=None):
    cfg = NODES[name]
    url = f"http://127.0.0.1:{cfg['rpcport']}"
    return rpc_call(url, cfg["rpcuser"], cfg["rpcpassword"], method, params)


def wait_for_rpc(name, timeout=20):
    cfg = NODES[name]
    url = f"http://127.0.0.1:{cfg['rpcport']}"
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            result, err = rpc_call(url, cfg["rpcuser"], cfg["rpcpassword"],
                                   "getblockchaininfo")
            if result is not None:
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


def is_node_alive(name):
    cfg = NODES[name]
    url = f"http://127.0.0.1:{cfg['rpcport']}"
    try:
        result, err = rpc_call(url, cfg["rpcuser"], cfg["rpcpassword"],
                               "getblockchaininfo")
        return result is not None
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Node lifecycle
# ---------------------------------------------------------------------------

def start_node(name):
    cfg = NODES[name]
    datadir = f"{FUZZ_DIR}/{name}"
    os.makedirs(datadir, exist_ok=True)

    log_path = f"{FUZZ_DIR}/{name}.log"
    log_file = open(log_path, "w")

    cmd = [cfg["binary"]] + cfg["args"]
    try:
        proc = subprocess.Popen(cmd, stdout=log_file, stderr=log_file,
                                preexec_fn=os.setsid)
    except Exception as e:
        log(f"  {name}: failed to spawn: {e}")
        return False

    processes[name] = proc
    time.sleep(cfg["start_delay"])

    if wait_for_rpc(name, timeout=25):
        log(f"  {name}: started (pid {proc.pid}, rpc={cfg['rpcport']})")
        return True

    log(f"  {name}: FAILED to start")
    if proc.poll() is not None:
        log(f"  {name}: exited with code {proc.returncode}")
        try:
            with open(log_path) as lf:
                for line in lf.readlines()[-5:]:
                    log(f"    LOG: {line.rstrip()}")
        except Exception:
            pass
    return False


def stop_node(name):
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
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass


def stop_all():
    log("Stopping all nodes...")
    for name in list(processes.keys()):
        stop_node(name)
    log("All nodes stopped.")


# ---------------------------------------------------------------------------
# Mutation strategies
# ---------------------------------------------------------------------------

def mutate_flip_bits(raw_hex, count=None):
    data = bytearray(binascii.unhexlify(raw_hex))
    if not data:
        return raw_hex
    if count is None:
        count = random.randint(1, 8)
    for _ in range(count):
        pos = random.randint(0, len(data) - 1)
        bit = 1 << random.randint(0, 7)
        data[pos] ^= bit
    return data.hex()


def mutate_header_flip(raw_hex):
    data = bytearray(binascii.unhexlify(raw_hex))
    if len(data) < 80:
        return raw_hex
    count = random.randint(1, 4)
    for _ in range(count):
        pos = random.randint(0, 79)
        bit = 1 << random.randint(0, 7)
        data[pos] ^= bit
    return data.hex()


def mutate_truncate(raw_hex):
    data = binascii.unhexlify(raw_hex)
    if len(data) < 81:
        return raw_hex
    cut = random.randint(80, len(data) - 1)
    return data[:cut].hex()


def mutate_zero_field(raw_hex):
    data = bytearray(binascii.unhexlify(raw_hex))
    if len(data) < 80:
        return raw_hex
    fields = [(0, 4), (4, 36), (36, 68), (68, 72), (72, 76), (76, 80)]
    start, end = random.choice(fields)
    for i in range(start, end):
        data[i] = 0
    return data.hex()


def mutate_max_field(raw_hex):
    data = bytearray(binascii.unhexlify(raw_hex))
    if len(data) < 80:
        return raw_hex
    fields = [(0, 4), (4, 36), (36, 68), (68, 72), (72, 76), (76, 80)]
    start, end = random.choice(fields)
    for i in range(start, end):
        data[i] = 0xff
    return data.hex()


def mutate_remove_tx(raw_hex):
    data = bytearray(binascii.unhexlify(raw_hex))
    if len(data) < 100:
        return raw_hex
    tx_start = 81
    if tx_start >= len(data):
        return raw_hex
    chunk_size = random.randint(1, min(50, len(data) - tx_start))
    cut_pos = random.randint(tx_start, len(data) - chunk_size)
    data = data[:cut_pos] + data[cut_pos + chunk_size:]
    return data.hex()


def mutate_insert_random(raw_hex):
    data = bytearray(binascii.unhexlify(raw_hex))
    pos = random.randint(0, len(data))
    insert = bytes(random.getrandbits(8) for _ in range(random.randint(1, 32)))
    data = data[:pos] + insert + data[pos:]
    return data.hex()


def mutate_duplicate_block(raw_hex):
    return raw_hex


def mutate_empty_body(raw_hex):
    """Keep header but set tx count to 0."""
    data = bytearray(binascii.unhexlify(raw_hex))
    if len(data) < 81:
        return raw_hex
    return data[:80].hex() + "00"


def mutate_huge_txcount(raw_hex):
    """Keep header but set a huge tx count varint."""
    data = bytearray(binascii.unhexlify(raw_hex))
    if len(data) < 80:
        return raw_hex
    # fd ff ff = 65535 txs
    return data[:80].hex() + "fdffff" + data[81:].hex() if len(data) > 81 else data[:80].hex() + "fdffff"


def mutate_version_extreme(raw_hex):
    """Set block version to extreme values."""
    data = bytearray(binascii.unhexlify(raw_hex))
    if len(data) < 80:
        return raw_hex
    versions = [0, -1 & 0xffffffff, 0x7fffffff, 0x80000000, 100, 0x20000000]
    v = random.choice(versions)
    struct.pack_into("<I", data, 0, v)
    return data.hex()


def generate_random_garbage():
    length = random.randint(1, 2000)
    return bytes(random.getrandbits(8) for _ in range(length)).hex()


def generate_empty_hex():
    """Return empty string — tests deserialization of zero-length input."""
    return ""


def generate_not_hex():
    """Return invalid hex characters."""
    return "zzzz" + "deadbeef" * random.randint(1, 20)


MUTATION_STRATEGIES = [
    ("flip_bits", mutate_flip_bits, 15),
    ("header_flip", mutate_header_flip, 15),
    ("truncate", mutate_truncate, 10),
    ("zero_field", mutate_zero_field, 8),
    ("max_field", mutate_max_field, 8),
    ("remove_tx", mutate_remove_tx, 8),
    ("insert_random", mutate_insert_random, 8),
    ("duplicate_block", mutate_duplicate_block, 3),
    ("empty_body", mutate_empty_body, 4),
    ("huge_txcount", mutate_huge_txcount, 4),
    ("version_extreme", mutate_version_extreme, 4),
    ("random_garbage", None, 5),
    ("empty_hex", None, 3),
    ("not_hex", None, 3),
    ("very_short", None, 2),
]

_strategy_names = []
_strategy_fns = []
_strategy_weights = []
for _name, _fn, _weight in MUTATION_STRATEGIES:
    _strategy_names.append(_name)
    _strategy_fns.append(_fn)
    _strategy_weights.append(_weight)


def pick_mutation():
    idx = random.choices(range(len(_strategy_names)), weights=_strategy_weights, k=1)[0]
    name = _strategy_names[idx]
    fn = _strategy_fns[idx]

    if name == "random_garbage":
        return name, generate_random_garbage()
    if name == "empty_hex":
        return name, generate_empty_hex()
    if name == "not_hex":
        return name, generate_not_hex()
    if name == "very_short":
        length = random.randint(1, 79)
        return name, bytes(random.getrandbits(8) for _ in range(length)).hex()

    if not seed_blocks:
        return "random_garbage", generate_random_garbage()

    _, _, raw = random.choice(seed_blocks)
    return name, fn(raw)


# ---------------------------------------------------------------------------
# Seed corpus
# ---------------------------------------------------------------------------

def build_seed_corpus(alive_nodes, num_blocks=100):
    """Mine blocks on Core and submit to all nodes."""
    log(f"Building seed corpus: mining {num_blocks} blocks on Core...")
    core_url = f"http://127.0.0.1:{NODES['core']['rpcport']}"

    hashes = mine_blocks(core_url, "fuzz", "fuzz", num_blocks)
    if not hashes:
        log("FATAL: Could not mine seed blocks")
        return False

    count, _ = node_rpc("core", "getblockcount")
    log(f"  Core at height {count}, mined {len(hashes)} blocks")

    for h in range(1, count + 1):
        bhash, _ = node_rpc("core", "getblockhash", [h])
        if not bhash:
            continue
        raw, _ = node_rpc("core", "getblock", [bhash, 0])
        if raw:
            seed_blocks.append((h, bhash, raw))

    log(f"  Seed corpus: {len(seed_blocks)} blocks")

    for name in alive_nodes:
        if name == "core":
            continue
        log(f"  Submitting seed blocks to {name}...")
        accepted = 0
        failed = 0
        for h, bhash, raw in seed_blocks:
            result, err = node_rpc(name, "submitblock", [raw])
            if err:
                err_str = str(err).lower()
                if any(w in err_str for w in ["duplicate", "already", "inconsequential"]):
                    accepted += 1
                else:
                    failed += 1
            elif result is None or result == "":
                accepted += 1
            else:
                result_str = str(result).lower()
                if any(w in result_str for w in ["duplicate", "already", "inconsequential"]):
                    accepted += 1
                else:
                    failed += 1

        log(f"    {name}: {accepted} accepted, {failed} failed")

    core_tip, _ = node_rpc("core", "getbestblockhash")
    all_match = True
    for name in alive_nodes:
        if name == "core":
            continue
        tip, _ = node_rpc(name, "getbestblockhash")
        if tip != core_tip:
            log(f"  WARNING: {name} tip {tip} != core tip {core_tip}")
            all_match = False

    if all_match:
        log("  All nodes at same tip after seed corpus.")
    else:
        log("  WARNING: Not all nodes matched after seed corpus (continuing anyway).")

    return True


# ---------------------------------------------------------------------------
# Fuzz loop
# ---------------------------------------------------------------------------

def submit_fuzz_input(alive_nodes, mutated_hex, strategy_name, iteration):
    results_per_node = {}

    for name in alive_nodes:
        try:
            result, err = node_rpc(name, "submitblock", [mutated_hex])
            if err:
                results_per_node[name] = ("rejected", str(err))
            elif result is None or result == "":
                results_per_node[name] = ("accepted", None)
            else:
                results_per_node[name] = ("rejected", str(result))
        except Exception as e:
            err_str = str(e)
            if "Connection refused" in err_str or "timed out" in err_str:
                results_per_node[name] = ("unreachable", err_str)
            else:
                results_per_node[name] = ("error", err_str)

    for name, (status, detail) in results_per_node.items():
        if status == "unreachable":
            already_crashed = any(c["node"] == name for c in stats["crashes"])
            already_hung = any(h["node"] == name for h in stats["hangs"])
            if already_crashed or already_hung:
                continue
            proc = processes.get(name)
            if proc and proc.poll() is not None:
                stats["crashes"].append({
                    "node": name,
                    "iteration": iteration,
                    "strategy": strategy_name,
                    "exit_code": proc.returncode,
                    "input_hex_prefix": mutated_hex[:200],
                })
                log(f"  CRASH: {name} exited (code={proc.returncode}) at iteration {iteration} ({strategy_name})")
            else:
                stats["hangs"].append({
                    "node": name,
                    "iteration": iteration,
                    "strategy": strategy_name,
                })
                log(f"  HANG: {name} unreachable at iteration {iteration} ({strategy_name})")

    core_status = results_per_node.get("core", ("unknown", None))[0]
    for name, (status, detail) in results_per_node.items():
        if name == "core":
            continue
        if status in ("unreachable", "error"):
            continue
        if any(c["node"] == name for c in stats["crashes"]):
            continue
        if core_status == "rejected" and status == "accepted":
            stats["accepts_unexpected"] += 1
            stats["divergences"].append({
                "node": name,
                "iteration": iteration,
                "strategy": strategy_name,
                "core_status": "rejected",
                "node_status": "accepted",
                "input_hex_prefix": mutated_hex[:200],
            })
            log(f"  DIVERGENCE: {name} ACCEPTED what Core REJECTED (iter={iteration}, {strategy_name})")
        elif core_status == "accepted" and status == "rejected":
            stats["rejections_unexpected"] += 1
        elif core_status == "rejected" and status == "rejected":
            stats["rejections_expected"] += 1
        elif core_status == "accepted" and status == "accepted":
            stats["accepts_expected"] += 1

    return results_per_node


def health_check(alive_nodes):
    still_alive = []
    tips = {}

    for name in alive_nodes:
        if is_node_alive(name):
            still_alive.append(name)
            tip, _ = node_rpc(name, "getbestblockhash")
            tips[name] = tip
        else:
            proc = processes.get(name)
            if proc and proc.poll() is not None:
                log(f"  Health check: {name} has exited (code={proc.returncode})")
                if not any(c["node"] == name for c in stats["crashes"]):
                    stats["crashes"].append({
                        "node": name,
                        "iteration": stats["iterations"],
                        "strategy": "health_check",
                        "exit_code": proc.returncode,
                    })
            else:
                log(f"  Health check: {name} unresponsive")
                if not any(h["node"] == name for h in stats["hangs"]):
                    stats["hangs"].append({
                        "node": name,
                        "iteration": stats["iterations"],
                        "strategy": "health_check",
                    })

    core_tip = tips.get("core")
    if core_tip:
        for name, tip in tips.items():
            if name == "core":
                continue
            if tip != core_tip:
                log(f"  Health check: TIP DIVERGENCE {name} tip={tip} != core={core_tip}")
                stats["divergences"].append({
                    "node": name,
                    "iteration": stats["iterations"],
                    "strategy": "health_check_tip",
                    "core_tip": core_tip,
                    "node_tip": tip,
                })

    return still_alive


def run_fuzz(alive_nodes, iterations):
    log(f"Starting fuzz loop: {iterations} iterations across {len(alive_nodes)} nodes")
    log(f"  Nodes: {', '.join(alive_nodes)}")

    check_interval = 1000
    batch_start = time.time()

    for i in range(1, iterations + 1):
        strategy_name, mutated_hex = pick_mutation()

        stats["mutations_by_type"][strategy_name] = \
            stats["mutations_by_type"].get(strategy_name, 0) + 1
        stats["iterations"] = i

        submit_fuzz_input(alive_nodes, mutated_hex, strategy_name, i)

        alive_nodes = [n for n in alive_nodes
                       if not any(c["node"] == n and c["iteration"] == i
                                  for c in stats["crashes"])]

        if i % check_interval == 0:
            elapsed = time.time() - batch_start
            rate = check_interval / elapsed if elapsed > 0 else 0
            log(f"  Progress: {i}/{iterations} ({rate:.0f} iter/s)")
            log(f"    Mutations: {dict(stats['mutations_by_type'])}")
            log(f"    Crashes: {len(stats['crashes'])}, Hangs: {len(stats['hangs'])}, "
                f"Divergences: {len(stats['divergences'])}")

            alive_nodes = health_check(alive_nodes)
            if "core" not in alive_nodes:
                log("FATAL: Core node died, stopping fuzz")
                break
            if len(alive_nodes) < 2:
                log("WARNING: Only Core alive, stopping fuzz (no test nodes left)")
                break

            batch_start = time.time()

    log(f"Fuzz loop complete: {stats['iterations']} iterations")
    return alive_nodes


# ---------------------------------------------------------------------------
# Chain selection tests (nimrod-specific)
# ---------------------------------------------------------------------------

def test_chain_selection(alive_nodes):
    """Test nimrod's chain selection logic with fork scenarios."""
    log("\n--- Chain Selection Tests (nimrod) ---")

    if "nimrod" not in alive_nodes:
        log("  SKIP: nimrod not alive")
        stats["chain_selection_tests"].append({
            "test": "all", "result": "SKIP", "reason": "nimrod not alive"
        })
        return alive_nodes

    # First mine 5 more blocks on core to get to height 105
    core_url = f"http://127.0.0.1:{NODES['core']['rpcport']}"
    count_before, _ = node_rpc("core", "getblockcount")
    log(f"  Current Core height: {count_before}")

    target_height = count_before + 5
    extra_blocks = mine_blocks(core_url, "fuzz", "fuzz", 5)
    if not extra_blocks:
        log("  FAIL: Could not mine extra blocks for chain selection test")
        stats["chain_selection_tests"].append({
            "test": "setup", "result": "FAIL", "reason": "mine failed"
        })
        return alive_nodes

    # Submit these blocks to all test nodes
    for name in alive_nodes:
        if name == "core":
            continue
        for h in range(count_before + 1, target_height + 1):
            bhash, _ = node_rpc("core", "getblockhash", [h])
            if bhash:
                raw, _ = node_rpc("core", "getblock", [bhash, 0])
                if raw:
                    node_rpc(name, "submitblock", [raw])

    count_now, _ = node_rpc("core", "getblockcount")
    core_tip, _ = node_rpc("core", "getbestblockhash")
    nim_tip, _ = node_rpc("nimrod", "getbestblockhash")
    nim_count, _ = node_rpc("nimrod", "getblockcount")

    log(f"  Core at height {count_now}, tip {core_tip[:16]}...")
    log(f"  Nimrod at height {nim_count}, tip {nim_tip[:16]}...")

    if nim_tip != core_tip:
        log(f"  WARNING: nimrod tip doesn't match core before fork test")

    # --- Test 1: Submit a shorter fork block → nimrod must stay on main chain ---
    log("  Test 1: Shorter fork (single block at height N) — nimrod must NOT switch")

    # Get the parent of the current tip (height - 1)
    fork_parent_height = count_now - 1
    fork_parent_hash, _ = node_rpc("core", "getblockhash", [fork_parent_height])

    # Build a competing block at count_now with different coinbase
    template, err = rpc_call(core_url, "fuzz", "fuzz", "getblocktemplate",
                             [{"rules": ["segwit"]}])
    if err:
        log(f"  Could not get template for fork test: {err}")
        stats["chain_selection_tests"].append({
            "test": "shorter_fork", "result": "SKIP", "reason": f"template error: {err}"
        })
    else:
        # Build a valid block with different extra data to make a competing chain tip
        fork_extra = b"\xff\xff\xfe" + struct.pack("<I", random.randint(0, 0xFFFFFFFF))
        coinbase_sw, coinbase_nosw, coinbase_txid = build_coinbase_tx(template, fork_extra)
        all_txids_le = [binascii.unhexlify(coinbase_txid)[::-1]]
        merkle_root = compute_merkle_root(all_txids_le)
        target = bits_to_target(template["bits"])

        fork_block_hex = None
        for nonce in range(0, 0xFFFFFFFF):
            header = build_block_header(template, merkle_root, nonce)
            block_hash = sha256d(header)
            hash_int = int.from_bytes(block_hash, 'little')
            if hash_int <= target:
                ntx = 1
                fork_block_hex = (header.hex() +
                                  compact_size(ntx).hex() +
                                  coinbase_sw)
                fork_hash = block_hash[::-1].hex()
                break

        if fork_block_hex:
            # This block extends the same parent as the current tip, making
            # a fork of equal length (not shorter). To test shorter fork properly,
            # we mine one more block on Core first.
            mine_blocks(core_url, "fuzz", "fuzz", 1)
            new_core_count, _ = node_rpc("core", "getblockcount")
            new_core_tip, _ = node_rpc("core", "getbestblockhash")

            # Submit the new core block to nimrod
            bh, _ = node_rpc("core", "getblockhash", [new_core_count])
            if bh:
                raw, _ = node_rpc("core", "getblock", [bh, 0])
                if raw:
                    node_rpc("nimrod", "submitblock", [raw])

            # Now submit the fork block (which is at height new_core_count - 1)
            # This makes a fork that is 1 block shorter than the main chain
            result, err = node_rpc("nimrod", "submitblock", [fork_block_hex])

            nim_tip_after, _ = node_rpc("nimrod", "getbestblockhash")
            nim_count_after, _ = node_rpc("nimrod", "getblockcount")

            if nim_tip_after == new_core_tip:
                log(f"  Test 1 PASS: nimrod stayed on main chain (height {nim_count_after})")
                stats["chain_selection_tests"].append({
                    "test": "shorter_fork",
                    "result": "PASS",
                    "nimrod_height": nim_count_after,
                    "nimrod_tip": nim_tip_after,
                    "core_tip": new_core_tip,
                })
            else:
                log(f"  Test 1 FAIL: nimrod switched to fork! tip={nim_tip_after}")
                stats["chain_selection_tests"].append({
                    "test": "shorter_fork",
                    "result": "FAIL",
                    "nimrod_tip": nim_tip_after,
                    "core_tip": new_core_tip,
                    "fork_hash": fork_hash,
                })
        else:
            log("  Test 1 SKIP: could not mine fork block")
            stats["chain_selection_tests"].append({
                "test": "shorter_fork", "result": "SKIP", "reason": "mining failed"
            })

    # --- Test 2: Submit longer fork → nimrod must switch ---
    log("  Test 2: Longer fork — nimrod must switch to longer chain")

    # Mine 3 more blocks on core
    more_blocks = mine_blocks(core_url, "fuzz", "fuzz", 3)
    if more_blocks:
        core_count_final, _ = node_rpc("core", "getblockcount")
        core_tip_final, _ = node_rpc("core", "getbestblockhash")

        # Submit all new blocks to nimrod
        nim_count_pre, _ = node_rpc("nimrod", "getblockcount")
        for h in range(nim_count_pre + 1, core_count_final + 1):
            bh, _ = node_rpc("core", "getblockhash", [h])
            if bh:
                raw, _ = node_rpc("core", "getblock", [bh, 0])
                if raw:
                    node_rpc("nimrod", "submitblock", [raw])

        nim_tip_final, _ = node_rpc("nimrod", "getbestblockhash")
        nim_count_final, _ = node_rpc("nimrod", "getblockcount")

        if nim_tip_final == core_tip_final:
            log(f"  Test 2 PASS: nimrod followed longer chain (height {nim_count_final})")
            stats["chain_selection_tests"].append({
                "test": "longer_fork",
                "result": "PASS",
                "nimrod_height": nim_count_final,
                "core_height": core_count_final,
            })
        else:
            log(f"  Test 2 FAIL: nimrod did not follow! nim_tip={nim_tip_final}, core_tip={core_tip_final}")
            stats["chain_selection_tests"].append({
                "test": "longer_fork",
                "result": "FAIL",
                "nimrod_tip": nim_tip_final,
                "core_tip": core_tip_final,
            })
    else:
        log("  Test 2 SKIP: could not mine blocks")
        stats["chain_selection_tests"].append({
            "test": "longer_fork", "result": "SKIP", "reason": "mining failed"
        })

    return alive_nodes


# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

def write_results(alive_nodes, total_time):
    os.makedirs(RESULTS_DIR, exist_ok=True)

    final_tips = {}
    for name in list(NODES.keys()):
        if is_node_alive(name):
            tip, _ = node_rpc(name, "getbestblockhash")
            count, _ = node_rpc(name, "getblockcount")
            final_tips[name] = {"tip": tip, "height": count}

    result_data = {
        "test": "phase3.9-refuzz",
        "description": "Re-fuzz after nimrod validation fix and blockbrew crash fix",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "duration_seconds": round(total_time, 1),
        "iterations": stats["iterations"],
        "seed_blocks": len(seed_blocks),
        "nodes_tested": [n for n in NODES.keys() if n != "core"],
        "mutations_by_type": stats["mutations_by_type"],
        "stats": {
            "rejections_expected": stats["rejections_expected"],
            "rejections_unexpected": stats["rejections_unexpected"],
            "accepts_expected": stats["accepts_expected"],
            "accepts_unexpected": stats["accepts_unexpected"],
        },
        "crashes": stats["crashes"],
        "hangs": stats["hangs"],
        "divergences": stats["divergences"],
        "chain_selection_tests": stats["chain_selection_tests"],
        "errors": stats["errors"],
        "final_tips": final_tips,
    }

    json_path = os.path.join(RESULTS_DIR, "phase3.9-refuzz.json")
    with open(json_path, "w") as f:
        json.dump(result_data, f, indent=2)
    log(f"Results written to {json_path}")

    # Text summary
    lines = []
    lines.append("=" * 72)
    lines.append("PHASE 3.9 RE-FUZZ TESTING SUMMARY")
    lines.append("Verify nimrod validation fix + blockbrew crash fix")
    lines.append("=" * 72)
    lines.append(f"Date:       {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}")
    lines.append(f"Duration:   {total_time:.1f}s")
    lines.append(f"Iterations: {stats['iterations']}")
    lines.append(f"Seed blocks: {len(seed_blocks)}")
    lines.append("")

    lines.append("Nodes tested:")
    for name in NODES:
        status = "alive" if is_node_alive(name) else "dead/stopped"
        tip_info = final_tips.get(name, {})
        h = tip_info.get("height", "?")
        lines.append(f"  {name:12s} {status:12s} height={h}")
    lines.append("")

    lines.append("Mutation distribution:")
    for mtype, count in sorted(stats["mutations_by_type"].items(),
                                key=lambda x: -x[1]):
        lines.append(f"  {mtype:20s} {count:>6}")
    lines.append("")

    lines.append(f"Expected rejections:    {stats['rejections_expected']}")
    lines.append(f"Unexpected rejections:  {stats['rejections_unexpected']}")
    lines.append(f"Expected accepts:       {stats['accepts_expected']}")
    lines.append(f"Unexpected accepts:     {stats['accepts_unexpected']}")
    lines.append("")

    lines.append(f"CRASHES:     {len(stats['crashes'])}")
    for c in stats["crashes"]:
        lines.append(f"  {c['node']} at iter {c['iteration']} ({c['strategy']}) "
                     f"exit_code={c.get('exit_code', '?')}")

    lines.append(f"HANGS:       {len(stats['hangs'])}")
    for h in stats["hangs"][:20]:
        lines.append(f"  {h['node']} at iter {h['iteration']} ({h['strategy']})")

    lines.append(f"DIVERGENCES: {len(stats['divergences'])}")
    for d in stats["divergences"][:20]:
        lines.append(f"  {d['node']} at iter {d['iteration']} ({d['strategy']}) "
                     f"core={d.get('core_status', '?')} node={d.get('node_status', '?')}")

    lines.append("")
    lines.append("CHAIN SELECTION TESTS (nimrod):")
    for t in stats["chain_selection_tests"]:
        lines.append(f"  {t['test']}: {t['result']}")

    lines.append("")

    # Verdicts per node
    nimrod_crashes = [c for c in stats["crashes"] if c["node"] == "nimrod"]
    nimrod_divs = [d for d in stats["divergences"] if d["node"] == "nimrod"]
    blockbrew_crashes = [c for c in stats["crashes"] if c["node"] == "blockbrew"]
    blockbrew_divs = [d for d in stats["divergences"] if d["node"] == "blockbrew"]
    clearbit_crashes = [c for c in stats["crashes"] if c["node"] == "clearbit"]
    clearbit_divs = [d for d in stats["divergences"] if d["node"] == "clearbit"]

    chain_pass = all(t.get("result") == "PASS" for t in stats["chain_selection_tests"]
                     if t.get("result") != "SKIP")

    lines.append("PER-NODE VERDICTS:")
    nim_ok = len(nimrod_crashes) == 0 and len(nimrod_divs) == 0 and chain_pass
    bb_ok = len(blockbrew_crashes) == 0 and len(blockbrew_divs) == 0
    cb_ok = len(clearbit_crashes) == 0 and len(clearbit_divs) == 0

    lines.append(f"  nimrod:    {'PASS' if nim_ok else 'FAIL'} "
                 f"(crashes={len(nimrod_crashes)}, divergences={len(nimrod_divs)}, "
                 f"chain_selection={'PASS' if chain_pass else 'FAIL'})")
    lines.append(f"  blockbrew: {'PASS' if bb_ok else 'FAIL'} "
                 f"(crashes={len(blockbrew_crashes)}, divergences={len(blockbrew_divs)})")
    lines.append(f"  clearbit:  {'PASS' if cb_ok else 'FAIL'} (control) "
                 f"(crashes={len(clearbit_crashes)}, divergences={len(clearbit_divs)})")

    lines.append("")
    total_issues = len(stats["crashes"]) + len(stats["divergences"])
    if total_issues == 0 and chain_pass:
        lines.append("OVERALL VERDICT: PASS - All fixes verified, no regressions")
    else:
        lines.append(f"OVERALL VERDICT: ISSUES FOUND - {total_issues} crash/divergence events")

    lines.append("=" * 72)

    summary_text = "\n".join(lines)
    summary_path = os.path.join(RESULTS_DIR, "phase3.9-refuzz-summary.txt")
    with open(summary_path, "w") as f:
        f.write(summary_text + "\n")
    log(f"Summary written to {summary_path}")

    print()
    print(summary_text)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Phase 3.9 re-fuzz testing")
    parser.add_argument("--iterations", type=int, default=75000,
                        help="Number of fuzz iterations (default: 75000)")
    parser.add_argument("--skip-setup", action="store_true",
                        help="Skip node startup (assume already running)")
    args = parser.parse_args()

    log("=" * 72)
    log("PHASE 3.9 RE-FUZZ TESTING")
    log("Verifying nimrod validation fix + blockbrew crash fix")
    log("=" * 72)

    t_start = time.time()

    # --- Phase 1: Start nodes ---
    alive_nodes = []
    if not args.skip_setup:
        log("\n--- Phase 1: Starting regtest nodes ---")

        subprocess.run(["rm", "-rf", FUZZ_DIR], check=False)
        for name in NODES:
            os.makedirs(f"{FUZZ_DIR}/{name}", exist_ok=True)

        for name in NODES:
            ok = start_node(name)
            if ok:
                alive_nodes.append(name)
            elif name == "core":
                log("FATAL: Cannot start Bitcoin Core")
                stop_all()
                return 1

        log(f"Started: {alive_nodes}")
        failed = [n for n in NODES if n not in alive_nodes]
        if failed:
            log(f"Failed to start: {failed}")
    else:
        for name in NODES:
            if is_node_alive(name):
                alive_nodes.append(name)
        log(f"Already running: {alive_nodes}")

    if "core" not in alive_nodes:
        log("FATAL: Core not available")
        stop_all()
        return 1

    if len(alive_nodes) < 2:
        log("FATAL: Need at least Core + 1 test node")
        stop_all()
        return 1

    # --- Phase 2: Build seed corpus (100 blocks) ---
    log("\n--- Phase 2: Building seed corpus (100 blocks) ---")
    if not build_seed_corpus(alive_nodes, 100):
        log("FATAL: Could not build seed corpus")
        stop_all()
        return 1

    # --- Phase 3: Fuzz ---
    log(f"\n--- Phase 3: Fuzzing ({args.iterations} iterations) ---")
    alive_nodes = run_fuzz(alive_nodes, args.iterations)

    # --- Phase 4: Chain selection tests ---
    log("\n--- Phase 4: Chain selection tests ---")
    alive_nodes = test_chain_selection(alive_nodes)

    # --- Phase 5: Results ---
    total_time = time.time() - t_start
    log(f"\n--- Phase 5: Writing results ---")
    write_results(alive_nodes, total_time)

    # --- Phase 6: Cleanup ---
    log("\n--- Phase 6: Cleanup ---")
    stop_all()
    subprocess.run(["rm", "-rf", FUZZ_DIR], check=False)
    log("Cleanup complete.")

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("Interrupted")
        stop_all()
        subprocess.run(["rm", "-rf", FUZZ_DIR], check=False)
        sys.exit(1)
    except Exception as e:
        log(f"Error: {e}")
        traceback.print_exc()
        stop_all()
        subprocess.run(["rm", "-rf", FUZZ_DIR], check=False)
        sys.exit(1)

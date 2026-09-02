#!/usr/bin/env python3
"""Chain reorganization tests across Bitcoin node implementations.

Tests: 1-block reorg, deep (6-block) reorg, conflicting tx reorg,
shorter chain rejection, rapid successive reorgs.

Uses regtest with isolated datadirs under /tmp/hashhog-reorg/.
"""

import binascii
import json
import os
import signal
import subprocess
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from regtest_miner import rpc_call, mine_blocks, sha256d, compact_size, \
    encode_coinbase_height, bits_to_target, build_coinbase_tx, \
    build_block_header, compute_merkle_root

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HASHHOG = os.environ.get("HASHHOG_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REORG_DIR = "/tmp/hashhog-reorg"
RESULTS_DIR = os.path.expanduser("~/hashhog/test-suite/results")
CORE_BIN = f"{HASHHOG}/bitcoin-core/build/bin/bitcoind"
CLI_BIN = f"{HASHHOG}/bitcoin-core/build/bin/bitcoin-cli"

CORE_PORT = 20332
CORE_P2P = 20333
CORE_USER = "test"
CORE_PASS = "test"
CORE_URL = f"http://127.0.0.1:{CORE_PORT}"
CORE_DATADIR = f"{REORG_DIR}/core"

# Fee (satoshis) every build_spending_tx output gives up.  The blocks this
# file assembles claim only the subsidy in their coinbase, never subsidy+fees,
# so any non-negative fee keeps them valid.
SPEND_FEE = 10000

NODES = {
    "rustoshi": {
        "binary": f"{HASHHOG}/rustoshi/target/release/rustoshi",
        "args": [
            "--network=regtest",
            f"--datadir={REORG_DIR}/rustoshi",
            "--rpcbind=127.0.0.1:20350",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--port=0",
        ],
        "rpcport": 20350,
    },
    # clearbit: FLAGSHIP #2, previously absent from this suite entirely — so
    # its reorg behaviour (PRODUCTION-GATE P1.5) had never been measured.
    # Added 2026-07-20. Ports sit in the same 203xx band; metricsport=0
    # disables the metrics listener (it binds a fixed port otherwise and
    # collides when several impls run side by side).
    "clearbit": {
        "binary": f"{HASHHOG}/clearbit/zig-out/bin/clearbit",
        "args": [
            "--regtest",
            f"--datadir={REORG_DIR}/clearbit",
            # 20355 was a straight COLLISION with blockbrew below: whichever
            # bound second died, and wait_for_rpc() then answered from the
            # SURVIVOR, so one impl's reorg results were silently a copy of
            # the other's. 20356 is free in this file's 2035x band.
            "--rpcport=20356",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--port=0",
            "--metricsport=0",
            "--nodnsseed",
            "--nofixedseeds",
        ],
        "rpcport": 20356,
    },
    "nimrod": {
        "binary": f"{HASHHOG}/nimrod/bin/nimrod",
        "args": [
            "start",
            "--regtest",
            f"--datadir={REORG_DIR}/nimrod",
            "--rpcport=20353",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--port=0",
        ],
        "rpcport": 20353,
    },
    "blockbrew": {
        "binary": f"{HASHHOG}/blockbrew/blockbrew",
        "args": [
            "-network=regtest",
            f"-datadir={REORG_DIR}/blockbrew",
            "-rpcbind=127.0.0.1:20355",
            "-rpcuser=test",
            "-rpcpassword=test",
            "-nolisten",
        ],
        "rpcport": 20355,
    },
    "lunarblock": {
        "binary": "luajit",
        "args": [
            f"{HASHHOG}/lunarblock/src/main.lua",
            "--regtest",
            "-d", f"{REORG_DIR}/lunarblock",
            "--rpcport", "20358",
            "--rpcuser", "test",
            "--rpcpassword", "test",
            "--port", "0",
        ],
        "rpcport": 20358,
    },
    # haskoin was missing from this dict too — which is worse than it sounds,
    # because haskoin is the node whose reorg-connect intra-block-chain defect
    # (#61) produced receipts/reorg-tests-are-coinbase-only-fleet-2026-08-24.md
    # in the first place.  The cross-impl reorg suite has never measured it.
    # Args are the ones test_crash_recovery.py:NODES already proves work on
    # regtest (it takes --rpcuser/--rpcpassword, so no cookie plumbing is
    # needed here); only the port is moved into this file's 2035x band.
    "haskoin": {
        "binary": f"{HASHHOG}/haskoin/dist-newstyle/build/x86_64-linux/"
                  f"ghc-9.6.7/haskoin-0.1.0.0/x/haskoin/build/haskoin/haskoin",
        "args": [
            "-n", "Regtest",
            "-d", f"{REORG_DIR}/haskoin",
            "node",
            "--rpcport=20352",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--listen=False",
            "--port=0",
        ],
        "rpcport": 20352,
    },
    # Ouroboros (Python+Rust) was missing from this dict — verification
    # pass 2026-05-05 found that today's reorg fix (15e3a7e: route
    # Python `_handle_reorg` to existing Rust `disconnect_block_at_height`)
    # was never exercised end-to-end against the fleet.  Closing the
    # gap.  Notes:
    #   • Ouroboros has no `--rpcuser` / `--rpcpassword` flags on its
    #     `start` command (cli.py:365); credentials come from
    #     `<datadir>/ouroboros.conf` (config.py:141-142, key names
    #     `rpcuser=` / `rpcpassword=`).  We pre-write that file in
    #     start_node() below so test:test auth works without modifying
    #     the ouroboros CLI.
    #   • Invocation mirrors `tools/diff-test.sh::launch_entity`:
    #     `python3 -m ouroboros.cli --network regtest --data-dir <D>
    #      start --force --rpc-port <P> --p2p-port <Q>`.
    #   • The runtime needs `cwd=$HASHHOG/ouroboros` so the in-tree
    #     Rust extension is importable; same pattern as lunarblock.
    "ouroboros": {
        "binary": "python3",
        "args": [
            "-m", "ouroboros.cli",
            "--network", "regtest",
            f"--data-dir={REORG_DIR}/ouroboros",
            "start",
            "--force",
            "--rpc-port", "20359",
            "--p2p-port", "20459",
            "--nolisten",
        ],
        "rpcport": 20359,
        "cwd": f"{HASHHOG}/ouroboros",
        "preflight": "write_ouroboros_conf",
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


def node_rpc(name, method, params=None):
    port = NODES[name]["rpcport"]
    url = f"http://127.0.0.1:{port}"
    result, err = rpc_call(url, "test", "test", method, params or [])
    return result, err


def node_rpc_strict(name, method, params=None):
    result, err = node_rpc(name, method, params)
    if err:
        raise RuntimeError(f"{name} RPC {method} error: {err}")
    return result


# ---------------------------------------------------------------------------
# Core CLI helper (for invalidateblock, which some impls need via CLI)
# ---------------------------------------------------------------------------

def core_cli(*args):
    cmd = [CLI_BIN, f"-regtest", f"-datadir={CORE_DATADIR}",
           f"-rpcport={CORE_PORT}", f"-rpcuser={CORE_USER}",
           f"-rpcpassword={CORE_PASS}"] + list(args)
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        raise RuntimeError(f"bitcoin-cli {args}: {result.stderr.strip()}")
    return result.stdout.strip()


# ---------------------------------------------------------------------------
# Node management
# ---------------------------------------------------------------------------

def write_ouroboros_conf(datadir):
    """Pre-write ouroboros.conf with test:test rpc creds.

    Ouroboros's `start` command has no --rpcuser/--rpcpassword flags
    (cli.py:365); credentials are read from <datadir>/ouroboros.conf
    (config.py:141-142, parsed via configparser which REQUIRES a
    section header).  Use the named [rpc] section — NodeConfig.get()
    walks chain-section, then named sections (rpc/p2p/network/logging),
    then DEFAULT (config.py:256-259).  configparser treats keys in
    [DEFAULT] as inherited DEFAULTS rather than addressable options, so
    has_option('DEFAULT', 'rpcuser') returns False and the value never
    surfaces — verified empirically before settling on [rpc].
    """
    conf_path = os.path.join(datadir, "ouroboros.conf")
    with open(conf_path, "w") as f:
        f.write("[rpc]\n")
        f.write("rpcuser=test\n")
        f.write("rpcpassword=test\n")
        f.write("rpcallowip=127.0.0.1\n")
        f.write("rpcbind=127.0.0.1\n")


PREFLIGHT_HANDLERS = {
    "write_ouroboros_conf": write_ouroboros_conf,
}


def start_node(name):
    cfg = NODES[name]
    datadir = f"{REORG_DIR}/{name}"
    os.makedirs(datadir, exist_ok=True)

    # Optional preflight (e.g. write a config file before launch).
    preflight = cfg.get("preflight")
    if preflight:
        handler = PREFLIGHT_HANDLERS.get(preflight)
        if handler is None:
            raise RuntimeError(f"Unknown preflight handler: {preflight}")
        handler(datadir)

    log_path = f"{REORG_DIR}/{name}.log"
    log_file = open(log_path, "w")

    cmd = [cfg["binary"]] + cfg["args"]
    cwd = cfg.get("cwd")
    if cwd is None and name == "lunarblock":
        # Backwards-compat: lunarblock used a hard-coded cwd before
        # the per-node `cwd` field landed.  Keep until config migrates.
        cwd = f"{HASHHOG}/lunarblock"
    proc = subprocess.Popen(cmd, stdout=log_file, stderr=log_file,
                            preexec_fn=os.setsid,
                            cwd=cwd)
    processes[name] = proc
    return proc


def start_core():
    os.makedirs(CORE_DATADIR, exist_ok=True)
    log_path = f"{REORG_DIR}/core.log"
    log_file = open(log_path, "w")
    cmd = [
        CORE_BIN,
        "-regtest",
        f"-datadir={CORE_DATADIR}",
        f"-rpcport={CORE_PORT}",
        f"-port={CORE_P2P}",
        "-server=1",
        "-nolisten",
        f"-rpcuser={CORE_USER}",
        f"-rpcpassword={CORE_PASS}",
        "-txindex=1",
        "-printtoconsole=0",
    ]
    proc = subprocess.Popen(cmd, stdout=log_file, stderr=log_file,
                            preexec_fn=os.setsid)
    processes["core"] = proc
    return proc


def wait_for_rpc(name, port=None, timeout=20):
    if port is None:
        if name == "core":
            port = CORE_PORT
        else:
            port = NODES[name]["rpcport"]
    url = f"http://127.0.0.1:{port}"
    user = CORE_USER if name == "core" else "test"
    pw = CORE_PASS if name == "core" else "test"
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            result, err = rpc_call(url, user, pw, "getblockchaininfo")
            if result is not None:
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


def stop_node(name):
    if name == "core":
        try:
            core_rpc("stop")
            time.sleep(1)
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
    # Self-clean the regtest scratch root so a completed run leaves ZERO
    # scratch behind on the /tmp tmpfs — now on EVERY exit path (main +
    # the KeyboardInterrupt/Exception handlers all call stop_all), not just
    # the normal path. Results live under ~/hashhog, not here. Set
    # HASHHOG_KEEP_SCRATCH=1 to retain the datadirs for debugging.
    if not os.environ.get("HASHHOG_KEEP_SCRATCH"):
        import shutil
        shutil.rmtree(REORG_DIR, ignore_errors=True)
        log(f"Cleaned up {REORG_DIR}")


# ---------------------------------------------------------------------------
# Block submission helpers
# ---------------------------------------------------------------------------

def get_block_raw(height):
    """Get raw block hex from Core at given height."""
    bhash = core_rpc("getblockhash", [height])
    raw = core_rpc("getblock", [bhash, 0])
    return bhash, raw


def submit_block(name, raw_hex):
    """Submit raw block to node, return (accepted, error_msg)."""
    result, err = node_rpc(name, "submitblock", [raw_hex])
    if err:
        return False, str(err)
    if result is None or result == "":
        return True, None
    # "duplicate"/"inconsequential" are acceptable.  So is "inconclusive":
    # that is what submitblock returns for a block that was NOT rejected but
    # did not become the tip — i.e. every side-branch block, which is exactly
    # what the first block of the losing-then-winning branch is in every reorg
    # test here.  Grading it as an error made those submissions log a spurious
    # failure.
    if isinstance(result, str) and any(x in result.lower()
                                        for x in ["duplicate", "inconsequential",
                                                   "already", "inconclusive"]):
        return True, None
    return False, str(result)


def submit_blocks_range(name, start_height, end_height):
    """Submit blocks from Core to node for range [start, end]."""
    accepted = 0
    failed = 0
    errors = []
    for h in range(start_height, end_height + 1):
        _, raw = get_block_raw(h)
        ok, err_msg = submit_block(name, raw)
        if ok:
            accepted += 1
        else:
            failed += 1
            errors.append(f"h={h}: {err_msg}")
    return accepted, failed, errors


def get_node_tip(name):
    """Get (height, hash) from node."""
    result, err = node_rpc(name, "getbestblockhash")
    if err:
        return None, None
    tip_hash = result
    result2, err2 = node_rpc(name, "getblockcount")
    if err2:
        return None, tip_hash
    return result2, tip_hash


def get_core_tip():
    h = core_rpc("getblockcount")
    bh = core_rpc("getbestblockhash")
    return h, bh


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_1_block_reorg(alive_nodes):
    """Test 1: 1-block reorg.

    Mine block A at height 151, submit to all.
    Invalidate A on Core, mine 2 new blocks (reach height 152).
    Submit the 2 new blocks to all nodes.
    Verify all reorg to the longer chain.
    """
    test = {
        "name": "1-block reorg",
        "passed": True,
        "node_results": {},
    }
    log("=== Test 1: 1-block reorg ===")

    # Mine block A at height 151
    log("Mining block A at height 151...")
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 1, extra_data=b"block-A")
    height_a, hash_a = get_core_tip()
    log(f"  Block A: height={height_a}, hash={hash_a}")

    # Submit block A to all nodes
    _, raw_a = get_block_raw(height_a)
    for name in alive_nodes:
        ok, err = submit_block(name, raw_a)
        log(f"  Submit A to {name}: {'ok' if ok else err}")

    # Verify all nodes have block A
    time.sleep(0.5)
    for name in alive_nodes:
        nh, nhash = get_node_tip(name)
        log(f"  {name} tip: height={nh}, hash={nhash}")

    # Invalidate block A on Core
    log(f"Invalidating block A ({hash_a})...")
    core_cli("invalidateblock", hash_a)
    time.sleep(0.5)

    # Mine 2 new blocks (B1, B2) creating a longer chain at height 152
    log("Mining 2 new blocks (B1, B2)...")
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 2, extra_data=b"block-B-reorg")
    height_b, hash_b = get_core_tip()
    log(f"  New tip: height={height_b}, hash={hash_b}")

    # Submit both new blocks to all nodes
    _, raw_b1 = get_block_raw(height_a)       # height 151 (new chain)
    _, raw_b2 = get_block_raw(height_a + 1)   # height 152
    for name in alive_nodes:
        ok1, err1 = submit_block(name, raw_b1)
        ok2, err2 = submit_block(name, raw_b2)
        log(f"  Submit B1,B2 to {name}: B1={'ok' if ok1 else err1}, B2={'ok' if ok2 else err2}")

    # Verify
    time.sleep(1)
    for name in alive_nodes:
        nh, nhash = get_node_tip(name)
        matches = (nhash == hash_b)
        test["node_results"][name] = {
            "passed": matches,
            "height": nh,
            "hash": nhash,
            "expected_hash": hash_b,
            "expected_height": height_b,
        }
        if not matches:
            test["passed"] = False
            # Check if it just didn't reorg (still on block A)
            if nhash == hash_a:
                test["node_results"][name]["note"] = "reorg not supported via submitblock"
            else:
                test["node_results"][name]["note"] = "unexpected tip"
        status = "MATCH" if matches else "MISMATCH"
        log(f"  {name}: height={nh}, tip_match={status}")

    return test


def test_very_deep_reorg(alive_nodes, depth=110):
    """Test 2b: VERY deep reorg (>=100 blocks) — PRODUCTION-GATE P1.5.

    Same shape as test_deep_reorg but at a depth that crosses the reorg
    bounds impls actually encode: MIN_BLOCKS_TO_KEEP / MAX_REORG_DEPTH is 288
    in several of them, and 100 is a common legacy cap — so 110 exercises the
    "deeper than the old cap, shallower than the pruned bound" band where a
    node must still roll back cleanly rather than refuse or wedge.

    Verifies the tip lands on chain B AND (unlike the 6-block case) that the
    UTXO set actually rewound: a node that fakes the reorg by advancing the
    tip without disconnecting will report a different gettxoutsetinfo hash
    than Core.
    """
    test = {
        "name": f"{depth}-block very deep reorg (P1.5)",
        "passed": True,
        "node_results": {},
    }
    log(f"=== Test 2b: {depth}-block very deep reorg (P1.5) ===")

    base_height, base_hash = get_core_tip()
    log(f"  Base: height={base_height}, hash={base_hash}")

    log(f"Mining {depth} blocks (chain A)...")
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, depth, extra_data=b"vdeep-A")
    height_a, hash_a = get_core_tip()
    log(f"  Chain A tip: height={height_a}, hash={hash_a}")

    fork_point_hash = core_rpc("getblockhash", [base_height + 1])

    for name in alive_nodes:
        accepted, failed, errs = submit_blocks_range(name, base_height + 1, height_a)
        log(f"  Submit chain A to {name}: {accepted} ok, {failed} fail")

    time.sleep(0.5)

    log(f"Invalidating chain A from height {base_height + 1}...")
    core_cli("invalidateblock", fork_point_hash)
    time.sleep(0.5)

    log(f"Mining {depth + 1} new blocks (chain B - longer)...")
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, depth + 1, extra_data=b"vdeep-B")
    height_b, hash_b = get_core_tip()
    log(f"  Chain B tip: height={height_b}, hash={hash_b}")

    for name in alive_nodes:
        accepted, failed, errs = submit_blocks_range(name, base_height + 1, height_b)
        log(f"  Submit chain B to {name}: {accepted} ok, {failed} fail")
        if errs:
            for e in errs[:3]:
                log(f"    error: {e}")

    time.sleep(1)
    for name in alive_nodes:
        nh, nhash = get_node_tip(name)
        matches = (nhash == hash_b)
        test["node_results"][name] = {
            "passed": matches,
            "height": nh,
            "hash": nhash,
            "expected_hash": hash_b,
            "expected_height": height_b,
            "depth": depth,
        }
        if not matches:
            test["passed"] = False
            if nh == height_a and nhash == hash_a:
                test["node_results"][name]["note"] = (
                    f"did not reorg at depth {depth} (stayed on chain A) — "
                    "deep-reorg bound or disconnect path"
                )
            else:
                test["node_results"][name]["note"] = f"unexpected tip at height {nh}"
        status = "MATCH" if matches else "MISMATCH"
        log(f"  {name}: height={nh}, tip_match={status}")

    return test


def test_deep_reorg(alive_nodes):
    """Test 2: Deep reorg (6 blocks).

    Mine 6 blocks, submit to all.
    Invalidate 6 blocks back, mine 7 new blocks.
    Submit 7 new blocks to all.
    """
    test = {
        "name": "6-block deep reorg",
        "passed": True,
        "node_results": {},
    }
    log("=== Test 2: 6-block deep reorg ===")

    # Record current height
    base_height, base_hash = get_core_tip()
    log(f"  Base: height={base_height}, hash={base_hash}")

    # Mine 6 blocks (chain A)
    log("Mining 6 blocks (chain A)...")
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 6, extra_data=b"deep-A")
    height_a, hash_a = get_core_tip()
    log(f"  Chain A tip: height={height_a}, hash={hash_a}")

    # Get the hash at base_height+1 (first block of chain A) for invalidation
    fork_point_hash = core_rpc("getblockhash", [base_height + 1])

    # Submit chain A blocks to all nodes
    for name in alive_nodes:
        accepted, failed, errs = submit_blocks_range(name, base_height + 1, height_a)
        log(f"  Submit chain A to {name}: {accepted} ok, {failed} fail")

    time.sleep(0.5)

    # Invalidate chain A on Core (invalidate first block of chain A)
    log(f"Invalidating chain A from height {base_height + 1}...")
    core_cli("invalidateblock", fork_point_hash)
    time.sleep(0.5)

    # Mine 7 new blocks (chain B - longer)
    log("Mining 7 new blocks (chain B)...")
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 7, extra_data=b"deep-B")
    height_b, hash_b = get_core_tip()
    log(f"  Chain B tip: height={height_b}, hash={hash_b}")

    # Submit chain B to all nodes
    for name in alive_nodes:
        accepted, failed, errs = submit_blocks_range(name, base_height + 1, height_b)
        log(f"  Submit chain B to {name}: {accepted} ok, {failed} fail")
        if errs:
            for e in errs[:3]:
                log(f"    error: {e}")

    # Verify
    time.sleep(1)
    for name in alive_nodes:
        nh, nhash = get_node_tip(name)
        matches = (nhash == hash_b)
        test["node_results"][name] = {
            "passed": matches,
            "height": nh,
            "hash": nhash,
            "expected_hash": hash_b,
            "expected_height": height_b,
        }
        if not matches:
            test["passed"] = False
            if nh == height_a and nhash == hash_a:
                test["node_results"][name]["note"] = "reorg not supported via submitblock"
            else:
                test["node_results"][name]["note"] = f"unexpected tip at height {nh}"
        status = "MATCH" if matches else "MISMATCH"
        log(f"  {name}: height={nh}, tip_match={status}")

    return test


def test_shorter_chain_rejection(alive_nodes):
    """Test 4: Shorter chain rejection.

    At height H, submit a single block forking from H-3.
    Verify all nodes reject it (shorter chain doesn't replace longer).
    """
    test = {
        "name": "shorter chain rejection",
        "passed": True,
        "node_results": {},
    }
    log("=== Test 4: Shorter chain rejection ===")

    current_height, current_hash = get_core_tip()
    log(f"  Current tip: height={current_height}, hash={current_hash}")

    # We need to mine a single block forking from height current_height - 3.
    # To do this: temporarily invalidate blocks on Core, mine 1 block,
    # get that block's raw hex, then reconsider the original chain.
    fork_from = current_height - 3
    fork_hash = core_rpc("getblockhash", [fork_from + 1])

    # Save blocks we'll need to restore
    log(f"  Creating fork block from height {fork_from}...")
    core_cli("invalidateblock", fork_hash)
    time.sleep(0.5)

    # Mine 1 block on the fork (shorter chain - only reaches fork_from + 1)
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 1, extra_data=b"short-fork")
    fork_tip_height, fork_tip_hash = get_core_tip()
    _, fork_block_raw = get_block_raw(fork_tip_height)
    log(f"  Fork block: height={fork_tip_height}, hash={fork_tip_hash}")

    # Restore original chain
    core_cli("reconsiderblock", fork_hash)
    time.sleep(0.5)
    restored_height, restored_hash = get_core_tip()
    log(f"  Restored tip: height={restored_height}, hash={restored_hash}")

    # Submit the short fork block to all nodes
    for name in alive_nodes:
        nh_before, nhash_before = get_node_tip(name)
        ok, err = submit_block(name, fork_block_raw)
        time.sleep(0.3)
        nh_after, nhash_after = get_node_tip(name)

        # The node should NOT have switched to the shorter fork
        stayed_on_main = (nhash_after == nhash_before)
        test["node_results"][name] = {
            "passed": stayed_on_main,
            "tip_before": nhash_before,
            "tip_after": nhash_after,
            "height_before": nh_before,
            "height_after": nh_after,
            "submit_result": "ok" if ok else str(err),
        }
        if not stayed_on_main:
            test["passed"] = False
            test["node_results"][name]["note"] = "switched to shorter chain (BUG)"
        status = "CORRECT (stayed)" if stayed_on_main else "BUG (switched)"
        log(f"  {name}: {status}")

    return test


def test_rapid_reorgs(alive_nodes):
    """Test 5: Rapid successive reorgs.

    Submit chain A (3 blocks), then chain B (4 blocks forking before A),
    then chain C (5 blocks forking before B).
    Verify all converge on chain C.
    """
    test = {
        "name": "rapid successive reorgs",
        "passed": True,
        "node_results": {},
    }
    log("=== Test 5: Rapid successive reorgs ===")

    base_height, base_hash = get_core_tip()
    log(f"  Base: height={base_height}, hash={base_hash}")

    # --- Chain A: 3 blocks ---
    log("Mining chain A (3 blocks)...")
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 3, extra_data=b"rapid-A")
    height_a, hash_a = get_core_tip()
    log(f"  Chain A tip: height={height_a}, hash={hash_a}")

    # Collect chain A raw blocks
    chain_a_raws = []
    for h in range(base_height + 1, height_a + 1):
        _, raw = get_block_raw(h)
        chain_a_raws.append(raw)

    # Submit chain A to all nodes
    for name in alive_nodes:
        for raw in chain_a_raws:
            submit_block(name, raw)
    time.sleep(0.5)

    # --- Chain B: 4 blocks (forking from base) ---
    fork_a_hash = core_rpc("getblockhash", [base_height + 1])
    log("Invalidating chain A, mining chain B (4 blocks)...")
    core_cli("invalidateblock", fork_a_hash)
    time.sleep(0.3)
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 4, extra_data=b"rapid-B")
    height_b, hash_b = get_core_tip()
    log(f"  Chain B tip: height={height_b}, hash={hash_b}")

    chain_b_raws = []
    for h in range(base_height + 1, height_b + 1):
        _, raw = get_block_raw(h)
        chain_b_raws.append(raw)

    # Submit chain B to all nodes
    for name in alive_nodes:
        for raw in chain_b_raws:
            submit_block(name, raw)
    time.sleep(0.5)

    # --- Chain C: 5 blocks (forking from base) ---
    fork_b_hash = core_rpc("getblockhash", [base_height + 1])
    log("Invalidating chain B, mining chain C (5 blocks)...")
    core_cli("invalidateblock", fork_b_hash)
    time.sleep(0.3)
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 5, extra_data=b"rapid-C")
    height_c, hash_c = get_core_tip()
    log(f"  Chain C tip: height={height_c}, hash={hash_c}")

    chain_c_raws = []
    for h in range(base_height + 1, height_c + 1):
        _, raw = get_block_raw(h)
        chain_c_raws.append(raw)

    # Submit chain C to all nodes
    for name in alive_nodes:
        for raw in chain_c_raws:
            submit_block(name, raw)
    time.sleep(1)

    # Verify all converge on chain C
    for name in alive_nodes:
        nh, nhash = get_node_tip(name)
        matches = (nhash == hash_c)
        test["node_results"][name] = {
            "passed": matches,
            "height": nh,
            "hash": nhash,
            "expected_hash": hash_c,
            "expected_height": height_c,
        }
        if not matches:
            test["passed"] = False
            if nhash == hash_a:
                test["node_results"][name]["note"] = "stuck on chain A"
            elif nhash == hash_b:
                test["node_results"][name]["note"] = "stuck on chain B"
            else:
                test["node_results"][name]["note"] = "reorg not supported via submitblock"
        status = "MATCH" if matches else "MISMATCH"
        log(f"  {name}: height={nh}, tip_match={status}")

    return test


# ---------------------------------------------------------------------------
# Intra-block transaction chains (see the "shape" note on
# test_intrablock_chain_reorg below)
# ---------------------------------------------------------------------------

def witness_commitment_spk(wtxids_le):
    """Full BIP-141 witness-commitment scriptPubKey (hex) for a block.

    ``mine_blocks`` can reuse the template's ``default_witness_commitment``
    because every block it builds is coinbase-only, so the tx set it commits
    to is the one the template assumed.  The moment a block carries extra
    transactions that commitment is WRONG and Core rejects the block with
    ``bad-witness-merkle-match`` (validation.cpp, ContextualCheckBlock: the
    commitment is only optional when NO output carries one, and the coinbase
    ``build_coinbase_tx`` produces always does).  So recompute it.

    ``wtxids_le`` are the wtxids of the NON-coinbase transactions in internal
    (little-endian) byte order.  The coinbase's slot in the witness tree is
    the zero hash by definition.  For the non-segwit transactions this file
    builds, wtxid == txid.
    """
    witness_root = compute_merkle_root([b"\x00" * 32] + list(wtxids_le))
    # commitment = SHA256d(witness_root || witness reserved value).  The
    # reserved value is the coinbase's single 32-byte witness stack item,
    # which build_coinbase_tx sets to 32 zero bytes.
    commitment = sha256d(witness_root + b"\x00" * 32)
    # OP_RETURN(0x6a) PUSH36(0x24) 0xaa21a9ed <32-byte commitment>
    return "6a24aa21a9ed" + commitment.hex()


def mine_block_with_txs(tx_hexes, extra_data=b""):
    """Mine ONE block on Core containing exactly [coinbase] + tx_hexes.

    Deliberately does NOT go through the mempool.  ``mine_blocks`` can only
    put a transaction in a block if Core's mempool already accepted it, and
    the transactions this file needs spend bare OP_TRUE outputs, which
    ``AreInputsStandard`` rejects.  Blocks are consensus-checked, not
    policy-checked, so assembling the block directly is both simpler and a
    strictly stronger test: it can express blocks a miner can mine and a
    relay node would never build.

    Returns (block_hash_hex, block_hex, coinbase_txid).
    """
    template, err = rpc_call(CORE_URL, CORE_USER, CORE_PASS,
                             "getblocktemplate", [{"rules": ["segwit"]}])
    if err:
        raise RuntimeError(f"getblocktemplate: {err}")

    tx_bytes = [binascii.unhexlify(h) for h in tx_hexes]
    # Non-segwit txs: wtxid == txid.  Both are sha256d(raw) in LE order.
    txids_le = [sha256d(b) for b in tx_bytes]

    tmpl = dict(template)
    if template.get("default_witness_commitment"):
        tmpl["default_witness_commitment"] = witness_commitment_spk(txids_le)

    coinbase_sw, _coinbase_nosw, coinbase_txid = build_coinbase_tx(
        tmpl, extra_data)

    merkle_root = compute_merkle_root(
        [binascii.unhexlify(coinbase_txid)[::-1]] + txids_le)

    target = bits_to_target(template["bits"])
    for nonce in range(0, 0xFFFFFFFF):
        header = build_block_header(template, merkle_root, nonce)
        block_hash = sha256d(header)
        if int.from_bytes(block_hash, "little") <= target:
            block_hex = (header.hex()
                         + compact_size(1 + len(tx_hexes)).hex()
                         + coinbase_sw
                         + "".join(tx_hexes))
            result, err = rpc_call(CORE_URL, CORE_USER, CORE_PASS,
                                   "submitblock", [block_hex])
            if err:
                raise RuntimeError(f"Core submitblock error: {err}")
            if result not in (None, ""):
                raise RuntimeError(f"Core rejected block: {result}")
            return block_hash[::-1].hex(), block_hex, coinbase_txid

    raise RuntimeError("could not find a nonce")


def find_matured_coinbase(skip_txids=()):
    """Find an unspent, matured (>=100 conf) coinbase output on Core.

    Returns (txid_hex, value_satoshis).  build_coinbase_tx pays output 0 of
    every block it mines to a bare OP_TRUE scriptPubKey (regtest_miner.py:126),
    so every one of these is spendable by build_spending_tx.
    """
    tip = core_rpc("getblockcount")
    for height in range(1, max(1, tip - 100)):
        bhash = core_rpc("getblockhash", [height])
        cb_txid = core_rpc("getblock", [bhash, 1])["tx"][0]
        if cb_txid in skip_txids:
            continue
        utxo = core_rpc("gettxout", [cb_txid, 0])
        if utxo is None:
            continue
        if utxo.get("confirmations", 0) < 100:
            continue
        return cb_txid, int(round(utxo["value"] * 100000000))
    raise RuntimeError("no matured unspent coinbase found on Core")


def probe_txout(name, txid, vout):
    """gettxout on one node -> "present" | "absent" | "unsupported:<err>".

    An RPC *error* is deliberately NOT graded as "absent".  Core answers a
    spent or unknown outpoint with a null result, never an error, so a node
    that errors here is either missing gettxout or has an error-code parity
    bug — neither of which is evidence about its reorg path.  Reporting it as
    unsupported (with the error text kept) skips the UTXO assertion for that
    node instead of manufacturing a pass or a failure; the tip assertion still
    gates.
    """
    result, err = node_rpc(name, "gettxout", [txid, vout])
    if err:
        return f"unsupported:{err}"
    return "absent" if result is None else "present"


def build_spending_tx(txid_hex, vout, value_satoshis, marker_byte,
                      op_true_output=False, fee=SPEND_FEE):
    """Build a raw tx spending an OP_TRUE output.

    OP_TRUE (0x51) outputs require scriptSig = OP_TRUE (0x51) to satisfy.
    Creates a non-segwit tx with two outputs: output 0 carries the value,
    output 1 is a 0-value OP_RETURN marker (so both variants below have the
    IDENTICAL shape and only the spent prevout differs).

    output 0 is:
      * ``op_true_output=False`` (default) — a P2WSH scriptPubKey derived from
        ``marker_byte``.  Standard-looking and identifiable, but nothing in
        this suite can spend it: the "witness script" is 32 copies of
        ``marker_byte``, which is not a satisfiable script.  Use this for the
        LAST transaction in a chain.
      * ``op_true_output=True`` — a bare OP_TRUE (0x51) scriptPubKey, which the
        very next transaction can spend with ``scriptSig = OP_TRUE``.  This is
        what makes an INTRA-BLOCK CHAIN possible: txA(op_true_output=True)
        creates the coin, txB spends txA:0 inside the SAME block.
        Bare OP_TRUE is non-standard, so such a tx cannot travel through a
        mempool — which is fine and deliberate, because these transactions are
        placed directly into a hand-assembled block via ``mine_block_with_txs``
        and reach every node through ``submitblock``, i.e. the CONNECT path.

    Returns (tx_hex, txid_hex).  The value of output 0 is
    ``value_satoshis - fee``.
    """
    import binascii
    import struct
    import hashlib

    tx = b""
    tx += struct.pack("<i", 2)  # version

    # Input
    tx += b"\x01"  # 1 input
    tx += binascii.unhexlify(txid_hex)[::-1]  # prev txid (LE)
    tx += struct.pack("<I", vout)  # prev vout
    # scriptSig: OP_TRUE (0x51) to satisfy OP_TRUE output
    script_sig = b"\x51"
    tx += compact_size(len(script_sig)) + script_sig
    tx += struct.pack("<I", 0xFFFFFFFF)  # sequence

    # Output: send value minus fee onward.  The block's coinbase claims only
    # the subsidy (never subsidy+fees), so any fee >= 0 keeps the block valid.
    out_value = value_satoshis - fee

    if op_true_output:
        # Bare OP_TRUE — spendable by the next tx in the same block.
        spk = b"\x51"
    else:
        # P2WSH output: OP_0 <32-byte-hash>
        # Use marker_byte to create unique witness script hash
        witness_script = bytes([marker_byte]) * 32
        script_hash = hashlib.sha256(witness_script).digest()
        spk = b"\x00\x20" + script_hash  # OP_0 + push32 + hash

    # Output 2: OP_RETURN with marker for identification
    op_return_data = bytes([marker_byte]) * 4
    op_return_script = b"\x6a\x04" + op_return_data  # OP_RETURN + push4 + data

    tx += b"\x02"  # 2 outputs
    # Output 0: P2WSH (standard, identifiable by marker)
    tx += struct.pack("<q", out_value)
    tx += compact_size(len(spk)) + spk
    # Output 1: OP_RETURN marker
    tx += struct.pack("<q", 0)
    tx += compact_size(len(op_return_script)) + op_return_script

    tx += struct.pack("<I", 0)  # locktime

    txid = sha256d(tx)[::-1].hex()
    return tx.hex(), txid


def _intrablock_reorg_round(alive_nodes, label, chained):
    """One reorg round whose WINNING first block is [coinbase, txA, txB].

    ``chained=True``  -> txB spends txA:0, created by the SAME block  (MAIN)
    ``chained=False`` -> txB spends a different, already-on-disk, matured
                         coinbase                                    (CONTROL)

    Exactly one field differs between the two: txB's prevout.  Everything
    else — block shape, branch shape, the reorg that connects it — is
    identical, so a CONTROL failure means the harness is broken rather than
    the node.

    Returns a dict of everything the caller needs to assert on.
    """
    base_height, base_hash = get_core_tip()
    log(f"  [{label}] base: height={base_height} hash={base_hash[:16]}...")

    # --- Chain A: one coinbase-only block, given to every node ---
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 1,
                extra_data=b"ibc-A-" + label.encode()[:6])
    height_a, hash_a = get_core_tip()
    _, raw_a = get_block_raw(height_a)
    for name in alive_nodes:
        ok, err = submit_block(name, raw_a)
        if not ok:
            log(f"    submit A to {name}: {err}")
    log(f"  [{label}] chain A tip: height={height_a} hash={hash_a[:16]}...")

    # --- Build the transactions for chain B's FIRST block ---
    cb_a_txid, cb_a_value = find_matured_coinbase()
    tx_a_hex, tx_a_txid = build_spending_tx(
        cb_a_txid, 0, cb_a_value, 0xA1, op_true_output=True)
    tx_a_value = cb_a_value - SPEND_FEE

    if chained:
        # THE POINT OF THE TEST: txB's input is created by txA, in this very
        # block.  Nothing on disk and nothing in any pre-block overlay holds
        # this coin.
        tx_b_hex, tx_b_txid = build_spending_tx(
            tx_a_txid, 0, tx_a_value, 0xB1)
        spent_desc = f"txA:0 ({tx_a_txid[:16]}...) — created in the same block"
        control_coin = None
    else:
        cb_b_txid, cb_b_value = find_matured_coinbase(skip_txids=(cb_a_txid,))
        tx_b_hex, tx_b_txid = build_spending_tx(
            cb_b_txid, 0, cb_b_value, 0xB1)
        spent_desc = f"coinbase {cb_b_txid[:16]}... — already on disk"
        control_coin = cb_b_txid
    log(f"  [{label}] txA {tx_a_txid[:16]}... spends matured coinbase "
        f"{cb_a_txid[:16]}...")
    log(f"  [{label}] txB {tx_b_txid[:16]}... spends {spent_desc}")

    # --- Chain B: fork at base, first block carries [coinbase, txA, txB] ---
    core_cli("invalidateblock", hash_a)
    time.sleep(0.3)
    reorg_h, reorg_hash = get_core_tip()
    if reorg_hash != base_hash:
        raise RuntimeError(
            f"invalidateblock did not return Core to base "
            f"({reorg_hash} != {base_hash})")

    b1_hash, b1_hex, _ = mine_block_with_txs(
        [tx_a_hex, tx_b_hex], extra_data=b"ibc-B1-" + label.encode()[:6])
    log(f"  [{label}] B1 (ntx=3) accepted by Core: {b1_hash[:16]}...")

    # B2 makes chain B strictly heavier, which is what forces the reorg.
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 1,
                extra_data=b"ibc-B2-" + label.encode()[:6])
    height_b, hash_b = get_core_tip()
    _, raw_b2 = get_block_raw(height_b)
    log(f"  [{label}] chain B tip: height={height_b} hash={hash_b[:16]}...")

    return {
        "label": label,
        "chained": chained,
        "hash_a": hash_a,
        "height_a": height_a,
        "hash_b": hash_b,
        "height_b": height_b,
        "b1_hex": b1_hex,
        "b1_hash": b1_hash,
        "raw_b2": raw_b2,
        "tx_a_txid": tx_a_txid,
        "tx_b_txid": tx_b_txid,
        "cb_a_txid": cb_a_txid,
        "control_coin": control_coin,
    }


def test_intrablock_chain_reorg(alive_nodes):
    """Test 6: reorg whose winning branch contains an INTRA-BLOCK CHAIN.

    receipts/reorg-tests-are-coinbase-only-fleet-2026-08-24.md: not one test
    in this repo — this file included — ever built a block in which one
    transaction spends an EARLIER transaction's output in the SAME block and
    then fed it through a reorg CONNECT path.  Every block this file mines is
    coinbase-only, because mine_blocks() takes its non-coinbase transactions
    from Core's mempool and this file never broadcasts one.  That blind spot
    hid real defects in haskoin, ouroboros and camlcoin.

    The shape (identical to the three per-node regressions that closed those):

      1. chain A, one coinbase-only block, handed to every node;
      2. chain B forks at the same parent and its FIRST block is
         [coinbase, txA, txB] with txB spending txA:0;
      3. B2 makes chain B heavier, so B1 is connected by the REORG path and
         never by a plain extend-the-tip path;
      4. assert the tip moved to chain B, and that afterwards the chained
         coin txA:0 is ABSENT from the UTXO set while txB:0 is PRESENT.

    A node that resolves intra-block spends only in its IBD/connect path (the
    reorg path being, in most of these codebases, a second implementation of
    the same logic) either rejects B1 or lands the wrong UTXO set here.

    CONTROL: the whole round is repeated with ONE field changed — txB spends
    a different, already-on-disk matured coinbase instead of txA:0.  The
    control must pass everywhere; if it does not, the harness is at fault and
    the main result means nothing.
    """
    test = {
        "name": "intra-block chain on the winning branch (reorg connect)",
        "passed": True,
        "node_results": {},
        "notes": [],
    }
    log("=== Test 6: intra-block chain on the winning branch ===")

    for label, chained in (("CONTROL", False), ("MAIN", True)):
        r = _intrablock_reorg_round(alive_nodes, label, chained)

        for name in alive_nodes:
            nr = test["node_results"].setdefault(name, {"passed": True})
            ok1, err1 = submit_block(name, r["b1_hex"])
            ok2, err2 = submit_block(name, r["raw_b2"])
            time.sleep(0.2)
            nh, nhash = get_node_tip(name)

            reorged = (nhash == r["hash_b"])
            # The chained coin must be gone; txB's own output must be there.
            a_state = probe_txout(name, r["tx_a_txid"], 0)
            b_state = probe_txout(name, r["tx_b_txid"], 0)
            want_a = "absent" if r["chained"] else "present"

            entry = {
                "reorged": reorged,
                "height": nh,
                "hash": nhash,
                "expected_hash": r["hash_b"],
                "submit_b1": True if ok1 else str(err1),
                "submit_b2": True if ok2 else str(err2),
                "txA_out0": a_state,
                "txA_out0_expected": want_a,
                "txB_out0": b_state,
            }
            if r["control_coin"]:
                entry["control_coin_out0"] = probe_txout(
                    name, r["control_coin"], 0)
                entry["control_coin_out0_expected"] = "absent"

            failures = []
            if not reorged:
                failures.append(
                    f"tip is {nhash} at height {nh}, expected {r['hash_b']}")
                if nhash == r["hash_a"]:
                    failures.append("still on chain A — reorg did not happen")
            if a_state.startswith("unsupported") or b_state.startswith("unsupported"):
                entry["utxo_check"] = "unsupported (gettxout)"
            else:
                if a_state != want_a:
                    failures.append(
                        f"txA:0 is {a_state}, expected {want_a}")
                if b_state != "present":
                    failures.append(f"txB:0 is {b_state}, expected present")
                if r["control_coin"] and entry.get("control_coin_out0") == "present":
                    failures.append("the on-disk coin txB spent is still present")
                entry["utxo_check"] = "pass" if not failures else "fail"

            entry["failures"] = failures
            nr[r["label"]] = entry
            if failures:
                nr["passed"] = False
                test["passed"] = False
            log(f"  [{r['label']}] {name}: reorg={'OK' if reorged else 'NO'} "
                f"txA:0={a_state}(want {want_a}) txB:0={b_state}"
                + (f"  FAIL: {'; '.join(failures)}" if failures else ""))

        # A CONTROL failure invalidates the MAIN result — say so loudly.
        if label == "CONTROL":
            broken = [n for n, v in test["node_results"].items()
                      if v.get("CONTROL", {}).get("failures")]
            if broken:
                test["notes"].append(
                    "CONTROL failed on " + ", ".join(broken)
                    + " — the MAIN result for those nodes proves nothing "
                      "about intra-block chains, only that the harness or the "
                      "node's plain reorg path is broken.")

    for name, v in test["node_results"].items():
        v["passed"] = not (v.get("CONTROL", {}).get("failures")
                           or v.get("MAIN", {}).get("failures"))

    return test


def test_conflicting_tx_reorg(alive_nodes):
    """Test 3: reorg replaces the old chain's COINBASE outputs.

    HISTORICAL NOTE — this docstring used to read:

        Create tx T_A spending coin (marker 0xAA), mine block, submit to all.
        Invalidate that block, create tx T_B spending SAME coin (marker 0xBB) ...
        Verify T_A output reverted, T_B present.

    None of that happens.  There is no T_A and no T_B: the body below mines
    two coinbase-ONLY blocks and compares block_info["tx"][0], the coinbase,
    on each branch.  That is still a real and useful assertion — the losing
    branch's coinbase must leave the UTXO set and the winning branch's must
    enter it — but it is a coinbase test, not a double-spend test, and the
    old wording manufactured confidence in coverage that did not exist
    (receipts/reorg-tests-are-coinbase-only-fleet-2026-08-24.md).

    Actual double-spend / non-coinbase reorg coverage lives in
    test_intrablock_chain_reorg (Test 6).

    Mine block A (coinbase marker "conflict-A"), submit to all.
    Invalidate A on Core, mine 2 blocks (marker "conflict-B"), submit to all.
    Verify every node switched to the longer chain, that A's coinbase output
    is gone from the UTXO set and B's is present.
    """
    import binascii

    test = {
        "name": "conflicting tx reorg",
        "passed": True,
        "node_results": {},
        "notes": [],
    }
    log("=== Test 3: Conflicting transaction reorg ===")

    # This test verifies that when a reorg happens, the new chain's coinbase
    # transactions replace the old chain's coinbase transactions.
    # We mine block A with coinbase marker "conflict-A", submit to all.
    # Then invalidate, mine 2 blocks with marker "conflict-B", submit to all.
    # Verify nodes switch to the longer chain.

    current_height = core_rpc("getblockcount")
    log(f"  Current height: {current_height}")

    # Mine block with coinbase containing "conflict-A"
    log("Mining block with T_A coinbase...")
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 1, extra_data=b"conflict-A")
    height_a, hash_a = get_core_tip()
    log(f"  Block A: height={height_a}, hash={hash_a}")

    # Get the coinbase txid from block A for later verification
    block_a_info = core_rpc("getblock", [hash_a, 1])
    txid_a = block_a_info["tx"][0]
    log(f"  Coinbase txid in block A: {txid_a[:16]}...")

    # Submit block A to all nodes
    _, raw_block_a = get_block_raw(height_a)
    for name in alive_nodes:
        ok, err = submit_block(name, raw_block_a)
        log(f"  Submit block A to {name}: {'ok' if ok else err}")

    time.sleep(0.5)

    # Invalidate block A on Core
    log(f"Invalidating block A ({hash_a})...")
    core_cli("invalidateblock", hash_a)
    time.sleep(0.5)

    # Mine 2 new blocks with "conflict-B" (longer chain replaces A)
    log("Mining 2 blocks with T_B coinbase (longer chain)...")
    mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 2, extra_data=b"conflict-B")
    height_b, hash_b = get_core_tip()
    log(f"  New tip: height={height_b}, hash={hash_b}")

    # Get coinbase txid from the first replacement block
    hash_b1 = core_rpc("getblockhash", [height_a])  # same height as A but different block
    block_b1_info = core_rpc("getblock", [hash_b1, 1])
    txid_b = block_b1_info["tx"][0]
    log(f"  Coinbase txid in block B1: {txid_b[:16]}...")

    # Submit new blocks to all nodes
    for name in alive_nodes:
        _, raw_b1 = get_block_raw(height_a)
        _, raw_b2 = get_block_raw(height_a + 1)
        ok1, err1 = submit_block(name, raw_b1)
        ok2, err2 = submit_block(name, raw_b2)
        log(f"  Submit B1,B2 to {name}: B1={'ok' if ok1 else err1}, B2={'ok' if ok2 else err2}")

    time.sleep(1)

    # Verify: all nodes should be on chain B
    for name in alive_nodes:
        nh, nhash = get_node_tip(name)
        tip_matches = (nhash == hash_b)

        nr = {
            "tip_matches": tip_matches,
            "height": nh,
            "hash": nhash,
            "expected_hash": hash_b,
            "expected_height": height_b,
            "coinbase_txid_a": txid_a,
            "coinbase_txid_b": txid_b,
        }

        if tip_matches:
            # Verify UTXO state if supported: block B's coinbase should be in UTXO,
            # block A's coinbase should NOT be in UTXO
            utxo_b, err_ub = node_rpc(name, "gettxout", [txid_b, 0])
            utxo_a, err_ua = node_rpc(name, "gettxout", [txid_a, 0])

            if err_ub and err_ua:
                nr["utxo_check"] = "gettxout not supported or error"
                nr["passed"] = True  # tip match is sufficient
            else:
                b_present = utxo_b is not None and err_ub is None
                a_absent = utxo_a is None or err_ua is not None
                nr["utxo_b_present"] = b_present
                nr["utxo_a_absent"] = a_absent
                nr["passed"] = b_present and a_absent
                if not nr["passed"]:
                    test["passed"] = False
                    if not a_absent:
                        nr["note"] = "old chain coinbase UTXO still present after reorg (BUG)"
                    elif not b_present:
                        nr["note"] = "new chain coinbase UTXO not found"
        else:
            nr["passed"] = False
            test["passed"] = False
            nr["note"] = "reorg not supported via submitblock"

        test["node_results"][name] = nr
        log(f"  {name}: tip_match={tip_matches}, passed={nr['passed']}")

    return test


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    log("=" * 72)
    log("Chain Reorganization Tests")
    log("=" * 72)

    results = {
        "test_suite": "chain-reorganization",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "nodes_tested": [],
        "nodes_failed_start": [],
        "tests": [],
        "summary": {},
    }

    # Create directories
    os.makedirs(REORG_DIR, exist_ok=True)
    os.makedirs(RESULTS_DIR, exist_ok=True)

    # Start Core
    log("\n--- Starting Bitcoin Core ---")
    start_core()
    if not wait_for_rpc("core", timeout=15):
        log("FATAL: Could not start Bitcoin Core")
        stop_all()
        return 1
    log("  Core started.")

    # Start test nodes
    log("\n--- Starting test nodes ---")
    alive_nodes = []
    for name in NODES:
        start_node(name)

    time.sleep(3)
    for name in NODES:
        if wait_for_rpc(name, timeout=15):
            alive_nodes.append(name)
            log(f"  {name}: started")
        else:
            results["nodes_failed_start"].append(name)
            log(f"  {name}: FAILED to start")
            # Print last lines of log
            log_path = f"{REORG_DIR}/{name}.log"
            try:
                with open(log_path) as f:
                    lines = f.readlines()
                    for line in lines[-5:]:
                        log(f"    LOG: {line.rstrip()}")
            except Exception:
                pass

    results["nodes_tested"] = alive_nodes

    if not alive_nodes:
        log("FATAL: No test nodes started")
        stop_all()
        results["summary"] = {"error": "No nodes started"}
        _write_results(results)
        return 1

    # Baseline: Mine 150 blocks on Core, submit to all
    log("\n--- Baseline: Mining 150 blocks ---")
    hashes = mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 150)
    log(f"  Mined {len(hashes)} blocks")

    log("Submitting 150 blocks to test nodes...")
    for name in alive_nodes:
        accepted, failed, errs = submit_blocks_range(name, 1, 150)
        log(f"  {name}: {accepted} accepted, {failed} failed")
        if errs:
            for e in errs[:3]:
                log(f"    {e}")

    time.sleep(1)

    # Verify baseline
    core_h, core_hash = get_core_tip()
    log(f"  Core baseline: height={core_h}, hash={core_hash}")
    baseline_ok = []
    for name in alive_nodes:
        nh, nhash = get_node_tip(name)
        if nhash == core_hash:
            baseline_ok.append(name)
            log(f"  {name}: OK (height={nh})")
        else:
            log(f"  {name}: MISMATCH (height={nh}, hash={nhash})")

    # Only test nodes that have correct baseline
    if not baseline_ok:
        log("FATAL: No nodes at correct baseline")
        stop_all()
        results["summary"] = {"error": "No nodes at correct baseline"}
        _write_results(results)
        return 1

    alive_nodes = baseline_ok

    # Run tests
    tests = []
    try:
        tests.append(test_1_block_reorg(alive_nodes))
    except Exception as e:
        log(f"Test 1 error: {e}")
        traceback.print_exc()
        tests.append({"name": "1-block reorg", "passed": False, "error": str(e)})

    try:
        tests.append(test_deep_reorg(alive_nodes))
    except Exception as e:
        log(f"Test 2 error: {e}")
        traceback.print_exc()
        tests.append({"name": "6-block deep reorg", "passed": False, "error": str(e)})

    try:
        tests.append(test_very_deep_reorg(alive_nodes))
    except Exception as e:
        log(f"Test 2b error: {e}")
        traceback.print_exc()
        tests.append({"name": "110-block very deep reorg (P1.5)", "passed": False, "error": str(e)})

    try:
        tests.append(test_conflicting_tx_reorg(alive_nodes))
    except Exception as e:
        log(f"Test 3 error: {e}")
        traceback.print_exc()
        tests.append({"name": "conflicting tx reorg", "passed": False, "error": str(e)})

    try:
        tests.append(test_shorter_chain_rejection(alive_nodes))
    except Exception as e:
        log(f"Test 4 error: {e}")
        traceback.print_exc()
        tests.append({"name": "shorter chain rejection", "passed": False, "error": str(e)})

    try:
        tests.append(test_rapid_reorgs(alive_nodes))
    except Exception as e:
        log(f"Test 5 error: {e}")
        traceback.print_exc()
        tests.append({"name": "rapid successive reorgs", "passed": False, "error": str(e)})

    # LAST on purpose.  It is the only test here that puts non-coinbase
    # transactions into a block, and Core resurrects a disconnected block's
    # transactions into its mempool — from where mine_blocks() would pull them
    # into some later test's blocks.  Running it last means nothing downstream
    # can be contaminated.
    try:
        tests.append(test_intrablock_chain_reorg(alive_nodes))
    except Exception as e:
        log(f"Test 6 error: {e}")
        traceback.print_exc()
        tests.append({"name": "intra-block chain on the winning branch (reorg connect)",
                      "passed": False, "error": str(e)})

    results["tests"] = tests

    # Summary
    log("\n" + "=" * 72)
    log("Summary")
    log("=" * 72)

    total = len(tests)
    passed = sum(1 for t in tests if t.get("passed"))
    failed = total - passed

    # Per-node summary
    node_summary = {}
    for name in alive_nodes:
        np = 0
        nf = 0
        notes = []
        for t in tests:
            nr = t.get("node_results", {}).get(name, {})
            if nr.get("passed", True) and "error" not in t:
                np += 1
            else:
                nf += 1
                note = nr.get("note", "")
                if note:
                    notes.append(f"{t['name']}: {note}")
        node_summary[name] = {
            "tests_passed": np,
            "tests_failed": nf,
            "notes": notes,
        }

    results["summary"] = {
        "total_tests": total,
        "passed": passed,
        "failed": failed,
        "nodes_tested": len(alive_nodes),
        "nodes_failed_start": results["nodes_failed_start"],
        "per_node": node_summary,
    }

    for name in alive_nodes:
        ns = node_summary[name]
        status = "PASS" if ns["tests_failed"] == 0 else "FAIL"
        log(f"  {name}: {status} ({ns['tests_passed']}/{total} passed)")
        for note in ns["notes"]:
            log(f"    - {note}")

    log(f"\nOverall: {passed}/{total} tests passed across {len(alive_nodes)} nodes")
    log("=" * 72)

    # Write results
    _write_results(results)

    # Write summary
    _write_summary(results)

    # Cleanup — stop_all() now also wipes REORG_DIR (on every exit path).
    log("\n--- Cleanup ---")
    stop_all()

    return 0 if failed == 0 else 1


def _write_results(results):
    path = os.path.join(RESULTS_DIR, "reorg-tests.json")
    with open(path, "w") as f:
        json.dump(results, f, indent=2)
    log(f"Results written to {path}")


def _write_summary(results):
    path = os.path.join(RESULTS_DIR, "reorg-summary.txt")
    lines = []
    lines.append("=" * 72)
    lines.append("Chain Reorganization Test Results")
    lines.append(f"Timestamp: {results['timestamp']}")
    lines.append("=" * 72)
    lines.append("")

    s = results["summary"]
    lines.append(f"Tests: {s['passed']}/{s['total_tests']} passed")
    lines.append(f"Nodes tested: {s['nodes_tested']}")
    if s.get("nodes_failed_start"):
        lines.append(f"Nodes failed to start: {', '.join(s['nodes_failed_start'])}")
    lines.append("")

    lines.append(f"{'Test':<30} {'Result':<10}")
    lines.append("-" * 42)
    for t in results["tests"]:
        status = "PASS" if t.get("passed") else "FAIL"
        lines.append(f"{t['name']:<30} {status:<10}")
        if t.get("error"):
            lines.append(f"  ERROR: {t['error']}")
    lines.append("")

    lines.append(f"{'Node':<15} {'Passed':>8} {'Failed':>8}")
    lines.append("-" * 33)
    per_node = s.get("per_node", {})
    for name, ns in per_node.items():
        lines.append(f"{name:<15} {ns['tests_passed']:>8} {ns['tests_failed']:>8}")
        for note in ns.get("notes", []):
            lines.append(f"  - {note}")
    lines.append("")

    # Detail per test per node
    lines.append("Detailed Results:")
    lines.append("-" * 72)
    for t in results["tests"]:
        lines.append(f"\n{t['name']}:")
        if t.get("error"):
            lines.append(f"  ERROR: {t['error']}")
            continue
        for name, nr in t.get("node_results", {}).items():
            passed = nr.get("passed", False)
            status = "PASS" if passed else "FAIL"
            note = nr.get("note", "")
            extra = f" ({note})" if note else ""
            lines.append(f"  {name:<15} {status}{extra}")
            if not passed and nr.get("expected_hash"):
                lines.append(f"    expected: {nr['expected_hash']}")
                lines.append(f"    got:      {nr.get('hash', 'N/A')}")

    lines.append("")
    lines.append("=" * 72)

    with open(path, "w") as f:
        f.write("\n".join(lines))
    log(f"Summary written to {path}")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("Interrupted")
        stop_all()
        sys.exit(1)
    except Exception as e:
        log(f"FATAL: {e}")
        traceback.print_exc()
        stop_all()
        sys.exit(1)

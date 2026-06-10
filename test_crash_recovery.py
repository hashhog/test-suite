#!/usr/bin/env python3
"""Crash recovery tests on regtest.

Starts Bitcoin Core + test nodes, mines blocks, kills nodes mid-sync
with SIGKILL, restarts, and verifies they recover correctly.
"""

import json
import os
import signal
import subprocess
import sys
import time

from regtest_miner import mine_blocks, rpc_call

HASHHOG = os.environ.get("HASHHOG_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CRASH_DIR = "/tmp/hashhog-crash"
RESULTS_DIR = os.path.expanduser("~/hashhog/test-suite/results")
RESULTS_FILE = os.path.join(RESULTS_DIR, "crash-recovery.json")

# Port allocation: 21332-21358 as specified
CORE_RPC = 21332
CORE_P2P = 21333

# Test nodes: pick 3 that are easy to start in regtest
NODES = {
    "core": {
        "binary": f"{HASHHOG}/bitcoin-core/build/bin/bitcoind",
        "args": lambda datadir: [
            "-regtest",
            f"-datadir={datadir}",
            f"-rpcport={CORE_RPC}",
            f"-port={CORE_P2P}",
            "-server=1",
            "-nolisten",
            "-rpcuser=test",
            "-rpcpassword=test",
            "-txindex=1",
            "-printtoconsole=0",
        ],
        "rpcport": CORE_RPC,
        "start_delay": 2,
    },
    "rustoshi": {
        "binary": f"{HASHHOG}/rustoshi/target/release/rustoshi",
        "args": lambda datadir: [
            "--network=regtest",
            f"--datadir={datadir}",
            "--rpcbind=127.0.0.1:21334",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--port=0",
        ],
        "rpcport": 21334,
        "start_delay": 2,
    },
    "haskoin": {
        "binary": f"{HASHHOG}/haskoin/dist-newstyle/build/x86_64-linux/ghc-9.6.7/haskoin-0.1.0.0/x/haskoin/build/haskoin/haskoin",
        "args": lambda datadir: [
            "-n", "Regtest",
            "-d", datadir,
            "node",
            "--rpcport=21336",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--listen=False",
            "--port=0",
        ],
        "rpcport": 21336,
        "start_delay": 3,
    },
    "clearbit": {
        "binary": f"{HASHHOG}/clearbit/zig-out/bin/clearbit",
        "args": lambda datadir: [
            "--regtest",
            f"--datadir={datadir}",
            "--rpcport=21338",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--port=0",
        ],
        "rpcport": 21338,
        "start_delay": 2,
    },
}

processes = {}


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def node_rpc(node_name, method, params=None):
    cfg = NODES[node_name]
    url = f"http://127.0.0.1:{cfg['rpcport']}"
    return rpc_call(url, "test", "test", method, params)


def wait_for_rpc(node_name, timeout=20):
    cfg = NODES[node_name]
    url = f"http://127.0.0.1:{cfg['rpcport']}"
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            result, err = rpc_call(url, "test", "test", "getblockchaininfo")
            if result is not None:
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


def start_node(name):
    cfg = NODES[name]
    datadir = f"{CRASH_DIR}/{name}"
    os.makedirs(datadir, exist_ok=True)

    log_path = f"{CRASH_DIR}/{name}.log"
    log_file = open(log_path, "a")

    cmd = [cfg["binary"]] + cfg["args"](datadir)
    proc = subprocess.Popen(cmd, stdout=log_file, stderr=log_file,
                            preexec_fn=os.setsid)
    processes[name] = proc
    time.sleep(cfg["start_delay"])
    if wait_for_rpc(name, timeout=20):
        log(f"  {name}: started (pid {proc.pid})")
        return True
    log(f"  {name}: FAILED to start (pid {proc.pid})")
    if proc.poll() is not None:
        log(f"  {name}: exited with code {proc.returncode}")
        try:
            with open(log_path, "r") as lf:
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
        del processes[name]


def kill_node(name):
    """Hard kill with SIGKILL (simulates crash)."""
    if name in processes:
        proc = processes[name]
        pid = proc.pid
        try:
            os.killpg(os.getpgid(pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=5)
        except Exception:
            pass
        del processes[name]
        log(f"  {name}: killed (pid {pid})")
        return True
    return False


def stop_all():
    log("Stopping all nodes...")
    for name in list(processes.keys()):
        stop_node(name)
    log("All nodes stopped.")
    # Self-clean the crash-test scratch root so a completed (or interrupted)
    # run leaves ZERO scratch behind on the /tmp tmpfs. Per-node datadirs are
    # already removed inside the test loop; this also reaps CRASH_DIR/core and
    # the root itself, and runs on the interrupt/exception paths too. Results
    # live under ~/hashhog. Set HASHHOG_KEEP_SCRATCH=1 to retain for debugging.
    if not os.environ.get("HASHHOG_KEEP_SCRATCH"):
        import shutil
        shutil.rmtree(CRASH_DIR, ignore_errors=True)


def get_block_raw(height):
    """Get raw block hex from core at given height."""
    hash_result, err = node_rpc("core", "getblockhash", [height])
    if err:
        return None, None
    raw, err = node_rpc("core", "getblock", [hash_result, 0])
    if err:
        return hash_result, None
    return hash_result, raw


def submit_blocks_to_node(name, start_height, end_height):
    """Submit blocks [start_height, end_height] to a node. Returns (accepted, failed, first_error)."""
    accepted = 0
    failed = 0
    first_error = None
    for h in range(start_height, end_height + 1):
        bhash, raw = get_block_raw(h)
        if not raw:
            failed += 1
            continue
        result, err = node_rpc(name, "submitblock", [raw])
        if err:
            # Check for "already have" type errors (not real failures)
            err_str = str(err)
            if any(x in err_str.lower() for x in ["duplicate", "already", "inconsequential"]):
                accepted += 1
            else:
                failed += 1
                if first_error is None:
                    first_error = err_str
        elif result is None or result == "":
            accepted += 1
        else:
            result_str = str(result)
            if any(x in result_str.lower() for x in ["duplicate", "already", "inconsequential"]):
                accepted += 1
            else:
                failed += 1
                if first_error is None:
                    first_error = result_str
    return accepted, failed, first_error


def get_node_height(name):
    """Get current block height of a node."""
    result, err = node_rpc(name, "getblockcount")
    if err:
        return None
    return result


def get_node_tip(name):
    """Get best block hash of a node."""
    result, err = node_rpc(name, "getbestblockhash")
    if err:
        return None
    return result


def run_crash_test(name, crash_point, total_blocks=110, base_blocks=100):
    """Run a single crash recovery test.

    1. Submit blocks 1..base_blocks
    2. Start submitting blocks base_blocks+1..total_blocks
    3. At crash_point: kill -9
    4. Restart and verify recovery
    5. Submit remaining blocks
    6. Verify tip matches core

    Returns a test result dict.
    """
    test_id = f"{name}_crash_at_{crash_point}"
    log(f"\n  --- Crash test: {name} at block {crash_point} ---")
    result = {
        "test_id": test_id,
        "node": name,
        "crash_point": crash_point,
        "passed": False,
        "steps": {},
    }

    # Step 1: Start the node
    ok = start_node(name)
    if not ok:
        result["steps"]["start"] = {"status": "fail", "error": "failed to start"}
        return result
    result["steps"]["start"] = {"status": "pass"}

    # Step 2: Submit base blocks
    log(f"  Submitting blocks 1-{base_blocks}...")
    acc, fail, err = submit_blocks_to_node(name, 1, base_blocks)
    result["steps"]["base_blocks"] = {
        "status": "pass" if fail == 0 else "fail",
        "accepted": acc, "failed": fail, "first_error": err,
    }
    if fail > 0:
        log(f"    WARNING: {fail} blocks failed during base submission: {err}")

    height_before = get_node_height(name)
    log(f"  Height after base blocks: {height_before}")

    # Step 3: Submit blocks up to crash point, then kill
    log(f"  Submitting blocks {base_blocks + 1}-{crash_point}...")
    acc, fail, err = submit_blocks_to_node(name, base_blocks + 1, crash_point)
    result["steps"]["pre_crash_blocks"] = {
        "status": "pass" if fail == 0 else "warn",
        "accepted": acc, "failed": fail,
    }

    height_at_crash = get_node_height(name)
    log(f"  Height at crash point: {height_at_crash}")
    result["steps"]["height_at_crash"] = height_at_crash

    # Step 4: SIGKILL
    log(f"  Sending SIGKILL...")
    kill_node(name)
    time.sleep(1)  # Brief pause before restart

    # Step 5: Restart
    log(f"  Restarting {name}...")
    ok = start_node(name)
    if not ok:
        result["steps"]["restart"] = {"status": "fail", "error": "failed to restart after crash"}
        return result
    result["steps"]["restart"] = {"status": "pass"}

    # Step 6: Verify RPC responsive and height >= base_blocks
    height_after_crash = get_node_height(name)
    log(f"  Height after restart: {height_after_crash}")
    result["steps"]["recovery"] = {
        "status": "pass" if height_after_crash is not None and height_after_crash >= base_blocks else "fail",
        "height_after_restart": height_after_crash,
        "minimum_expected": base_blocks,
    }

    if height_after_crash is None:
        log(f"  FAIL: node not responding after restart")
        stop_node(name)
        return result

    # Step 7: Submit remaining blocks
    remaining_start = (height_after_crash or base_blocks) + 1
    if remaining_start <= total_blocks:
        log(f"  Submitting remaining blocks {remaining_start}-{total_blocks}...")
        acc, fail, err = submit_blocks_to_node(name, remaining_start, total_blocks)
        result["steps"]["remaining_blocks"] = {
            "status": "pass" if fail == 0 else "fail",
            "accepted": acc, "failed": fail, "first_error": err,
        }
    else:
        result["steps"]["remaining_blocks"] = {"status": "pass", "note": "no remaining blocks needed"}

    # Step 8: Verify tip matches core
    core_tip = get_node_tip("core")
    core_height = get_node_height("core")
    node_tip = get_node_tip(name)
    node_height = get_node_height(name)

    tip_match = (core_tip == node_tip) if (core_tip and node_tip) else False
    result["steps"]["final_verification"] = {
        "status": "pass" if tip_match else "fail",
        "core_height": core_height,
        "core_tip": core_tip,
        "node_height": node_height,
        "node_tip": node_tip,
        "tip_match": tip_match,
    }
    log(f"  Final: node_height={node_height}, tip_match={tip_match}")

    result["passed"] = (
        result["steps"].get("restart", {}).get("status") == "pass" and
        result["steps"].get("recovery", {}).get("status") == "pass" and
        tip_match
    )

    # Clean up this node for next test
    stop_node(name)
    time.sleep(1)

    # Remove datadir so next test starts fresh
    import shutil
    datadir = f"{CRASH_DIR}/{name}"
    if os.path.exists(datadir):
        shutil.rmtree(datadir)

    status = "PASS" if result["passed"] else "FAIL"
    log(f"  Result: {status}")
    return result


def main():
    log("=" * 60)
    log("Crash Recovery Tests (regtest)")
    log("=" * 60)

    os.makedirs(CRASH_DIR, exist_ok=True)
    os.makedirs(RESULTS_DIR, exist_ok=True)

    report = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "test": "crash-recovery",
        "nodes_tested": [],
        "test_results": [],
        "summary": {},
    }

    # Check which test node binaries exist
    test_nodes = []
    for name in ["rustoshi", "haskoin", "clearbit"]:
        binary = NODES[name]["binary"]
        if os.path.isfile(binary):
            test_nodes.append(name)
            log(f"  {name}: binary found at {binary}")
        else:
            log(f"  {name}: binary NOT found at {binary}, skipping")

    if not test_nodes:
        log("No test node binaries found, exiting")
        report["summary"] = {"error": "no test node binaries available"}
        with open(RESULTS_FILE, "w") as f:
            json.dump(report, f, indent=2)
        sys.exit(1)

    report["nodes_tested"] = test_nodes

    # Start Core
    log("\n--- Starting Bitcoin Core ---")
    os.makedirs(f"{CRASH_DIR}/core", exist_ok=True)
    if not start_node("core"):
        log("FATAL: Cannot start Bitcoin Core")
        report["summary"] = {"error": "core failed to start"}
        with open(RESULTS_FILE, "w") as f:
            json.dump(report, f, indent=2)
        sys.exit(1)

    # Mine 110 blocks on Core
    log("\n--- Mining 110 blocks on Core ---")
    core_url = f"http://127.0.0.1:{CORE_RPC}"
    hashes = mine_blocks(core_url, "test", "test", 110)
    core_height = get_node_height("core")
    log(f"  Core at height {core_height}")
    report["core_height"] = core_height

    if core_height < 110:
        log("FATAL: Failed to mine enough blocks")
        stop_all()
        sys.exit(1)

    # Crash points: early (103), mid (105), late (108)
    crash_points = [103, 105, 108]
    log(f"\nCrash points to test: {crash_points}")

    # Run crash tests for each node at each crash point
    for name in test_nodes:
        log(f"\n{'='*40}")
        log(f"Testing {name}")
        log(f"{'='*40}")

        for crash_point in crash_points:
            result = run_crash_test(name, crash_point,
                                    total_blocks=110, base_blocks=100)
            report["test_results"].append(result)

    # Stop core
    stop_all()

    # Summary
    total = len(report["test_results"])
    passed = sum(1 for r in report["test_results"] if r["passed"])
    failed = total - passed

    report["summary"] = {
        "total_tests": total,
        "passed": passed,
        "failed": failed,
        "crash_points_tested": crash_points,
    }

    # Per-node summary
    per_node = {}
    for r in report["test_results"]:
        name = r["node"]
        if name not in per_node:
            per_node[name] = {"passed": 0, "failed": 0, "tests": []}
        if r["passed"]:
            per_node[name]["passed"] += 1
        else:
            per_node[name]["failed"] += 1
        per_node[name]["tests"].append({
            "crash_point": r["crash_point"],
            "passed": r["passed"],
        })
    report["summary"]["per_node"] = per_node

    log(f"\n{'='*60}")
    log(f"RESULTS: {passed}/{total} crash recovery tests passed")
    for name, info in per_node.items():
        log(f"  {name}: {info['passed']}/{info['passed'] + info['failed']} passed")
    log(f"{'='*60}")

    with open(RESULTS_FILE, "w") as f:
        json.dump(report, f, indent=2)
    log(f"Results written to {RESULTS_FILE}")

    # Final teardown: stop any straggler nodes + wipe the scratch root so the
    # normal-exit path also leaves ZERO scratch behind (the test loop only
    # removes per-node datadirs, not CRASH_DIR/core or the root).
    stop_all()

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("Interrupted")
        stop_all()
        sys.exit(1)
    except Exception as e:
        log(f"Fatal error: {e}")
        import traceback
        traceback.print_exc()
        stop_all()
        sys.exit(1)

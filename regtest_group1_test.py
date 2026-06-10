#!/usr/bin/env python3
"""Regtest consensus test -- Group 1.

Tests that haskoin, rustoshi, nimrod, beamchain, and clearbit all
accept the same blocks as Bitcoin Core and arrive at identical chain state.
"""

import json
import os
import signal
import subprocess
import sys
import time
import urllib.request
import urllib.error

from regtest_miner import mine_blocks, rpc_call

HASHHOG = os.environ.get("HASHHOG_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGTEST_DIR = "/tmp/hashhog-regtest"
RESULTS_FILE = os.path.expanduser("~/hashhog/test-suite/results/regtest-group1.json")

NODES = {
    "core": {
        "binary": f"{HASHHOG}/bitcoin-core/build/bin/bitcoind",
        "args": [
            "-regtest",
            f"-datadir={REGTEST_DIR}/core",
            "-rpcport=18443",
            "-port=18444",
            "-server=1",
            "-nolisten",
            "-rpcuser=test",
            "-rpcpassword=test",
            "-txindex=1",
            "-printtoconsole=0",
        ],
        "rpcport": 18443,
        "rpcuser": "test",
        "rpcpassword": "test",
        "start_delay": 2,
    },
    "rustoshi": {
        "binary": f"{HASHHOG}/rustoshi/target/release/rustoshi",
        "args": [
            "--network=regtest",
            f"--datadir={REGTEST_DIR}/rustoshi",
            "--rpcbind=127.0.0.1:18450",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--port=0",
        ],
        "rpcport": 18450,
        "rpcuser": "test",
        "rpcpassword": "test",
        "start_delay": 2,
    },
    "haskoin": {
        "binary": f"{HASHHOG}/haskoin/dist-newstyle/build/x86_64-linux/ghc-9.6.7/haskoin-0.1.0.0/x/haskoin/build/haskoin/haskoin",
        "args": [
            "-n", "Regtest",
            "-d", f"{REGTEST_DIR}/haskoin",
            "node",
            "--rpcport=18454",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--listen=False",
            "--port=0",
        ],
        "rpcport": 18454,
        "rpcuser": "test",
        "rpcpassword": "test",
        "start_delay": 3,
    },
    "nimrod": {
        "binary": f"{HASHHOG}/nimrod/bin/nimrod",
        "args": [
            "start",
            "--regtest",
            f"--datadir={REGTEST_DIR}/nimrod",
            "--rpcport=18453",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--port=0",
        ],
        "rpcport": 18453,
        "rpcuser": "test",
        "rpcpassword": "test",
        "start_delay": 2,
    },
    "beamchain": {
        "binary": f"{HASHHOG}/beamchain/_build/default/bin/beamchain",
        "args": [
            "start",
            "--network=regtest",
            f"--datadir={REGTEST_DIR}/beamchain",
            "--rpc-port=18448",
            "--p2p-port=0",
        ],
        "rpcport": 18448,
        "rpcuser": "",
        "rpcpassword": "",
        "start_delay": 3,
    },
    "clearbit": {
        "binary": f"{HASHHOG}/clearbit/zig-out/bin/clearbit",
        "args": [
            "--regtest",
            f"--datadir={REGTEST_DIR}/clearbit",
            "--rpcport=18456",
            "--rpcuser=test",
            "--rpcpassword=test",
            "--port=0",
        ],
        "rpcport": 18456,
        "rpcuser": "test",
        "rpcpassword": "test",
        "start_delay": 2,
    },
}

processes = {}
results = {
    "test": "regtest-group1",
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "nodes": {},
    "blocks_mined": 0,
    "test_batches": [],
    "consensus_check": {},
    "invalid_block_tests": {},
    "bugs_found": [],
    "summary": {},
}


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def node_rpc(node_name, method, params=None):
    cfg = NODES[node_name]
    url = f"http://127.0.0.1:{cfg['rpcport']}"
    return rpc_call(url, cfg["rpcuser"], cfg["rpcpassword"], method, params)


def wait_for_rpc(node_name, timeout=15):
    cfg = NODES[node_name]
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


def start_node(name):
    cfg = NODES[name]
    datadir = f"{REGTEST_DIR}/{name}"
    os.makedirs(datadir, exist_ok=True)

    log_path = f"{REGTEST_DIR}/{name}.log"
    log_file = open(log_path, "w")

    cmd = [cfg["binary"]] + cfg["args"]
    proc = subprocess.Popen(cmd, stdout=log_file, stderr=log_file,
                            preexec_fn=os.setsid)
    processes[name] = proc
    time.sleep(cfg["start_delay"])
    if wait_for_rpc(name, timeout=20):
        log(f"  {name}: started (pid {proc.pid})")
        return True
    log(f"  {name}: FAILED to start (pid {proc.pid})")
    if proc.poll() is not None:
        log(f"  {name}: process exited with code {proc.returncode}")
        try:
            with open(log_path, "r") as lf:
                lines = lf.readlines()
                for line in lines[-5:]:
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
    for name in list(NODES.keys()):
        stop_node(name)
    log("All nodes stopped.")
    # Self-clean the regtest scratch root so a completed run leaves ZERO
    # scratch behind on the /tmp tmpfs (RESULTS_FILE lives under ~/hashhog,
    # not here, so it survives). Runs on every exit path (main + the
    # KeyboardInterrupt/Exception handlers all call stop_all). Set
    # HASHHOG_KEEP_SCRATCH=1 to retain the datadirs for debugging.
    if not os.environ.get("HASHHOG_KEEP_SCRATCH"):
        import shutil
        shutil.rmtree(REGTEST_DIR, ignore_errors=True)


def get_block_raw(height):
    hash_result, err = node_rpc("core", "getblockhash", [height])
    if err:
        return None, None
    raw, err = node_rpc("core", "getblock", [hash_result, 0])
    if err:
        return hash_result, None
    return hash_result, raw


def submit_block_to_node(name, raw_hex):
    result, err = node_rpc(name, "submitblock", [raw_hex])
    if err:
        return False, str(err)
    if result is None or result == "":
        return True, None
    return False, str(result)


def verify_chain_tip(started_nodes):
    """Compare chain tips across all nodes."""
    core_tip, _ = node_rpc("core", "getbestblockhash")
    core_count, _ = node_rpc("core", "getblockcount")
    log(f"  Core tip: height={core_count}, hash={core_tip}")

    tip_results = {}
    for name in started_nodes:
        if name == "core":
            continue
        tip, _ = node_rpc(name, "getbestblockhash")
        cnt, _ = node_rpc(name, "getblockcount")
        matches_hash = (tip == core_tip)
        tip_results[name] = {
            "height": cnt,
            "hash": tip,
            "core_height": core_count,
            "core_hash": core_tip,
            "hash_matches": matches_hash,
        }
        status = "MATCH" if matches_hash else "MISMATCH"
        log(f"  {name}: height={cnt}, tip_hash_match={status}")
    return tip_results


def verify_blocks(started_nodes, height_range, batch_name):
    """Verify block data matches Core for a range of heights."""
    log(f"Verifying {batch_name} (heights {height_range[0]}-{height_range[-1]})...")
    batch_result = {"name": batch_name, "range": [height_range[0], height_range[-1]],
                    "nodes": {}}

    # Get Core's block data
    core_blocks = {}
    for h in height_range:
        bhash, _ = node_rpc("core", "getblockhash", [h])
        if bhash:
            block_info, _ = node_rpc("core", "getblock", [bhash, 1])
            core_blocks[h] = {
                "hash": bhash,
                "merkleroot": block_info.get("merkleroot") if block_info else None,
                "nTx": block_info.get("nTx") if block_info else None,
                "size": block_info.get("size") if block_info else None,
                "weight": block_info.get("weight") if block_info else None,
            }

    for name in started_nodes:
        if name == "core":
            continue
        if not results["nodes"].get(name, {}).get("started"):
            continue

        node_result = {"hash_matches": 0, "hash_mismatches": 0, "errors": 0, "details": []}

        for h in height_range:
            if h not in core_blocks:
                continue
            bhash, err = node_rpc(name, "getblockhash", [h])
            if err:
                node_result["errors"] += 1
                node_result["details"].append({"height": h, "error": str(err)})
                continue

            if bhash == core_blocks[h]["hash"]:
                node_result["hash_matches"] += 1
            else:
                node_result["hash_mismatches"] += 1
                node_result["details"].append({
                    "height": h,
                    "expected": core_blocks[h]["hash"],
                    "got": bhash,
                })

        batch_result["nodes"][name] = node_result
        total = len(height_range)
        log(f"  {name}: {node_result['hash_matches']}/{total} match, "
            f"{node_result['hash_mismatches']} mismatch, {node_result['errors']} err")

    return batch_result


def test_invalid_blocks(started_nodes):
    """Test that nodes reject invalid blocks."""
    log("Testing invalid block rejection...")
    invalid_results = {}

    # Get the latest valid block and corrupt the nonce
    core_count, _ = node_rpc("core", "getblockcount")
    _, raw = get_block_raw(core_count)
    if not raw:
        log("  Could not get block for corruption tests")
        return invalid_results

    # Corrupt nonce (bytes 76-79 of header, hex positions 152-159)
    corrupted = raw[:152] + "deadbeef" + raw[160:]

    for name in started_nodes:
        if name == "core":
            continue
        if not results["nodes"].get(name, {}).get("started"):
            continue

        invalid_results[name] = {}

        # Test 1: Corrupted nonce
        accepted, err_msg = submit_block_to_node(name, corrupted)
        invalid_results[name]["corrupt_nonce"] = {
            "correctly_rejected": not accepted,
            "error": err_msg,
        }
        status = "REJECTED (correct)" if not accepted else "ACCEPTED (BUG!)"
        log(f"  {name} corrupt_nonce: {status}")

    return invalid_results


def main():
    log("=" * 60)
    log("Regtest Consensus Test - Group 1")
    log("=" * 60)

    # Create directories
    for name in NODES:
        os.makedirs(f"{REGTEST_DIR}/{name}", exist_ok=True)

    # --- Phase 1: Start all nodes ---
    log("\n--- Phase 1: Starting nodes ---")
    started_nodes = []

    for name in NODES:
        ok = start_node(name)
        results["nodes"][name] = {"started": ok}
        if ok:
            started_nodes.append(name)
        elif name == "core":
            log("FATAL: Cannot start Bitcoin Core")
            stop_all()
            sys.exit(1)

    log(f"\nStarted: {started_nodes}")
    not_started = [n for n in NODES if n not in started_nodes]
    if not_started:
        log(f"Failed to start: {not_started}")
        for name in not_started:
            if name != "core":
                results["bugs_found"].append({
                    "node": name,
                    "category": "startup",
                    "description": f"{name} failed to start in regtest mode",
                    "severity": "blocker",
                })

    # --- Phase 2: Mine blocks on Core ---
    log("\n--- Phase 2: Mining blocks on Core ---")
    core_url = "http://127.0.0.1:18443"

    log("Mining 150 base blocks...")
    mine_blocks(core_url, "test", "test", 150)
    count, _ = node_rpc("core", "getblockcount")
    log(f"  Core at height {count}")

    log("Batch 1: Basic blocks (151-160)")
    mine_blocks(core_url, "test", "test", 5, extra_data=b"batch1-basic")
    mine_blocks(core_url, "test", "test", 5, extra_data=b"batch1-varied")

    log("Batch 2: More blocks (161-170)")
    mine_blocks(core_url, "test", "test", 10, extra_data=b"batch2-scripts")

    log("Batch 3: Edge cases (171-180)")
    for i in range(10):
        data = f"edge-{i}".encode() + b"\x00" * (i * 5)
        mine_blocks(core_url, "test", "test", 1, extra_data=data)

    total_count, _ = node_rpc("core", "getblockcount")
    results["blocks_mined"] = total_count
    log(f"Total blocks on Core: {total_count}")

    # --- Phase 3: Submit blocks to test nodes ---
    log("\n--- Phase 3: Submitting blocks to test nodes ---")

    for name in started_nodes:
        if name == "core":
            continue
        log(f"  Submitting to {name}...")
        accept_count = 0
        fail_count = 0
        first_error = None
        first_error_height = None

        # Submit blocks 1..total_count (skip genesis, nodes have it)
        for h in range(1, total_count + 1):
            bhash, raw = get_block_raw(h)
            if not raw:
                fail_count += 1
                continue
            accepted, err_msg = submit_block_to_node(name, raw)
            if accepted:
                accept_count += 1
            else:
                if err_msg and any(x in str(err_msg).lower() for x in
                                   ["duplicate", "already", "inconsequential"]):
                    accept_count += 1
                else:
                    fail_count += 1
                    if first_error is None:
                        first_error = err_msg
                        first_error_height = h

        results["nodes"][name]["blocks_accepted"] = accept_count
        results["nodes"][name]["blocks_rejected"] = fail_count
        results["nodes"][name]["first_error"] = first_error
        results["nodes"][name]["first_error_height"] = first_error_height
        log(f"    {accept_count} accepted, {fail_count} rejected")
        if first_error:
            log(f"    First error at height {first_error_height}: {first_error}")

    # --- Phase 4: Verify consensus ---
    log("\n--- Phase 4: Chain tip comparison ---")
    tip_results = verify_chain_tip(started_nodes)
    results["consensus_check"]["tips"] = tip_results

    log("\n--- Phase 4b: Block-by-block verification ---")
    batches = []
    batches.append(verify_blocks(started_nodes, list(range(1, 11)), "initial_blocks"))
    batches.append(verify_blocks(started_nodes, list(range(151, 161)), "batch1_basic"))
    batches.append(verify_blocks(started_nodes, list(range(161, 171)), "batch2_scripts"))
    batches.append(verify_blocks(started_nodes, list(range(171, 181)), "batch3_edge_cases"))
    results["test_batches"] = batches

    # --- Phase 5: Invalid block rejection ---
    log("\n--- Phase 5: Invalid block rejection ---")
    results["invalid_block_tests"] = test_invalid_blocks(started_nodes)

    # --- Phase 6: Bug analysis ---
    log("\n--- Phase 6: Bug analysis ---")

    for name in started_nodes:
        if name == "core":
            continue
        node_info = results["nodes"][name]
        tip_info = tip_results.get(name, {})
        tip_match = tip_info.get("hash_matches", False)
        all_accepted = node_info.get("blocks_rejected", 0) == 0

        # Check for specific bugs
        if not tip_match and all_accepted:
            # Blocks accepted but chain tip wrong
            reported_height = tip_info.get("height")
            core_height = tip_info.get("core_height")
            if reported_height == 0 and core_height > 0:
                results["bugs_found"].append({
                    "node": name,
                    "category": "submitblock",
                    "description": f"{name}: submitblock RPC accepts blocks but does not process them (chain tip stays at genesis)",
                    "severity": "critical",
                })
            elif reported_height is not None and core_height is not None:
                if reported_height != core_height:
                    results["bugs_found"].append({
                        "node": name,
                        "category": "rpc",
                        "description": f"{name}: getblockcount returns {reported_height} instead of {core_height} (off-by-one)",
                        "severity": "moderate",
                    })

        if not all_accepted:
            first_err = node_info.get("first_error", "")
            if "BIP-34" in str(first_err) or "height" in str(first_err).lower():
                results["bugs_found"].append({
                    "node": name,
                    "category": "validation",
                    "description": f"{name}: BIP-34 coinbase height parsing rejects valid blocks with OP_1..OP_16 height encoding",
                    "severity": "critical",
                    "detail": str(first_err),
                })
            else:
                results["bugs_found"].append({
                    "node": name,
                    "category": "validation",
                    "description": f"{name}: block rejection starting at height {node_info.get('first_error_height')}: {first_err}",
                    "severity": "critical",
                })

        # Check invalid block rejection
        inv = results["invalid_block_tests"].get(name, {})
        if inv.get("corrupt_nonce", {}).get("correctly_rejected") is False:
            results["bugs_found"].append({
                "node": name,
                "category": "validation",
                "description": f"{name}: accepts blocks with invalid PoW (corrupt nonce)",
                "severity": "critical",
            })

        # Check getblockhash off-by-one
        for batch in batches:
            node_batch = batch["nodes"].get(name, {})
            if node_batch.get("hash_mismatches", 0) > 0:
                details = node_batch.get("details", [])
                if len(details) >= 2:
                    # Check if it's a systematic off-by-one
                    d0 = details[0]
                    d1 = details[1]
                    if (d0.get("got") and d1.get("expected") and
                            d0.get("got") == d1.get("expected")):
                        results["bugs_found"].append({
                            "node": name,
                            "category": "rpc",
                            "description": f"{name}: getblockhash has off-by-one error (returns hash for height N-1 instead of N)",
                            "severity": "moderate",
                        })
                        break

    # --- Phase 7: Summary ---
    log("\n--- Summary ---")

    for bug in results["bugs_found"]:
        log(f"  BUG [{bug['severity']}] {bug['node']}: {bug['description']}")

    # Determine pass/fail per node
    # A node "passes" if: started, all blocks accepted, chain tip hash matches Core
    total_tested = 0
    passing = 0
    for name in NODES:
        if name == "core":
            continue
        total_tested += 1
        node_info = results["nodes"].get(name, {})
        tip_info = tip_results.get(name, {})

        started = node_info.get("started", False)
        tip_match = tip_info.get("hash_matches", False)
        all_accepted = node_info.get("blocks_rejected", 0) == 0

        node_pass = started and tip_match and all_accepted
        node_info["verdict"] = "PASS" if node_pass else "FAIL"

        if not started:
            node_info["fail_reason"] = "failed to start"
        elif not all_accepted:
            node_info["fail_reason"] = f"{node_info.get('blocks_rejected', 0)} blocks rejected"
        elif not tip_match:
            node_info["fail_reason"] = "chain tip mismatch"

        if node_pass:
            passing += 1
        status = "PASS" if node_pass else "FAIL"
        reason = f" ({node_info.get('fail_reason', '')})" if not node_pass else ""
        log(f"  {name}: {status}{reason}")

    results["summary"] = {
        "total_nodes": total_tested,
        "passing": passing,
        "failing": total_tested - passing,
        "core_height": total_count,
        "bugs_found": len(results["bugs_found"]),
    }

    log(f"\nResult: {passing}/{total_tested} nodes passing, {len(results['bugs_found'])} bugs found")

    # Write results
    os.makedirs(os.path.dirname(RESULTS_FILE), exist_ok=True)
    with open(RESULTS_FILE, "w") as f:
        json.dump(results, f, indent=2)
    log(f"Results written to {RESULTS_FILE}")

    # Cleanup
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
        log(f"Error: {e}")
        import traceback
        traceback.print_exc()
        stop_all()
        sys.exit(1)

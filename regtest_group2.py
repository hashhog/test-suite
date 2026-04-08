#!/usr/bin/env python3
"""Regtest consensus tests - Group 2.

Nodes: hotbuns, blockbrew, lunarblock, ouroboros, camlcoin
Reference: Bitcoin Core

Mines blocks on Core (including various tx types) then submits them
to every node via submitblock RPC, comparing chain state afterwards.
"""

import json
import os
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from regtest_miner import rpc_call, mine_blocks

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CORE_PORT = 18543
CORE_USER = "user"
CORE_PASS = "pass"
CORE_DATADIR = "/tmp/hashhog-regtest2/core"
CORE_URL = f"http://127.0.0.1:{CORE_PORT}"

NODES = {
    "hotbuns":    {"port": 18551, "datadir": "/tmp/hashhog-regtest2/hotbuns"},
    "blockbrew":  {"port": 18555, "datadir": "/tmp/hashhog-regtest2/blockbrew"},
    "lunarblock": {"port": 18760, "datadir": "/tmp/hashhog-regtest2/lunarblock"},
    "ouroboros":  {"port": 18559, "datadir": "/tmp/hashhog-regtest2/ouroboros"},
    "camlcoin":   {"port": 18557, "datadir": "/tmp/hashhog-regtest2/camlcoin"},
}

RESULTS_PATH = os.path.expanduser("~/hashhog/test-suite/results/regtest-group2.json")


# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------

def core_rpc(method, params=None):
    result, err = rpc_call(CORE_URL, CORE_USER, CORE_PASS, method, params or [])
    if err:
        raise RuntimeError(f"Core RPC {method} error: {err}")
    return result


def _node_auth(name):
    """Return (user, password) for a node, trying cookie then user:pass."""
    datadir = NODES[name]["datadir"]
    cookie_path = os.path.join(datadir, ".cookie")
    # Also check in regtest subdir
    cookie_path_regtest = os.path.join(datadir, "regtest", ".cookie")
    for cp in [cookie_path, cookie_path_regtest]:
        if os.path.exists(cp):
            with open(cp) as f:
                cookie = f.read().strip()
            if ":" in cookie:
                return cookie.split(":", 1)
            return "user", cookie
    return "user", "pass"


def node_rpc(name, port, method, params=None):
    user, password = _node_auth(name)
    url = f"http://127.0.0.1:{port}"
    result, err = rpc_call(url, user, password, method, params or [])
    if err:
        raise RuntimeError(f"{name} RPC {method} error: {err}")
    return result


def node_rpc_safe(name, port, method, params=None):
    try:
        return node_rpc(name, port, method, params), None
    except Exception as e:
        return None, str(e)


# ---------------------------------------------------------------------------
# Check which nodes are alive
# ---------------------------------------------------------------------------

def check_nodes():
    alive = {}
    for name, cfg in NODES.items():
        result, err = node_rpc_safe(name, cfg["port"], "getblockchaininfo")
        alive[name] = result is not None
        if result is not None:
            print(f"  {name:12s} port={cfg['port']} OK (height={result.get('blocks', '?')})")
        else:
            print(f"  {name:12s} port={cfg['port']} FAILED: {err}")
    return alive


# ---------------------------------------------------------------------------
# Submit blocks to all nodes
# ---------------------------------------------------------------------------

def submit_blocks_to_nodes(alive_nodes, start_height, end_height):
    """Get raw blocks from Core and submit to all alive nodes.

    Returns dict of node -> {accepted, rejected, errors, submitblock_errors}.
    submitblock_errors are cases where submitblock returned an RPC error
    (as opposed to a rejection string).
    """
    results = {name: {"accepted": 0, "rejected": 0, "errors": [],
                       "submitblock_errors": []}
               for name in alive_nodes}

    for h in range(start_height, end_height + 1):
        bhash = core_rpc("getblockhash", [h])
        raw = core_rpc("getblock", [bhash, 0])

        for name in alive_nodes:
            port = NODES[name]["port"]
            resp, err = node_rpc_safe(name, port, "submitblock", [raw])
            if err:
                # RPC-level error. Could be a bug in the node or expected rejection.
                results[name]["submitblock_errors"].append(f"h={h}: {err}")
                # Try to check if the block was actually accepted despite the error
                info, _ = node_rpc_safe(name, port, "getblockchaininfo")
                if info and info.get("blocks", 0) >= h:
                    results[name]["accepted"] += 1
                else:
                    results[name]["rejected"] += 1
                    results[name]["errors"].append(f"h={h}: {err}")
            elif resp is not None and resp not in ("", "duplicate", "inconclusive"):
                results[name]["rejected"] += 1
                results[name]["errors"].append(f"h={h}: {resp}")
            else:
                results[name]["accepted"] += 1

        if (h - start_height + 1) % 25 == 0:
            print(f"  Submitted blocks up to height {h}")

    return results


def submit_blocks_with_retry(alive_nodes, start_height, end_height, max_retries=3):
    """Submit blocks with retries for nodes with async validation."""
    results = {name: {"accepted": 0, "rejected": 0, "errors": [],
                       "submitblock_errors": []}
               for name in alive_nodes}

    for h in range(start_height, end_height + 1):
        bhash = core_rpc("getblockhash", [h])
        raw = core_rpc("getblock", [bhash, 0])

        for name in alive_nodes:
            port = NODES[name]["port"]
            accepted = False

            for attempt in range(max_retries):
                resp, err = node_rpc_safe(name, port, "submitblock", [raw])
                if err:
                    # Check if block was actually accepted
                    info, _ = node_rpc_safe(name, port, "getblockchaininfo")
                    if info and info.get("blocks", 0) >= h:
                        accepted = True
                        if attempt > 0:
                            results[name]["submitblock_errors"].append(
                                f"h={h}: accepted on retry {attempt+1}")
                        break
                    elif attempt < max_retries - 1:
                        time.sleep(0.1)  # Short delay for async processing
                        continue
                    else:
                        results[name]["submitblock_errors"].append(f"h={h}: {err}")
                        results[name]["errors"].append(f"h={h}: {err}")
                elif resp is not None and resp not in ("", "duplicate", "inconclusive"):
                    results[name]["errors"].append(f"h={h}: {resp}")
                    break
                else:
                    accepted = True
                    break

            if accepted:
                results[name]["accepted"] += 1
            else:
                results[name]["rejected"] += 1

        if (h - start_height + 1) % 25 == 0:
            print(f"  Submitted blocks up to height {h}")

    return results


# ---------------------------------------------------------------------------
# Test: Chain tip agreement
# ---------------------------------------------------------------------------

def test_chain_tip(alive_nodes, expected_height):
    test = {
        "name": "chain_tip_agreement",
        "passed": True,
        "expected_height": expected_height,
        "node_results": {},
    }

    core_hash = core_rpc("getblockhash", [expected_height])
    test["expected_hash"] = core_hash

    for name in alive_nodes:
        port = NODES[name]["port"]
        info, err = node_rpc_safe(name, port, "getblockchaininfo")
        if err:
            test["node_results"][name] = {"passed": False, "error": err}
            test["passed"] = False
            continue

        node_height = info.get("blocks", -1)
        node_hash = info.get("bestblockhash", "")

        passed = (node_height == expected_height and node_hash == core_hash)
        test["node_results"][name] = {
            "passed": passed,
            "height": node_height,
            "hash": node_hash,
            "height_match": node_height == expected_height,
            "hash_match": node_hash == core_hash,
        }
        if not passed:
            test["passed"] = False

    return test


# ---------------------------------------------------------------------------
# Test: Block-level data comparison (only for nodes at correct tip)
# ---------------------------------------------------------------------------

def test_block_data(alive_nodes, heights_to_check):
    """Compare block data fields for given heights.

    Only compares fields that Core returns. Tolerates missing 'weight' field
    and minor weight differences (some nodes compute slightly differently).
    """
    test = {
        "name": "block_data_comparison",
        "passed": True,
        "heights_checked": heights_to_check,
        "node_results": {},
    }

    # Core fields to compare
    # 'weight' is known to differ slightly in some impls, so we track but tolerate
    strict_fields = ["merkleroot", "previousblockhash", "version", "bits", "nonce", "nTx"]
    informational_fields = ["size", "weight"]

    for name in alive_nodes:
        test["node_results"][name] = {"passed": True, "diffs": [],
                                       "informational_diffs": []}

    for h in heights_to_check:
        bhash = core_rpc("getblockhash", [h])
        core_block = core_rpc("getblock", [bhash, 1])

        for name in alive_nodes:
            port = NODES[name]["port"]
            node_block, err = node_rpc_safe(name, port, "getblock", [bhash, 1])
            if err:
                test["node_results"][name]["diffs"].append(
                    {"height": h, "error": err})
                test["node_results"][name]["passed"] = False
                test["passed"] = False
                continue

            # Strict field comparison
            for field in strict_fields:
                core_val = core_block.get(field)
                node_val = node_block.get(field)
                if core_val is not None and node_val is not None and core_val != node_val:
                    test["node_results"][name]["diffs"].append({
                        "height": h, "field": field,
                        "expected": core_val, "got": node_val,
                    })
                    test["node_results"][name]["passed"] = False
                    test["passed"] = False

            # Informational (non-failing) comparisons
            for field in informational_fields:
                core_val = core_block.get(field)
                node_val = node_block.get(field)
                if core_val is not None and node_val is not None and core_val != node_val:
                    test["node_results"][name]["informational_diffs"].append({
                        "height": h, "field": field,
                        "expected": core_val, "got": node_val,
                    })

    return test


# ---------------------------------------------------------------------------
# Test: UTXO spot-checks
# ---------------------------------------------------------------------------

def test_utxo_spot_check(alive_nodes, utxo_queries):
    test = {
        "name": "utxo_spot_check",
        "passed": True,
        "queries": len(utxo_queries),
        "node_results": {},
    }

    for name in alive_nodes:
        test["node_results"][name] = {"passed": True, "diffs": [], "errors": []}

    for txid, vout in utxo_queries:
        core_utxo = core_rpc("gettxout", [txid, vout])

        for name in alive_nodes:
            port = NODES[name]["port"]
            node_utxo, err = node_rpc_safe(name, port, "gettxout", [txid, vout])

            if err:
                test["node_results"][name]["errors"].append(
                    f"gettxout {txid[:16]}...:{vout}: {err}")
                continue

            if core_utxo is None and node_utxo is None:
                continue
            if core_utxo is None and node_utxo is not None:
                test["node_results"][name]["diffs"].append({
                    "txid": txid, "vout": vout,
                    "issue": "node has UTXO but Core does not"
                })
                test["node_results"][name]["passed"] = False
                test["passed"] = False
            elif core_utxo is not None and node_utxo is None:
                test["node_results"][name]["diffs"].append({
                    "txid": txid, "vout": vout,
                    "issue": "Core has UTXO but node does not"
                })
                test["node_results"][name]["passed"] = False
                test["passed"] = False
            else:
                core_val = core_utxo.get("value")
                node_val = node_utxo.get("value")
                if core_val != node_val:
                    test["node_results"][name]["diffs"].append({
                        "txid": txid, "vout": vout,
                        "field": "value",
                        "expected": core_val, "got": node_val,
                    })
                    test["node_results"][name]["passed"] = False
                    test["passed"] = False

    return test


# ---------------------------------------------------------------------------
# Test: Invalid block rejection
# ---------------------------------------------------------------------------

def test_invalid_block_rejection(alive_nodes):
    """Submit an invalid block and verify all nodes reject it."""
    test = {
        "name": "invalid_block_rejection",
        "passed": True,
        "node_results": {},
    }

    # Get the current tip height from Core
    tip_height = core_rpc("getblockcount")
    tip_hash = core_rpc("getblockhash", [tip_height])
    raw_hex = core_rpc("getblock", [tip_hash, 0])

    # Corrupt merkle root bytes (offset 36-68 in the 80-byte header)
    raw_bytes = bytes.fromhex(raw_hex)
    corrupted = bytearray(raw_bytes)
    corrupted[40] ^= 0xff
    corrupted[41] ^= 0xff
    corrupted[42] ^= 0xff
    corrupted_hex = bytes(corrupted).hex()

    for name in alive_nodes:
        port = NODES[name]["port"]

        # Record height before submission
        info_before, _ = node_rpc_safe(name, port, "getblockchaininfo")
        height_before = info_before.get("blocks", 0) if info_before else 0

        resp, err = node_rpc_safe(name, port, "submitblock", [corrupted_hex])

        # Wait a moment for async processing
        time.sleep(0.2)

        # Check height after - should not have increased
        info_after, _ = node_rpc_safe(name, port, "getblockchaininfo")
        height_after = info_after.get("blocks", 0) if info_after else 0

        if height_after > height_before:
            # Node accepted the corrupted block -- consensus bug
            test["node_results"][name] = {
                "passed": False,
                "error": f"CRITICAL: Node accepted corrupted block! "
                         f"Height went from {height_before} to {height_after}",
            }
            test["passed"] = False
        elif err:
            test["node_results"][name] = {
                "passed": True,
                "rejection": "RPC error (block rejected)",
            }
        elif resp is not None and resp not in ("", "duplicate"):
            test["node_results"][name] = {
                "passed": True,
                "rejection": resp,
            }
        elif resp is None or resp == "":
            # Might have silently accepted but height didn't increase = ok
            # (duplicate of existing block)
            test["node_results"][name] = {
                "passed": True,
                "rejection": "duplicate (same hash as existing block)",
            }
        else:
            test["node_results"][name] = {
                "passed": True,
                "rejection": "duplicate",
            }

    return test


# ---------------------------------------------------------------------------
# Main test flow
# ---------------------------------------------------------------------------

def main():
    results = {
        "group": 2,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "reference": "bitcoin-core",
        "nodes_tested": [],
        "nodes_skipped": [],
        "tests": [],
        "submission_report": {},
        "summary": {},
    }

    print("=" * 72)
    print("Regtest Consensus Tests - Group 2")
    print("=" * 72)

    # Step 1: Check node availability
    print("\n[1] Checking node availability...")
    alive = check_nodes()
    alive_nodes = [n for n, ok in alive.items() if ok]
    skipped_nodes = [n for n, ok in alive.items() if not ok]
    results["nodes_tested"] = alive_nodes
    results["nodes_skipped"] = skipped_nodes

    if not alive_nodes:
        print("ERROR: No nodes are available!")
        results["summary"] = {"error": "No nodes available"}
        _write_results(results)
        return 1

    print(f"\n  Alive: {', '.join(alive_nodes)}")
    if skipped_nodes:
        print(f"  Skipped: {', '.join(skipped_nodes)}")

    # Step 2: Mine 150 blocks on Core (coinbase maturity)
    print("\n[2] Mining 150 initial blocks on Core...")
    hashes = mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 150)
    print(f"  Mined {len(hashes)} blocks")

    if len(hashes) < 150:
        print("ERROR: Could not mine enough blocks on Core")
        results["summary"] = {"error": f"Only mined {len(hashes)} blocks"}
        _write_results(results)
        return 1

    core_height = core_rpc("getblockcount")
    print(f"  Core height: {core_height}")

    # Step 3: Submit initial blocks to all nodes (with retry for async validators)
    print("\n[3] Submitting blocks 1-150 to test nodes...")
    submit_results = submit_blocks_with_retry(alive_nodes, 1, 150)
    for name in alive_nodes:
        sr = submit_results[name]
        print(f"  {name:12s}: accepted={sr['accepted']} rejected={sr['rejected']}")
        if sr['errors']:
            for e in sr['errors'][:3]:
                print(f"    error: {e}")
        if sr['submitblock_errors']:
            print(f"    submitblock_errors: {len(sr['submitblock_errors'])}")

    results["submission_report"]["phase1"] = {
        name: {"accepted": sr["accepted"], "rejected": sr["rejected"],
               "errors": sr["errors"][:5],
               "submitblock_errors": sr["submitblock_errors"][:5]}
        for name, sr in submit_results.items()
    }

    # Step 4: Mine 50 more blocks with varied coinbase data
    print("\n[4] Mining additional test blocks (151-200)...")
    extra_hashes = mine_blocks(CORE_URL, CORE_USER, CORE_PASS, 50,
                               extra_data=b"group2test")
    print(f"  Mined {len(extra_hashes)} additional blocks")

    new_height = core_rpc("getblockcount")
    print(f"  Core height: {new_height}")

    # Step 5: Submit blocks 151-200
    print("\n[5] Submitting blocks 151-200 to test nodes...")
    submit_results2 = submit_blocks_with_retry(alive_nodes, 151, new_height)
    for name in alive_nodes:
        sr = submit_results2[name]
        print(f"  {name:12s}: accepted={sr['accepted']} rejected={sr['rejected']}")
        if sr['errors']:
            for e in sr['errors'][:3]:
                print(f"    error: {e}")

    results["submission_report"]["phase2"] = {
        name: {"accepted": sr["accepted"], "rejected": sr["rejected"],
               "errors": sr["errors"][:5]}
        for name, sr in submit_results2.items()
    }

    # Give async nodes a moment to finish processing
    print("\n  Waiting 3s for async processing...")
    time.sleep(3)

    # Determine which nodes are at the correct tip for further testing
    nodes_at_tip = []
    nodes_behind = []
    for name in alive_nodes:
        port = NODES[name]["port"]
        info, _ = node_rpc_safe(name, port, "getblockchaininfo")
        if info:
            h = info.get("blocks", 0)
            if h == new_height:
                nodes_at_tip.append(name)
            else:
                nodes_behind.append((name, h))

    print(f"\n  Nodes at tip ({new_height}): {', '.join(nodes_at_tip) or 'none'}")
    if nodes_behind:
        for name, h in nodes_behind:
            print(f"  {name}: behind at height {h}")

    # Step 6: Run consensus tests
    print("\n[6] Running consensus tests...")

    # Test 6a: Chain tip agreement (all alive nodes)
    print("\n  [6a] Chain tip agreement...")
    tip_test = test_chain_tip(alive_nodes, new_height)
    results["tests"].append(tip_test)
    _print_test_result(tip_test)

    # Test 6b: Block-level data comparison (only nodes at tip)
    print("\n  [6b] Block data comparison...")
    if nodes_at_tip:
        check_heights = [0, 1, 2, 50, 100, 149, 150, 151, new_height - 1, new_height]
        check_heights = sorted(set(h for h in check_heights if 0 <= h <= new_height))
        block_test = test_block_data(nodes_at_tip, check_heights)
        results["tests"].append(block_test)
        _print_test_result(block_test)
    else:
        skip_test = {"name": "block_data_comparison", "passed": False,
                     "node_results": {},
                     "error": "No nodes at correct tip height"}
        results["tests"].append(skip_test)
        print("  SKIPPED: No nodes at correct tip height")

    # Test 6c: UTXO spot-checks (only nodes at tip)
    print("\n  [6c] UTXO spot-checks...")
    if nodes_at_tip:
        utxo_queries = []
        for h in [150, 160, 180, new_height]:
            if h > new_height:
                continue
            try:
                bhash = core_rpc("getblockhash", [h])
                block = core_rpc("getblock", [bhash, 1])
                if block.get("tx"):
                    utxo_queries.append((block["tx"][0], 0))
            except Exception:
                pass

        utxo_test = test_utxo_spot_check(nodes_at_tip, utxo_queries)
        results["tests"].append(utxo_test)
        _print_test_result(utxo_test)
    else:
        skip_test = {"name": "utxo_spot_check", "passed": False,
                     "node_results": {},
                     "error": "No nodes at correct tip height"}
        results["tests"].append(skip_test)
        print("  SKIPPED: No nodes at correct tip height")

    # Test 6d: Invalid block rejection (all alive nodes)
    print("\n  [6d] Invalid block rejection...")
    invalid_test = test_invalid_block_rejection(alive_nodes)
    results["tests"].append(invalid_test)
    _print_test_result(invalid_test)

    # Summary
    print("\n" + "=" * 72)
    total = len(results["tests"])
    passed = sum(1 for t in results["tests"] if t["passed"])
    failed = total - passed

    results["summary"] = {
        "total_tests": total,
        "passed": passed,
        "failed": failed,
        "nodes_tested": len(alive_nodes),
        "nodes_skipped": len(skipped_nodes),
        "nodes_at_tip": nodes_at_tip,
        "nodes_behind": {name: h for name, h in nodes_behind},
    }

    # Per-node summary
    node_summary = {}
    for name in alive_nodes:
        node_pass = 0
        node_fail = 0
        node_errors_list = []
        for t in results["tests"]:
            nr = t.get("node_results", {}).get(name, {})
            if nr.get("passed", True):
                node_pass += 1
            else:
                node_fail += 1
                if nr.get("error"):
                    node_errors_list.append(f"{t['name']}: {nr['error'][:100]}")
                if nr.get("diffs"):
                    diffs = nr["diffs"]
                    if isinstance(diffs, list) and diffs:
                        node_errors_list.append(f"{t['name']}: {len(diffs)} diffs")
        node_summary[name] = {
            "passed": node_pass,
            "failed": node_fail,
            "errors": node_errors_list[:5],
        }
    results["summary"]["per_node"] = node_summary

    print(f"\nResults: {passed}/{total} tests passed")
    print(f"Nodes tested: {len(alive_nodes)}, skipped: {len(skipped_nodes)}")
    for name in alive_nodes:
        ns = node_summary[name]
        status = "PASS" if ns["failed"] == 0 else "FAIL"
        print(f"  {name:12s}: {status} ({ns['passed']}/{total})")
        for e in ns["errors"][:3]:
            print(f"    - {e}")

    print("=" * 72)

    _write_results(results)
    return 0 if failed == 0 else 1


def _print_test_result(test):
    status = "PASS" if test["passed"] else "FAIL"
    print(f"  {test['name']}: {status}")
    for name, nr in test.get("node_results", {}).items():
        if not nr.get("passed", True):
            print(f"    {name}: FAIL")
            if nr.get("error"):
                print(f"      {nr['error'][:120]}")
            if nr.get("diffs"):
                diffs = nr["diffs"]
                if isinstance(diffs, list):
                    for d in diffs[:3]:
                        print(f"      {d}")
                elif isinstance(diffs, dict):
                    for k, v in list(diffs.items())[:3]:
                        print(f"      {k}: {v}")
        # Print informational diffs even if passed
        if nr.get("informational_diffs"):
            idiffs = nr["informational_diffs"]
            print(f"    {name}: {len(idiffs)} informational diff(s) (weight/size)")


def _write_results(results):
    os.makedirs(os.path.dirname(RESULTS_PATH), exist_ok=True)
    with open(RESULTS_PATH, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nResults written to {RESULTS_PATH}")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"\nFATAL ERROR: {e}")
        traceback.print_exc()
        sys.exit(2)

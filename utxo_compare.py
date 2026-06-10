#!/usr/bin/env python3
"""UTXO set comparison across mainnet nodes + BIP30 verification.

Read-only: only uses RPC queries, never modifies node state.
"""

import json
import os
import random
import sys
import time
MAINNET_ROOT = os.environ.get("HASHHOG_MAINNET_ROOT", "/data/nvme1/hashhog-mainnet")

from framework import RPCClient, NODE_CONFIGS

RESULTS_DIR = os.path.expanduser("~/hashhog/test-suite/results")
RESULTS_FILE = os.path.join(RESULTS_DIR, "utxo-comparison.json")

# Mainnet nodes to test (subset specified in task)
MAINNET_NODES = {
    "core":      {"port": 8332,  "cookie": f"{MAINNET_ROOT}/bitcoin-core/.cookie"},
    "haskoin":   {"port": 8354,  "cookie": f"{MAINNET_ROOT}/haskoin/.cookie"},
    "rustoshi":  {"port": 8350,  "cookie": f"{MAINNET_ROOT}/rustoshi/.cookie"},
    "beamchain": {"port": 48348, "cookie": f"{MAINNET_ROOT}/beamchain/.cookie"},
    "hotbuns":   {"port": 8351,  "cookie": f"{MAINNET_ROOT}/hotbuns/.cookie"},
    "blockbrew": {"port": 8355,  "cookie": f"{MAINNET_ROOT}/blockbrew/.cookie"},
}

# BIP30 duplicate coinbase blocks
BIP30_BLOCKS = [91842, 91880]


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def make_clients():
    """Create RPC clients for all mainnet nodes."""
    clients = {}
    for name, cfg in MAINNET_NODES.items():
        clients[name] = RPCClient(
            name=name,
            host="127.0.0.1",
            port=cfg["port"],
            cookie_path=cfg["cookie"],
            timeout=120.0,  # gettxoutsetinfo can be slow
        )
    return clients


def get_available_clients(clients):
    """Return clients that respond to getblockchaininfo."""
    available = {}
    for name, client in clients.items():
        try:
            info = client.call("getblockchaininfo")
            height = info.get("blocks", 0)
            available[name] = {"client": client, "height": height}
            log(f"  {name}: online, height={height}")
        except Exception as e:
            log(f"  {name}: offline ({e})")
    return available


def test_gettxoutsetinfo(available):
    """Try gettxoutsetinfo on all available nodes."""
    log("\n--- UTXO Set Info (gettxoutsetinfo) ---")
    results = {}
    supported_nodes = {}

    for name, info in available.items():
        client = info["client"]
        log(f"  Querying {name} (this may take 30-60s)...")
        try:
            # Use hash_serialized_2 hash_type for compatibility
            utxo_info = client.call("gettxoutsetinfo")
            results[name] = {
                "supported": True,
                "height": utxo_info.get("height"),
                "bestblock": utxo_info.get("bestblock"),
                "txouts": utxo_info.get("txouts"),
                "hash_serialized_2": utxo_info.get("hash_serialized_2"),
                "hash_serialized_3": utxo_info.get("hash_serialized_3"),
                "total_amount": utxo_info.get("total_amount"),
                "bogosize": utxo_info.get("bogosize"),
            }
            supported_nodes[name] = results[name]
            log(f"    txouts={utxo_info.get('txouts')}, "
                f"total_amount={utxo_info.get('total_amount')}")
        except Exception as e:
            results[name] = {"supported": False, "error": str(e)}
            log(f"    Not supported or error: {e}")

    # Compare supported nodes against core
    comparison = {"matches": [], "mismatches": [], "skipped": []}
    core_info = supported_nodes.get("core")
    if core_info:
        for name, info in supported_nodes.items():
            if name == "core":
                continue
            diffs = {}
            for field in ["txouts", "hash_serialized_2", "total_amount"]:
                core_val = core_info.get(field)
                node_val = info.get(field)
                if core_val is not None and node_val is not None:
                    if core_val != node_val:
                        diffs[field] = {"core": core_val, "node": node_val}
            if diffs:
                comparison["mismatches"].append({"node": name, "diffs": diffs})
                log(f"    MISMATCH: {name} differs in {list(diffs.keys())}")
            else:
                comparison["matches"].append(name)
                log(f"    MATCH: {name}")
    else:
        comparison["skipped"].append("core not available for comparison")

    return results, comparison, bool(supported_nodes.get("core") and len(supported_nodes) > 1)


def spot_check_utxos(available, num_samples=100):
    """Spot-check UTXOs by sampling random coinbase outputs."""
    log(f"\n--- UTXO Spot Check ({num_samples} random coinbase outputs) ---")

    if "core" not in available:
        log("  Core not available, skipping spot check")
        return {"error": "core not available"}

    core = available["core"]["client"]
    core_height = available["core"]["height"]

    # Pick random heights from 0 to tip-100
    max_height = max(0, core_height - 100)
    if max_height < 1:
        log("  Chain too short for spot check")
        return {"error": "chain too short"}

    sample_heights = sorted(random.sample(range(1, max_height + 1),
                                          min(num_samples, max_height)))
    log(f"  Sampling {len(sample_heights)} heights from 1 to {max_height}")

    results = {"samples": len(sample_heights), "nodes": {}}
    for name in available:
        if name == "core":
            continue
        results["nodes"][name] = {"match": 0, "mismatch": 0, "error": 0, "details": []}

    checked = 0
    for height in sample_heights:
        try:
            bhash = core.call("getblockhash", height)
            block = core.call("getblock", bhash, 2)  # verbosity=2
        except Exception as e:
            log(f"  Core error at height {height}: {e}")
            continue

        # Get first coinbase txid
        txs = block.get("tx", [])
        if not txs:
            continue
        coinbase_txid = txs[0].get("txid") if isinstance(txs[0], dict) else txs[0]

        # Get UTXO from core
        try:
            core_utxo = core.call("gettxout", coinbase_txid, 0)
        except Exception:
            core_utxo = None

        # Check each other node
        for name, info in available.items():
            if name == "core":
                continue
            client = info["client"]
            node_results = results["nodes"][name]
            try:
                node_utxo = client.call("gettxout", coinbase_txid, 0)

                # Both None = both agree it's spent
                if core_utxo is None and node_utxo is None:
                    node_results["match"] += 1
                    continue

                # One None, one not = mismatch
                if (core_utxo is None) != (node_utxo is None):
                    node_results["mismatch"] += 1
                    node_results["details"].append({
                        "height": height, "txid": coinbase_txid,
                        "core_exists": core_utxo is not None,
                        "node_exists": node_utxo is not None,
                    })
                    continue

                # Compare value and scriptPubKey
                diffs = {}
                core_val = core_utxo.get("value")
                node_val = node_utxo.get("value")
                if core_val != node_val:
                    diffs["value"] = {"core": core_val, "node": node_val}

                core_spk = core_utxo.get("scriptPubKey", {}).get("hex")
                node_spk = node_utxo.get("scriptPubKey", {}).get("hex")
                if core_spk and node_spk and core_spk != node_spk:
                    diffs["scriptPubKey"] = {"core": core_spk, "node": node_spk}

                # Confirmations can vary slightly
                core_conf = core_utxo.get("confirmations", 0)
                node_conf = node_utxo.get("confirmations", 0)
                if abs(core_conf - node_conf) > 2:
                    diffs["confirmations"] = {"core": core_conf, "node": node_conf}

                if diffs:
                    node_results["mismatch"] += 1
                    node_results["details"].append({
                        "height": height, "txid": coinbase_txid, "diffs": diffs,
                    })
                else:
                    node_results["match"] += 1

            except Exception as e:
                node_results["error"] += 1
                if len(node_results["details"]) < 5:
                    node_results["details"].append({
                        "height": height, "txid": coinbase_txid,
                        "error": str(e),
                    })

        checked += 1
        if checked % 20 == 0:
            log(f"  Checked {checked}/{len(sample_heights)} samples...")

    # Trim details to keep report manageable
    for name in results["nodes"]:
        details = results["nodes"][name]["details"]
        if len(details) > 20:
            results["nodes"][name]["details"] = details[:20]
            results["nodes"][name]["details_truncated"] = len(details)

    # Summary
    for name, node_res in results["nodes"].items():
        total = node_res["match"] + node_res["mismatch"] + node_res["error"]
        log(f"  {name}: {node_res['match']}/{total} match, "
            f"{node_res['mismatch']} mismatch, {node_res['error']} error")

    return results


def verify_bip30(available):
    """Verify BIP30 duplicate coinbase blocks are retrievable on all nodes."""
    log("\n--- BIP30 Verification (blocks 91842, 91880) ---")

    if "core" not in available:
        log("  Core not available, skipping BIP30 check")
        return {"error": "core not available"}

    core = available["core"]["client"]
    results = {"blocks": {}, "nodes": {}}

    # Get reference data from core
    for height in BIP30_BLOCKS:
        try:
            bhash = core.call("getblockhash", height)
            block = core.call("getblock", bhash, 1)
            results["blocks"][str(height)] = {
                "hash": bhash,
                "nTx": block.get("nTx"),
                "size": block.get("size"),
            }
            log(f"  Core block {height}: hash={bhash[:16]}..., nTx={block.get('nTx')}")
        except Exception as e:
            results["blocks"][str(height)] = {"error": str(e)}
            log(f"  Core block {height}: ERROR {e}")

    # Check each node
    for name, info in available.items():
        if name == "core":
            continue
        client = info["client"]
        node_height = info["height"]
        node_result = {}

        for height in BIP30_BLOCKS:
            if node_height < height:
                node_result[str(height)] = {"status": "skipped", "reason": "below height"}
                continue

            core_block = results["blocks"].get(str(height), {})
            core_hash = core_block.get("hash")
            if not core_hash:
                node_result[str(height)] = {"status": "skipped", "reason": "core error"}
                continue

            try:
                node_hash = client.call("getblockhash", height)
                node_block = client.call("getblock", node_hash, 1)
                matches_hash = (node_hash == core_hash)
                node_result[str(height)] = {
                    "status": "pass" if matches_hash else "fail",
                    "hash_match": matches_hash,
                    "node_hash": node_hash,
                    "nTx": node_block.get("nTx"),
                }
                status = "MATCH" if matches_hash else "MISMATCH"
                log(f"  {name} block {height}: {status}")
            except Exception as e:
                node_result[str(height)] = {"status": "error", "error": str(e)}
                log(f"  {name} block {height}: ERROR {e}")

        results["nodes"][name] = node_result

    return results


def main():
    log("=" * 60)
    log("UTXO Set Comparison & BIP30 Verification (mainnet, read-only)")
    log("=" * 60)

    clients = make_clients()

    log("\n--- Checking node availability ---")
    available = get_available_clients(clients)

    if not available:
        log("No nodes available, exiting")
        sys.exit(1)

    if "core" not in available:
        log("WARNING: Core not available, comparisons will be limited")

    report = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "test": "utxo-comparison",
        "nodes_available": {name: info["height"] for name, info in available.items()},
    }

    # Part 1: Try gettxoutsetinfo
    utxo_info, utxo_comparison, utxo_supported = test_gettxoutsetinfo(available)
    report["gettxoutsetinfo"] = {
        "results": utxo_info,
        "comparison": utxo_comparison,
    }

    # Part 2: Spot check if gettxoutsetinfo not broadly supported
    num_supported = sum(1 for v in utxo_info.values() if v.get("supported"))
    if num_supported < 2 or not utxo_supported:
        log("  gettxoutsetinfo not broadly supported, falling back to spot check")
        spot_results = spot_check_utxos(available, num_samples=100)
    else:
        log("  gettxoutsetinfo comparison done, running spot check as additional validation")
        spot_results = spot_check_utxos(available, num_samples=100)

    report["spot_check"] = spot_results

    # Part 3: BIP30 verification
    bip30_results = verify_bip30(available)
    report["bip30_verification"] = bip30_results

    # Summary
    log("\n--- Summary ---")
    summary = {"utxo_set_matches": [], "utxo_set_mismatches": [],
               "bip30_pass": [], "bip30_fail": []}

    for m in utxo_comparison.get("matches", []):
        summary["utxo_set_matches"].append(m)
    for m in utxo_comparison.get("mismatches", []):
        summary["utxo_set_mismatches"].append(m["node"])

    for name, node_res in bip30_results.get("nodes", {}).items():
        all_pass = all(v.get("status") == "pass" for v in node_res.values())
        if all_pass:
            summary["bip30_pass"].append(name)
        else:
            summary["bip30_fail"].append(name)

    report["summary"] = summary

    log(f"  UTXO matches: {summary['utxo_set_matches']}")
    log(f"  UTXO mismatches: {summary['utxo_set_mismatches']}")
    log(f"  BIP30 pass: {summary['bip30_pass']}")
    log(f"  BIP30 fail: {summary['bip30_fail']}")

    # Write results
    os.makedirs(RESULTS_DIR, exist_ok=True)
    with open(RESULTS_FILE, "w") as f:
        json.dump(report, f, indent=2)
    log(f"\nResults written to {RESULTS_FILE}")

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("Interrupted")
        sys.exit(1)
    except Exception as e:
        log(f"Fatal error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

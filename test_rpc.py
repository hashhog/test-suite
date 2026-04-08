#!/usr/bin/env python3
"""RPC conformance tests for Bitcoin full node implementations.

Compares all at-tip nodes against Bitcoin Core (the reference).
"""

import json
import os
import sys

from framework import (
    NodeRegistry, ComparisonEngine, TestRunner, ComparisonResult, NodeResult
)


# ---------------------------------------------------------------------------
# Test definitions
# ---------------------------------------------------------------------------

def test_getblockchaininfo(engine: ComparisonEngine, registry: NodeRegistry):
    """Test 1: getblockchaininfo — chain, blocks, headers, bestblockhash, difficulty, mediantime."""
    cr = engine.compare_all(
        "getblockchaininfo",
        fields=["chain", "blocks", "headers", "bestblockhash", "difficulty", "mediantime"],
        tolerance={"blocks": 2, "headers": 2},
    )
    return [cr]


def test_getblockhash(engine: ComparisonEngine, registry: NodeRegistry):
    """Test 2: getblockhash at notable heights."""
    ref = registry.get_reference()
    ref_info = ref.call("getblockchaininfo")
    tip = ref_info["blocks"]

    heights = [0, 1, 100, 1000, 100000, 200000, 300000, 400000,
               481824, 500000, 600000, 709632, 800000, 900000, tip - 10]

    results = []
    for h in heights:
        cr = engine.compare_all("getblockhash", h)
        results.append(cr)
    return results


def test_getblockheader(engine: ComparisonEngine, registry: NodeRegistry):
    """Test 3: getblockheader for notable block hashes."""
    ref = registry.get_reference()
    ref_info = ref.call("getblockchaininfo")
    tip = ref_info["blocks"]

    heights = [0, 1, 100, 1000, 100000, 200000, 300000, 400000,
               481824, 500000, 600000, 709632, 800000, 900000, tip - 10]

    header_fields = [
        "hash", "confirmations", "height", "version", "versionHex",
        "merkleroot", "time", "mediantime", "nonce", "bits", "difficulty",
        "chainwork", "nTx", "previousblockhash",
    ]

    results = []
    for h in heights:
        block_hash = ref.call("getblockhash", h)
        cr = engine.compare_all(
            "getblockheader", block_hash, True,
            fields=header_fields,
            tolerance={"confirmations": 3},
        )
        results.append(cr)
    return results


def test_getblock(engine: ComparisonEngine, registry: NodeRegistry):
    """Test 4: getblock verbosity=1 for notable blocks."""
    ref = registry.get_reference()
    ref_info = ref.call("getblockchaininfo")
    tip = ref_info["blocks"]

    # Genesis, first tx block, segwit activation, taproot activation, near tip
    heights = [0, 170, 481824, 709632, tip - 5]

    block_fields = [
        "hash", "height", "version", "versionHex", "merkleroot",
        "time", "mediantime", "nonce", "bits", "difficulty",
        "nTx", "previousblockhash", "tx",
    ]

    results = []
    for h in heights:
        block_hash = ref.call("getblockhash", h)
        cr = engine.compare_all(
            "getblock", block_hash, 1,
            fields=block_fields,
            tolerance={"confirmations": 3},
        )
        results.append(cr)
    return results


def test_getrawtransaction(engine: ComparisonEngine, registry: NodeRegistry):
    """Test 5: getrawtransaction for txids from notable blocks."""
    ref = registry.get_reference()

    # Get txids from a few notable blocks
    test_blocks = [170, 481824, 709632]
    txids = []
    for h in test_blocks:
        block_hash = ref.call("getblockhash", h)
        block = ref.call("getblock", block_hash, 1)
        block_txs = block.get("tx", [])
        # Take first tx (coinbase) and last tx if different
        if block_txs:
            txids.append(block_txs[0])
            if len(block_txs) > 1:
                txids.append(block_txs[-1])

    results = []
    at_tip = registry.get_at_tip_nodes()
    for txid in txids[:6]:  # Limit to 6 txids
        # getrawtransaction with verbose=false returns hex string
        cr = engine.compare_all("getrawtransaction", txid, False, nodes=at_tip)
        results.append(cr)
    return results


def test_gettxout(engine: ComparisonEngine, registry: NodeRegistry):
    """Test 6: gettxout for known UTXOs and a spent output."""
    ref = registry.get_reference()

    # We'll find some unspent outputs dynamically from a recent block's coinbase
    # and also test a known-spent output (genesis coinbase is unspendable)
    ref_info = ref.call("getblockchaininfo")
    tip = ref_info["blocks"]

    # Try recent coinbase outputs (they need 100 confirms to be spendable but
    # gettxout should still show them in the UTXO set)
    test_cases = []

    # Recent coinbases should be unspent
    for offset in [200, 300, 400, 500, 600]:
        h = tip - offset
        block_hash = ref.call("getblockhash", h)
        block = ref.call("getblock", block_hash, 1)
        coinbase_txid = block["tx"][0]
        result = ref.call_safe("gettxout", coinbase_txid, 0)
        if result is not None:
            test_cases.append((coinbase_txid, 0, True))
            if len(test_cases) >= 5:
                break

    # Known spent: the first non-coinbase tx ever (block 170)
    # Output 0 of Satoshi's tx in block 170 was spent
    block_hash_170 = ref.call("getblockhash", 170)
    block_170 = ref.call("getblock", block_hash_170, 1)
    if len(block_170["tx"]) > 1:
        spent_txid = block_170["tx"][1]
        test_cases.append((spent_txid, 0, False))

    results = []
    at_tip = registry.get_at_tip_nodes()

    for txid, vout, expect_unspent in test_cases:
        cr = ComparisonResult(method="gettxout", params=[txid, vout])
        try:
            cr.reference_result = ref.call("gettxout", txid, vout)
        except Exception as e:
            cr.reference_error = str(e)
            results.append(cr)
            continue

        for client in at_tip:
            if client.name == "core":
                cr.node_results.append(NodeResult(node="core", passed=True,
                                                  result=cr.reference_result))
                continue

            nr = NodeResult(node=client.name, passed=True)
            try:
                nr.result = client.call("gettxout", txid, vout)
            except Exception as e:
                nr.passed = False
                nr.error = str(e)
                cr.node_results.append(nr)
                continue

            # For spent outputs, both should be None/null
            if cr.reference_result is None:
                if nr.result is not None:
                    nr.passed = False
                    nr.diffs["value"] = {"expected": None, "got": "non-null"}
            else:
                # Compare key fields if both non-null
                if nr.result is None:
                    nr.passed = False
                    nr.diffs["value"] = {"expected": "non-null", "got": None}
                else:
                    for field in ["bestblock", "value", "confirmations"]:
                        if field == "confirmations":
                            # Allow tolerance
                            rv = cr.reference_result.get(field, 0)
                            nv = nr.result.get(field, 0)
                            if isinstance(rv, (int, float)) and isinstance(nv, (int, float)):
                                if abs(rv - nv) > 3:
                                    nr.diffs[field] = {"expected": rv, "got": nv}
                                    nr.passed = False
                        elif field == "bestblock":
                            # May differ slightly, skip
                            pass
                        else:
                            rv = cr.reference_result.get(field)
                            nv = nr.result.get(field)
                            if rv != nv:
                                nr.diffs[field] = {"expected": rv, "got": nv}
                                nr.passed = False

            cr.node_results.append(nr)
        results.append(cr)

    return results


def test_getmempoolinfo(engine: ComparisonEngine, registry: NodeRegistry):
    """Test 7: getmempoolinfo — verify all respond with valid data."""
    at_tip = registry.get_at_tip_nodes()
    cr = ComparisonResult(method="getmempoolinfo", params=[])

    ref = registry.get_reference()
    try:
        cr.reference_result = ref.call("getmempoolinfo")
    except Exception as e:
        cr.reference_error = str(e)
        return [cr]

    for client in at_tip:
        if client.name == "core":
            cr.node_results.append(NodeResult(node="core", passed=True,
                                              result=cr.reference_result))
            continue

        nr = NodeResult(node=client.name, passed=True)
        try:
            result = client.call("getmempoolinfo")
            nr.result = result
            # Just verify it has the expected fields
            required_fields = ["size", "bytes"]
            for f in required_fields:
                if f not in result:
                    nr.diffs[f] = {"expected": "present", "got": "missing"}
                    nr.passed = False
        except Exception as e:
            nr.passed = False
            nr.error = str(e)
        cr.node_results.append(nr)

    return [cr]


def test_getpeerinfo(engine: ComparisonEngine, registry: NodeRegistry):
    """Test 8: getpeerinfo — verify returns array."""
    at_tip = registry.get_at_tip_nodes()
    cr = ComparisonResult(method="getpeerinfo", params=[])

    ref = registry.get_reference()
    try:
        cr.reference_result = ref.call("getpeerinfo")
    except Exception as e:
        cr.reference_error = str(e)
        return [cr]

    for client in at_tip:
        if client.name == "core":
            cr.node_results.append(NodeResult(node="core", passed=True,
                                              result=cr.reference_result))
            continue

        nr = NodeResult(node=client.name, passed=True)
        try:
            result = client.call("getpeerinfo")
            nr.result = result
            if not isinstance(result, list):
                nr.diffs["type"] = {"expected": "array", "got": type(result).__name__}
                nr.passed = False
        except Exception as e:
            nr.passed = False
            nr.error = str(e)
        cr.node_results.append(nr)

    return [cr]


def test_estimatesmartfee(engine: ComparisonEngine, registry: NodeRegistry):
    """Test 9: estimatesmartfee — conf_target=6, verify response format."""
    at_tip = registry.get_at_tip_nodes()
    cr = ComparisonResult(method="estimatesmartfee", params=[6])

    ref = registry.get_reference()
    try:
        cr.reference_result = ref.call("estimatesmartfee", 6)
    except Exception as e:
        cr.reference_error = str(e)
        return [cr]

    for client in at_tip:
        if client.name == "core":
            cr.node_results.append(NodeResult(node="core", passed=True,
                                              result=cr.reference_result))
            continue

        nr = NodeResult(node=client.name, passed=True)
        try:
            result = client.call("estimatesmartfee", 6)
            nr.result = result
            if not isinstance(result, dict):
                nr.diffs["type"] = {"expected": "dict", "got": type(result).__name__}
                nr.passed = False
            elif "blocks" not in result and "errors" not in result:
                nr.diffs["format"] = {
                    "expected": "has 'blocks' or 'errors' key",
                    "got": list(result.keys()),
                }
                nr.passed = False
        except Exception as e:
            nr.passed = False
            nr.error = str(e)
        cr.node_results.append(nr)

    return [cr]


def test_validateaddress(engine: ComparisonEngine, registry: NodeRegistry):
    """Test 10: validateaddress — P2PKH, P2SH, P2WPKH, P2TR addresses."""
    addresses = [
        # P2PKH
        "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
        # P2SH
        "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy",
        # P2WPKH (bech32)
        "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
        # P2TR (bech32m)
        "bc1p5cyxnuxmeuwuvkwfem96lqzszee2457nljwv3lvd7mxhqx0e7xqshh0uh8",
        # Invalid address
        "1InvalidAddressxxxxxxxxxxxxxxxxx",
    ]

    results = []
    at_tip = registry.get_at_tip_nodes()

    for addr in addresses:
        cr = ComparisonResult(method="validateaddress", params=[addr])
        ref = registry.get_reference()
        try:
            cr.reference_result = ref.call("validateaddress", addr)
        except Exception as e:
            cr.reference_error = str(e)
            results.append(cr)
            continue

        for client in at_tip:
            if client.name == "core":
                cr.node_results.append(NodeResult(node="core", passed=True,
                                                  result=cr.reference_result))
                continue

            nr = NodeResult(node=client.name, passed=True)
            try:
                result = client.call("validateaddress", addr)
                nr.result = result
                # Compare isvalid field
                ref_valid = cr.reference_result.get("isvalid")
                node_valid = result.get("isvalid")
                if ref_valid != node_valid:
                    nr.diffs["isvalid"] = {"expected": ref_valid, "got": node_valid}
                    nr.passed = False
                # If valid, compare address field
                if ref_valid:
                    ref_addr = cr.reference_result.get("address")
                    node_addr = result.get("address")
                    if ref_addr != node_addr:
                        nr.diffs["address"] = {"expected": ref_addr, "got": node_addr}
                        nr.passed = False
            except Exception as e:
                nr.passed = False
                nr.error = str(e)
            cr.node_results.append(nr)

        results.append(cr)
    return results


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

ALL_TESTS = [
    ("getblockchaininfo", test_getblockchaininfo),
    ("getblockhash", test_getblockhash),
    ("getblockheader", test_getblockheader),
    ("getblock_v1", test_getblock),
    ("getrawtransaction", test_getrawtransaction),
    ("gettxout", test_gettxout),
    ("getmempoolinfo", test_getmempoolinfo),
    ("getpeerinfo", test_getpeerinfo),
    ("estimatesmartfee", test_estimatesmartfee),
    ("validateaddress", test_validateaddress),
]


def main():
    print("RPC Conformance Test Suite")
    print("=" * 40)

    registry = NodeRegistry()

    # Show which nodes are available
    print("\nDiscovering nodes...")
    available = registry.get_available_nodes()
    print(f"  Available: {[n.name for n in available]}")

    at_tip = registry.get_at_tip_nodes()
    print(f"  At tip:    {[n.name for n in at_tip]}")
    print()

    if not at_tip:
        print("ERROR: No nodes at tip. Cannot run tests.")
        sys.exit(1)

    runner = TestRunner(registry)

    print("Running tests...")
    for name, fn in ALL_TESTS:
        runner.run_test(name, fn)

    # Write results
    results_dir = os.path.join(os.path.dirname(__file__), "results")
    os.makedirs(results_dir, exist_ok=True)

    json_path = os.path.join(results_dir, "rpc-conformance.json")
    with open(json_path, "w") as f:
        json.dump(runner.to_json(), f, indent=2, default=str)
    print(f"\nJSON results: {json_path}")

    summary_path = os.path.join(results_dir, "rpc-conformance-summary.txt")
    summary = runner.summary()
    with open(summary_path, "w") as f:
        f.write(summary)
    print(f"Summary:      {summary_path}")

    print()
    print(summary)

    # Exit code
    failed = sum(1 for r in runner.results if not r.passed)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

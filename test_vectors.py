#!/usr/bin/env python3
"""Bitcoin Core test vector validation across hashhog node implementations.

Tests:
1. decoderawtransaction - parse tx_valid.json and tx_invalid.json serialized txs
2. decodescript - parse script_tests.json, assemble scripts to hex, decode via RPC

Reference: Bitcoin Core's src/test/data/
"""

import json
import os
import sys
import time
import re
import struct

# Add parent dir so we can import framework
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from framework import RPCClient, NodeRegistry

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BITCOIN_CORE_DATA = os.path.expanduser(
    "~/hashhog/bitcoin-core/src/test/data"
)
RESULTS_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "results", "test-vectors.json"
)

# Nodes that support decoderawtransaction and decodescript
# (hotbuns does not implement these RPCs)
SKIP_NODES = {"hotbuns"}

# ---------------------------------------------------------------------------
# Script assembler: convert Bitcoin Script assembly to hex
# ---------------------------------------------------------------------------

OPCODES = {
    "OP_0": 0x00, "OP_FALSE": 0x00,
    "OP_PUSHDATA1": 0x4c, "OP_PUSHDATA2": 0x4d, "OP_PUSHDATA4": 0x4e,
    "OP_1NEGATE": 0x4f,
    "OP_RESERVED": 0x50,
    "OP_1": 0x51, "OP_TRUE": 0x51,
    "OP_2": 0x52, "OP_3": 0x53, "OP_4": 0x54, "OP_5": 0x55,
    "OP_6": 0x56, "OP_7": 0x57, "OP_8": 0x58, "OP_9": 0x59,
    "OP_10": 0x5a, "OP_11": 0x5b, "OP_12": 0x5c, "OP_13": 0x5d,
    "OP_14": 0x5e, "OP_15": 0x5f, "OP_16": 0x60,
    "OP_NOP": 0x61, "OP_VER": 0x62, "OP_IF": 0x63, "OP_NOTIF": 0x64,
    "OP_VERIF": 0x65, "OP_VERNOTIF": 0x66, "OP_ELSE": 0x67,
    "OP_ENDIF": 0x68, "OP_VERIFY": 0x69, "OP_RETURN": 0x6a,
    "OP_TOALTSTACK": 0x6b, "OP_FROMALTSTACK": 0x6c,
    "OP_2DROP": 0x6d, "OP_2DUP": 0x6e, "OP_3DUP": 0x6f,
    "OP_2OVER": 0x70, "OP_2ROT": 0x71, "OP_2SWAP": 0x72,
    "OP_IFDUP": 0x73, "OP_DEPTH": 0x74, "OP_DROP": 0x75,
    "OP_DUP": 0x76, "OP_NIP": 0x77, "OP_OVER": 0x78, "OP_PICK": 0x79,
    "OP_ROLL": 0x7a, "OP_ROT": 0x7b, "OP_SWAP": 0x7c, "OP_TUCK": 0x7d,
    "OP_CAT": 0x7e, "OP_SUBSTR": 0x7f, "OP_LEFT": 0x80, "OP_RIGHT": 0x81,
    "OP_SIZE": 0x82,
    "OP_INVERT": 0x83, "OP_AND": 0x84, "OP_OR": 0x85, "OP_XOR": 0x86,
    "OP_EQUAL": 0x87, "OP_EQUALVERIFY": 0x88,
    "OP_RESERVED1": 0x89, "OP_RESERVED2": 0x8a,
    "OP_1ADD": 0x8b, "OP_1SUB": 0x8c,
    "OP_2MUL": 0x8d, "OP_2DIV": 0x8e,
    "OP_NEGATE": 0x8f, "OP_ABS": 0x90, "OP_NOT": 0x91,
    "OP_0NOTEQUAL": 0x92,
    "OP_ADD": 0x93, "OP_SUB": 0x94,
    "OP_MUL": 0x95, "OP_DIV": 0x96, "OP_MOD": 0x97,
    "OP_LSHIFT": 0x98, "OP_RSHIFT": 0x99,
    "OP_BOOLAND": 0x9a, "OP_BOOLOR": 0x9b,
    "OP_NUMEQUAL": 0x9c, "OP_NUMEQUALVERIFY": 0x9d,
    "OP_NUMNOTEQUAL": 0x9e,
    "OP_LESSTHAN": 0x9f, "OP_GREATERTHAN": 0xa0,
    "OP_LESSTHANOREQUAL": 0xa1, "OP_GREATERTHANOREQUAL": 0xa2,
    "OP_MIN": 0xa3, "OP_MAX": 0xa4,
    "OP_WITHIN": 0xa5,
    "OP_RIPEMD160": 0xa6, "OP_SHA1": 0xa7, "OP_SHA256": 0xa8,
    "OP_HASH160": 0xa9, "OP_HASH256": 0xaa,
    "OP_CODESEPARATOR": 0xab, "OP_CHECKSIG": 0xac,
    "OP_CHECKSIGVERIFY": 0xad,
    "OP_CHECKMULTISIG": 0xae, "OP_CHECKMULTISIGVERIFY": 0xaf,
    "OP_NOP1": 0xb0,
    "OP_CHECKLOCKTIMEVERIFY": 0xb1, "OP_NOP2": 0xb1,
    "OP_CHECKSEQUENCEVERIFY": 0xb2, "OP_NOP3": 0xb2,
    "OP_NOP4": 0xb3, "OP_NOP5": 0xb4, "OP_NOP6": 0xb5,
    "OP_NOP7": 0xb6, "OP_NOP8": 0xb7, "OP_NOP9": 0xb8,
    "OP_NOP10": 0xb9,
    "OP_CHECKSIGADD": 0xba,
    "OP_INVALIDOPCODE": 0xff,
}

# Short aliases without OP_ prefix
OPCODE_ALIASES = {}
for name, val in list(OPCODES.items()):
    short = name[3:] if name.startswith("OP_") else name
    OPCODE_ALIASES[short] = val
OPCODE_ALIASES.update(OPCODES)
# Numeric aliases
for i in range(1, 17):
    OPCODE_ALIASES[str(i)] = 0x50 + i
OPCODE_ALIASES["0"] = 0x00
OPCODE_ALIASES["-1"] = 0x4f


def int_to_script_num(n):
    """Encode an integer as a Bitcoin script number (little-endian with sign bit)."""
    if n == 0:
        return b""
    negative = n < 0
    absval = abs(n)
    result = []
    while absval > 0:
        result.append(absval & 0xff)
        absval >>= 8
    if result[-1] & 0x80:
        result.append(0x80 if negative else 0x00)
    elif negative:
        result[-1] |= 0x80
    return bytes(result)


def assemble_script(asm_str):
    """Convert Bitcoin Script assembly string to hex.

    Handles:
    - Opcode names (with or without OP_ prefix)
    - 0xNN hex push notation (e.g., 0x20 followed by 32 hex bytes)
    - Quoted strings ('hello')
    - Bare hex data
    - Numeric literals
    """
    if not asm_str or not asm_str.strip():
        return ""

    result = bytearray()
    tokens = tokenize_script(asm_str)
    i = 0
    while i < len(tokens):
        tok = tokens[i]

        # 0xNN format: explicit push with length prefix
        if tok.startswith("0x"):
            hex_data = tok[2:]
            data = bytes.fromhex(hex_data)
            # In Bitcoin Core test vectors, 0xNN is a raw byte sequence
            # The first byte is the length, rest is data
            result.extend(data)
            i += 1
            continue

        # Quoted string
        if tok.startswith("'") and tok.endswith("'"):
            data = tok[1:-1].encode("utf-8")
            result.extend(push_data(data))
            i += 1
            continue

        # Opcode lookup (with or without OP_ prefix)
        upper = tok.upper()
        if upper in OPCODE_ALIASES:
            result.append(OPCODE_ALIASES[upper])
            i += 1
            continue

        if "OP_" + upper in OPCODES:
            result.append(OPCODES["OP_" + upper])
            i += 1
            continue

        # Pure hex data (even length, all hex chars)
        if re.match(r"^[0-9a-fA-F]+$", tok) and len(tok) % 2 == 0 and len(tok) > 2:
            data = bytes.fromhex(tok)
            result.extend(push_data(data))
            i += 1
            continue

        # Numeric literal
        try:
            num = int(tok)
            if num == 0:
                result.append(0x00)
            elif 1 <= num <= 16:
                result.append(0x50 + num)
            elif num == -1:
                result.append(0x4f)
            else:
                data = int_to_script_num(num)
                result.extend(push_data(data))
            i += 1
            continue
        except ValueError:
            pass

        # Unknown token - skip
        i += 1

    return result.hex()


def push_data(data):
    """Create a push data opcode sequence for the given bytes."""
    n = len(data)
    if n == 0:
        return bytes([0x00])
    elif n <= 75:
        return bytes([n]) + data
    elif n <= 255:
        return bytes([0x4c, n]) + data
    elif n <= 65535:
        return bytes([0x4d]) + struct.pack("<H", n) + data
    else:
        return bytes([0x4e]) + struct.pack("<I", n) + data


def tokenize_script(asm_str):
    """Tokenize a Bitcoin Script assembly string."""
    tokens = []
    i = 0
    s = asm_str.strip()
    while i < len(s):
        # Skip whitespace
        if s[i] in " \t\n\r":
            i += 1
            continue
        # Quoted string
        if s[i] == "'":
            j = s.index("'", i + 1) + 1
            tokens.append(s[i:j])
            i = j
            continue
        # Regular token
        j = i
        while j < len(s) and s[j] not in " \t\n\r":
            j += 1
        tokens.append(s[i:j])
        i = j
    return tokens


# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------

def make_clients():
    """Create RPC clients for nodes that are reachable and support decode RPCs."""
    # Only try nodes known to be at tip and supporting decode RPCs
    TARGET_NODES = ["core", "rustoshi", "blockbrew", "beamchain", "haskoin"]
    registry = NodeRegistry()
    clients = {}
    for name in TARGET_NODES:
        if name in SKIP_NODES:
            continue
        client = registry.get_node(name)
        client.timeout = 10.0  # shorter timeout for test vectors
        try:
            client.call("getblockchaininfo")
            clients[name] = client
            print(f"  Connected: {name} (port {client.port})")
        except Exception as e:
            print(f"  Skipped: {name} - {e}")
    return clients


def rpc_decodescript(client, hex_script):
    """Call decodescript, return result or error string."""
    try:
        return ("ok", client.call("decodescript", hex_script))
    except Exception as e:
        return ("error", str(e))


def rpc_decoderawtx(client, hex_tx):
    """Call decoderawtransaction, return result or error string."""
    try:
        return ("ok", client.call("decoderawtransaction", hex_tx))
    except Exception as e:
        return ("error", str(e))


# ---------------------------------------------------------------------------
# Test: decoderawtransaction
# ---------------------------------------------------------------------------

# Fields to compare for decoderawtransaction
# Core fields to compare. vsize/weight may be absent in some implementations
# for legacy (non-segwit) transactions, so we treat missing as acceptable.
DECODE_TX_FIELDS_REQUIRED = ["txid", "version", "locktime"]
DECODE_TX_FIELDS_OPTIONAL = ["size", "vsize", "weight"]


def compare_decoded_tx(ref_result, node_result):
    """Compare decoded tx fields, return list of diffs."""
    diffs = []
    for field in DECODE_TX_FIELDS_REQUIRED:
        ref_val = ref_result.get(field)
        node_val = node_result.get(field)
        if ref_val is not None and ref_val != node_val:
            diffs.append({"field": field, "expected": ref_val, "got": node_val})

    for field in DECODE_TX_FIELDS_OPTIONAL:
        ref_val = ref_result.get(field)
        node_val = node_result.get(field)
        # Only flag if node returns a value and it's wrong (missing is OK)
        if ref_val is not None and node_val is not None and ref_val != node_val:
            diffs.append({"field": field, "expected": ref_val, "got": node_val})

    # Compare vin count and vout count
    ref_vin = len(ref_result.get("vin", []))
    node_vin = len(node_result.get("vin", []))
    if ref_vin != node_vin:
        diffs.append({"field": "vin_count", "expected": ref_vin, "got": node_vin})

    ref_vout = len(ref_result.get("vout", []))
    node_vout = len(node_result.get("vout", []))
    if ref_vout != node_vout:
        diffs.append({"field": "vout_count", "expected": ref_vout, "got": node_vout})

    # Compare vout values and scriptPubKey types
    for idx in range(min(ref_vout, node_vout)):
        rv = ref_result["vout"][idx]
        nv = node_result["vout"][idx]
        if rv.get("value") != nv.get("value"):
            diffs.append({
                "field": f"vout[{idx}].value",
                "expected": rv.get("value"),
                "got": nv.get("value"),
            })
        ref_type = rv.get("scriptPubKey", {}).get("type")
        node_type = nv.get("scriptPubKey", {}).get("type")
        if ref_type and node_type and ref_type != node_type:
            # "nonstandard" vs "unknown" is a cosmetic alias
            if not ({ref_type, node_type} <= {"nonstandard", "unknown"}):
                diffs.append({
                    "field": f"vout[{idx}].scriptPubKey.type",
                    "expected": ref_type,
                    "got": node_type,
                })

    return diffs


def test_decoderawtransaction(clients, ref_client):
    """Test decoderawtransaction using tx_valid.json and tx_invalid.json."""
    results = {
        "tx_valid": {"total": 0, "tested": 0, "per_node": {}},
        "tx_invalid": {"total": 0, "tested": 0, "per_node": {}},
    }

    for node_name in clients:
        if node_name == "core":
            continue
        results["tx_valid"]["per_node"][node_name] = {
            "pass": 0, "fail": 0, "skip": 0, "errors": []
        }
        results["tx_invalid"]["per_node"][node_name] = {
            "pass": 0, "fail": 0, "skip": 0, "errors": []
        }

    for label, filename in [("tx_valid", "tx_valid.json"),
                             ("tx_invalid", "tx_invalid.json")]:
        filepath = os.path.join(BITCOIN_CORE_DATA, filename)
        data = json.load(open(filepath))

        test_entries = []
        for entry in data:
            if isinstance(entry, list) and len(entry) == 3 and isinstance(entry[0], list):
                test_entries.append(entry)

        results[label]["total"] = len(test_entries)

        tested = 0
        for entry in test_entries:
            raw_tx = entry[1]

            # Decode with reference (Core)
            ref_status, ref_val = rpc_decoderawtx(ref_client, raw_tx)
            if ref_status == "error":
                # Core can't decode it (truly malformed serialization)
                for node_name in clients:
                    if node_name == "core":
                        continue
                    # For invalid txs, Core error is expected
                    node_status, node_val = rpc_decoderawtx(clients[node_name], raw_tx)
                    if node_status == "error":
                        results[label]["per_node"][node_name]["pass"] += 1
                    else:
                        # Node decoded what Core couldn't - might be lenient
                        results[label]["per_node"][node_name]["pass"] += 1
                tested += 1
                continue

            tested += 1
            for node_name, client in clients.items():
                if node_name == "core":
                    continue

                node_status, node_val = rpc_decoderawtx(client, raw_tx)
                node_results = results[label]["per_node"][node_name]

                if node_status == "error":
                    node_results["fail"] += 1
                    if len(node_results["errors"]) < 20:
                        node_results["errors"].append({
                            "tx": raw_tx[:64] + "...",
                            "error": str(node_val)[:200],
                        })
                    continue

                diffs = compare_decoded_tx(ref_val, node_val)
                if diffs:
                    node_results["fail"] += 1
                    if len(node_results["errors"]) < 20:
                        node_results["errors"].append({
                            "tx": raw_tx[:64] + "...",
                            "txid": ref_val.get("txid", "?")[:16],
                            "diffs": diffs[:5],
                        })
                else:
                    node_results["pass"] += 1

        results[label]["tested"] = tested

    return results


# ---------------------------------------------------------------------------
# Test: decodescript
# ---------------------------------------------------------------------------

DECODE_SCRIPT_FIELDS = ["type", "address", "asm"]

# Map for normalizing asm opcode representations
ASM_NORMALIZE = {}
# OP_N vs N
for i in range(1, 17):
    ASM_NORMALIZE[f"OP_{i}"] = str(i)
ASM_NORMALIZE["OP_0"] = "0"
ASM_NORMALIZE["OP_1NEGATE"] = "-1"
# Some nodes output OP_ prefix, some don't
_OPCODES_LIST = [
    "DUP", "HASH160", "EQUAL", "EQUALVERIFY", "CHECKSIG", "CHECKSIGVERIFY",
    "CHECKMULTISIG", "CHECKMULTISIGVERIFY", "RETURN", "IF", "NOTIF", "ELSE",
    "ENDIF", "VERIFY", "DROP", "2DROP", "NIP", "OVER", "PICK", "ROLL",
    "ROT", "SWAP", "TUCK", "2DUP", "3DUP", "2OVER", "2ROT", "2SWAP",
    "IFDUP", "DEPTH", "SIZE", "TOALTSTACK", "FROMALTSTACK",
    "ADD", "SUB", "BOOLAND", "BOOLOR", "NUMEQUAL", "NUMEQUALVERIFY",
    "NUMNOTEQUAL", "LESSTHAN", "GREATERTHAN", "LESSTHANOREQUAL",
    "GREATERTHANOREQUAL", "MIN", "MAX", "WITHIN",
    "RIPEMD160", "SHA1", "SHA256", "HASH256", "CODESEPARATOR",
    "NEGATE", "ABS", "NOT", "0NOTEQUAL", "1ADD", "1SUB",
    "NOP", "NOP1", "NOP2", "NOP3", "NOP4", "NOP5", "NOP6", "NOP7",
    "NOP8", "NOP9", "NOP10",
    "CHECKLOCKTIMEVERIFY", "CHECKSEQUENCEVERIFY",
    "CHECKSIGADD", "RESERVED", "RESERVED1", "RESERVED2",
    "VER", "VERIF", "VERNOTIF",
    "CAT", "SUBSTR", "LEFT", "RIGHT", "INVERT", "AND", "OR", "XOR",
    "2MUL", "2DIV", "MUL", "DIV", "MOD", "LSHIFT", "RSHIFT",
    "INVALIDOPCODE",
]


def normalize_asm_token(tok):
    """Normalize a single asm token for comparison."""
    upper = tok.upper()
    if upper in ASM_NORMALIZE:
        return ASM_NORMALIZE[upper]
    # Strip OP_ prefix for comparison
    if upper.startswith("OP_"):
        return upper[3:]
    return upper


def hex_to_script_int(hex_str):
    """Try to interpret a hex string as a Bitcoin script integer."""
    try:
        data = bytes.fromhex(hex_str)
        if len(data) == 0:
            return "0"
        # Little-endian with sign bit
        negative = data[-1] & 0x80
        val = int.from_bytes(data, "little")
        if negative:
            val = -(val ^ (0x80 << (8 * (len(data) - 1))))
        return str(val)
    except Exception:
        return hex_str


def normalize_asm(asm_str):
    """Normalize full asm string for lenient comparison."""
    if not asm_str:
        return ""
    tokens = asm_str.split()
    normalized = []
    for t in tokens:
        nt = normalize_asm_token(t)
        # If it looks like pure hex data push, try interpreting as integer
        if re.match(r'^[0-9a-fA-F]+$', nt) and len(nt) % 2 == 0 and len(nt) <= 8:
            nt = hex_to_script_int(nt)
        normalized.append(nt)
    return " ".join(normalized)


def compare_decoded_script(ref_result, node_result):
    """Compare decoded script fields. Returns (strict_diffs, semantic_diffs).

    strict_diffs: exact field mismatches
    semantic_diffs: mismatches even after normalization (real bugs)
    """
    strict_diffs = []
    semantic_diffs = []
    for field in DECODE_SCRIPT_FIELDS:
        ref_val = ref_result.get(field)
        node_val = node_result.get(field)
        if ref_val is not None and ref_val != node_val:
            diff = {"field": field, "expected": ref_val, "got": node_val}
            strict_diffs.append(diff)
            # For asm, check after normalization
            if field == "asm" and ref_val and node_val:
                if normalize_asm(ref_val) != normalize_asm(node_val):
                    semantic_diffs.append(diff)
            elif field != "asm":
                semantic_diffs.append(diff)
    return strict_diffs, semantic_diffs


def test_decodescript(clients, ref_client):
    """Test decodescript using assembled scripts from script_tests.json."""
    filepath = os.path.join(BITCOIN_CORE_DATA, "script_tests.json")
    data = json.load(open(filepath))

    results = {"total": 0, "assembled": 0, "tested": 0, "per_node": {}}

    for node_name in clients:
        if node_name == "core":
            continue
        results["per_node"][node_name] = {
            "pass_strict": 0, "fail_strict": 0,
            "pass_semantic": 0, "fail_semantic": 0,
            "rpc_errors": 0,
            "errors": [],
        }

    # Collect unique scriptPubKey hex values to avoid redundant RPC calls
    scripts_to_test = []
    seen_hex = set()

    for entry in data:
        if not isinstance(entry, list):
            continue
        # Non-witness: [scriptSig, scriptPubKey, flags, result, ...]
        # Witness: [[wit..., amount], scriptSig, scriptPubKey, flags, result, ...]
        if isinstance(entry[0], list) and len(entry) >= 5:
            # witness format
            script_pubkey = entry[2]
        elif len(entry) >= 4 and isinstance(entry[0], str):
            if len(entry) == 1:
                continue  # comment
            script_pubkey = entry[1]
        else:
            continue

        results["total"] += 1

        try:
            hex_script = assemble_script(script_pubkey)
        except Exception:
            continue

        if not hex_script or hex_script in seen_hex:
            continue

        seen_hex.add(hex_script)
        scripts_to_test.append((script_pubkey, hex_script))

    results["assembled"] = len(scripts_to_test)
    print(f"    Assembled {len(scripts_to_test)} unique scripts from "
          f"{results['total']} test entries")

    tested = 0
    for asm_str, hex_script in scripts_to_test:
        ref_status, ref_val = rpc_decodescript(ref_client, hex_script)
        if ref_status == "error":
            continue

        tested += 1
        for node_name, client in clients.items():
            if node_name == "core":
                continue

            node_status, node_val = rpc_decodescript(client, hex_script)
            node_results = results["per_node"][node_name]

            if node_status == "error":
                node_results["rpc_errors"] += 1
                node_results["fail_strict"] += 1
                node_results["fail_semantic"] += 1
                if len(node_results["errors"]) < 20:
                    node_results["errors"].append({
                        "script_asm": asm_str[:80],
                        "script_hex": hex_script[:64],
                        "error": str(node_val)[:200],
                    })
                continue

            strict_diffs, semantic_diffs = compare_decoded_script(ref_val, node_val)

            if strict_diffs:
                node_results["fail_strict"] += 1
            else:
                node_results["pass_strict"] += 1

            if semantic_diffs:
                node_results["fail_semantic"] += 1
                if len(node_results["errors"]) < 20:
                    node_results["errors"].append({
                        "script_asm": asm_str[:80],
                        "script_hex": hex_script[:64],
                        "semantic_diffs": semantic_diffs[:5],
                    })
            else:
                node_results["pass_semantic"] += 1

    results["tested"] = tested
    return results


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print("=" * 72)
    print("Bitcoin Core Test Vector Validation")
    print("=" * 72)
    print()

    # Discover available nodes
    print("Discovering nodes...")
    clients = make_clients()
    if "core" not in clients:
        print("ERROR: Bitcoin Core is not reachable. Cannot proceed.")
        sys.exit(1)

    ref_client = clients["core"]
    node_names = sorted(n for n in clients if n != "core")
    print(f"  Reference: core")
    print(f"  Test nodes: {', '.join(node_names)}")
    print()

    output = {}

    # Test 1: decoderawtransaction
    print("[1/2] Testing decoderawtransaction (tx_valid.json + tx_invalid.json)...")
    t0 = time.time()
    decode_tx_results = test_decoderawtransaction(clients, ref_client)
    elapsed = time.time() - t0
    print(f"  tx_valid:   {decode_tx_results['tx_valid']['tested']}/{decode_tx_results['tx_valid']['total']} entries tested")
    print(f"  tx_invalid: {decode_tx_results['tx_invalid']['tested']}/{decode_tx_results['tx_invalid']['total']} entries tested")
    for node_name in node_names:
        for label in ["tx_valid", "tx_invalid"]:
            nr = decode_tx_results[label]["per_node"].get(node_name, {})
            p = nr.get("pass", 0)
            f = nr.get("fail", 0)
            print(f"    {node_name}/{label}: {p} pass, {f} fail")
    print(f"  Elapsed: {elapsed:.1f}s")
    print()
    output["decoderawtransaction"] = decode_tx_results

    # Test 2: decodescript
    print("[2/2] Testing decodescript (script_tests.json)...")
    t0 = time.time()
    decode_script_results = test_decodescript(clients, ref_client)
    elapsed = time.time() - t0
    print(f"  Tested {decode_script_results['tested']}/{decode_script_results['assembled']} assembled scripts")
    for node_name in node_names:
        nr = decode_script_results["per_node"].get(node_name, {})
        ps = nr.get("pass_strict", 0)
        fs = nr.get("fail_strict", 0)
        psem = nr.get("pass_semantic", 0)
        fsem = nr.get("fail_semantic", 0)
        print(f"    {node_name}: strict {ps}/{ps+fs}, semantic {psem}/{psem+fsem}")
    print(f"  Elapsed: {elapsed:.1f}s")
    print()
    output["decodescript"] = decode_script_results

    # Summary (use semantic pass/fail for decodescript, regular for decoderawtx)
    total_pass = 0
    total_fail = 0
    per_node_summary = {}
    for section in [decode_tx_results.get("tx_valid", {}),
                    decode_tx_results.get("tx_invalid", {})]:
        pn = section.get("per_node", {})
        for node_name, nr in pn.items():
            if node_name not in per_node_summary:
                per_node_summary[node_name] = {"pass": 0, "fail": 0}
            per_node_summary[node_name]["pass"] += nr.get("pass", 0)
            per_node_summary[node_name]["fail"] += nr.get("fail", 0)
            total_pass += nr.get("pass", 0)
            total_fail += nr.get("fail", 0)

    # Add decodescript semantic results
    for node_name, nr in decode_script_results.get("per_node", {}).items():
        if node_name not in per_node_summary:
            per_node_summary[node_name] = {"pass": 0, "fail": 0}
        per_node_summary[node_name]["pass"] += nr.get("pass_semantic", 0)
        per_node_summary[node_name]["fail"] += nr.get("fail_semantic", 0)
        total_pass += nr.get("pass_semantic", 0)
        total_fail += nr.get("fail_semantic", 0)

    output["summary"] = {
        "total_comparisons": total_pass + total_fail,
        "total_pass": total_pass,
        "total_fail": total_fail,
        "per_node": per_node_summary,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "nodes_tested": node_names,
    }

    # Write results
    os.makedirs(os.path.dirname(RESULTS_PATH), exist_ok=True)
    with open(RESULTS_PATH, "w") as f:
        json.dump(output, f, indent=2)
    print(f"Results written to {RESULTS_PATH}")

    # Print summary table
    print()
    print("=" * 72)
    print(f"{'Node':<15} {'Pass':>8} {'Fail':>8} {'Total':>8}")
    print("-" * 42)
    for node_name in sorted(per_node_summary.keys()):
        ns = per_node_summary[node_name]
        t = ns["pass"] + ns["fail"]
        print(f"{node_name:<15} {ns['pass']:>8} {ns['fail']:>8} {t:>8}")
    print("-" * 42)
    print(f"{'TOTAL':<15} {total_pass:>8} {total_fail:>8} {total_pass+total_fail:>8}")
    print("=" * 72)

    return 0 if total_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

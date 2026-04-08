#!/usr/bin/env python3
"""Simple regtest block miner using getblocktemplate and submitblock."""

import json
import struct
import hashlib
import time
import sys
import urllib.request
import urllib.error
import binascii
import base64


def rpc_call(url, user, password, method, params=None):
    """Make a JSON-RPC call."""
    if params is None:
        params = []
    payload = json.dumps({
        "jsonrpc": "1.0",
        "id": "miner",
        "method": method,
        "params": params,
    }).encode()
    req = urllib.request.Request(url, data=payload)
    credentials = base64.b64encode(f"{user}:{password}".encode()).decode()
    req.add_header("Authorization", f"Basic {credentials}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read())
            if result.get("error"):
                return None, result["error"]
            return result["result"], None
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        try:
            err = json.loads(body)
            return None, err.get("error", body)
        except:
            return None, body


def sha256d(data):
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()


def build_coinbase_tx(template, extra_data=b"", op_return_data=None):
    """Build a coinbase transaction from template data."""
    height = template["height"]
    coinbase_value = template["coinbasevalue"]

    # Serialize height for coinbase script (BIP34)
    if height == 0:
        height_script = b"\x00"
    elif height <= 0xff:
        height_script = b"\x02" + struct.pack("<H", height)
    elif height <= 0xffff:
        height_script = b"\x03" + struct.pack("<I", height)[:3]
    elif height <= 0xffffff:
        height_script = b"\x03" + struct.pack("<I", height)[:3]
    else:
        height_script = b"\x04" + struct.pack("<I", height)

    coinbase_script = height_script + extra_data

    # Build the transaction
    tx = b""
    # Version
    tx += struct.pack("<I", 1)
    # Marker + flag for segwit
    tx_segwit = tx + b"\x00\x01"

    # Input count
    input_part = b"\x01"
    # Previous output (null for coinbase)
    input_part += b"\x00" * 32  # txid
    input_part += struct.pack("<I", 0xFFFFFFFF)  # vout
    # Coinbase script
    input_part += bytes([len(coinbase_script)]) + coinbase_script
    # Sequence
    input_part += struct.pack("<I", 0xFFFFFFFF)

    # Outputs
    outputs = b""
    num_outputs = 1

    # Main output - pay to OP_TRUE (anyone can spend, fine for regtest)
    # Using P2WSH OP_TRUE for segwit compatibility
    # scriptPubKey: OP_0 <32-byte-hash>  (P2WSH of OP_TRUE)
    op_true_hash = sha256d(b"\x51")[:32]  # SHA256 of OP_TRUE
    op_true_sha256 = hashlib.sha256(b"\x51").digest()
    spk = b"\x00\x20" + op_true_sha256  # witness v0 + 32 bytes

    remaining_value = coinbase_value

    if op_return_data is not None:
        num_outputs += 1
        op_return_spk = b"\x6a" + bytes([len(op_return_data)]) + op_return_data
        outputs += struct.pack("<q", 0)  # 0 value for OP_RETURN
        outputs += bytes([len(op_return_spk)]) + op_return_spk

    outputs += struct.pack("<q", remaining_value)
    outputs += bytes([len(spk)]) + spk

    # Default witness commitment
    witness_commitment = None
    if "default_witness_commitment" in template:
        witness_commitment = binascii.unhexlify(template["default_witness_commitment"])
        num_outputs += 1
        outputs += struct.pack("<q", 0)
        outputs += bytes([len(witness_commitment)]) + witness_commitment

    tx_no_witness = tx + bytes([num_outputs]) if False else b""

    # Build non-segwit serialization for txid
    tx_nosw = struct.pack("<I", 1)  # version
    tx_nosw += input_part
    tx_nosw += bytes([num_outputs]) + outputs
    tx_nosw += struct.pack("<I", 0)  # locktime

    # Build segwit serialization
    tx_sw = struct.pack("<I", 1)  # version
    tx_sw += b"\x00\x01"  # segwit marker+flag
    tx_sw += input_part
    tx_sw += bytes([num_outputs]) + outputs
    # Witness for coinbase: single stack item (witness nonce)
    tx_sw += b"\x01\x20" + b"\x00" * 32
    tx_sw += struct.pack("<I", 0)  # locktime

    txid = sha256d(tx_nosw)[::-1].hex()
    return tx_sw.hex(), tx_nosw.hex(), txid


def build_block(template, coinbase_hex_nosw, coinbase_hex_sw, txids_hex):
    """Build a block from template + coinbase + transactions."""
    version = template["version"]
    prev_hash = template["previousblockhash"]
    bits = template["bits"]
    curtime = template["curtime"]

    # Compute merkle root
    # txids: coinbase txid first, then transaction txids
    all_txids = txids_hex
    hashes = [binascii.unhexlify(txid)[::-1] for txid in all_txids]

    while len(hashes) > 1:
        if len(hashes) % 2 != 0:
            hashes.append(hashes[-1])
        new_hashes = []
        for i in range(0, len(hashes), 2):
            new_hashes.append(sha256d(hashes[i] + hashes[i + 1]))
        hashes = new_hashes

    merkle_root = hashes[0]

    # Build header
    header = struct.pack("<I", version)
    header += binascii.unhexlify(prev_hash)[::-1]
    header += merkle_root
    header += struct.pack("<I", curtime)
    header += binascii.unhexlify(bits)[::-1]

    # Mine (find nonce) - regtest difficulty is 1, should be instant
    for nonce in range(0, 0xFFFFFFFF):
        candidate = header + struct.pack("<I", nonce)
        block_hash = sha256d(candidate)
        if block_hash[-4:] == b"\x00\x00\x00\x00":  # regtest target
            # Build full block
            txs = coinbase_hex_sw
            for tx_hex in template.get("transactions", []):
                txs += tx_hex["data"]

            # Transaction count as varint
            ntx = 1 + len(template.get("transactions", []))
            if ntx < 0xfd:
                txcount = bytes([ntx]).hex()
            else:
                txcount = "fd" + struct.pack("<H", ntx).hex()

            block_hex = candidate.hex() + txcount + txs
            return block_hex, block_hash[::-1].hex(), nonce
    return None, None, None


def mine_blocks(rpc_url, user, password, count, extra_data=b""):
    """Mine count blocks and return their hashes."""
    hashes = []
    for i in range(count):
        template, err = rpc_call(rpc_url, user, password, "getblocktemplate", [{"rules": ["segwit"]}])
        if err:
            print(f"  getblocktemplate error: {err}")
            return hashes

        coinbase_sw, coinbase_nosw, coinbase_txid = build_coinbase_tx(template, extra_data)

        # Collect all txids (coinbase first)
        all_txids = [coinbase_txid]
        for tx in template.get("transactions", []):
            all_txids.append(tx["txid"])

        block_hex, block_hash, nonce = build_block(template, coinbase_nosw, coinbase_sw, all_txids)
        if block_hex is None:
            print(f"  Failed to mine block {template['height']}")
            return hashes

        result, err = rpc_call(rpc_url, user, password, "submitblock", [block_hex])
        if err:
            print(f"  submitblock error at height {template['height']}: {err}")
            return hashes
        if result is not None and result != "":
            print(f"  submitblock rejected at height {template['height']}: {result}")
            return hashes

        hashes.append(block_hash)
        if (i + 1) % 10 == 0:
            print(f"  Mined {i + 1}/{count} blocks")

    return hashes


if __name__ == "__main__":
    url = "http://127.0.0.1:18443"
    user = "test"
    password = "test"
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 10

    print(f"Mining {count} blocks...")
    hashes = mine_blocks(url, user, password, count)
    print(f"Mined {len(hashes)} blocks")
    if hashes:
        print(f"Last hash: {hashes[-1]}")

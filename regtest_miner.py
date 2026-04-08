#!/usr/bin/env python3
"""Simple regtest block miner using getblocktemplate and submitblock."""

import json
import struct
import hashlib
import sys
import urllib.request
import urllib.error
import binascii
import base64


def rpc_call(url, user, password, method, params=None):
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


def compact_size(n):
    if n < 0xfd:
        return bytes([n])
    elif n <= 0xffff:
        return b"\xfd" + struct.pack("<H", n)
    elif n <= 0xffffffff:
        return b"\xfe" + struct.pack("<I", n)
    else:
        return b"\xff" + struct.pack("<Q", n)


def encode_coinbase_height(n):
    """Encode block height for coinbase script (CScript << int64_t).

    Bitcoin Core uses push_int64 which maps:
      0 -> OP_0 (0x00)
      1..16 -> OP_1..OP_16 (0x51..0x60)
      -1 -> OP_1NEGATE (0x4f)
      otherwise -> CScriptNum push (length-prefixed little-endian)
    """
    if n == 0:
        return b"\x00"  # OP_0
    if n == -1:
        return b"\x4f"  # OP_1NEGATE
    if 1 <= n <= 16:
        return bytes([0x50 + n])  # OP_1 through OP_16
    # For larger values, use CScriptNum encoding
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
    return bytes([len(result)] + result)


def bits_to_target(bits_hex):
    bits = int(bits_hex, 16)
    exp = bits >> 24
    mant = bits & 0x7fffff
    if exp <= 3:
        target = mant >> (8 * (3 - exp))
    else:
        target = mant << (8 * (exp - 3))
    return target


def build_coinbase_tx(template, extra_data=b""):
    """Build a segwit coinbase transaction."""
    height = template["height"]
    coinbase_value = template["coinbasevalue"]

    # BIP34 height in coinbase
    height_script = encode_coinbase_height(height)
    # Coinbase scriptSig must be 2-100 bytes; pad with OP_0 if needed
    coinbase_script = height_script + extra_data
    if len(coinbase_script) < 2:
        coinbase_script += b"\x00"  # OP_0 padding

    # --- Non-witness serialization (for txid) ---
    tx_nosw = b""
    tx_nosw += struct.pack("<i", 2)  # version 2

    # 1 input (coinbase)
    tx_nosw += b"\x01"
    tx_nosw += b"\x00" * 32  # null prev txid
    tx_nosw += struct.pack("<I", 0xFFFFFFFF)  # null prev vout
    tx_nosw += compact_size(len(coinbase_script)) + coinbase_script
    tx_nosw += struct.pack("<I", 0xFFFFFFFF)  # sequence

    # Outputs
    outputs_data = b""
    num_outputs = 0

    # Output 0: coinbase value to anyone-can-spend (OP_TRUE)
    num_outputs += 1
    spk = b"\x51"  # OP_TRUE
    outputs_data += struct.pack("<q", coinbase_value)
    outputs_data += compact_size(len(spk)) + spk

    # Witness commitment output (required for segwit)
    dwc = template.get("default_witness_commitment")
    if dwc:
        num_outputs += 1
        wc_script = binascii.unhexlify(dwc)
        outputs_data += struct.pack("<q", 0)
        outputs_data += compact_size(len(wc_script)) + wc_script

    tx_nosw += compact_size(num_outputs) + outputs_data
    tx_nosw += struct.pack("<I", 0)  # locktime

    txid = sha256d(tx_nosw)[::-1].hex()

    # --- Witness serialization ---
    tx_sw = b""
    tx_sw += struct.pack("<i", 2)  # version 2
    tx_sw += b"\x00\x01"  # segwit marker + flag

    # Same input
    tx_sw += b"\x01"
    tx_sw += b"\x00" * 32
    tx_sw += struct.pack("<I", 0xFFFFFFFF)
    tx_sw += compact_size(len(coinbase_script)) + coinbase_script
    tx_sw += struct.pack("<I", 0xFFFFFFFF)

    # Same outputs
    tx_sw += compact_size(num_outputs) + outputs_data

    # Witness: 1 item, 32-byte zero nonce
    tx_sw += b"\x01"  # 1 witness field
    tx_sw += b"\x20" + b"\x00" * 32  # 32 zero bytes

    tx_sw += struct.pack("<I", 0)  # locktime

    return tx_sw.hex(), tx_nosw.hex(), txid


def build_block_header(template, merkle_root, nonce):
    header = struct.pack("<i", template["version"])
    header += binascii.unhexlify(template["previousblockhash"])[::-1]
    header += merkle_root
    header += struct.pack("<I", template["curtime"])
    header += binascii.unhexlify(template["bits"])[::-1]
    header += struct.pack("<I", nonce)
    return header


def compute_merkle_root(txids_le):
    """Compute merkle root from list of txid bytes (little-endian)."""
    hashes = list(txids_le)
    if not hashes:
        return b"\x00" * 32
    while len(hashes) > 1:
        if len(hashes) % 2 != 0:
            hashes.append(hashes[-1])
        new = []
        for i in range(0, len(hashes), 2):
            new.append(sha256d(hashes[i] + hashes[i + 1]))
        hashes = new
    return hashes[0]


def mine_blocks(rpc_url, user, password, count, extra_data=b""):
    """Mine count blocks and return their hashes."""
    hashes = []
    for i in range(count):
        template, err = rpc_call(rpc_url, user, password, "getblocktemplate",
                                 [{"rules": ["segwit"]}])
        if err:
            print(f"  getblocktemplate error: {err}", file=sys.stderr)
            return hashes

        target = bits_to_target(template["bits"])

        coinbase_sw, coinbase_nosw, coinbase_txid = build_coinbase_tx(
            template, extra_data)

        # All txids in little-endian bytes
        all_txids_le = [binascii.unhexlify(coinbase_txid)[::-1]]
        tx_data = ""
        for tx in template.get("transactions", []):
            all_txids_le.append(binascii.unhexlify(tx["txid"])[::-1])
            tx_data += tx["data"]

        merkle_root = compute_merkle_root(all_txids_le)

        # Mine (find valid nonce)
        found = False
        for nonce in range(0, 0xFFFFFFFF):
            header = build_block_header(template, merkle_root, nonce)
            block_hash = sha256d(header)
            # Compare as 256-bit LE integer
            hash_int = int.from_bytes(block_hash, 'little')
            if hash_int <= target:
                # Assemble full block
                ntx = 1 + len(template.get("transactions", []))
                block_hex = (header.hex() +
                             compact_size(ntx).hex() +
                             coinbase_sw +
                             tx_data)

                result, err = rpc_call(rpc_url, user, password,
                                       "submitblock", [block_hex])
                if err:
                    print(f"  submitblock error at height {template['height']}: {err}",
                          file=sys.stderr)
                    return hashes
                if result is not None and result != "" and result is not None:
                    print(f"  submitblock rejected at height {template['height']}: {result}",
                          file=sys.stderr)
                    return hashes

                block_hash_hex = block_hash[::-1].hex()
                hashes.append(block_hash_hex)
                found = True
                break

        if not found:
            print(f"  Failed to mine block {template['height']}", file=sys.stderr)
            return hashes

        if (i + 1) % 10 == 0 or i == count - 1:
            print(f"  Mined {i + 1}/{count} blocks (height {template['height']})")

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

#!/usr/bin/env python3
"""
build_spend_chain.py — build a regtest chain on a running Bitcoin Core that
INCLUDES a real spend, WITHOUT relying on the Core wallet (this Core build is
compiled without wallet support).

Uses Core's MiniWallet (RAW_P2PK mode: deterministic privkey k=1) so the spend
input carries a real signature and the spent prevout is a P2PK scriptPubKey —
making the confirming block's BIP-158 filter a non-trivial multi-element filter
(an output scriptPubKey AND a spent-prevout scriptPubKey from undo data).

Talks to Core over JSON-RPC via the functional test framework's
AuthServiceProxy (cookie auth). Only non-wallet RPCs are used
(generatetodescriptor, scantxoutset, sendrawtransaction, getblock*, ...).

Args (positional): <tf_path> <rpc_port> <cookie_path> <coinbase_blocks> <final_mine_addr>

Prints, one per line:
    TOTAL <height>
    SPEND_HEIGHT <height>
    SPEND_HASH <blockhash>
    SPEND_TXID <txid>
"""
import sys
import os


def main():
    tf_path = sys.argv[1]
    rpc_port = int(sys.argv[2])
    cookie_path = sys.argv[3]
    coinbase_blocks = int(sys.argv[4])
    final_addr = sys.argv[5]

    sys.path.insert(0, tf_path)
    from test_framework.authproxy import AuthServiceProxy
    from test_framework.wallet import MiniWallet, MiniWalletMode

    with open(cookie_path) as f:
        cookie = f.read().strip()
    url = f"http://{cookie}@127.0.0.1:{rpc_port}"

    # Thin node wrapper: MiniWallet calls node.<rpc>(...); AuthServiceProxy
    # provides those via __getattr__. A fresh proxy per attribute keeps the
    # HTTP connection simple and avoids keep-alive surprises.
    class Node:
        def __getattr__(self, name):
            return getattr(AuthServiceProxy(url, timeout=120), name)

    node = Node()

    # RAW_P2PK: real signed spend; spent prevout is a P2PK script.
    w = MiniWallet(node, mode=MiniWalletMode.RAW_P2PK)

    # Mine coinbase_blocks to the MiniWallet so its coinbase outputs mature
    # and are spendable (regtest COINBASE_MATURITY = 100).
    w.generate(coinbase_blocks)

    # Create a real spend (self-transfer) and broadcast it to the mempool.
    spend = w.send_self_transfer(from_node=node)
    spend_txid = spend["txid"]

    # Mine ONE block (to the deterministic non-wallet address) that confirms
    # the spend -> the SPEND BLOCK with a multi-element filter.
    node.generatetoaddress(1, final_addr)

    total = node.getblockcount()
    spend_height = total  # the spend tx confirms in the most recent block
    spend_hash = node.getblockhash(spend_height)

    # Sanity: the spend tx must be in that block.
    blk = node.getblock(spend_hash, 1)
    if spend_txid not in blk["tx"]:
        sys.stderr.write(
            f"ERROR: spend tx {spend_txid} not in block {spend_hash}\n")
        sys.exit(2)

    print(f"TOTAL {total}")
    print(f"SPEND_HEIGHT {spend_height}")
    print(f"SPEND_HASH {spend_hash}")
    print(f"SPEND_TXID {spend_txid}")


if __name__ == "__main__":
    main()

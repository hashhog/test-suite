#!/usr/bin/env bash
#
# rustoshi_walletdiff.sh — walletdiff slice 1 (address-derivation parity, P2.1)
# for rustoshi, differential against a REAL bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_address.py over wallet-diff/vectors-address.json. This
# script just launches rustoshi + the Core oracle and hands both to the shared
# driver in wallet-diff/_lib.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-rustoshi* only;
# reserved ports 22150/22151 (Core RPC/P2P) + 22170/22171 (rustoshi RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF rustoshi: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

IMPL="rustoshi"
BIN="$HASHHOG_ROOT/rustoshi/target/release/rustoshi"
BUILD_HINT="build with: cargo build --release"

CORE_RPC=22150
CORE_P2P=22151
IMPL_RPC=22170
IMPL_P2P=22171

IMPL_DATADIR="/tmp/walletdiff-rustoshi"
CORE_DATADIR="/tmp/walletdiff-rustoshi-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/.cookie" "$IMPL_DATADIR/regtest/.cookie")

launch_impl() {
    "$BIN" --network=regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcbind="127.0.0.1:$IMPL_RPC" \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_address_main

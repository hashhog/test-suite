#!/usr/bin/env bash
#
# rustoshi_walletsign.sh — walletdiff SLICE 3 (signing + sighash, incl. taproot,
# P2.1) for rustoshi, differential against a REAL bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparison logic lives
# in wallet-diff/probe_sign.py. This script just launches rustoshi + the Core
# oracle and hands both to the shared driver in wallet-diff/_sign_lib.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletsign-rustoshi* only;
# reserved ports 22154/22155 (Core RPC/P2P) + 22174/22175 (rustoshi RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF rustoshi: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_sign_lib.sh"

IMPL="rustoshi"
BIN="$HASHHOG_ROOT/rustoshi/target/release/rustoshi"
BUILD_HINT="build with: cargo build --release"

CORE_RPC=22154
CORE_P2P=22155
IMPL_RPC=22174
IMPL_P2P=22175

IMPL_DATADIR="/tmp/walletsign-rustoshi"
CORE_DATADIR="/tmp/walletsign-rustoshi-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/.cookie" "$IMPL_DATADIR/regtest/.cookie")

launch_impl() {
    "$BIN" --network=regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcbind="127.0.0.1:$IMPL_RPC" \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_signing_main

#!/usr/bin/env bash
#
# camlcoin_walletdiff_psbt.sh — walletdiff SLICE 2 (PSBT round-trip parity,
# P2.1/P2.2) for camlcoin (OCaml), differential against a REAL wallet-enabled
# bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_psbt.py. This script just launches camlcoin + the Core
# oracle and hands both endpoints to the shared driver in _lib_psbt.sh.
#
# Launch shape: `main.exe --network regtest --datadir <dd> --port <p2p>
# --rpcport <rpc>` (space-separated args). Cookie at <datadir>/.cookie
# (lib/cli.ml:1301). camlcoin routes /wallet/<name> and base "/" -> default
# wallet (lib/rpc.ml:14056), so the probe's single-wallet base-URL flow works.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-psbt-camlcoin* only;
# reserved ports 22194/22195 (Core RPC/P2P) + 22196/22197 (camlcoin RPC/P2P);
# ONE summary line on stdout; exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER
# touches /data/nvme1/, testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib_psbt.sh"

IMPL="camlcoin"
BIN="$HASHHOG_ROOT/camlcoin/_build/default/bin/main.exe"
BUILD_HINT="build with: ./build-all.sh camlcoin"

CORE_RPC=22194
CORE_P2P=22195
IMPL_RPC=22196
IMPL_P2P=22197

IMPL_DATADIR="/tmp/walletdiff-psbt-camlcoin"
CORE_DATADIR="/tmp/walletdiff-psbt-camlcoin-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/.cookie" "$IMPL_DATADIR/regtest/.cookie")

launch_impl() {
    "$BIN" --network regtest --datadir "$IMPL_DATADIR" \
        --port "$IMPL_P2P" --rpcport "$IMPL_RPC" \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_psbt_main

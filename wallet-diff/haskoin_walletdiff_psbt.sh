#!/usr/bin/env bash
#
# haskoin_walletdiff_psbt.sh — walletdiff SLICE 2 (PSBT round-trip parity,
# P2.1/P2.2) for haskoin (Haskell), differential against a REAL wallet-enabled
# bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_psbt.py. This script just launches haskoin + the Core
# oracle and hands both endpoints to the shared driver in _lib_psbt.sh.
#
# Launch shape: GLOBAL --datadir/--network BEFORE the `node` subcommand; node
# options after. Cookie at <datadir>/regtest/.cookie. --metricsport/--healthport
# 0 to avoid busy-port noise. haskoin routes wallet calls under /wallet/<name>;
# the probe keeps a single wallet loaded per phase and uses the base URL (works
# on haskoin's /wallet routing too since exactly one wallet is loaded at once).
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-psbt-haskoin* only;
# reserved ports 22156/22157 (Core RPC/P2P) + 22176/22177 (haskoin RPC/P2P);
# ONE summary line on stdout; exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER
# touches /data/nvme1/, testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib_psbt.sh"

IMPL="haskoin"
BIN="$(find "$HASHHOG_ROOT/haskoin/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"
BUILD_HINT="build with: cd haskoin && cabal build (rocksdb_compat shim: scripts/build-rocksdb-compat.sh)"

CORE_RPC=22156
CORE_P2P=22157
IMPL_RPC=22176
IMPL_P2P=22177

IMPL_DATADIR="/tmp/walletdiff-psbt-haskoin"
CORE_DATADIR="/tmp/walletdiff-psbt-haskoin-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/regtest/.cookie" "$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" --datadir="$IMPL_DATADIR" --network Regtest \
        node --rpcport "$IMPL_RPC" --port "$IMPL_P2P" \
        --metricsport 0 --healthport 0 \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_psbt_main

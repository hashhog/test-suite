#!/usr/bin/env bash
#
# blockbrew_walletdiff_psbt.sh — walletdiff SLICE 2 (PSBT round-trip parity,
# P2.1/P2.2) for blockbrew (Go), differential against a REAL wallet-enabled
# bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_psbt.py. This script just launches blockbrew + the Core
# oracle and hands both endpoints to the shared driver in _lib_psbt.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-psbt-blockbrew* only;
# reserved ports 22160/22161 (Core RPC/P2P) + 22162/22163 (blockbrew RPC/P2P);
# ONE summary line on stdout; exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER
# touches /data/nvme1/, testnet4-data/, or any live node.
#
# blockbrew resolves wallet-context RPCs on the base URL to the sole loaded
# wallet (server.go getWalletForRPC: empty walletName -> GetDefaultWallet), so
# the probe's single-wallet discipline (unload-before-create) works on the base
# URL exactly as it does for rustoshi. -metricsport=0 avoids the 9332 bind race.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib_psbt.sh"

IMPL="blockbrew"
BIN="$HASHHOG_ROOT/blockbrew/blockbrew"
BUILD_HINT="build with: go build -o blockbrew ./..."

CORE_RPC=22160
CORE_P2P=22161
IMPL_RPC=22162
IMPL_P2P=22163

IMPL_DATADIR="/tmp/walletdiff-psbt-blockbrew"
CORE_DATADIR="/tmp/walletdiff-psbt-blockbrew-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/regtest/.cookie" "$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" -network=regtest -datadir="$IMPL_DATADIR" \
        -listen=127.0.0.1:"$IMPL_P2P" -rpcbind=127.0.0.1:"$IMPL_RPC" \
        -metricsport=0 \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_psbt_main

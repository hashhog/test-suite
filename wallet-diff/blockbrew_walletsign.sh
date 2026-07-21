#!/usr/bin/env bash
#
# blockbrew_walletsign.sh — walletdiff SLICE 3 (signing + sighash, incl. taproot,
# P2.1) for blockbrew (Go), differential against a REAL bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparison logic lives
# in wallet-diff/probe_sign.py. This script just launches blockbrew + the Core
# oracle and hands both to the shared driver in wallet-diff/_sign_lib.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletsign-blockbrew* only;
# reserved ports 22164/22165 (Core RPC/P2P) + 22166/22167 (blockbrew RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF blockbrew: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.
#
# -metricsport=0 disables the 9332 Prometheus bind so back-to-back runs never
# collide. Cookie lands at <dd>/regtest/.cookie (regtest datadir subdir).

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_sign_lib.sh"

IMPL="blockbrew"
BIN="$HASHHOG_ROOT/blockbrew/blockbrew"
BUILD_HINT="build with: go build -o blockbrew ./..."

CORE_RPC=22164
CORE_P2P=22165
IMPL_RPC=22166
IMPL_P2P=22167

IMPL_DATADIR="/tmp/walletsign-blockbrew"
CORE_DATADIR="/tmp/walletsign-blockbrew-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/regtest/.cookie" "$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" -network=regtest -datadir="$IMPL_DATADIR" \
        -listen=127.0.0.1:"$IMPL_P2P" -rpcbind=127.0.0.1:"$IMPL_RPC" \
        -metricsport=0 \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_signing_main

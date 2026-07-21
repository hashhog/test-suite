#!/usr/bin/env bash
#
# blockbrew_walletdiff.sh — walletdiff slice 1 (address-derivation parity, P2.1)
# for blockbrew (Go), differential against a REAL bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_address.py over wallet-diff/vectors-address.json. This
# script just launches blockbrew + the Core oracle and hands both to the shared
# driver in wallet-diff/_lib.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-blockbrew* only;
# reserved ports 22158/22159 (Core RPC/P2P) + 22178/22179 (blockbrew RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF blockbrew: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.
#
# blockbrew flag-style CLI: -network=regtest -datadir=<dd> -listen=<ip:port>
# -rpcbind=<ip:port>. On a non-mainnet network it appends the network name as a
# datadir subdir, so the cookie lands at <dd>/regtest/.cookie. -metricsport=0
# disables the Prometheus bind so back-to-back runs never collide on 9332.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

IMPL="blockbrew"
BIN="$HASHHOG_ROOT/blockbrew/blockbrew"
BUILD_HINT="build with: go build -o blockbrew ./..."

CORE_RPC=22158
CORE_P2P=22159
IMPL_RPC=22178
IMPL_P2P=22179

IMPL_DATADIR="/tmp/walletdiff-blockbrew"
CORE_DATADIR="/tmp/walletdiff-blockbrew-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/regtest/.cookie" "$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" -network=regtest -datadir="$IMPL_DATADIR" \
        -listen=127.0.0.1:"$IMPL_P2P" -rpcbind=127.0.0.1:"$IMPL_RPC" \
        -metricsport=0 \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_address_main

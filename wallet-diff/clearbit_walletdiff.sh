#!/usr/bin/env bash
#
# clearbit_walletdiff.sh — walletdiff slice 1 (address-derivation parity, P2.1)
# for clearbit, differential against a REAL bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_address.py over wallet-diff/vectors-address.json. This
# script just launches clearbit + the Core oracle and hands both to the shared
# driver in wallet-diff/_lib.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-clearbit* only;
# reserved ports 22152/22153 (Core RPC/P2P) + 22172/22173 (clearbit RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF clearbit: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.
#
# NOTE: clearbit also tries to bind its Prometheus port 9332 at startup; on
# this box that bind fails harmlessly (logged, node keeps running) — do not
# treat the "failed to bind port 9332" log line as a launch failure.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

IMPL="clearbit"
BIN="$HASHHOG_ROOT/clearbit/zig-out/bin/clearbit"
BUILD_HINT="build with: zig build -Doptimize=ReleaseFast"

CORE_RPC=22152
CORE_P2P=22153
IMPL_RPC=22172
IMPL_P2P=22173

IMPL_DATADIR="/tmp/walletdiff-clearbit"
CORE_DATADIR="/tmp/walletdiff-clearbit-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/regtest/.cookie" "$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" --regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcport="$IMPL_RPC" \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_address_main

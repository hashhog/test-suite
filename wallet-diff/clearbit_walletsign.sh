#!/usr/bin/env bash
#
# clearbit_walletsign.sh — walletdiff SLICE 3 (signing + sighash, incl. taproot,
# P2.1) for clearbit, differential against a REAL bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparison logic lives
# in wallet-diff/probe_sign.py. This script just launches clearbit + the Core
# oracle and hands both to the shared driver in wallet-diff/_sign_lib.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletsign-clearbit* only;
# reserved ports 22156/22157 (Core RPC/P2P) + 22176/22177 (clearbit RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF clearbit: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.
#
# NOTE: clearbit also tries to bind its Prometheus port 9332 at startup; on this
# box that bind fails harmlessly (logged, node keeps running) — do not treat the
# "failed to bind port 9332" log line as a launch failure.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_sign_lib.sh"

IMPL="clearbit"
BIN="$HASHHOG_ROOT/clearbit/zig-out/bin/clearbit"
BUILD_HINT="build with: zig build -Doptimize=ReleaseFast"

CORE_RPC=22156
CORE_P2P=22157
IMPL_RPC=22176
IMPL_P2P=22177

IMPL_DATADIR="/tmp/walletsign-clearbit"
CORE_DATADIR="/tmp/walletsign-clearbit-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/regtest/.cookie" "$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" --regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcport="$IMPL_RPC" \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_signing_main

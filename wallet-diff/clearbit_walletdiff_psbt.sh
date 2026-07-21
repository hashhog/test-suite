#!/usr/bin/env bash
#
# clearbit_walletdiff_psbt.sh — walletdiff SLICE 2 (PSBT round-trip parity,
# P2.1/P2.2) for clearbit, differential against a REAL wallet-enabled bitcoind
# regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_psbt.py. This script just launches clearbit + the Core
# oracle and hands both endpoints to the shared driver in _lib_psbt.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-psbt-clearbit* only;
# reserved ports 22156/22157 (Core RPC/P2P) + 22176/22177 (clearbit RPC/P2P);
# ONE summary line on stdout; exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER
# touches /data/nvme1/, testnet4-data/, or any live node.
#
# NOTE: clearbit also tries to bind its Prometheus port 9332 at startup; on this
# box that bind fails harmlessly (logged, node keeps running) — do not treat the
# "failed to bind port 9332" log line as a launch failure. The probe keeps a
# single wallet loaded per phase and uses the base URL (works on clearbit's
# /wallet routing too, since exactly one wallet is loaded at a time).

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib_psbt.sh"

IMPL="clearbit"
BIN="$HASHHOG_ROOT/clearbit/zig-out/bin/clearbit"
BUILD_HINT="build with: zig build -Doptimize=ReleaseFast"

CORE_RPC=22156
CORE_P2P=22157
IMPL_RPC=22176
IMPL_P2P=22177

IMPL_DATADIR="/tmp/walletdiff-psbt-clearbit"
CORE_DATADIR="/tmp/walletdiff-psbt-clearbit-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/regtest/.cookie" "$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" --regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcport="$IMPL_RPC" \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_psbt_main

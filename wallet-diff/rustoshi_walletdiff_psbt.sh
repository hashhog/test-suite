#!/usr/bin/env bash
#
# rustoshi_walletdiff_psbt.sh — walletdiff SLICE 2 (PSBT round-trip parity,
# P2.1/P2.2) for rustoshi, differential against a REAL wallet-enabled bitcoind
# regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_psbt.py. This script just launches rustoshi + the Core
# oracle and hands both endpoints to the shared driver in _lib_psbt.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-psbt-rustoshi* only;
# reserved ports 22154/22155 (Core RPC/P2P) + 22174/22175 (rustoshi RPC/P2P);
# ONE summary line on stdout; exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER
# touches /data/nvme1/, testnet4-data/, or any live node.
#
# NOTE: rustoshi has NO /wallet/<name> URL routing — exactly one wallet loaded
# at a time (recovery-script precedent). The probe honours this by keeping a
# single wallet loaded per phase (unload-before-create) and using the base URL.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib_psbt.sh"

IMPL="rustoshi"
BIN="$HASHHOG_ROOT/rustoshi/target/release/rustoshi"
BUILD_HINT="build with: cargo build --release"

CORE_RPC=22154
CORE_P2P=22155
IMPL_RPC=22174
IMPL_P2P=22175

IMPL_DATADIR="/tmp/walletdiff-psbt-rustoshi"
CORE_DATADIR="/tmp/walletdiff-psbt-rustoshi-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/.cookie" "$IMPL_DATADIR/regtest/.cookie")

launch_impl() {
    "$BIN" --network=regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcbind="127.0.0.1:$IMPL_RPC" \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_psbt_main

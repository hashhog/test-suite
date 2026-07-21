#!/usr/bin/env bash
#
# nimrod_walletdiff_psbt.sh — walletdiff SLICE 2 (PSBT round-trip parity,
# P2.1/P2.2) for nimrod, differential against a REAL wallet-enabled bitcoind
# regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_psbt.py. This script just launches nimrod + the Core oracle
# and hands both endpoints to the shared driver in _lib_psbt.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-psbt-nimrod* only;
# reserved ports 22160/22161 (Core RPC/P2P) + 22162/22163 (nimrod RPC/P2P);
# ONE summary line on stdout; exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER
# touches /data/nvme1/, testnet4-data/, or any live node.
#
# NOTE: nimrod needs the trailing `start` subcommand, binds RPC to
# 127.0.0.1:<rpcport>, and writes its cookie to <datadir>/regtest/.cookie. We
# pass --metricsport=0 to disable its default Prometheus 9332 bind.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib_psbt.sh"

IMPL="nimrod"
BIN="$HASHHOG_ROOT/nimrod/bin/nimrod"
BUILD_HINT="build with: nimble build -d:release -y"

CORE_RPC=22160
CORE_P2P=22161
IMPL_RPC=22162
IMPL_P2P=22163

IMPL_DATADIR="/tmp/walletdiff-psbt-nimrod"
CORE_DATADIR="/tmp/walletdiff-psbt-nimrod-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/regtest/.cookie" "$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" --regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcport="$IMPL_RPC" --metricsport=0 start \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_psbt_main

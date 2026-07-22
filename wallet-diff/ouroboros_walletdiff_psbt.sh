#!/usr/bin/env bash
#
# ouroboros_walletdiff_psbt.sh — walletdiff SLICE 2 (PSBT round-trip parity,
# P2.1/P2.2) for ouroboros, differential against a REAL wallet-enabled bitcoind
# regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_psbt.py. This script just launches ouroboros + the Core
# oracle and hands both endpoints to the shared driver in _lib_psbt.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-psbt-ouroboros* only;
# reserved ports 22156/22157 (Core RPC/P2P) + 22176/22177 (ouroboros RPC/P2P);
# ONE summary line on stdout; exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER
# touches /data/nvme1/, testnet4-data/, or any live node.
#
# ouroboros dialect: multi-wallet with /wallet/<name> URL routing, BUT the probe
# keeps EXACTLY ONE wallet loaded per phase (reset_wallet unloads every loaded
# wallet — including the auto-created "default" — before createwallet), so all
# wallet RPCs go to the base URL and route unambiguously. Cookie: <dd>/.cookie.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib_psbt.sh"

IMPL="ouroboros"
OURO_DIR="$HASHHOG_ROOT/ouroboros"
BIN="$(command -v python3 || echo python3)"
BUILD_HINT="python module ouroboros.cli (no build; reinstall Rust ext via tools/reinstall_ouroboros.sh only if import fails)"

CORE_RPC=22156
CORE_P2P=22157
IMPL_RPC=22176
IMPL_P2P=22177

IMPL_DATADIR="/tmp/walletdiff-psbt-ouroboros"
CORE_DATADIR="/tmp/walletdiff-psbt-ouroboros-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/.cookie" "$IMPL_DATADIR/regtest/.cookie")

launch_impl() {
    ( cd "$OURO_DIR" && exec python3 -m ouroboros.cli \
        --network regtest --data-dir "$IMPL_DATADIR" \
        start --force --rpc-port "$IMPL_RPC" --p2p-port "$IMPL_P2P" \
        --nodnsseed --nolisten \
        >"$IMPL_DATADIR/node.log" 2>&1 ) &
    IMPL_PID=$!
}

walletdiff_psbt_main

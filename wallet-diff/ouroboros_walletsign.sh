#!/usr/bin/env bash
#
# ouroboros_walletsign.sh — walletdiff SLICE 3 (signing + sighash, incl. taproot,
# P2.1) for ouroboros, differential against a REAL bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparison logic lives
# in wallet-diff/probe_sign.py. This script just launches ouroboros + the Core
# oracle and hands both to the shared driver in wallet-diff/_sign_lib.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletsign-ouroboros* only;
# reserved ports 22156/22157 (Core RPC/P2P) + 22176/22177 (ouroboros RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF ouroboros: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.
#
# ouroboros dialect: multi-wallet with /wallet/<name> routing. The sign probe
# createwallets a named wallet and drives it on the base URL. Cookie: <dd>/.cookie.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_sign_lib.sh"

IMPL="ouroboros"
OURO_DIR="$HASHHOG_ROOT/ouroboros"
BIN="$(command -v python3 || echo python3)"
BUILD_HINT="python module ouroboros.cli (no build; reinstall Rust ext via tools/reinstall_ouroboros.sh only if import fails)"

CORE_RPC=22156
CORE_P2P=22157
IMPL_RPC=22176
IMPL_P2P=22177

IMPL_DATADIR="/tmp/walletsign-ouroboros"
CORE_DATADIR="/tmp/walletsign-ouroboros-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/.cookie" "$IMPL_DATADIR/regtest/.cookie")

launch_impl() {
    ( cd "$OURO_DIR" && exec python3 -m ouroboros.cli \
        --network regtest --data-dir "$IMPL_DATADIR" \
        start --force --rpc-port "$IMPL_RPC" --p2p-port "$IMPL_P2P" \
        --nodnsseed --nolisten \
        >"$IMPL_DATADIR/node.log" 2>&1 ) &
    IMPL_PID=$!
}

walletdiff_signing_main

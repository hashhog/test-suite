#!/usr/bin/env bash
#
# hotbuns_walletsign.sh — walletdiff SLICE 3 (signing + sighash, incl. taproot,
# P2.1) for hotbuns (TypeScript/Bun), differential against a REAL bitcoind
# regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparison logic lives
# in wallet-diff/probe_sign.py. This script just launches hotbuns + the Core
# oracle and hands both to the shared driver in wallet-diff/_sign_lib.sh.
#
# NOTE (interpreted node): hotbuns runs under Bun directly; BIN points at `bun`
# and launch_impl runs the TS entrypoint by absolute path. It writes a
# Core-style cookie (`__cookie__:<hex>`) to <datadir>/.cookie and loads exactly
# one wallet on the base "/" URL. --metricsport=0 disables its Prometheus port
# (default 9332) to avoid a bind collision with the live node.
#
# Interface: no args; idempotent; scratch /tmp/walletsign-hotbuns* only;
# reserved ports 22156/22157 (Core RPC/P2P) + 22176/22177 (hotbuns RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF hotbuns: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_sign_lib.sh"

IMPL="hotbuns"
BIN="$(command -v bun || echo "$HOME/.bun/bin/bun")"
HOTBUNS_ENTRY="$HASHHOG_ROOT/hotbuns/src/index.ts"
BUILD_HINT="interpreted — needs Bun; run: bun run hotbuns/src/index.ts"

CORE_RPC=22156
CORE_P2P=22157
IMPL_RPC=22176
IMPL_P2P=22177

IMPL_DATADIR="/tmp/walletsign-hotbuns"
CORE_DATADIR="/tmp/walletsign-hotbuns-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" run "$HOTBUNS_ENTRY" --network=regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcport="$IMPL_RPC" --metricsport=0 \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_signing_main

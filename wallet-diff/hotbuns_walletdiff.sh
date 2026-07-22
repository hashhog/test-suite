#!/usr/bin/env bash
#
# hotbuns_walletdiff.sh — walletdiff slice 1 (address-derivation parity, P2.1)
# for hotbuns (TypeScript/Bun), differential against a REAL bitcoind regtest
# oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_address.py over wallet-diff/vectors-address.json. This
# script just launches hotbuns + the Core oracle and hands both to the shared
# driver in wallet-diff/_lib.sh.
#
# NOTE (interpreted node): hotbuns has no compiled binary — it runs under Bun
# directly (`bun run src/index.ts`). BIN therefore points at the `bun`
# executable; launch_impl runs the TS entrypoint by absolute path (Bun resolves
# hotbuns/node_modules by walking up from the file). Its default command is
# "start", so no subcommand is needed. It writes a Bitcoin-Core-style cookie
# (`__cookie__:<hex>`) to <datadir>/.cookie and loads exactly one wallet on the
# base "/" URL, so the probe's base-URL wallet RPCs work without /wallet/ routing.
#
# NOTE: hotbuns defaults its Prometheus metrics port to 9332; we pass
# --metricsport=0 to disable it and avoid an EADDRINUSE against the live node.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-hotbuns* only;
# reserved ports 22158/22159 (Core RPC/P2P) + 22178/22179 (hotbuns RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF hotbuns: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

IMPL="hotbuns"
BIN="$(command -v bun || echo "$HOME/.bun/bin/bun")"
HOTBUNS_ENTRY="$HASHHOG_ROOT/hotbuns/src/index.ts"
BUILD_HINT="interpreted — needs Bun; run: bun run hotbuns/src/index.ts"

CORE_RPC=22158
CORE_P2P=22159
IMPL_RPC=22178
IMPL_P2P=22179

IMPL_DATADIR="/tmp/walletdiff-hotbuns"
CORE_DATADIR="/tmp/walletdiff-hotbuns-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" run "$HOTBUNS_ENTRY" --network=regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcport="$IMPL_RPC" --metricsport=0 \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_address_main

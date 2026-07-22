#!/usr/bin/env bash
#
# lunarblock_walletdiff_psbt.sh — walletdiff SLICE 2 (PSBT round-trip parity,
# P2.1/P2.2) for lunarblock (Lua/LuaJIT), differential against a REAL
# wallet-enabled bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_psbt.py. This script just launches lunarblock + the Core
# oracle and hands both endpoints to the shared driver in _lib_psbt.sh.
#
# lunarblock loads exactly ONE (auto-created) wallet on the base "/" URL — same
# single-wallet discipline as rustoshi — so the probe keeps one wallet loaded
# per phase and uses the base URL (no /wallet/<name> routing needed). See the
# auth note below (lunarblock writes no cookie; launch_impl writes one).
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-psbt-lunarblock* only;
# reserved ports 22164/22165 (Core RPC/P2P) + 22166/22167 (lunarblock RPC/P2P);
# ONE summary line on stdout; exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER
# touches /data/nvme1/, testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib_psbt.sh"

IMPL="lunarblock"
BIN="$(command -v luajit || echo luajit)"
BUILD_HINT="interpreted — needs luajit + lua-cjson; run: luajit lunarblock/src/main.lua"

CORE_RPC=22164
CORE_P2P=22165
IMPL_RPC=22166
IMPL_P2P=22167

IMPL_DATADIR="/tmp/walletdiff-psbt-lunarblock"
CORE_DATADIR="/tmp/walletdiff-psbt-lunarblock-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/.cookie")

LB_RPCUSER="lunarblock"
LB_RPCPASS="walletdiff-lb"

launch_impl() {
    export LUA_PATH="$HASHHOG_ROOT/lunarblock/src/?.lua;$HASHHOG_ROOT/lunarblock/src/?/init.lua;;"
    export LUA_CPATH="${LUA_CPATH:-$HOME/.local/lib/lua/5.1/?.so;;}"
    printf '%s:%s' "$LB_RPCUSER" "$LB_RPCPASS" > "$IMPL_DATADIR/.cookie"
    ( cd "$HASHHOG_ROOT/lunarblock" && \
      "$BIN" src/main.lua --network regtest --datadir "$IMPL_DATADIR" \
        --port "$IMPL_P2P" --rpcport "$IMPL_RPC" \
        --rpcuser "$LB_RPCUSER" --rpcpassword "$LB_RPCPASS" \
        --nov2transport ) \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_psbt_main

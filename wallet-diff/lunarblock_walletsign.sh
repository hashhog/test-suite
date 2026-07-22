#!/usr/bin/env bash
#
# lunarblock_walletsign.sh — walletdiff SLICE 3 (signing + sighash, incl.
# taproot, P2.1) for lunarblock (Lua/LuaJIT), differential against a REAL
# bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparison logic lives
# in wallet-diff/probe_sign.py. This script just launches lunarblock + the Core
# oracle and hands both to the shared driver in wallet-diff/_sign_lib.sh.
#
# lunarblock loads exactly ONE (auto-created) wallet on the base "/" URL (same
# single-wallet discipline as rustoshi). See the auth note below (lunarblock
# writes no cookie; launch_impl writes one and passes matching --rpcuser/pass).
#
# Interface: no args; idempotent; scratch /tmp/walletsign-lunarblock* only;
# reserved ports 22156/22157 (Core RPC/P2P) + 22176/22177 (lunarblock RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF lunarblock: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_sign_lib.sh"

IMPL="lunarblock"
BIN="$(command -v luajit || echo luajit)"
BUILD_HINT="interpreted — needs luajit + lua-cjson; run: luajit lunarblock/src/main.lua"

CORE_RPC=22156
CORE_P2P=22157
IMPL_RPC=22176
IMPL_P2P=22177

IMPL_DATADIR="/tmp/walletsign-lunarblock"
CORE_DATADIR="/tmp/walletsign-lunarblock-core"
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

walletdiff_signing_main

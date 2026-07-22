#!/usr/bin/env bash
#
# lunarblock_walletdiff.sh — walletdiff slice 1 (address-derivation parity, P2.1)
# for lunarblock (Lua/LuaJIT), differential against a REAL bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_address.py over wallet-diff/vectors-address.json. This
# script just launches lunarblock + the Core oracle and hands both to the shared
# driver in wallet-diff/_lib.sh.
#
# NOTE ON AUTH: lunarblock does NOT write a Bitcoin-Core-style .cookie file; its
# RPC server uses HTTP Basic auth from --rpcuser/--rpcpassword and only enforces
# it when the password is non-empty (rpc.lua:13883). So launch_impl WRITES a
# cookie file "<user>:<pass>" into the datadir itself and launches with a
# matching --rpcuser/--rpcpassword, giving the shared driver the cookie file it
# expects. lunarblock loads exactly ONE (auto-created) wallet on the base "/" URL
# — same single-wallet discipline as rustoshi — so the probe's base-URL wallet
# RPCs work without /wallet/<name> routing.
#
# NOTE: lunarblock also tries to bind Prometheus port 9332 at startup; on this
# box that bind fails harmlessly (logged "Metrics server failed on port 9332") —
# do NOT treat that log line as a launch failure.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-lunarblock* only;
# reserved ports 22158/22159 (Core RPC/P2P) + 22178/22179 (lunarblock RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF lunarblock: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

IMPL="lunarblock"
BIN="$(command -v luajit || echo luajit)"
LB_MAIN="$HASHHOG_ROOT/lunarblock/src/main.lua"
BUILD_HINT="interpreted — needs luajit + lua-cjson; run: luajit lunarblock/src/main.lua"

CORE_RPC=22158
CORE_P2P=22159
IMPL_RPC=22178
IMPL_P2P=22179

IMPL_DATADIR="/tmp/walletdiff-lunarblock"
CORE_DATADIR="/tmp/walletdiff-lunarblock-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/.cookie")

LB_RPCUSER="lunarblock"
LB_RPCPASS="walletdiff-lb"

launch_impl() {
    export LUA_PATH="$HASHHOG_ROOT/lunarblock/src/?.lua;$HASHHOG_ROOT/lunarblock/src/?/init.lua;;"
    export LUA_CPATH="${LUA_CPATH:-$HOME/.local/lib/lua/5.1/?.so;;}"
    # lunarblock does not write a cookie; supply one the shared driver can read.
    printf '%s:%s' "$LB_RPCUSER" "$LB_RPCPASS" > "$IMPL_DATADIR/.cookie"
    ( cd "$HASHHOG_ROOT/lunarblock" && \
      "$BIN" src/main.lua --network regtest --datadir "$IMPL_DATADIR" \
        --port "$IMPL_P2P" --rpcport "$IMPL_RPC" \
        --rpcuser "$LB_RPCUSER" --rpcpassword "$LB_RPCPASS" \
        --nov2transport ) \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_address_main

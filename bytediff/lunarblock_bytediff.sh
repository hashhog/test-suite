#!/usr/bin/env bash
#
# lunarblock_bytediff.sh — byte-exact RPC differential arm for lunarblock.
#
# Thin per-impl arm (see rustoshi_bytediff.sh for the contract). Per-impl
# divergence is ONLY the launch command + RPC-auth mode. All diff/mask logic
# lives in bytediff_lib.sh.
#
# AUTH (the lunarblock divergence): lunarblock does NOT use a cookie file. Its
# RPC server (src/rpc.lua RPCServer:new + the auth gate at the dispatch site)
# uses HTTP Basic auth ONLY when a password is configured:
#     self.password = config.rpcpassword or ""
#     if self.password ~= "" and not M.check_auth(...) then -> 401
# i.e. with the default empty rpcpassword the auth check is SKIPPED entirely.
# The probe in the 2026-06-06 RPC sweep "couldn't reach" lunarblock because it
# assumed cookie auth (there is no .cookie). So this arm launches with the
# default empty password and sets IMPL_AUTH_MODE="none" — the lib then sends NO
# `-u` flag, matching lunarblock's no-auth posture. (DO NOT pass --rpcpassword:
# any non-empty value would flip the server INTO Basic-auth and 401 every call.)
#
# Touches ONLY /tmp/bd-lunarblock-* and ports 22760/22780 (lunarblock RPC/P2P) +
# 22762/22782 (Core RPC/P2P) + 22764/22784 (2nd Core, self-test only). All < 32768.
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

IMPL_NAME="lunarblock"
IMPL_AUTH_MODE="none"
IMPL_RPC=22760
IMPL_P2P=22780
CORE_RPC=22762
CORE_P2P=22782
CORE2_RPC=22764
CORE2_P2P=22784

source "$HASHHOG_ROOT/test-suite/bytediff/bytediff_lib.sh"

# lunarblock is interpreted Lua (LuaJIT) — no build step, no compiled binary. It
# is invoked as `luajit src/main.lua ...` from the repo root, and resolves its
# `require("lunarblock.*")` modules via LUA_PATH (mirrors start_testnet4.sh:17).
LUNAR_DIR="$HASHHOG_ROOT/lunarblock"

impl_launch() {
    command -v luajit >/dev/null 2>&1 || fail "luajit not found (lunarblock runs via 'luajit src/main.lua'; install LuaJIT)"
    [[ -f "$LUNAR_DIR/src/main.lua" ]] || fail "lunarblock entrypoint not found at $LUNAR_DIR/src/main.lua"
    log "launching lunarblock (regtest) rpc=:$IMPL_RPC p2p=:$IMPL_P2P -> $IMPL_LOG"
    # Module resolution: LUA_PATH must point at lunarblock/src (start_testnet4.sh:17).
    export LUA_PATH="$LUNAR_DIR/src/?.lua;$LUNAR_DIR/src/?/init.lua;;"
    # Launch posture for an isolated, submitblock-fed regtest node:
    #   --network regtest      datadir becomes <datadir>/regtest (main.lua:419-421);
    #                          regtest genesis matches Core (consensus.lua:1218).
    #   --maxpeers 0           forces max_outbound=0 (main.lua:1410) so the node
    #                          never dials out — the chain is fed via submitblock.
    #   --metricsport 0        disables the Prometheus server, which otherwise
    #                          binds 0.0.0.0:9332 (main.lua:2393-2401) and would
    #                          collide with a sibling arm + draw a sandbox SIGKILL.
    #   --nov2transport        match the fleet launcher (start_testnet4.sh:129);
    #                          isolated node, transport version is immaterial.
    #   --printtoconsole       route logs to the redirected stdout/stderr ($IMPL_LOG)
    #                          instead of a datadir debug.log file.
    #   NO --rpcpassword       leave the default empty password -> RPC auth disabled
    #                          (see header). NO --daemon: foreground so $! is the
    #                          real node PID for rule-10 PID-scoped teardown.
    # NOTE: the inbound P2P listener still binds 0.0.0.0:$IMPL_P2P unconditionally
    # (main.lua:2439) — lunarblock has no --nolisten flag — but its failure is
    # non-fatal (main.lua:2442 logs a WARNING and continues), so even if the
    # sandbox refuses the bind the RPC server (loopback) still comes up.
    ( cd "$LUNAR_DIR" && exec luajit src/main.lua \
        --network regtest --datadir "$IMPL_DATADIR" \
        --rpcport "$IMPL_RPC" --port "$IMPL_P2P" \
        --maxpeers 0 --metricsport 0 --nov2transport --printtoconsole ) \
        >"$IMPL_LOG" 2>&1 &
    IMPL_PID=$!
    log "lunarblock pid=$IMPL_PID"
}

bd_run

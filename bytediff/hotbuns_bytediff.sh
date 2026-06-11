#!/usr/bin/env bash
#
# hotbuns_bytediff.sh — byte-exact RPC differential arm for hotbuns.
#
# Thin per-impl arm (see rustoshi_bytediff.sh for the contract). Per-impl
# divergence is ONLY the launch command + RPC-auth mode (cookie). All diff/mask
# logic lives in bytediff_lib.sh.
#
# hotbuns is TypeScript/Bun. It is launched by running the SOURCE directly via
# `bun run src/index.ts` (NOT `node src/index.js`, which is a stale compiled
# bundle) so that .ts edits are exercised by the byte-diff without a rebuild.
#
# Touches ONLY /tmp/bd-hotbuns-* and ports 22670/22690 (hotbuns RPC/P2P) +
# 22672/22692 (Core RPC/P2P) + 22674/22694 (2nd Core, self-test only). All < 32768.
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

IMPL_NAME="hotbuns"
IMPL_AUTH_MODE="cookie"
IMPL_RPC=22670
IMPL_P2P=22690
CORE_RPC=22672
CORE_P2P=22692
CORE2_RPC=22674
CORE2_P2P=22694

source "$HASHHOG_ROOT/test-suite/bytediff/bytediff_lib.sh"

# hotbuns is run source-direct with Bun; the entrypoint is src/index.ts.
HOTBUNS_DIR="$HASHHOG_ROOT/hotbuns"
BUN_BIN="$(command -v bun || echo "$HOME/.bun/bin/bun")"
# hotbuns writes its cookie directly under <datadir>/.cookie (no network subdir;
# rpc/server.ts: path.join(this.config.datadir, ".cookie")). Cover the network
# subdir form too in case that changes.
IMPL_COOKIE_PATHS="$IMPL_DATADIR/.cookie $IMPL_DATADIR/regtest/.cookie"

impl_launch() {
    [[ -x "$BUN_BIN" ]] || fail "bun not found (need ~/.bun/bin/bun on PATH); cannot run hotbuns source"
    [[ -f "$HOTBUNS_DIR/src/index.ts" ]] || fail "hotbuns entrypoint not found at $HOTBUNS_DIR/src/index.ts"
    log "launching hotbuns (regtest, bun run src/index.ts) rpc=:$IMPL_RPC p2p=:$IMPL_P2P -> $IMPL_LOG"
    # RPC binds 127.0.0.1 internally (rpc/server.ts host hard-coded loopback).
    # --listen=0 disables the inbound P2P TCP listener (manager.ts binds 0.0.0.0
    # only when listen is on), keeping the arm off any non-loopback socket the
    # sandbox would SIGKILL. The chain is fed via submitblock, so no inbound
    # P2P is needed. cwd = hotbuns dir so `bun run src/index.ts` resolves.
    ( cd "$HOTBUNS_DIR" && exec "$BUN_BIN" run src/index.ts \
        --network=regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcport="$IMPL_RPC" --listen=0 ) >"$IMPL_LOG" 2>&1 &
    IMPL_PID=$!
    log "hotbuns pid=$IMPL_PID"
}

bd_run

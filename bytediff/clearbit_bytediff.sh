#!/usr/bin/env bash
#
# clearbit_bytediff.sh — byte-exact RPC differential arm for clearbit.
#
# Thin per-impl arm (see rustoshi_bytediff.sh for the contract). Per-impl
# divergence is ONLY the launch command + RPC-auth mode (cookie). All diff/mask
# logic lives in bytediff_lib.sh.
#
# Touches ONLY /tmp/bd-clearbit-* and ports 22650/22670 (clearbit RPC/P2P) +
# 22652/22672 (Core RPC/P2P) + 22654/22674 (2nd Core, self-test only). All < 32768.
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

IMPL_NAME="clearbit"
IMPL_AUTH_MODE="cookie"
IMPL_RPC=22650
IMPL_P2P=22670
CORE_RPC=22652
CORE_P2P=22672
CORE2_RPC=22654
CORE2_P2P=22674

source "$HASHHOG_ROOT/test-suite/bytediff/bytediff_lib.sh"

NODE_BIN="$HASHHOG_ROOT/clearbit/zig-out/bin/clearbit"
# clearbit writes its cookie under <datadir>/regtest/.cookie.
IMPL_COOKIE_PATHS="$IMPL_DATADIR/regtest/.cookie $IMPL_DATADIR/.cookie"

impl_launch() {
    [[ -x "$NODE_BIN" ]] || fail "clearbit binary not found at $NODE_BIN (zig build -Doptimize=ReleaseFast)"
    log "launching clearbit (regtest) rpc=:$IMPL_RPC p2p=:$IMPL_P2P -> $IMPL_LOG"
    "$NODE_BIN" --regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcport="$IMPL_RPC" >"$IMPL_LOG" 2>&1 &
    IMPL_PID=$!
    log "clearbit pid=$IMPL_PID"
}

bd_run

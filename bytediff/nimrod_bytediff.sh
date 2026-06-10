#!/usr/bin/env bash
#
# nimrod_bytediff.sh — byte-exact RPC differential arm for nimrod.
#
# Thin per-impl arm (see rustoshi_bytediff.sh for the contract). Per-impl
# divergence is ONLY the launch command + RPC-auth mode (cookie). All diff/mask
# logic lives in bytediff_lib.sh.
#
# Touches ONLY /tmp/bd-nimrod-* and ports 22640/22660 (nimrod RPC/P2P) +
# 22642/22662 (Core RPC/P2P) + 22644/22664 (2nd Core, self-test only). All < 32768.
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

IMPL_NAME="nimrod"
IMPL_AUTH_MODE="cookie"
IMPL_RPC=22640
IMPL_P2P=22660
CORE_RPC=22642
CORE_P2P=22662
CORE2_RPC=22644
CORE2_P2P=22664

source "$HASHHOG_ROOT/test-suite/bytediff/bytediff_lib.sh"

NODE_BIN="$HASHHOG_ROOT/nimrod/bin/nimrod"
# nimrod writes its cookie under <datadir>/regtest/.cookie.
IMPL_COOKIE_PATHS="$IMPL_DATADIR/regtest/.cookie $IMPL_DATADIR/.cookie"

impl_launch() {
    [[ -x "$NODE_BIN" ]] || fail "nimrod binary not found at $NODE_BIN (nimble build -d:release)"
    log "launching nimrod (regtest) rpc=:$IMPL_RPC p2p=:$IMPL_P2P -> $IMPL_LOG"
    "$NODE_BIN" --network=regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcport="$IMPL_RPC" start >"$IMPL_LOG" 2>&1 &
    IMPL_PID=$!
    log "nimrod pid=$IMPL_PID"
}

bd_run

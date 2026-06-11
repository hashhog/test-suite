#!/usr/bin/env bash
#
# blockbrew_bytediff.sh — byte-exact RPC differential arm for blockbrew.
#
# Thin per-impl arm (see rustoshi_bytediff.sh for the contract). Per-impl
# divergence is ONLY the launch command + RPC-auth mode (cookie). All diff/mask
# logic lives in bytediff_lib.sh.
#
# Touches ONLY /tmp/bd-blockbrew-* and ports 22660/22680 (blockbrew RPC/P2P) +
# 22662/22682 (Core RPC/P2P) + 22664/22684 (2nd Core, self-test only). All < 32768.
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

IMPL_NAME="blockbrew"
IMPL_AUTH_MODE="cookie"
IMPL_RPC=22660
IMPL_P2P=22680
CORE_RPC=22662
CORE_P2P=22682
CORE2_RPC=22664
CORE2_P2P=22684

source "$HASHHOG_ROOT/test-suite/bytediff/bytediff_lib.sh"

NODE_BIN="$HASHHOG_ROOT/blockbrew/blockbrew"
# blockbrew writes its cookie under <datadir>/<network>/.cookie (it appends the
# network name to -datadir for non-mainnet networks), i.e. <datadir>/regtest/.cookie.
IMPL_COOKIE_PATHS="$IMPL_DATADIR/regtest/.cookie $IMPL_DATADIR/.cookie"

impl_launch() {
    [[ -x "$NODE_BIN" ]] || fail "blockbrew binary not found at $NODE_BIN (cd blockbrew && go build -o blockbrew ./cmd/blockbrew)"
    log "launching blockbrew (regtest) rpc=:$IMPL_RPC p2p=:$IMPL_P2P -> $IMPL_LOG"
    # -rpcpassword unset => cookie auth (matches Core). P2P bound to loopback so
    # the sandbox does not SIGKILL a 0.0.0.0 listener. -metricsport=0 keeps the
    # arm from binding a stray Prometheus port. -dnsseed off / no -connect: an
    # isolated regtest node never reaches out, the chain is fed via submitblock.
    "$NODE_BIN" -network=regtest -datadir="$IMPL_DATADIR" \
        -listen=127.0.0.1:"$IMPL_P2P" -rpcbind=127.0.0.1:"$IMPL_RPC" \
        -metricsport=0 -nodnsseed -fixedseeds=0 >"$IMPL_LOG" 2>&1 &
    IMPL_PID=$!
    log "blockbrew pid=$IMPL_PID"
}

bd_run

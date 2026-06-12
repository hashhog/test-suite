#!/usr/bin/env bash
#
# beamchain_bytediff.sh — byte-exact RPC differential arm for beamchain.
#
# Thin per-impl arm (see rustoshi_bytediff.sh for the contract). Per-impl
# divergence is ONLY the launch command + RPC-auth mode (cookie). All diff/mask
# logic lives in bytediff_lib.sh.
#
# Touches ONLY /tmp/bd-beamchain-* and ports 22800/22820 (beamchain RPC/P2P) +
# 22802/22822 (Core RPC/P2P) + 22804/22824 (2nd Core, self-test only). All < 32768.
# Distinct from every other arm's port block (haskoin's 22770/22790 block is the
# nearest neighbour; arms run SEQUENTIALLY so reuse would be safe, but a clean
# 22800 block keeps a concurrent stray run unambiguous).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

IMPL_NAME="beamchain"
IMPL_AUTH_MODE="cookie"
IMPL_RPC=22800
IMPL_P2P=22820
CORE_RPC=22802
CORE_P2P=22822
CORE2_RPC=22804
CORE2_P2P=22824

source "$HASHHOG_ROOT/test-suite/bytediff/bytediff_lib.sh"

# beamchain is an Erlang/OTP escript. It APPENDS the network name to the datadir
# (verified live: --datadir=/tmp/X --network=regtest writes under /tmp/X/regtest),
# and setup_auth (beamchain_rpc.erl:557) writes the cookie to <datadir>/.cookie.
# So the cookie lands at <datadir>/regtest/.cookie. The file content is
# "__cookie__:<hex>" (rpc:579), which is exactly Core's cookie format, so the
# lib's `curl -u <file-contents>` accepts it verbatim. We list the regtest subdir
# FIRST since that is where it actually appears.
NODE_BIN="$HASHHOG_ROOT/beamchain/_build/default/bin/beamchain"
IMPL_COOKIE_PATHS="$IMPL_DATADIR/regtest/.cookie $IMPL_DATADIR/.cookie"

impl_launch() {
    [[ -x "$NODE_BIN" ]] || fail "beamchain escript not found at $NODE_BIN (cd beamchain && rebar3 escriptize)"
    command -v escript >/dev/null 2>&1 || fail "escript not found (Erlang/OTP runtime missing)"
    log "launching beamchain (regtest) rpc=:$IMPL_RPC p2p=:$IMPL_P2P -> $IMPL_LOG"
    # `start` (foreground; NO --daemon) runs do_start_node in-process so $! is the
    # real escript/beam PID for rule-10 PID-scoped teardown. Global flags follow
    # the start_mainnet.sh / start_testnet4.sh arg shape (--network=, --datadir=,
    # --rpc-port=, --p2p-port=).
    #   --nodnsseed : an isolated regtest node never reaches out; the chain is fed
    #                 exclusively via submitblock. (--nofixedseeds is deliberately
    #                 NOT passed: the pinned escript predates that flag and rejects
    #                 it with "unknown option" — and a regtest node has no fixed
    #                 seeds to fall back to anyway.)
    # ERL_FLAGS pins the metrics_port off the default 9332 (which collides with a
    # sibling arm / a stray live node's Prometheus listener), mirroring
    # start_mainnet.sh's `-beamchain metrics_port`. 0 disables the listener.
    ERL_FLAGS="-beamchain metrics_port 0" \
        "$NODE_BIN" start \
            --network=regtest --datadir="$IMPL_DATADIR" \
            --rpc-port="$IMPL_RPC" --p2p-port="$IMPL_P2P" \
            --nodnsseed >"$IMPL_LOG" 2>&1 &
    IMPL_PID=$!
    log "beamchain pid=$IMPL_PID"
}

bd_run

#!/usr/bin/env bash
#
# camlcoin_bytediff.sh — byte-exact RPC differential arm for camlcoin.
#
# Thin per-impl arm (see rustoshi_bytediff.sh for the contract). Per-impl
# divergence is ONLY the launch command + RPC-auth mode (cookie). All diff/mask
# logic lives in bytediff_lib.sh.
#
# Touches ONLY /tmp/bd-camlcoin-* and ports 22730/22750 (camlcoin RPC/P2P) +
# 22732/22752 (Core RPC/P2P) + 22734/22754 (2nd Core, self-test only). All < 32768.
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

IMPL_NAME="camlcoin"
IMPL_AUTH_MODE="cookie"
IMPL_RPC=22730
IMPL_P2P=22750
CORE_RPC=22732
CORE_P2P=22752
CORE2_RPC=22734
CORE2_P2P=22754

source "$HASHHOG_ROOT/test-suite/bytediff/bytediff_lib.sh"

NODE_BIN="$HASHHOG_ROOT/camlcoin/_build/default/bin/main.exe"
# camlcoin (OCaml) writes its cookie to <data_dir>/.cookie directly — the datadir
# passed on the CLI is used verbatim, NO regtest subdir is appended
# (lib/cli.ml:1175: cookie_path = Filename.concat config.data_dir ".cookie"). The
# content is "__cookie__:<hex>", which curl -u accepts verbatim.
IMPL_COOKIE_PATHS="$IMPL_DATADIR/.cookie $IMPL_DATADIR/regtest/.cookie"

impl_launch() {
    [[ -x "$NODE_BIN" ]] || fail "camlcoin binary not found at $NODE_BIN (cd camlcoin && dune build)"
    log "launching camlcoin (regtest) rpc=:$IMPL_RPC p2p=:$IMPL_P2P -> $IMPL_LOG"
    # camlcoin is invoked directly (no subcommand) with global flags. Mirrors the
    # camlcoin_v2interop.sh / start_mainnet.sh arg shape:
    #   --metricsport 0   disables the Prometheus listener, which otherwise binds a
    #                     FIXED port (9332, main.ml:131) that would collide with a
    #                     concurrent sibling arm or a prior run.
    #   --printtoconsole=true  routes logs to the redirected stdout/stderr ($IMPL_LOG).
    # No --connect / --nodnsseed: an isolated regtest node never reaches out and the
    # chain is fed exclusively via submitblock. Foreground (no daemon) so $! is the
    # real node PID for rule-10 PID-scoped teardown.
    "$NODE_BIN" --network regtest --datadir "$IMPL_DATADIR" \
        --rpcport "$IMPL_RPC" --port "$IMPL_P2P" \
        --metricsport 0 --printtoconsole=true >"$IMPL_LOG" 2>&1 &
    IMPL_PID=$!
    log "camlcoin pid=$IMPL_PID"
}

bd_run

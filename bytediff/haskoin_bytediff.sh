#!/usr/bin/env bash
#
# haskoin_bytediff.sh — byte-exact RPC differential arm for haskoin.
#
# Thin per-impl arm (see rustoshi_bytediff.sh / clearbit_bytediff.sh for the
# contract). Per-impl divergence is ONLY the launch command + RPC-auth mode
# (cookie). All diff/mask logic lives in bytediff_lib.sh.
#
# haskoin is the Haskell node. It is launched on regtest as:
#     <bin> --network Regtest --datadir <dir> node --rpcport <r> --port <p>
# (arg shape mirrors tools/start_mainnet.sh's haskoin stanza and the
# test-suite/v2interop/haskoin_v2interop.sh launcher). The binary lives under
# dist-newstyle (cabal); discovered with `find ... -name haskoin -type f
# -executable` so the ghc-version path component is not hard-coded.
#
# haskoin appends the network name to the datadir (app/Main.hs:426
# networkDir = dataDir </> netName net, netName Regtest = "regtest") and writes
# its cookie to <networkDir>/.cookie (Rpc.hs:800 rpcDataDir </> ".cookie"), i.e.
# <datadir>/regtest/.cookie. We list that first, with the bare <datadir>/.cookie
# as a fallback.
#
# Touches ONLY /tmp/bd-haskoin-* and ports 22770/22790 (haskoin RPC/P2P) +
# 22772/22792 (Core RPC/P2P) + 22774/22794 (2nd Core, self-test only). All
# < 32768 and DISTINCT from every other arm (highest existing quad is
# lunarblock's 2276x/2278x). NEVER touches /data/nvme1/ or testnet4-data/ or any
# live node. test-suite is PUBLIC -> no private absolute paths baked in.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

IMPL_NAME="haskoin"
IMPL_AUTH_MODE="cookie"
IMPL_RPC=22770
IMPL_P2P=22790
CORE_RPC=22772
CORE_P2P=22792
CORE2_RPC=22774
CORE2_P2P=22794

source "$HASHHOG_ROOT/test-suite/bytediff/bytediff_lib.sh"

# haskoin's cabal build artifact (ghc-version path component is not hard-coded).
NODE_BIN="$(find "$HASHHOG_ROOT/haskoin/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"
# Cookie under <datadir>/regtest/.cookie (network subdir appended), bare as fallback.
IMPL_COOKIE_PATHS="$IMPL_DATADIR/regtest/.cookie $IMPL_DATADIR/.cookie"

impl_launch() {
    [[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] \
        || fail "haskoin binary not found under dist-newstyle (cabal build; find -name haskoin -type f -executable)"
    log "launching haskoin (regtest) rpc=:$IMPL_RPC p2p=:$IMPL_P2P -> $IMPL_LOG"
    # Global opts (--network/--datadir) BEFORE the `node` subcommand, mirroring
    # start_mainnet.sh + haskoin_v2interop.sh. No --connect/--addnode: this is an
    # isolated regtest node fed entirely via submitblock (never real P2P), so the
    # sandbox does not SIGKILL a 0.0.0.0 listener. Foreground (no daemon) so $!
    # is the real node PID for rule-10 PID-scoped teardown.
    "$NODE_BIN" --network Regtest --datadir "$IMPL_DATADIR" \
        node --rpcport "$IMPL_RPC" --port "$IMPL_P2P" >"$IMPL_LOG" 2>&1 &
    IMPL_PID=$!
    log "haskoin pid=$IMPL_PID"
}

bd_run

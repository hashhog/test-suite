#!/usr/bin/env bash
#
# ouroboros_bytediff.sh — byte-exact RPC differential arm for ouroboros.
#
# Thin per-impl arm (see rustoshi_bytediff.sh for the contract). Per-impl
# divergence is ONLY the launch command + RPC-auth mode (cookie). All diff/mask
# logic lives in bytediff_lib.sh.
#
# Touches ONLY /tmp/bd-ouroboros-* and ports 22700/22720 (ouroboros RPC/P2P) +
# 22702/22722 (Core RPC/P2P) + 22704/22724 (2nd Core, self-test only). All < 32768.
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

IMPL_NAME="ouroboros"
IMPL_AUTH_MODE="cookie"
IMPL_RPC=22700
IMPL_P2P=22720
CORE_RPC=22702
CORE_P2P=22722
CORE2_RPC=22704
CORE2_P2P=22724

source "$HASHHOG_ROOT/test-suite/bytediff/bytediff_lib.sh"

# ouroboros runs from source via `python3 -m ouroboros.cli` (editable install;
# no compiled binary). It writes its cookie to <data_dir>/.cookie directly — the
# data_dir passed on the CLI is used verbatim, no network subdir is appended
# (src/ouroboros/cookie_auth.py: cookie_path = Path(data_dir)/".cookie").
IMPL_COOKIE_PATHS="$IMPL_DATADIR/.cookie $IMPL_DATADIR/regtest/.cookie"

impl_launch() {
    command -v python3 >/dev/null 2>&1 || fail "python3 not found (ouroboros runs via python3 -m ouroboros.cli)"
    python3 -c 'import ouroboros' 2>/dev/null \
        || fail "ouroboros package not importable (editable install missing: pip install -e ouroboros)"
    log "launching ouroboros (regtest) rpc=:$IMPL_RPC p2p=:$IMPL_P2P -> $IMPL_LOG"
    # Global opts (--network/--data-dir) BEFORE the `start` subcommand, mirroring
    # start_testnet4.sh / start_mainnet.sh. --nolisten binds P2P to loopback so
    # the sandbox does not SIGKILL a 0.0.0.0 listener (the chain is fed via
    # submitblock, never real P2P). --nodnsseed: an isolated regtest node never
    # reaches out. --force skips the sync-check prompt. Foreground (no --daemon)
    # so $! is the real node PID for rule-10 PID-scoped teardown.
    python3 -m ouroboros.cli \
        --network regtest --data-dir "$IMPL_DATADIR" \
        start --force --nolisten --nodnsseed \
        --rpc-port "$IMPL_RPC" --p2p-port "$IMPL_P2P" >"$IMPL_LOG" 2>&1 &
    IMPL_PID=$!
    log "ouroboros pid=$IMPL_PID"
}

bd_run

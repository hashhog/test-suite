#!/usr/bin/env bash
#
# rustoshi_bytediff.sh — byte-exact RPC differential arm for rustoshi.
#
# Thin per-impl arm: set identity/ports/auth, define impl_launch(), call bd_run.
# ALL load-bearing logic (boot/mirror/sign, rule-10 teardown, THE DIFF ENGINE,
# the method×params manifest + per-method masks) lives in bytediff_lib.sh.
#
# rustoshi is the most Core-faithful impl, so it is the reference arm. Per-impl
# divergence here is ONLY the launch command + RPC-auth mode (cookie).
#
# Touches ONLY /tmp/bd-rustoshi-* and ports 22610/22630 (rustoshi RPC/P2P) +
# 22612/22632 (Core RPC/P2P) + 22614/22634 (2nd Core, self-test only). All < 32768.
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Impl identity (BEFORE sourcing the lib). ──────────────────────────────
IMPL_NAME="rustoshi"
IMPL_AUTH_MODE="cookie"
IMPL_RPC=22610
IMPL_P2P=22630
CORE_RPC=22612
CORE_P2P=22632
CORE2_RPC=22614
CORE2_P2P=22634

source "$HASHHOG_ROOT/test-suite/bytediff/bytediff_lib.sh"

NODE_BIN="$HASHHOG_ROOT/rustoshi/target/release/rustoshi"
IMPL_COOKIE_PATHS="$IMPL_DATADIR/.cookie $IMPL_DATADIR/regtest/.cookie"

# impl_launch — background the node, set IMPL_PID. (Skipped in BD_SELFTEST=1.)
impl_launch() {
    [[ -x "$NODE_BIN" ]] || fail "rustoshi binary not found at $NODE_BIN (cargo build --release)"
    log "launching rustoshi (regtest) rpc=:$IMPL_RPC p2p=:$IMPL_P2P -> $IMPL_LOG"
    "$NODE_BIN" --network=regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcbind="127.0.0.1:$IMPL_RPC" >"$IMPL_LOG" 2>&1 &
    IMPL_PID=$!
    log "rustoshi pid=$IMPL_PID"
}

bd_run

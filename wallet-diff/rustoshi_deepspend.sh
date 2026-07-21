#!/usr/bin/env bash
#
# rustoshi_deepspend.sh — walletdiff SLICE 5 (DEEP spend surface: multi-input
# taproot, mixed p2wpkh+p2tr, non-default sighash, external-input prevtxs gap)
# for rustoshi, differential against a REAL wallet-enabled bitcoind regtest
# oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparison logic lives
# in wallet-diff/probe_deepspend.py. This script just launches rustoshi + the
# Core oracle and hands both to the shared driver in wallet-diff/_deepspend_lib.sh.
#
# Interface: no args; idempotent; scratch /tmp/walletdeep-rustoshi* only;
# reserved ports 22194/22195 (Core RPC/P2P) + 22196/22197 (rustoshi RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF rustoshi: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_deepspend_lib.sh"

IMPL="rustoshi"
BIN="$HASHHOG_ROOT/rustoshi/target/release/rustoshi"
BUILD_HINT="build with: cargo build --release"

CORE_RPC=22194
CORE_P2P=22195
IMPL_RPC=22196
IMPL_P2P=22197

IMPL_DATADIR="/tmp/walletdeep-rustoshi"
CORE_DATADIR="/tmp/walletdeep-rustoshi-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/.cookie" "$IMPL_DATADIR/regtest/.cookie")

launch_impl() {
    "$BIN" --network=regtest --datadir="$IMPL_DATADIR" \
        --port="$IMPL_P2P" --rpcbind="127.0.0.1:$IMPL_RPC" \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_deepspend_main

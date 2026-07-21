#!/usr/bin/env bash
#
# rustoshi_restore.sh — wallet BACKUP->DESTROY->RESTORE->SPEND drill (P2.3) for
# rustoshi. Plumbing ONLY: all assertions live in wallet-diff/_restore_lib.sh.
#
# rustoshi loads exactly ONE wallet at a time and does NOT wire /wallet/<name>
# URL routing, so every wallet + node call goes to "/". Restore mechanism is the
# HD master seed via sethdseed(true, <64-byte hex seed>) — documented Core
# divergence (Core takes a WIF); proven spendable by spend/rustoshi_spend.sh.
#
# Idempotent; scratch /tmp/walletdiff-restore-rustoshi-* only; reserved ports
# 22180/22181 (rustoshi) + 22182/22183 (Core oracle). ONE summary line on stdout;
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/, testnet4-data/,
# or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_restore_lib.sh"

IMPL="rustoshi"
BIN="$HASHHOG_ROOT/rustoshi/target/release/rustoshi"
BUILD_HINT="build with: cargo build --release"

# 64-byte (128 hex char) master seed — same constant as recovery/ + spend/ cells.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"

IMPL_RPC=22180; IMPL_P2P=22181
CORE_RPC=22182; CORE_P2P=22183

DATADIR_ORIG="/tmp/walletdiff-restore-rustoshi-orig"
DATADIR_RESTORE="/tmp/walletdiff-restore-rustoshi-new"
CORE_DATADIR="/tmp/walletdiff-restore-rustoshi-core"

adapter_launch() {
    local dd="$1"
    "$BIN" --network=regtest --datadir="$dd" \
        --port="$IMPL_P2P" --rpcbind="127.0.0.1:$IMPL_RPC" \
        >"$dd/node.log" 2>&1 &
    IMPL_PID=$!
}
adapter_cookie_candidates() { local dd="$1"; echo "$dd/.cookie" "$dd/regtest/.cookie"; }
adapter_wpath() { echo ""; }
adapter_create_and_seed() {
    local o e
    o=$(rpc "" createwallet '["w1"]')
    e=$(echo "$o" | rpc_errmsg)
    if [[ -n "$e" ]]; then log "createwallet w1: $e"; return 1; fi
    o=$(rpc "" sethdseed "[true,\"$SEED\"]")
    e=$(echo "$o" | rpc_errmsg)
    if [[ -n "$e" ]]; then log "sethdseed: $e"; return 1; fi
    return 0
}

walletdiff_restore_main

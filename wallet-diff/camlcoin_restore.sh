#!/usr/bin/env bash
#
# camlcoin_restore.sh — wallet BACKUP->DESTROY->RESTORE->SPEND drill (P2.3) for
# camlcoin (OCaml). Plumbing ONLY: all assertions live in
# wallet-diff/_restore_lib.sh.
#
# camlcoin routes wallet calls under /wallet/<name> and base "/" -> default
# wallet (lib/rpc.ml:14056). createwallet(name) generates a random seed, so it
# is NOT a deterministic restore channel by itself; the spendable seed-backup
# channel is the HD master seed via `sethdseed(newkeypool, <hex seed>)`. camlcoin
# accepts a RAW 16..64-byte hex seed directly (handle_sethdseed, lib/rpc.ml:2994),
# Core-compatible arg order (newkeypool, seed) — same shape as rustoshi/nimrod.
# Documented divergence from Core's WIF-blob sethdseed.
#
# adapter_create_and_seed therefore does createwallet "w1" + sethdseed(SEED) on
# the base URL (single loaded wallet per phase), giving byte-identical addresses
# across the destroy (the drill's hard requirement).
#
# Idempotent; scratch /tmp/walletdiff-restore-camlcoin-* only; reserved ports
# 22190/22191 (camlcoin) + 22198/22199 (Core oracle). ONE summary line on stdout;
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/, testnet4-data/,
# or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_restore_lib.sh"

IMPL="camlcoin"
BIN="$HASHHOG_ROOT/camlcoin/_build/default/bin/main.exe"
BUILD_HINT="build with: ./build-all.sh camlcoin"

# 64-byte (128 hex char) master seed — same constant as rustoshi/nimrod restore.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"

IMPL_RPC=22190; IMPL_P2P=22191
CORE_RPC=22198; CORE_P2P=22199

DATADIR_ORIG="/tmp/walletdiff-restore-camlcoin-orig"
DATADIR_RESTORE="/tmp/walletdiff-restore-camlcoin-new"
CORE_DATADIR="/tmp/walletdiff-restore-camlcoin-core"

adapter_launch() {
    local dd="$1"
    "$BIN" --network regtest --datadir "$dd" \
        --port "$IMPL_P2P" --rpcport "$IMPL_RPC" \
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

#!/usr/bin/env bash
#
# ouroboros_restore.sh — wallet BACKUP->DESTROY->RESTORE->SPEND drill (P2.3) for
# ouroboros. Plumbing ONLY: all assertions live in wallet-diff/_restore_lib.sh.
#
# ouroboros is multi-wallet and DOES wire /wallet/<name> URL routing, so wallet
# calls go to /wallet/w1 while node calls go to "/". createwallet takes just the
# name ([ "w1" ]); descriptors=true is the default. Restore mechanism is the HD
# master seed via `sethdseed(<hex seed>)` — NOTE the ouroboros dialect takes a
# SINGLE positional seed-hex arg (rpc.py rpc_sethdseed(seed_hex)), NOT Core's
# two-arg [newkeypool, seed]; the adapter calls it single-arg accordingly. The
# seed is a 64-byte hex blob (ouroboros accepts 16..64 bytes).
#
# ouroboros auto-creates+loads a "default" wallet at startup; because every
# wallet op here routes to the EXPLICIT /wallet/w1 path, that default wallet
# never introduces base-URL ambiguity.
#
# Launched as the Python CLI (no compiled binary); cookie at <dd>/.cookie.
#
# Idempotent; scratch /tmp/walletdiff-restore-ouroboros-* only; reserved ports
# 22186/22187 (ouroboros) + 22188/22189 (Core oracle). ONE summary line on stdout;
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/, testnet4-data/,
# or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_restore_lib.sh"

IMPL="ouroboros"
OURO_DIR="$HASHHOG_ROOT/ouroboros"
BIN="$(command -v python3 || echo python3)"
BUILD_HINT="python module ouroboros.cli (no build; reinstall Rust ext via tools/reinstall_ouroboros.sh only if import fails)"

# 64-byte (128 hex char) master seed — same constant as rustoshi restore cell.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"

IMPL_RPC=22186; IMPL_P2P=22187
CORE_RPC=22188; CORE_P2P=22189

DATADIR_ORIG="/tmp/walletdiff-restore-ouroboros-orig"
DATADIR_RESTORE="/tmp/walletdiff-restore-ouroboros-new"
CORE_DATADIR="/tmp/walletdiff-restore-ouroboros-core"

adapter_launch() {
    local dd="$1"
    ( cd "$OURO_DIR" && exec python3 -m ouroboros.cli \
        --network regtest --data-dir "$dd" \
        start --force --rpc-port "$IMPL_RPC" --p2p-port "$IMPL_P2P" \
        --nodnsseed --nolisten \
        >"$dd/node.log" 2>&1 ) &
    IMPL_PID=$!
}
adapter_cookie_candidates() { local dd="$1"; echo "$dd/.cookie" "$dd/regtest/.cookie"; }
adapter_wpath() { echo "/wallet/w1"; }
adapter_create_and_seed() {
    local o e
    o=$(rpc "" createwallet '["w1"]')
    e=$(echo "$o" | rpc_errmsg)
    if [[ -n "$e" ]]; then log "createwallet w1: $e"; return 1; fi
    # ouroboros sethdseed dialect: single positional seed-hex arg.
    o=$(rpc "/wallet/w1" sethdseed "[\"$SEED\"]")
    e=$(echo "$o" | rpc_errmsg)
    if [[ -n "$e" ]]; then log "sethdseed: $e"; return 1; fi
    return 0
}

walletdiff_restore_main

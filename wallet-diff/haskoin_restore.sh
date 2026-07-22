#!/usr/bin/env bash
#
# haskoin_restore.sh — wallet BACKUP->DESTROY->RESTORE->SPEND drill (P2.3) for
# haskoin (Haskell). Plumbing ONLY: all assertions live in
# wallet-diff/_restore_lib.sh.
#
# haskoin routes wallet calls under /wallet/<name>; node calls go to "/".
# haskoin has NO sethdseed. Its deterministic seed-backup channel is the BIP-39
# MNEMONIC via `restorewallet "name" "mnemonic"` (Rpc.hs:8065 handleRestoreWallet
# -> importMnemonic): restoring the SAME mnemonic deterministically reconstructs
# the identical keypool + addresses. This is the documented divergence from
# Core's WIF-based restore (and from rustoshi/nimrod which take a raw hex master
# seed via sethdseed — haskoin has none). Same shape as beamchain_restore.sh.
#
# adapter_create_and_seed therefore uses restorewallet with a FIXED mnemonic for
# BOTH the original and the restored wallet, giving byte-identical addresses
# across the destroy (the drill's hard requirement). SEED here is the mnemonic.
#
# The mnemonic is the canonical BIP-39 all-zero-entropy 12-word test vector
# (valid checksum: 11x "abandon" + "about").
#
# Launch shape: GLOBAL --datadir/--network BEFORE the `node` subcommand; node
# options after. Cookie at <datadir>/regtest/.cookie. --metricsport/--healthport
# 0 to avoid busy-port noise.
#
# Idempotent; scratch /tmp/walletdiff-restore-haskoin-* only; reserved ports
# 22186/22187 (haskoin) + 22188/22189 (Core oracle). ONE summary line on stdout;
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/, testnet4-data/,
# or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_restore_lib.sh"

IMPL="haskoin"
BIN="$(find "$HASHHOG_ROOT/haskoin/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"
BUILD_HINT="build with: cd haskoin && cabal build (rocksdb_compat shim: scripts/build-rocksdb-compat.sh)"

# Canonical BIP-39 all-zero-entropy test mnemonic (valid checksum).
SEED="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

IMPL_RPC=22186; IMPL_P2P=22187
CORE_RPC=22188; CORE_P2P=22189

DATADIR_ORIG="/tmp/walletdiff-restore-haskoin-orig"
DATADIR_RESTORE="/tmp/walletdiff-restore-haskoin-new"
CORE_DATADIR="/tmp/walletdiff-restore-haskoin-core"

adapter_launch() {
    local dd="$1"
    "$BIN" --datadir="$dd" --network Regtest \
        node --rpcport "$IMPL_RPC" --port "$IMPL_P2P" \
        --metricsport 0 --healthport 0 \
        >"$dd/node.log" 2>&1 &
    IMPL_PID=$!
}
adapter_cookie_candidates() { local dd="$1"; echo "$dd/regtest/.cookie" "$dd/.cookie"; }
adapter_wpath() { echo "/wallet/w1"; }
adapter_create_and_seed() {
    local o e
    # restorewallet deterministically creates + loads "w1" from the mnemonic.
    o=$(rpc "" restorewallet "[\"w1\",\"$SEED\"]")
    e=$(echo "$o" | rpc_errmsg)
    if [[ -n "$e" ]]; then log "restorewallet w1: $e"; return 1; fi
    return 0
}

walletdiff_restore_main

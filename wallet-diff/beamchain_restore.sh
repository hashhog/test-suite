#!/usr/bin/env bash
#
# beamchain_restore.sh — wallet BACKUP->DESTROY->RESTORE->SPEND drill (P2.3) for
# beamchain (Erlang escript). Plumbing ONLY: all assertions live in
# wallet-diff/_restore_lib.sh.
#
# beamchain routes wallet calls under /wallet/<name>; node calls go to "/".
# createwallet(name) generates a RANDOM seed, so it is NOT a deterministic
# restore channel. beamchain's spendable seed-backup channel is the BIP-39
# MNEMONIC via `restorewallet "name" "mnemonic"` (beamchain_rpc.erl:8927 ->
# beamchain_wallet_sup:restore_wallet/3): restoring the same mnemonic
# deterministically reconstructs the identical keypool + addresses. This is the
# documented divergence from Core's WIF-based restore (and from rustoshi/clearbit
# which take a raw hex master seed via sethdseed — beamchain has NO sethdseed).
#
# adapter_create_and_seed therefore uses restorewallet with a FIXED mnemonic for
# BOTH the original and the restored wallet, giving byte-identical addresses
# across the destroy (the drill's hard requirement). SEED here is the mnemonic.
#
# The mnemonic is the canonical BIP-39 all-zero-entropy 12-word test vector
# (valid checksum: 11x "abandon" + "about").
#
# Idempotent; scratch /tmp/walletdiff-restore-beamchain-* only; reserved ports
# 22188/22189 (beamchain) + 22186/22187 (Core oracle). ONE summary line on stdout;
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/, testnet4-data/,
# or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../..}"
HASHHOG_ROOT="$(cd "$HASHHOG_ROOT" && pwd)"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_restore_lib.sh"

IMPL="beamchain"
BIN="$HASHHOG_ROOT/beamchain/_build/default/bin/beamchain"
BUILD_HINT="build with: ./build-all.sh beamchain"

# Canonical BIP-39 all-zero-entropy test mnemonic (valid checksum).
SEED="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

IMPL_RPC=22188; IMPL_P2P=22189
CORE_RPC=22186; CORE_P2P=22187

DATADIR_ORIG="/tmp/walletdiff-restore-beamchain-orig"
DATADIR_RESTORE="/tmp/walletdiff-restore-beamchain-new"
CORE_DATADIR="/tmp/walletdiff-restore-beamchain-core"

adapter_launch() {
    local dd="$1"
    "$BIN" start --network=regtest --datadir="$dd" \
        --p2p-port="$IMPL_P2P" --rpc-port="$IMPL_RPC" \
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

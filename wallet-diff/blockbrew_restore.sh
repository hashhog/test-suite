#!/usr/bin/env bash
#
# blockbrew_restore.sh — wallet BACKUP->DESTROY->RESTORE->SPEND drill (P2.3) for
# blockbrew (Go). Plumbing ONLY: all assertions live in wallet-diff/_restore_lib.sh.
#
# blockbrew routes wallet-context RPCs under /wallet/<name> (server.go:467); node
# calls go to "/". Its spendable backup channel is NOT Core's sethdseed (blockbrew
# does not expose sethdseed) but the BIP-39 MNEMONIC supplied directly to
# createwallet's restore arg (arg index 9 — multiwallet_methods.go:88; a non-Core
# extension mirroring ouroboros). The same words always re-derive byte-identical
# keys+addresses (manager.go CreateFromMnemonic), so the drill restores by
# recreating w1 from the SAME fixed mnemonic on a fresh datadir. This is the
# spendable channel under test; the listdescriptors export channel is separately
# characterised + reported by the shared driver.
#
# Fixed restore identity: the canonical all-zeros BIP-39 test vector mnemonic
# (valid 12-word checksum). Deterministic => identical addresses across the
# destroy, which is exactly what the drill asserts.
#
# Idempotent; scratch /tmp/walletdiff-restore-blockbrew-* only; reserved ports
# 22186/22187 (blockbrew) + 22188/22189 (Core oracle). ONE summary line on stdout;
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/, testnet4-data/,
# or any live node. -metricsport=0 avoids the 9332 Prometheus bind race.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_restore_lib.sh"

IMPL="blockbrew"
BIN="$HASHHOG_ROOT/blockbrew/blockbrew"
BUILD_HINT="build with: go build -o blockbrew ./..."

# Canonical all-zeros-entropy BIP-39 mnemonic (valid checksum). blockbrew's
# spendable backup IS these words; restore = re-create w1 from them.
SEED="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

IMPL_RPC=22186; IMPL_P2P=22187
CORE_RPC=22188; CORE_P2P=22189

DATADIR_ORIG="/tmp/walletdiff-restore-blockbrew-orig"
DATADIR_RESTORE="/tmp/walletdiff-restore-blockbrew-new"
CORE_DATADIR="/tmp/walletdiff-restore-blockbrew-core"

adapter_launch() {
    local dd="$1"
    "$BIN" -network=regtest -datadir="$dd" \
        -listen=127.0.0.1:"$IMPL_P2P" -rpcbind=127.0.0.1:"$IMPL_RPC" \
        -metricsport=0 \
        >"$dd/node.log" 2>&1 &
    IMPL_PID=$!
}
adapter_cookie_candidates() { local dd="$1"; echo "$dd/regtest/.cookie" "$dd/.cookie"; }
adapter_wpath() { echo "/wallet/w1"; }
adapter_create_and_seed() {
    # createwallet(name, disable_private_keys, blank, passphrase, avoid_reuse,
    #   descriptors, load_on_startup, external_signer, seed_passphrase, mnemonic)
    # mnemonic at arg index 9 RESTORES deterministically from the fixed words.
    local params o e
    params=$(python3 -c 'import json,sys; print(json.dumps(["w1",False,False,"",False,True,False,"","",sys.argv[1]]))' "$SEED")
    o=$(rpc "" createwallet "$params")
    e=$(echo "$o" | rpc_errmsg)
    if [[ -n "$e" ]]; then log "createwallet w1 (mnemonic restore): $e"; return 1; fi
    return 0
}

walletdiff_restore_main

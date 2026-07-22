#!/usr/bin/env bash
#
# hotbuns_restore.sh — wallet BACKUP->DESTROY->RESTORE->SPEND drill (P2.3) for
# hotbuns (TypeScript/Bun). Plumbing ONLY: all assertions live in
# wallet-diff/_restore_lib.sh.
#
# BACKUP MECHANISM: hotbuns has no sethdseed. Its deterministic recovery channel
# is a BIP-39 MNEMONIC passed to createwallet — a hotbuns extension at param
# index 7: createwallet(name, disable_private_keys, blank, passphrase,
# avoid_reuse, descriptors, load_on_startup, MNEMONIC, mnemonic_passphrase)
# (src/rpc/server.ts createWallet). Supplying the SAME mnemonic on a fresh
# datadir re-derives the identical receive address and thus recovers the funds.
#
# hotbuns runs under Bun directly (no compiled binary); BIN points at `bun` and
# adapter_launch runs the TS entrypoint by absolute path. Its default command is
# "start". It writes a Core-style cookie (`__cookie__:<hex>`) to <datadir>/.cookie
# and routes wallet calls under /wallet/<name>. --metricsport=0 disables its
# Prometheus port (default 9332) to avoid a bind collision with the live node.
#
# Idempotent; scratch /tmp/walletdiff-restore-hotbuns-* only; reserved ports
# 22186/22187 (hotbuns) + 22188/22189 (Core oracle). ONE summary line on stdout;
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/, testnet4-data/,
# or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_restore_lib.sh"

IMPL="hotbuns"
BIN="$(command -v bun || echo "$HOME/.bun/bin/bun")"
HOTBUNS_ENTRY="$HASHHOG_ROOT/hotbuns/src/index.ts"
BUILD_HINT="interpreted — needs Bun; run: bun run hotbuns/src/index.ts"

# Fixed BIP-39 mnemonic — the deterministic seed backup under test.
SEED="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

IMPL_RPC=22186; IMPL_P2P=22187
CORE_RPC=22188; CORE_P2P=22189

DATADIR_ORIG="/tmp/walletdiff-restore-hotbuns-orig"
DATADIR_RESTORE="/tmp/walletdiff-restore-hotbuns-new"
CORE_DATADIR="/tmp/walletdiff-restore-hotbuns-core"

adapter_launch() {
    local dd="$1"
    "$BIN" run "$HOTBUNS_ENTRY" --network=regtest --datadir="$dd" \
        --port="$IMPL_P2P" --rpcport="$IMPL_RPC" --metricsport=0 \
        >"$dd/node.log" 2>&1 &
    IMPL_PID=$!
}
adapter_cookie_candidates() { local dd="$1"; echo "$dd/.cookie" "$dd/regtest/.cookie"; }
adapter_wpath() { echo "/wallet/w1"; }
adapter_create_and_seed() {
    # createwallet(name, disable_private_keys, blank, passphrase, avoid_reuse,
    #   descriptors, load_on_startup, mnemonic, mnemonic_passphrase)
    # mnemonic at arg index 7 RESTORES deterministically from the fixed words.
    local params o e
    params=$(python3 -c 'import json,sys; print(json.dumps(["w1",False,False,"",False,True,False,sys.argv[1]]))' "$SEED")
    o=$(rpc "" createwallet "$params")
    e=$(echo "$o" | rpc_errmsg)
    if [[ -n "$e" ]]; then log "createwallet w1 (mnemonic restore): $e"; return 1; fi
    return 0
}

walletdiff_restore_main

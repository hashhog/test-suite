#!/usr/bin/env bash
#
# nimrod_restore.sh — wallet BACKUP->DESTROY->RESTORE->SPEND drill (P2.3) for
# nimrod. Plumbing ONLY: all assertions live in wallet-diff/_restore_lib.sh.
#
# nimrod keeps exactly ONE active wallet and does NOT wire /wallet/<name> URL
# routing, so every wallet + node call goes to "/". Restore mechanism is the HD
# master seed via sethdseed(true, <hex seed>) — nimrod accepts a raw 16..64-byte
# hex seed (or a BIP-39 mnemonic) directly, Core-compatible arg order
# (newkeypool, seed). Documented divergence from Core's WIF-blob sethdseed.
#
# nimrod also tries to bind Prometheus port 9332 by default; we pass
# --metricsport=0 to disable it (avoids a busy-9332 warning on this box). nimrod
# needs the trailing `start` subcommand and writes its cookie to
# <datadir>/regtest/.cookie.
#
# Idempotent; scratch /tmp/walletdiff-restore-nimrod-* only; reserved ports
# 22186/22187 (nimrod) + 22188/22189 (Core oracle). ONE summary line on stdout;
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/, testnet4-data/,
# or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_restore_lib.sh"

IMPL="nimrod"
BIN="$HASHHOG_ROOT/nimrod/bin/nimrod"
BUILD_HINT="build with: nimble build -d:release -y"

# 64-byte (128 hex char) master seed — same constant as rustoshi restore cell.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"

IMPL_RPC=22186; IMPL_P2P=22187
CORE_RPC=22188; CORE_P2P=22189

DATADIR_ORIG="/tmp/walletdiff-restore-nimrod-orig"
DATADIR_RESTORE="/tmp/walletdiff-restore-nimrod-new"
CORE_DATADIR="/tmp/walletdiff-restore-nimrod-core"

adapter_launch() {
    local dd="$1"
    "$BIN" --regtest --datadir="$dd" \
        --port="$IMPL_P2P" --rpcport="$IMPL_RPC" --metricsport=0 start \
        >"$dd/node.log" 2>&1 &
    IMPL_PID=$!
}
adapter_cookie_candidates() { local dd="$1"; echo "$dd/regtest/.cookie" "$dd/.cookie"; }
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

#!/usr/bin/env bash
#
# clearbit_restore.sh — wallet BACKUP->DESTROY->RESTORE->SPEND drill (P2.3) for
# clearbit. Plumbing ONLY: all assertions live in wallet-diff/_restore_lib.sh.
#
# clearbit routes wallet calls under /wallet/<name>; node calls go to "/".
# createwallet takes [name, disable_private_keys=false, blank=true]. Restore
# mechanism is the HD master seed via sethdseed(true, <hex seed>) — documented
# divergence from Core's WIF; proven spendable by spend/clearbit_spend.sh.
#
# NOTE ON THE DESCRIPTOR CHANNEL: clearbit's importdescriptors is WATCH-ONLY
# (src/wallet.zig:1362 — imported descriptors are deliberately NOT spendable;
# coin selection + signing skip them). A descriptor-only restore would recover a
# watch-only balance that CANNOT be spent — a funds-loss trap. The spendable
# backup channel is therefore the SEED, which this drill exercises. The
# descriptor-export channel is characterised and reported by the shared driver.
#
# clearbit also tries to bind Prometheus port 9332 at startup; that bind fails
# harmlessly here (logged, node keeps running) — not a launch failure.
#
# Idempotent; scratch /tmp/walletdiff-restore-clearbit-* only; reserved ports
# 22184/22185 (clearbit) + 22192/22193 (Core oracle). ONE summary line on stdout;
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/, testnet4-data/,
# or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_restore_lib.sh"

IMPL="clearbit"
BIN="$HASHHOG_ROOT/clearbit/zig-out/bin/clearbit"
BUILD_HINT="build with: zig build -Doptimize=ReleaseFast"

# 16-byte (32 hex char) seed — same constant as spend/clearbit_spend.sh.
SEED="000102030405060708090a0b0c0d0e0f"

IMPL_RPC=22184; IMPL_P2P=22185
CORE_RPC=22192; CORE_P2P=22193

DATADIR_ORIG="/tmp/walletdiff-restore-clearbit-orig"
DATADIR_RESTORE="/tmp/walletdiff-restore-clearbit-new"
CORE_DATADIR="/tmp/walletdiff-restore-clearbit-core"

adapter_launch() {
    local dd="$1"
    "$BIN" --regtest --datadir="$dd" \
        --port="$IMPL_P2P" --rpcport="$IMPL_RPC" \
        >"$dd/node.log" 2>&1 &
    IMPL_PID=$!
}
adapter_cookie_candidates() { local dd="$1"; echo "$dd/regtest/.cookie" "$dd/.cookie"; }
adapter_wpath() { echo "/wallet/w1"; }
adapter_create_and_seed() {
    local o e
    o=$(rpc "" createwallet '["w1",false,true]')
    e=$(echo "$o" | rpc_errmsg)
    if [[ -n "$e" ]]; then log "createwallet w1: $e"; return 1; fi
    o=$(rpc "/wallet/w1" sethdseed "[true,\"$SEED\"]")
    e=$(echo "$o" | rpc_errmsg)
    if [[ -n "$e" ]]; then log "sethdseed: $e"; return 1; fi
    return 0
}

walletdiff_restore_main

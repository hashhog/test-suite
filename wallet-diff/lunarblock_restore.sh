#!/usr/bin/env bash
#
# lunarblock_restore.sh — wallet BACKUP->DESTROY->RESTORE->SPEND drill (P2.3) for
# lunarblock (Lua/LuaJIT). Plumbing ONLY: all assertions live in
# wallet-diff/_restore_lib.sh.
#
# lunarblock routes wallet calls under /wallet/<name>; node calls go to "/".
# lunarblock has NO sethdseed and no mnemonic-aware createwallet. Its
# deterministic, spendable seed-backup channel is the BIP-39 MNEMONIC via
# `importmnemonic <mnemonic> <bip39_passphrase> <wallet_name>` (rpc.lua:9707 ->
# wallet.import_mnemonic -> PBKDF2 seed -> BIP-32 master_key_from_seed). The same
# words deterministically reconstruct the identical keypool + addresses, and the
# wallet holds the private master key so it can SIGN (proven: sendtoaddress
# returns a real txid). This is the documented divergence from Core's WIF-based
# restore (same mnemonic class as haskoin/blockbrew/beamchain). The
# `listdescriptors true` descriptor-export channel is separately characterised +
# reported by the shared driver; lunarblock's importdescriptors is WATCH-ONLY
# (rpc.lua add_watch_descriptor), so the seed channel is the spendable one.
#
# adapter_create_and_seed therefore does importmnemonic with a FIXED mnemonic for
# BOTH the original and the restored wallet under the name "w1", giving
# byte-identical addresses across the destroy (the drill's hard requirement).
# SEED here is the mnemonic. Wallet RPCs route to /wallet/w1.
#
# The mnemonic is the canonical BIP-39 all-zero-entropy 12-word test vector
# (valid checksum: 11x "abandon" + "about").
#
# AUTH: lunarblock writes no cookie; adapter_launch writes a "<user>:<pass>"
# cookie into the datadir and launches with matching --rpcuser/--rpcpassword.
# Launch args use SPACE-separated forms (lunarblock's parser rejects --opt=val
# for --datadir). --nov2transport matches the fleet launch shape.
#
# Idempotent; scratch /tmp/walletdiff-restore-lunarblock-* only; reserved ports
# 22186/22187 (lunarblock) + 22188/22189 (Core oracle). ONE summary line on
# stdout; exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_restore_lib.sh"

IMPL="lunarblock"
BIN="$(command -v luajit || echo luajit)"
BUILD_HINT="interpreted — needs luajit + lua-cjson; run: luajit lunarblock/src/main.lua"

# Canonical BIP-39 all-zero-entropy test mnemonic (valid checksum). This IS the
# spendable backup; restore = re-import these words on a fresh datadir.
SEED="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

IMPL_RPC=22186; IMPL_P2P=22187
CORE_RPC=22188; CORE_P2P=22189

DATADIR_ORIG="/tmp/walletdiff-restore-lunarblock-orig"
DATADIR_RESTORE="/tmp/walletdiff-restore-lunarblock-new"
CORE_DATADIR="/tmp/walletdiff-restore-lunarblock-core"

LB_RPCUSER="lunarblock"
LB_RPCPASS="walletdiff-lb"

adapter_launch() {
    local dd="$1"
    export LUA_PATH="$HASHHOG_ROOT/lunarblock/src/?.lua;$HASHHOG_ROOT/lunarblock/src/?/init.lua;;"
    export LUA_CPATH="${LUA_CPATH:-$HOME/.local/lib/lua/5.1/?.so;;}"
    printf '%s:%s' "$LB_RPCUSER" "$LB_RPCPASS" > "$dd/.cookie"
    ( cd "$HASHHOG_ROOT/lunarblock" && \
      "$BIN" src/main.lua --network regtest --datadir "$dd" \
        --port "$IMPL_P2P" --rpcport "$IMPL_RPC" \
        --rpcuser "$LB_RPCUSER" --rpcpassword "$LB_RPCPASS" \
        --nov2transport ) \
        >"$dd/node.log" 2>&1 &
    IMPL_PID=$!
}
adapter_cookie_candidates() { local dd="$1"; echo "$dd/.cookie"; }
adapter_wpath() { echo "/wallet/w1"; }
adapter_create_and_seed() {
    local o e
    # importmnemonic deterministically creates + loads "w1" from the mnemonic,
    # holding the private master key (spendable). wallet_name is required under
    # the multi-wallet manager.
    o=$(rpc "" importmnemonic "[\"$SEED\",\"\",\"w1\"]")
    e=$(echo "$o" | rpc_errmsg)
    if [[ -n "$e" ]]; then log "importmnemonic w1: $e"; return 1; fi
    return 0
}

walletdiff_restore_main

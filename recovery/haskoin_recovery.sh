#!/usr/bin/env bash
#
# haskoin_recovery.sh — wallet-recovery regression test (regtest, self-contained).
#
# Codifies the recovery green cell landed 2026-06-03 (haskoin 3ffa7db:
# "scantxoutset (built from scratch) + restore-from-seed -> recovery GREEN").
# Proves the seed-only recovery property end-to-end on a throwaway regtest node:
#
#   createwallet w1 + backupwallet (before any address) -> getnewaddress (A1)  ->
#   generatetoaddress to fund A1 (coinbase)      ->  scantxoutset BEFORE (total) ->
#   unload, restorewallet w2 from that backup file -> rescanblockchain       ->
#   w2's listunspent address set == w1's (no first-address assumption)       ->
#   scantxoutset AFTER (assert ==BEFORE)         ->  negative control (foreign addr -> 0).
#
# STRICT UNIFORM INTERFACE (the assembled nightly runner greps the summary line):
#   on success: RECOVERY haskoin: PASS funded=<X> recovered=<X> addrs=match neg=0   (exit 0)
#   on failure: RECOVERY haskoin: FAIL <short reason>                               (exit 1)
# All other output goes to stderr / the per-run log; the summary line is the only stdout.
#
# Scratch datadir: /tmp/recreg-haskoin/   RPC port: 21509   P2P port: 21539
# NEVER touches /data/nvme1/, testnet4-data/, or any live node.
#
# RPC auth: cookie (-u $(cat .../regtest/.cookie)), JSON-RPC 1.0 — matches
# tools/smoke-harness.sh's rpc_call and the recovery flow proven last session.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
RPC_PORT=21509
P2P_PORT=21539
DATADIR=/tmp/recreg-haskoin
LOG="$DATADIR/recovery.log"
BASEDIR=${HASHHOG_ROOT}
HASKOIN_REPO="$BASEDIR/haskoin"

# Canonical all-zeros-entropy BIP-39 test mnemonic (valid 12-word checksum).
# This is the seed that worked last session; its BIP-84 regtest m/84'/1'/0'/0/0
# address is the well-known bcrt1qcr8te4kr609gcawutmrza0j4xv80jy8zeqchgx.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# generatetoaddress this many blocks so the first coinbase matures (regtest
# COINBASE_MATURITY = 100; 101 blocks => >=1 spendable, all 101 visible to scan).
N_BLOCKS=101

# A valid regtest bech32 address NOT derived from our seed (negative control).
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""

# ── Logging / fail helpers ─────────────────────────────────────────────────
log() { echo "[$(date +%T)] $*" >>"$LOG" 2>/dev/null; }

# Emit the single clean summary line on stdout, then exit.
fail() {
    echo "RECOVERY haskoin: FAIL $*"
    exit 1
}

# ── Cleanup (always runs) ──────────────────────────────────────────────────
cleanup() {
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NODE_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    rm -rf "$DATADIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── Locate the haskoin binary (build tree; not installed) ──────────────────
HB=$(find "$HASKOIN_REPO/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)
[[ -n "$HB" && -x "$HB" ]] || fail "haskoin binary not found under $HASKOIN_REPO/dist-newstyle"

# ── Launch (smoke-harness recipe) ──────────────────────────────────────────
# haskoin_datadir points Paths_haskoin.getDataFileName at the in-tree resources/
# dir so the BIP-39 word list loads (the package is built, not cabal-installed,
# so the default install datadir has no resources/bip39-english.txt — W161 BUG-8).
log "launching $HB"
haskoin_datadir="$HASKOIN_REPO" \
    "$HB" --network Regtest --datadir "$DATADIR" \
    node --port "$P2P_PORT" --rpcport "$RPC_PORT" \
    >>"$LOG" 2>&1 &
NODE_PID=$!
log "node pid $NODE_PID"

# ── RPC helper (cookie auth, JSON-RPC 1.0) ─────────────────────────────────
cookie_file() {
    for c in "$DATADIR/regtest/.cookie" "$DATADIR/.cookie"; do
        [[ -f "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

# rpc <method> <json-params>  ->  prints raw JSON response on stdout
rpc() {
    local method=$1 params="${2:-[]}" ck
    ck=$(cookie_file) || { echo ""; return 1; }
    curl -s --max-time 30 -u "$(cat "$ck")" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:${RPC_PORT}/" 2>/dev/null
}

# Extract a top-level string "result":"..." value.
res_str() { echo "$1" | sed 's/.*"result":"//; s/".*//'; }
# Extract scantxoutset "total_amount":<number> (BTC, decimal string).
total_amount() { echo "$1" | grep -o '"total_amount":[0-9.]*' | head -1 | sed 's/"total_amount"://'; }
# Count matched unspents (number of "txid" keys in a scantxoutset result).
count_unspents() { echo "$1" | grep -o '"txid"' | wc -l | tr -d ' '; }
has_error() { echo "$1" | grep -q '"error":null' && return 1 || return 0; }
# Sorted, de-duplicated addresses the default wallet holds unspent coins on.
wallet_addr_set() {
    rpc listunspent '[0]' | grep -o '"address":"[^"]*"' | sed 's/"address":"//; s/"$//' | sort -u
}

# ── Wait up to 40s for RPC ─────────────────────────────────────────────────
rpc_up=0
for _ in $(seq 1 40); do
    if [[ -f "$(cookie_file 2>/dev/null)" ]] 2>/dev/null || cookie_file >/dev/null 2>&1; then
        r=$(rpc getblockcount '[]')
        if echo "$r" | grep -q '"result"'; then rpc_up=1; break; fi
    fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node exited during startup (see $LOG)"
    sleep 1
done
[[ "$rpc_up" -eq 1 ]] || fail "RPC did not come up within 40s on :$RPC_PORT"
log "rpc up"

# Sanity: fresh regtest must be at height 0.
r=$(rpc getblockcount '[]')
h0=$(echo "$r" | grep -o '"result":[0-9]*' | grep -o '[0-9]*')
[[ "$h0" == "0" ]] || fail "fresh regtest not at height 0 (got ${h0:-none})"

# ── 1. Restore wallet from the FIXED seed, derive A1 ───────────────────────
# haskoin's restorewallet is Core-shaped (name, backup_file) and its wallet.dat is
# sealed with a per-datadir key, so a seed cannot be handed to it and a backup
# file cannot be authored outside the node. The seed is made by the node
# (createwallet) and carried across wallets by backupwallet -> restorewallet.
# The backup is taken BEFORE the first getnewaddress so the restored wallet
# owns A1 even though it is derived after the backup.
r=$(rpc createwallet '["w1"]')
has_error "$r" && fail "createwallet w1 errored: $(echo "$r" | head -c 160)"
W1_BACKUP="$DATADIR/seed-backups/w1.dat"
mkdir -p "$DATADIR/seed-backups"
r=$(rpc backupwallet "[\"$W1_BACKUP\"]")
has_error "$r" && fail "backupwallet w1 errored: $(echo "$r" | head -c 160)"
[[ -s "$W1_BACKUP" ]] || fail "backupwallet w1 wrote no file at $W1_BACKUP"
log "created w1, backed up to $W1_BACKUP"

A1=$(res_str "$(rpc getnewaddress '[]')")
[[ "$A1" == bcrt1q* ]] || fail "getnewaddress A1 not a regtest bech32 addr (got '${A1:0:40}')"
log "A1=$A1"

# ── 2. Fund A1 via coinbase ────────────────────────────────────────────────
r=$(rpc generatetoaddress "[$N_BLOCKS,\"$A1\"]")
has_error "$r" && fail "generatetoaddress errored: $(echo "$r" | head -c 160)"
r=$(rpc getblockcount '[]')
hn=$(echo "$r" | grep -o '"result":[0-9]*' | grep -o '[0-9]*')
[[ "$hn" == "$N_BLOCKS" ]] || fail "expected height $N_BLOCKS after funding, got ${hn:-none}"
log "funded to height $hn"

# ── 3. scantxoutset BEFORE on A1 ───────────────────────────────────────────
r=$(rpc scantxoutset "[\"start\",[\"addr($A1)\"]]")
has_error "$r" && fail "scantxoutset BEFORE errored: $(echo "$r" | head -c 160)"
BEFORE=$(total_amount "$r")
BEFORE_N=$(count_unspents "$r")
[[ -n "$BEFORE" ]] || fail "scantxoutset BEFORE returned no total_amount"
# Must have actually funded something.
if [[ "$BEFORE" == "0.00000000" || "$BEFORE" == "0" || "$BEFORE_N" == "0" ]]; then
    fail "scantxoutset BEFORE found nothing (total=$BEFORE n=$BEFORE_N) — funding did not land"
fi
log "BEFORE total=$BEFORE unspents=$BEFORE_N"

# The set of addresses w1 holds coins on. The restored wallet must hold coins on
# exactly this set.
W1_SET=$(wallet_addr_set)
[[ -n "$W1_SET" ]] || fail "w1 listunspent holds no address after funding"
grep -qx "$A1" <<<"$W1_SET" || fail "w1 listunspent does not hold A1 ($A1)"
log "w1 address set: $(echo $W1_SET)"

# ── 4. Seed-only recovery: unload, restore SAME seed into a FRESH wallet ───
r=$(rpc unloadwallet '["w1"]')
has_error "$r" && fail "unloadwallet w1 errored: $(echo "$r" | head -c 160)"
W2_BACKUP="$W1_BACKUP"
if [[ -n "${HASKOIN_RECOVERY_W2_DECOY_SEED:-}" ]]; then
    # Negative-control hook: restore w2 from a DIFFERENT wallet's backup. The
    # arm must then FAIL on the recovered-address-set mismatch. Unset in normal runs.
    r=$(rpc createwallet '["wdecoy"]')
    has_error "$r" && fail "createwallet wdecoy errored: $(echo "$r" | head -c 160)"
    W2_BACKUP="$DATADIR/seed-backups/wdecoy.dat"
    r=$(rpc backupwallet "[\"$W2_BACKUP\"]")
    has_error "$r" && fail "backupwallet wdecoy errored: $(echo "$r" | head -c 160)"
    r=$(rpc unloadwallet '["wdecoy"]')
    has_error "$r" && fail "unloadwallet wdecoy errored: $(echo "$r" | head -c 160)"
fi
r=$(rpc restorewallet "[\"w2\",\"$W2_BACKUP\"]")
has_error "$r" && fail "restorewallet w2 (w1 backup) errored: $(echo "$r" | head -c 160)"
log "restored fresh w2 from $W2_BACKUP"

# Do NOT assume the restored wallet's next getnewaddress is A1: Core's
# restorewallet rescans on load, sees A1 used, and hands out the next unused
# address. Rescan explicitly (a node whose restore does not scan needs it; on
# Core it is a no-op re-scan), then the restored wallet must hold coins on
# exactly w1's address set.
r=$(rpc rescanblockchain '[]')
has_error "$r" && fail "rescanblockchain w2 errored: $(echo "$r" | head -c 160)"
W2_SET=$(wallet_addr_set)
[[ "$W2_SET" == "$W1_SET" ]] \
    || fail "recovered address set mismatch: w1={$(echo $W1_SET)} w2={$(echo $W2_SET)}"
log "w2 address set == w1 address set: $(echo $W2_SET)"

# ── 5. scantxoutset AFTER on the recovered address set ─────────────────────
scan_descs=$(sed 's/.*/"addr(&)"/' <<<"$W2_SET" | paste -sd, -)
r=$(rpc scantxoutset "[\"start\",[$scan_descs]]")
has_error "$r" && fail "scantxoutset AFTER errored: $(echo "$r" | head -c 160)"
AFTER=$(total_amount "$r")
AFTER_N=$(count_unspents "$r")
[[ -n "$AFTER" ]] || fail "scantxoutset AFTER returned no total_amount"
[[ "$AFTER" == "$BEFORE" ]] || fail "recovered total $AFTER != funded total $BEFORE"
[[ "$AFTER_N" == "$BEFORE_N" ]] || fail "recovered unspent count $AFTER_N != funded $BEFORE_N"
log "AFTER total=$AFTER unspents=$AFTER_N (== BEFORE)"

# ── 6. Negative control: a foreign address must recover nothing ────────────
r=$(rpc scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]")
has_error "$r" && fail "scantxoutset negative-control errored: $(echo "$r" | head -c 160)"
NEG=$(total_amount "$r")
NEG_N=$(count_unspents "$r")
if [[ "$NEG_N" != "0" ]] || { [[ "$NEG" != "0.00000000" && "$NEG" != "0" ]]; }; then
    fail "negative control non-zero (total=$NEG n=$NEG_N) — scan is over-matching"
fi
log "negative control = 0 (total=$NEG n=$NEG_N)"

# ── PASS ────────────────────────────────────────────────────────────────────
echo "RECOVERY haskoin: PASS funded=$BEFORE recovered=$AFTER addrs=match neg=0"
exit 0

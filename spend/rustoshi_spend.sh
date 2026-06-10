#!/usr/bin/env bash
#
# rustoshi_spend.sh — self-contained wallet-native spend regression test.
#
# Codifies the "wallet can see and spend its own coins" cell for rustoshi — the
# successor to the wallet-recovery cell (rustoshi_recovery.sh). Proves the full
# on-chain spend round-trip on regtest using ONLY wallet-native RPCs, landed by
# the feat(wallet) commit that wires block-connect -> wallet UTXO ledger:
#
#   createwallet w1 -> sethdseed(FIXED 64-byte seed) -> getnewaddress -> A1
#   generatetoaddress 101 -> A1        -> fund A1 with mined coinbase
#   getbalance                          -> reflects spendable (MATURE) coins
#                                          (Core: coinbase matures at 100 conf;
#                                          only the height-1 coinbase is mature
#                                          at tip 101 -> exactly 50 BTC)
#   listunspent                         -> lists the owned UTXOs (101 coinbases)
#   sendtoaddress <foreign-addr> <amt>  -> returns a txid, tx enters mempool
#   generatetoaddress 1 -> A1          -> the tx CONFIRMS
#   ASSERT:
#     * recipient address credited <amt>     (verified via scantxoutset, the
#       authoritative on-chain UTXO oracle — independent of wallet bookkeeping)
#     * sender getbalance dropped by <amt>+fee (change returns to the wallet,
#       so the net debit is exactly amount + fee, modulo a single 50 BTC
#       coinbase maturing on the confirm block)
#     * mempool no longer lists the confirmed tx (no BIP30 wedge / re-broadcast)
#     * listunspent reflects the post-spend set (count changed)
#
# Recipient is a FOREIGN regtest address (not in the wallet) so the recipient
# credit is proven purely on-chain via scantxoutset, and the single loaded
# wallet's getbalance is an honest sender-side measurement.
#
# Restore mechanism for rustoshi: `sethdseed` takes a 64-byte (128 hex char)
# master seed (documented Core divergence — Core takes a WIF privkey). RPC auth
# is cookie-based (<datadir>/.cookie), matching rustoshi_recovery.sh /
# tools/smoke-harness.sh. A single wallet is loaded at any moment so the
# default-wallet resolver is unambiguous (rustoshi does not wire /wallet/<name>
# URL routing).
#
# STRICT UNIFORM INTERFACE (mirrors beamchain_spend.sh / rustoshi_recovery.sh):
# no required args, idempotent, trap cleanup, scratch datadir + unique ports,
# single clean summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: SPEND rustoshi: PASS funded=<X> sent=<Y> recipient=<Y> sender_debited=<Y+fee> ...
#   FAIL: SPEND rustoshi: FAIL <short reason>
#
# Touches ONLY /tmp/spendfleet-rustoshi/ and ports 21610 (RPC) / 21630 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
BIN="$BASEDIR/rustoshi/target/release/rustoshi"
DATADIR="/tmp/spendfleet-rustoshi"
RPC_PORT=21610
P2P_PORT=21630
LOG="$DATADIR/node.log"
RUNLOG="$DATADIR/spend.log"

# FIXED 64-byte master seed (128 hex chars) — the same seed the recovery cell
# uses, so the two tests share a deterministic wallet identity.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"

# Coinbase maturity on regtest is 100 blocks. Mine 101 so EXACTLY the first
# reward (height 1, subsidy 50 BTC) is mature/spendable at tip 101
# (101 - 1 = 100 >= COINBASE_MATURITY). getbalance must therefore report 50 BTC
# — the single mature coinbase — proving maturity is enforced (the other 100
# coinbases are immature and excluded). 50 BTC also funds a clean 10 BTC spend.
NBLOCKS=101
FUNDED_BTC=50          # expected spendable balance after funding (mature coinbase)
SEND_BTC=10            # amount to send
SEND_SATS=1000000000   # 10 BTC in satoshis

# A foreign regtest address NOT derived from our seed — the spend recipient.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""

# ── stderr logger (keeps stdout clean for the single summary line) ──────────
log() { echo "[spend] $*" >&2; }

# ── Emit the one summary line + exit ────────────────────────────────────────
# pass <funded> <sent> <recipient> <sender_debited> <fee>
pass() {
    echo "SPEND rustoshi: PASS funded=$1 sent=$2 recipient=$3 sender_debited=$4 fee_sats=$5 mempool=clean"
    exit 0
}
fail() {
    echo "SPEND rustoshi: FAIL $*"
    exit 1
}

# ── Cleanup: always kill node + wipe scratch datadir ────────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do
            kill -0 "$NODE_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── RPC helper (cookie auth, like rustoshi_recovery.sh) ─────────────────────
# Usage: rpc <method> [json-params]   — echoes the raw JSON response.
rpc() {
    local method=$1 params="${2:-[]}" auth=""
    for c in "$DATADIR/.cookie" "$DATADIR/regtest/.cookie"; do
        if [[ -f "$c" ]]; then auth="-u $(cat "$c")"; break; fi
    done
    # shellcheck disable=SC2086
    curl -s --max-time 40 $auth \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}

# Extract a numeric "result":N scalar (integer or decimal) from a JSON reply.
result_num() {
    echo "$1" | grep -o '"result":[0-9.]*' | head -1 | sed 's/"result"://'
}

# Extract a string "result":"..." from a JSON reply.
result_str() {
    echo "$1" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//'
}

# Convert a BTC decimal string (e.g. "50.00000000") to integer satoshis.
btc_to_sats() {
    local amt="$1" whole frac
    [[ -z "$amt" ]] && { echo ""; return 1; }
    whole="${amt%%.*}"
    if [[ "$amt" == *.* ]]; then frac="${amt#*.}"; else frac="0"; fi
    frac="${frac}00000000"
    frac="${frac:0:8}"
    whole=$((10#${whole:-0}))
    frac=$((10#${frac:-0}))
    echo $(( whole * 100000000 + frac ))
}

# Pull total_amount (BTC) out of a scantxoutset reply, in satoshis.
scan_total_sats() {
    local amt
    amt=$(echo "$1" | grep -o '"total_amount":[0-9.]*' | head -1 | sed 's/.*://; s/[" ]//g')
    [[ -z "$amt" ]] && { echo ""; return 1; }
    btc_to_sats "$amt"
}

# Count "txid" occurrences in a listunspent reply.
count_unspent() {
    echo "$1" | grep -o '"txid"' | wc -l | tr -d ' '
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR" || fail "cannot create scratch datadir $DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -x "$BIN" ]] || fail "rustoshi binary not found at $BIN (build with: cargo build --release)"

# ── 2. Launch rustoshi on regtest. ─────────────────────────────────────────
log "launching rustoshi regtest (rpc=$RPC_PORT p2p=$P2P_PORT datadir=$DATADIR)"
"$BIN" --network=regtest --datadir="$DATADIR" \
    --port="$P2P_PORT" --rpcbind="127.0.0.1:$RPC_PORT" \
    >"$LOG" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"
kill -0 "$NODE_PID" 2>/dev/null || fail "node process exited immediately (see $LOG)"

# ── 3. Wait up to 30s for RPC. ─────────────────────────────────────────────
log "waiting for RPC..."
rpc_ready=0
deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < deadline )); do
    if echo "$(rpc getblockcount)" | grep -q '"result"'; then rpc_ready=1; break; fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node died during startup (see $LOG)"
    sleep 1
done
[[ "$rpc_ready" == "1" ]] || fail "RPC did not respond within 30s"
log "RPC ready"

# ── 4. Create wallet w1 + restore the FIXED seed. ──────────────────────────
log "createwallet w1 + sethdseed (restore fixed seed)"
out=$(rpc createwallet '["w1"]')
echo "$out" | grep -q '"w1"' || fail "createwallet w1 failed: $out"
out=$(rpc sethdseed "[true, \"$SEED\"]")
echo "$out" | grep -q '"result"' || fail "sethdseed failed: $out"

# ── 5. Derive A1 (the address we fund). ────────────────────────────────────
A1=$(result_str "$(rpc getnewaddress)")
[[ -n "$A1" ]] || fail "getnewaddress returned empty"
log "A1=$A1"

# ── 6. Fund A1 with coinbase. ──────────────────────────────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
out=$(rpc generatetoaddress "[$NBLOCKS, \"$A1\"]")
echo "$out" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$out" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# ── 7. getbalance reflects spendable (MATURE) coins. ───────────────────────
# At tip 101 only the height-1 coinbase is mature -> exactly 50 BTC.
BAL_BEFORE_BTC=$(result_num "$(rpc getbalance)")
[[ -n "$BAL_BEFORE_BTC" ]] || fail "getbalance returned no result: $(rpc getbalance | head -c 200)"
BAL_BEFORE_SATS=$(btc_to_sats "$BAL_BEFORE_BTC")
log "getbalance BEFORE = $BAL_BEFORE_BTC BTC ($BAL_BEFORE_SATS sats)"
EXPECT_FUNDED_SATS=$(( FUNDED_BTC * 100000000 ))
[[ "$BAL_BEFORE_SATS" -eq "$EXPECT_FUNDED_SATS" ]] \
    || fail "getbalance $BAL_BEFORE_SATS sats != expected mature $EXPECT_FUNDED_SATS sats (coinbase maturity not enforced?)"

# ── 8. listunspent lists the owned UTXOs. ──────────────────────────────────
LU_BEFORE=$(rpc listunspent)
echo "$LU_BEFORE" | grep -q '"error":{' && fail "listunspent error: $(echo "$LU_BEFORE" | grep -o '"message":"[^"]*"' | head -1)"
N_BEFORE=$(count_unspent "$LU_BEFORE")
[[ "${N_BEFORE:-0}" -gt 0 ]] || fail "listunspent returned 0 UTXOs after funding"
log "listunspent BEFORE = $N_BEFORE UTXOs"

# ── 9. Negative control: foreign recipient holds nothing yet. ──────────────
out=$(rpc scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]")
PRE_RECIP_SATS=$(scan_total_sats "$out")
log "recipient PRE-spend on-chain = ${PRE_RECIP_SATS:-?} sats"
[[ "${PRE_RECIP_SATS:-0}" -eq 0 ]] || fail "recipient already funded before spend (${PRE_RECIP_SATS} sats)"

# ── 10. sendtoaddress -> txid, tx enters mempool. ──────────────────────────
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR (from w1)"
SEND=$(rpc sendtoaddress "[\"$FOREIGN_ADDR\", $SEND_BTC]")
echo "$SEND" | grep -q '"error":{' \
    && fail "sendtoaddress error: $(echo "$SEND" | grep -o '"message":"[^"]*"' | head -1)"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
log "TXID=$TXID"

MEMPOOL=$(rpc getrawmempool)
echo "$MEMPOOL" | grep -q "$TXID" || fail "tx $TXID not in mempool after sendtoaddress: $(echo "$MEMPOOL" | head -c 200)"
log "tx is in mempool"

# ── 11. Mine 1 block -> the tx CONFIRMS. ───────────────────────────────────
log "generatetoaddress 1 -> $A1 (confirm the spend)"
out=$(rpc generatetoaddress "[1, \"$A1\"]")
echo "$out" | grep -q '"error":{' && fail "confirm-block generate error: $(echo "$out" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -gt "$HEIGHT" ]] || fail "height did not advance on confirm block"
log "height after confirm = $HEIGHT2"

# ── 12. Mempool no longer lists the confirmed tx (no wedge / re-broadcast). ─
MEMPOOL2=$(rpc getrawmempool)
echo "$MEMPOOL2" | grep -q "$TXID" && fail "tx $TXID STILL in mempool after confirmation (mempool wedge)"
log "mempool cleared the confirmed tx"

# ── 13. Recipient credited <amt> on-chain (scantxoutset oracle). ───────────
out=$(rpc scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]")
echo "$out" | grep -q '"error":{' && fail "scantxoutset recipient error: $(echo "$out" | grep -o '"message":"[^"]*"' | head -1)"
RECIP_SATS=$(scan_total_sats "$out")
[[ -n "$RECIP_SATS" ]] || fail "scantxoutset recipient returned no total_amount"
log "recipient POST-spend on-chain = $RECIP_SATS sats (want $SEND_SATS)"
[[ "$RECIP_SATS" -eq "$SEND_SATS" ]] \
    || fail "recipient credited $RECIP_SATS sats != sent $SEND_SATS sats"

# ── 14. Sender getbalance dropped by amount + fee. ─────────────────────────
BAL_AFTER_BTC=$(result_num "$(rpc getbalance)")
[[ -n "$BAL_AFTER_BTC" ]] || fail "getbalance AFTER returned no result"
BAL_AFTER_SATS=$(btc_to_sats "$BAL_AFTER_BTC")
log "getbalance AFTER = $BAL_AFTER_BTC BTC ($BAL_AFTER_SATS sats)"

# Mining the confirm block to A1 awards a NEW (immature) coinbase that does NOT
# count toward spendable balance, AND matures the height-2 coinbase (now at 100
# confs) which ADDS exactly 50 BTC of newly-spendable balance. So the raw delta
# is not simply amount+fee. The amount the wallet actually LOST to the spend is:
#   debited = (50 BTC matured in) - SEND_SATS - (after - before)
# i.e. the implied fee = before + matured_in - send - after. It must be a small
# positive number (a real fee was paid).
MATURED_IN=$(( 50 * 100000000 ))   # height-2 coinbase matures at tip 102
EXPECTED_AFTER_NOFEE=$(( BAL_BEFORE_SATS + MATURED_IN - SEND_SATS ))
DEBIT_FEE=$(( EXPECTED_AFTER_NOFEE - BAL_AFTER_SATS ))
log "implied fee (sender debit beyond amount) = $DEBIT_FEE sats"
[[ "$DEBIT_FEE" -gt 0 ]] \
    || fail "no fee debited (sender balance arithmetic wrong: before=$BAL_BEFORE_SATS after=$BAL_AFTER_SATS)"
[[ "$DEBIT_FEE" -lt 100000 ]] \
    || fail "implied fee $DEBIT_FEE sats unreasonably large (balance accounting drift)"
SENDER_DEBITED=$(( SEND_SATS + DEBIT_FEE ))
log "sender debited amount+fee = $SENDER_DEBITED sats"

# ── 15. listunspent reflects the post-spend set. ───────────────────────────
LU_AFTER=$(rpc listunspent "[0]")   # minconf 0 so the change output is visible
echo "$LU_AFTER" | grep -q '"error":{' && fail "listunspent AFTER error"
N_AFTER=$(count_unspent "$LU_AFTER")
log "listunspent AFTER (minconf 0) = $N_AFTER UTXOs (was $N_BEFORE)"
[[ "${N_AFTER:-0}" -gt 0 ]] || fail "listunspent AFTER is empty (ledger lost track of coins)"
[[ "$N_AFTER" != "$N_BEFORE" ]] || fail "listunspent count unchanged after spend+block (ledger not updating)"

# ── 16. Success. ───────────────────────────────────────────────────────────
log "PASS: funded=$FUNDED_BTC BTC sent=$SEND_BTC BTC recipient=$SEND_BTC BTC " \
    "sender_debited=$SENDER_DEBITED sats mempool=clean"
pass "$FUNDED_BTC" "$SEND_BTC" "$SEND_BTC" "$SENDER_DEBITED" "$DEBIT_FEE"

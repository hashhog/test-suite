#!/usr/bin/env bash
#
# camlcoin_spend.sh — self-contained wallet-native spend regression test.
#
# Codifies the "wallet can see and spend its own coins" cell for camlcoin —
# the successor to the recovery cell (camlcoin_recovery.sh). Proves the full
# on-chain spend round-trip on regtest using ONLY wallet-native RPCs:
#
#   sethdseed <FIXED hex seed>          -> deterministic HD master key
#   getnewaddress -> A1                  -> a wallet receive address
#   generatetoaddress 101 -> A1          -> fund A1 with mined coinbase
#   getbalance                           -> reflects spendable (MATURE) coins
#                                           (Core: coinbase matures at 100 conf;
#                                           only the height-1 coinbase is mature
#                                           at tip 101 -> exactly 50 BTC)
#   listunspent                          -> lists the owned UTXOs
#   sendtoaddress <foreign-addr> <amt>   -> returns a txid, tx enters mempool
#   generatetoaddress 1 -> A1            -> the tx CONFIRMS
#   ASSERT:
#     * recipient address credited <amt>     (verified via scantxoutset, the
#       authoritative on-chain UTXO oracle — independent of wallet bookkeeping)
#     * sender getbalance reflects the spend  (debit = amount + fee net of the
#       one coinbase that newly matured on the confirm block)
#     * mempool no longer lists the confirmed tx (no wedge / re-broadcast)
#     * listunspent reflects the post-spend set (count changed)
#
# Recipient is a FOREIGN regtest address (not in any camlcoin wallet) so the
# recipient credit is proven purely on-chain via scantxoutset.
#
# STRICT UNIFORM INTERFACE (mirrors beamchain_spend.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: SPEND camlcoin: PASS funded=<X> sent=<Y> recipient=<Y> sender_debited=<Y+fee> ...
#   FAIL: SPEND camlcoin: FAIL <short reason>
#
# Touches ONLY /tmp/spendfleet-camlcoin/ and ports 39715 (RPC) / 39735 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/camlcoin/_build/default/bin/main.exe"
DATADIR="/tmp/spendfleet-camlcoin"
RPC_PORT=39715
P2P_PORT=39735
RPC_URL="http://127.0.0.1:${RPC_PORT}/"
LOGFILE="$DATADIR/spend-test.log"

# Fixed BIP-32 seed — the same classic 00..1f test vector the recovery cell
# (camlcoin_recovery.sh) uses, so the two tests share a wallet identity.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

# Coinbase maturity on regtest is 100 blocks. Mine 101 so EXACTLY the first
# reward (height 1, subsidy 50 BTC) is mature/spendable at tip 101
# (101 - 1 = 100 >= COINBASE_MATURITY). getbalance must therefore report 50 BTC
# — the single mature coinbase — proving maturity is enforced (the other 100
# coinbases are immature and excluded). 50 BTC also funds a clean 10 BTC spend.
NBLOCKS=101
FUNDED_BTC=50          # expected spendable balance after funding (mature coinbase)
SEND_BTC=10            # amount to send
SEND_SATS=1000000000   # 10 BTC in satoshis

# A foreign address NOT derived from our seed — the spend recipient. Proving
# this address is credited on-chain (scantxoutset) demonstrates a real transfer
# of value out of the wallet to an external party.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""

# ── Logging: everything noisy goes to stderr + logfile, never stdout. ──────
log() { echo "[spend:camlcoin] $*" >&2; }

# ── Emit the single summary line + exit. ───────────────────────────────────
# pass <funded> <sent> <recipient> <sender_debited> <fee>
pass() {
    echo "SPEND camlcoin: PASS funded=$1 sent=$2 recipient=$3 sender_debited=$4 fee_sats=$5 mempool=clean"
    exit 0
}
fail() {
    echo "SPEND camlcoin: FAIL $*"
    exit 1
}

# ── Cleanup trap: always kill node + wipe scratch datadir on any exit. ─────
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
    fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
    fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
    rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT

# ── RPC helper (cookie auth). ──────────────────────────────────────────────
# usage: rpc <method> <params-json>
COOKIE=""
rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 40 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "$RPC_URL" 2>/dev/null
}

# Extract a numeric "result":N scalar (integer or decimal) from a JSON reply.
result_num() {
    echo "$1" | grep -o '"result":[0-9.]*' | head -1 | sed 's/"result"://'
}

# Extract a string "result":"..." from a JSON reply.
result_str() {
    echo "$1" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//'
}

# Convert a BTC decimal string (e.g. "50.00000000") to integer satoshis without
# bc: split on the dot, pad/truncate the fractional part to 8 digits.
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
    amt=$(echo "$1" | grep -o '"total_amount":[^,}]*' | head -1 | sed 's/.*://; s/[" ]//g')
    [[ -z "$amt" ]] && { echo ""; return 1; }
    btc_to_sats "$amt"
}

# Count "txid" occurrences in a listunspent reply.
count_unspent() {
    echo "$1" | grep -o '"txid"' | wc -l | tr -d ' '
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
pkill -f "spendfleet-camlcoin" 2>/dev/null || true
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"
: > "$LOGFILE"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -x "$NODE_BIN" ]] || fail "binary not found at $NODE_BIN (run dune build)"

# ── 2. Launch camlcoin on regtest. ─────────────────────────────────────────
log "launching $NODE_BIN on regtest (rpc=$RPC_PORT p2p=$P2P_PORT)"
"$NODE_BIN" --network regtest --datadir "$DATADIR" \
    --port "$P2P_PORT" --rpcport "$RPC_PORT" \
    >>"$LOGFILE" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"

# ── 3. Locate the cookie + wait for RPC. ───────────────────────────────────
rpc_up=0
for _ in $(seq 1 45); do
    if [[ -z "$COOKIE" && -f "$DATADIR/.cookie" ]]; then
        COOKIE=$(cat "$DATADIR/.cookie")
    fi
    if [[ -n "$COOKIE" ]]; then
        r=$(rpc getblockcount)
        if echo "$r" | grep -q '"result"'; then rpc_up=1; log "RPC ready: $r"; break; fi
    fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node exited during startup (see $LOGFILE)"
    sleep 1
done
[[ $rpc_up -eq 1 ]] || fail "RPC did not respond within 45s"

# ── 4. Restore wallet from the FIXED seed, derive A1. ──────────────────────
log "sethdseed (fixed seed) -> deterministic HD master key"
r=$(rpc sethdseed "[true,\"$SEED\"]")
echo "$r" | grep -q '"seed_hex"' || fail "sethdseed failed: $r"

log "getnewaddress -> A1"
A1=$(result_str "$(rpc getnewaddress)")
[[ -n "$A1" ]] || fail "getnewaddress returned no address"
log "A1=$A1"

# ── 5. Fund A1 with coinbase. ──────────────────────────────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A1\"]")
echo "$r" | grep -q '"result":\[' || fail "generatetoaddress error: $r"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# ── 6. getbalance reflects spendable (MATURE) coins. ───────────────────────
# At tip 101 only the height-1 coinbase is mature -> exactly 50 BTC.
BAL_BEFORE_BTC=$(result_num "$(rpc getbalance)")
[[ -n "$BAL_BEFORE_BTC" ]] || fail "getbalance returned no result: $(rpc getbalance | head -c 200)"
BAL_BEFORE_SATS=$(btc_to_sats "$BAL_BEFORE_BTC")
log "getbalance BEFORE = $BAL_BEFORE_BTC BTC ($BAL_BEFORE_SATS sats)"
EXPECT_FUNDED_SATS=$(( FUNDED_BTC * 100000000 ))
[[ "$BAL_BEFORE_SATS" -eq "$EXPECT_FUNDED_SATS" ]] \
    || fail "getbalance $BAL_BEFORE_SATS sats != expected mature $EXPECT_FUNDED_SATS sats (coinbase maturity not enforced?)"

# ── 7. listunspent lists the owned UTXOs. ──────────────────────────────────
LU_BEFORE=$(rpc listunspent)
echo "$LU_BEFORE" | grep -q '"error":{' && fail "listunspent error: $(echo "$LU_BEFORE" | grep -o '"message":"[^"]*"' | head -1)"
N_BEFORE=$(count_unspent "$LU_BEFORE")
[[ "${N_BEFORE:-0}" -gt 0 ]] || fail "listunspent returned 0 UTXOs after funding"
log "listunspent BEFORE = $N_BEFORE UTXOs"

# ── 8. Negative control: foreign recipient holds nothing yet. ──────────────
r=$(rpc scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]")
PRE_RECIP_SATS=$(scan_total_sats "$r")
log "recipient PRE-spend on-chain = ${PRE_RECIP_SATS:-?} sats"
[[ "${PRE_RECIP_SATS:-0}" -eq 0 ]] || fail "recipient already funded before spend (${PRE_RECIP_SATS} sats)"

# ── 9. sendtoaddress -> txid, tx enters mempool. ───────────────────────────
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR"
SEND=$(rpc sendtoaddress "[\"$FOREIGN_ADDR\",$SEND_BTC]")
echo "$SEND" | grep -q '"error":{' \
    && fail "sendtoaddress error: $(echo "$SEND" | grep -o '"message":"[^"]*"' | head -1)"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
log "TXID=$TXID"

MEMPOOL=$(rpc getrawmempool)
echo "$MEMPOOL" | grep -q "$TXID" || fail "tx $TXID not in mempool after sendtoaddress: $(echo "$MEMPOOL" | head -c 200)"
log "tx is in mempool"

# ── 10. Mine 1 block -> the tx CONFIRMS. ───────────────────────────────────
log "generatetoaddress 1 -> $A1 (confirm the spend)"
r=$(rpc generatetoaddress "[1,\"$A1\"]")
echo "$r" | grep -q '"result":\[' || fail "confirm-block generate error: $r"
HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -gt "$HEIGHT" ]] || fail "height did not advance on confirm block"
log "height after confirm = $HEIGHT2"

# ── 11. Mempool no longer lists the confirmed tx (no wedge / re-broadcast). ─
MEMPOOL2=$(rpc getrawmempool)
echo "$MEMPOOL2" | grep -q "$TXID" && fail "tx $TXID STILL in mempool after confirmation (mempool wedge)"
log "mempool cleared the confirmed tx"

# ── 12. Recipient credited <amt> on-chain (scantxoutset oracle). ───────────
r=$(rpc scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]")
echo "$r" | grep -q '"error":{' && fail "scantxoutset recipient error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
RECIP_SATS=$(scan_total_sats "$r")
[[ -n "$RECIP_SATS" ]] || fail "scantxoutset recipient returned no total_amount"
log "recipient POST-spend on-chain = $RECIP_SATS sats (want $SEND_SATS)"
[[ "$RECIP_SATS" -eq "$SEND_SATS" ]] \
    || fail "recipient credited $RECIP_SATS sats != sent $SEND_SATS sats"

# ── 13. Sender getbalance reflects amount + fee debit. ─────────────────────
# Mining the confirm block to A1 awards a NEW (immature) coinbase that does NOT
# count toward spendable balance, AND matures the height-2 coinbase (now at 100
# confs) which ADDS 50 BTC of newly-spendable balance. So the raw delta is not
# simply amount+fee. The amount the wallet LOST to the spend (amount + fee) is:
#   debited = (before + matured-in) - after
# where matured-in is the single 50 BTC coinbase that crossed maturity.
BAL_AFTER_BTC=$(result_num "$(rpc getbalance)")
[[ -n "$BAL_AFTER_BTC" ]] || fail "getbalance AFTER returned no result"
BAL_AFTER_SATS=$(btc_to_sats "$BAL_AFTER_BTC")
log "getbalance AFTER = $BAL_AFTER_BTC BTC ($BAL_AFTER_SATS sats)"

MATURED_IN=$(( 50 * 100000000 ))   # height-2 coinbase matures at tip 102
SENDER_DEBITED=$(( BAL_BEFORE_SATS + MATURED_IN - BAL_AFTER_SATS ))
log "sender debited (amount+fee) = $SENDER_DEBITED sats"
DEBIT_FEE=$(( SENDER_DEBITED - SEND_SATS ))
log "implied fee (sender debit beyond amount) = $DEBIT_FEE sats"
# Fee must be positive (a real fee was paid) and small (regtest on a ~1-2 input
# tx -> well under 100k sats). Sender was genuinely debited amount+fee.
[[ "$DEBIT_FEE" -gt 0 ]] || fail "no fee debited (sender balance arithmetic wrong: before=$BAL_BEFORE_SATS after=$BAL_AFTER_SATS)"
[[ "$DEBIT_FEE" -lt 100000 ]] || fail "implied fee $DEBIT_FEE sats unreasonably large (balance accounting drift)"

# ── 14. listunspent reflects the post-spend set. ───────────────────────────
LU_AFTER=$(rpc listunspent)
echo "$LU_AFTER" | grep -q '"error":{' && fail "listunspent AFTER error"
N_AFTER=$(count_unspent "$LU_AFTER")
log "listunspent AFTER = $N_AFTER UTXOs (was $N_BEFORE)"
# The set must have changed: the spent coinbase is gone, a change output and a
# newly-mined coinbase appeared. A non-zero, different count proves the ledger
# tracked the spend + new block.
[[ "${N_AFTER:-0}" -gt 0 ]] || fail "listunspent AFTER is empty (ledger lost track of coins)"
[[ "$N_AFTER" != "$N_BEFORE" ]] || fail "listunspent count unchanged after spend+block (ledger not updating)"

# ── 15. Success. ───────────────────────────────────────────────────────────
log "PASS: funded=$FUNDED_BTC BTC sent=$SEND_BTC BTC recipient=$SEND_BTC BTC " \
    "sender_debited=$SENDER_DEBITED sats mempool=clean"
pass "$FUNDED_BTC" "$SEND_BTC" "$SEND_BTC" "$SENDER_DEBITED" "$DEBIT_FEE"

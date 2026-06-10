#!/usr/bin/env bash
#
# hotbuns_spend.sh — self-contained wallet-native spend regression test.
#
# Codifies the "wallet can see and spend its own coins" cell for hotbuns — the
# successor to the wallet-recovery cell (hotbuns_recovery.sh). Proves the full
# on-chain spend round-trip on regtest using ONLY wallet-native RPCs:
#
#   createwallet w1 <fixed mnemonic>   -> getnewaddress -> A1
#   generatetoaddress 101 -> A1        -> fund A1 with mined coinbase
#   getbalance                          -> reflects spendable (MATURE) coins
#                                          (Core: coinbase matures at depth 100;
#                                          the wallet treats a coin spendable at
#                                          chain_depth >= COINBASE_MATURITY + 1,
#                                          i.e. only the height-1 coinbase is
#                                          mature at tip 101 -> exactly 50 BTC)
#   listunspent                         -> lists the owned UTXOs
#   sendtoaddress <foreign-addr> <amt>  -> returns a txid, tx enters mempool
#   generatetoaddress 1 -> A1          -> the tx CONFIRMS
#   ASSERT:
#     * recipient address credited <amt>     (verified via scantxoutset, the
#       authoritative on-chain UTXO oracle — independent of wallet bookkeeping)
#     * sender getbalance dropped by <amt>+fee (change returns to the wallet,
#       so the net debit is exactly amount + fee)
#     * mempool no longer lists the confirmed tx (no BIP30 wedge / re-broadcast)
#     * listunspent reflects the post-spend set (count changed)
#
# Recipient is a FOREIGN regtest address (not in any hotbuns wallet) so the
# recipient credit is proven purely on-chain via scantxoutset, and the single
# loaded wallet's getbalance is an honest sender-side measurement.
#
# STRICT UNIFORM INTERFACE (mirrors beamchain_spend.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: SPEND hotbuns: PASS funded=<X> sent=<Y> recipient=<Y> sender_debited=<Y+fee> ...
#   FAIL: SPEND hotbuns: FAIL <short reason>
#
# Touches ONLY /tmp/spendfleet-hotbuns/ and ports 21614 (RPC) / 21634 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_DIR="$BASEDIR/hotbuns"
DATADIR="/tmp/spendfleet-hotbuns"
RPC_PORT=21614
P2P_PORT=21634
LOGFILE="$DATADIR/node.log"

# Canonical BIP-39 all-zero-entropy 12-word test mnemonic (valid checksum).
# Same FIXED seed as the recovery cell so the two tests share a wallet identity.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# Coinbase maturity on regtest is 100 blocks. Mine 101 so EXACTLY the first
# reward (height 1, subsidy 50 BTC) is mature/spendable at tip 101 (wallet depth
# 101 >= COINBASE_MATURITY + 1). getbalance must therefore report 50 BTC — the
# single mature coinbase — proving maturity is enforced (the other 100 coinbases
# are immature and excluded). 50 BTC also funds a clean 10 BTC spend.
NBLOCKS=101
FUNDED_BTC=50          # expected spendable balance after funding (mature coinbase)
SEND_BTC=10            # amount to send
SEND_SATS=1000000000   # 10 BTC in satoshis

# A foreign address NOT derived from our seed — the spend recipient. Proving
# this address is credited on-chain (scantxoutset) demonstrates a real transfer
# of value out of the wallet to an external party.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""
COOKIE=""

# ── Logging: everything noisy goes to stderr + logfile, never stdout. ──────
log() { echo "[spend] $*" >&2; }

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
    rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Emit the single summary line + exit. ───────────────────────────────────
# pass <funded> <sent> <recipient> <sender_debited> <fee>
pass() {
    echo "SPEND hotbuns: PASS funded=$1 sent=$2 recipient=$3 sender_debited=$4 fee_sats=$5 mempool=clean"
    exit 0
}
fail() {
    echo "SPEND hotbuns: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth). ──────────────────────────────────────────────
# hotbuns writes "__cookie__:<hex>" to {datadir}/.cookie on start
# (src/rpc/server.ts); mirror smoke-harness.sh / hotbuns_recovery.sh: -u <cookie>.
# usage: rpc <method> <params-json>
rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 40 -u "$COOKIE" \
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
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
command -v bun >/dev/null 2>&1 || fail "bun runtime not found on PATH"
[[ -f "$NODE_DIR/src/index.ts" ]] || fail "hotbuns entrypoint not found at $NODE_DIR/src/index.ts"

# ── 2. Launch hotbuns on regtest (smoke-harness bun recipe). ───────────────
log "launching hotbuns (regtest) rpc=:$RPC_PORT p2p=:$P2P_PORT -> $LOGFILE"
(
    cd "$NODE_DIR" || exit 1
    exec bun run src/index.ts \
        --network=regtest --datadir="$DATADIR" \
        --port="$P2P_PORT" --rpcport="$RPC_PORT"
) >"$LOGFILE" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"

# ── 3. Locate the cookie + wait for RPC. ───────────────────────────────────
deadline=$(( $(date +%s) + 45 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$COOKIE" ]]; then
        for c in "$DATADIR/.cookie" "$DATADIR/regtest/.cookie"; do
            if [[ -f "$c" ]]; then COOKIE=$(cat "$c"); break; fi
        done
    fi
    if [[ -n "$COOKIE" ]]; then
        r=$(rpc getblockcount)
        if echo "$r" | grep -q '"result"'; then
            log "RPC ready: $r"
            break
        fi
    fi
    kill -0 "$NODE_PID" 2>/dev/null || { tail -n 20 "$LOGFILE" >&2 2>/dev/null || true; fail "node exited during startup (see $LOGFILE)"; }
    sleep 1
done
[[ -n "$COOKIE" ]] || fail "cookie never appeared within 45s"
r=$(rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "RPC never responded within 45s"

# ── 4. Create wallet w1 from fixed mnemonic, derive A1. ────────────────────
# createwallet params: [name, disable_priv, blank, passphrase, avoid_reuse,
#                       descriptors, load_on_startup, mnemonic, mnemonic_passphrase]
log "createwallet w1 from fixed mnemonic"
r=$(rpc createwallet "[\"w1\", false, false, \"\", false, true, false, \"$MNEMONIC\", \"\"]")
echo "$r" | grep -q '"name":"w1"' || fail "createwallet w1 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

log "getnewaddress on w1 (bech32/p2wpkh) -> A1"
A1=$(result_str "$(rpc getnewaddress)")
[[ -n "$A1" ]] || fail "getnewaddress returned no address"
log "A1=$A1"

# ── 5. Fund A1 with coinbase. ──────────────────────────────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS, \"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
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
r=$(rpc scantxoutset "[\"start\", [\"addr($FOREIGN_ADDR)\"]]")
PRE_RECIP_SATS=$(scan_total_sats "$r")
log "recipient PRE-spend on-chain = ${PRE_RECIP_SATS:-?} sats"
[[ "${PRE_RECIP_SATS:-0}" -eq 0 ]] || fail "recipient already funded before spend (${PRE_RECIP_SATS} sats)"

# ── 9. sendtoaddress -> txid, tx enters mempool. ───────────────────────────
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

# ── 10. Mine 1 block -> the tx CONFIRMS. ───────────────────────────────────
log "generatetoaddress 1 -> $A1 (confirm the spend)"
r=$(rpc generatetoaddress "[1, \"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "confirm-block generate error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -gt "$HEIGHT" ]] || fail "height did not advance on confirm block"
log "height after confirm = $HEIGHT2"

# ── 11. Mempool no longer lists the confirmed tx (no wedge / re-broadcast). ─
MEMPOOL2=$(rpc getrawmempool)
echo "$MEMPOOL2" | grep -q "$TXID" && fail "tx $TXID STILL in mempool after confirmation (mempool wedge)"
log "mempool cleared the confirmed tx"

# ── 12. Recipient credited <amt> on-chain (scantxoutset oracle). ───────────
r=$(rpc scantxoutset "[\"start\", [\"addr($FOREIGN_ADDR)\"]]")
echo "$r" | grep -q '"error":{' && fail "scantxoutset recipient error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
RECIP_SATS=$(scan_total_sats "$r")
[[ -n "$RECIP_SATS" ]] || fail "scantxoutset recipient returned no total_amount"
log "recipient POST-spend on-chain = $RECIP_SATS sats (want $SEND_SATS)"
[[ "$RECIP_SATS" -eq "$SEND_SATS" ]] \
    || fail "recipient credited $RECIP_SATS sats != sent $SEND_SATS sats"

# ── 13. Sender getbalance dropped by amount + fee. ─────────────────────────
# Change returns to the wallet, so the net debit is exactly amount + fee.
BAL_AFTER_BTC=$(result_num "$(rpc getbalance)")
[[ -n "$BAL_AFTER_BTC" ]] || fail "getbalance AFTER returned no result"
BAL_AFTER_SATS=$(btc_to_sats "$BAL_AFTER_BTC")
log "getbalance AFTER = $BAL_AFTER_BTC BTC ($BAL_AFTER_SATS sats)"

# NOTE: mining the confirm block to A1 awards a NEW (immature) coinbase that
# does NOT count toward spendable balance, AND matures the height-2 coinbase
# (now buried 100 deep) which ADDS 50 BTC of newly-spendable balance. So the raw
# delta is not simply amount+fee. We back out the single 50 BTC maturation and
# assert the spend-debit component directly: the residual is exactly the fee,
# which must be positive (a real fee was paid) and small.
MATURED_IN=$(( 50 * 100000000 ))   # height-2 coinbase matures at tip 102
EXPECTED_AFTER_NOFEE=$(( BAL_BEFORE_SATS + MATURED_IN - SEND_SATS ))
DEBIT_FEE=$(( EXPECTED_AFTER_NOFEE - BAL_AFTER_SATS ))
log "implied fee (sender debit beyond amount) = $DEBIT_FEE sats"
[[ "$DEBIT_FEE" -gt 0 ]] || fail "no fee debited (sender balance arithmetic wrong: before=$BAL_BEFORE_SATS after=$BAL_AFTER_SATS)"
[[ "$DEBIT_FEE" -lt 100000 ]] || fail "implied fee $DEBIT_FEE sats unreasonably large (balance accounting drift)"
SENDER_DEBITED=$(( SEND_SATS + DEBIT_FEE ))
log "sender debited amount+fee = $SENDER_DEBITED sats"

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

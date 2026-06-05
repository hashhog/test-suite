#!/usr/bin/env bash
#
# clearbit_spend.sh — self-contained wallet-native spend regression test.
#
# Codifies the "wallet can see and spend its own coins" cell for clearbit, the
# successor to the wallet-recovery cell (clearbit_recovery.sh). Proves the full
# on-chain spend round-trip on regtest using ONLY wallet-native RPCs:
#
#   createwallet w1 (blank) -> sethdseed(FIXED SEED) -> getnewaddress -> A1
#   generatetoaddress 101 -> A1        -> fund A1 with mined coinbase
#   getbalance                          -> reflects spendable (MATURE) coins
#                                          (Core: coinbase matures at 100 conf;
#                                          clearbit depth = tip_height - height,
#                                          so at tip 101 only the height-1
#                                          coinbase is mature -> exactly 50 BTC)
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
# Recipient is a FOREIGN regtest address (not in any clearbit wallet) so the
# recipient credit is proven purely on-chain via scantxoutset, and w1's
# getbalance is an honest sender-side measurement.
#
# The capability this proves is the "block-connect -> wallet-scan" hook
# (rpc.zig handleGenerateToAddress -> wallet.zig scanBlockForWallet) plus the
# wallet-native sendtoaddress (coin-select -> build -> sign -> broadcast).
#
# STRICT UNIFORM INTERFACE (mirrors beamchain_spend.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: SPEND clearbit: PASS funded=<X> sent=<Y> recipient=<Y> sender_debited=<Y+fee> ...
#   FAIL: SPEND clearbit: FAIL <short reason>
#
# Touches ONLY /tmp/spendfleet-clearbit/ and ports 39716 (RPC) / 39736 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
IMPL="clearbit"
RPC_PORT=39716
P2P_PORT=39736
DATADIR="/tmp/spendfleet-clearbit"
NETDIR="$DATADIR/regtest"          # clearbit appends the network subdir
COOKIE_FILE="$NETDIR/.cookie"
LOGFILE="$DATADIR/node.log"
BASE="http://127.0.0.1:$RPC_PORT"

# Resolve the binary the same way build-all.sh / smoke-harness.sh do.
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"

# The FIXED 16-byte BIP-32 test seed (hex) the recovery cell uses, so the spend
# cell and the recovery cell share a wallet identity. clearbit's sethdseed
# takes a HEX seed (documented divergence from Core's WIF).
SEED="000102030405060708090a0b0c0d0e0f"

# Coinbase maturity on regtest is 100 blocks. Mine 101 so EXACTLY the first
# reward (height 1, subsidy 50 BTC) is mature/spendable at tip 101
# (clearbit depth = 101 - 1 = 100 >= COINBASE_MATURITY). getbalance must
# therefore report 50 BTC — proving maturity is enforced. 50 BTC also funds a
# clean 10 BTC spend.
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

# ── Logging: everything noisy goes to stderr, never stdout. ────────────────
log() { echo "[spend] $*" >&2; }

# ── Cleanup trap: always kill node + wipe scratch datadir on any exit. ─────
kill_port() {
    fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
    fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
}
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
    kill_port
    rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Emit the single summary line + exit. ───────────────────────────────────
# pass <funded> <sent> <recipient> <sender_debited> <fee>
pass() {
    echo "SPEND $IMPL: PASS funded=$1 sent=$2 recipient=$3 sender_debited=$4 fee_sats=$5 mempool=clean"
    exit 0
}
fail() {
    echo "SPEND $IMPL: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth; wallet path). ─────────────────────────────────
# usage: rpc <path> <method> <params-json>
rpc() {
    local path="$1" method="$2" params="${3:-[]}"
    curl -s --max-time 40 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "$BASE$path" 2>/dev/null
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
kill_port
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -x "$BIN" ]] || fail "binary not found at $BIN (build clearbit first: zig build -Doptimize=ReleaseFast)"

# ── 2. Launch clearbit on regtest. ─────────────────────────────────────────
log "launching clearbit (regtest) -> $LOGFILE"
"$BIN" --regtest --datadir="$DATADIR" --port="$P2P_PORT" --rpcport="$RPC_PORT" \
    >"$LOGFILE" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"
sleep 1
kill -0 "$NODE_PID" 2>/dev/null || fail "node exited immediately (see $LOGFILE)"

# ── 3. Locate the cookie + wait for RPC. ───────────────────────────────────
deadline=$(( $(date +%s) + 45 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$COOKIE" && -f "$COOKIE_FILE" ]]; then
        COOKIE="$(cat "$COOKIE_FILE" 2>/dev/null)"
    fi
    if [[ -n "$COOKIE" ]]; then
        r=$(rpc "/" getblockcount)
        if echo "$r" | grep -q '"result"'; then
            log "RPC ready: $r"
            break
        fi
    fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node exited during startup (see $LOGFILE)"
    sleep 1
done
[[ -n "$COOKIE" ]] || fail "cookie never appeared within 45s"
r=$(rpc "/" getblockcount)
echo "$r" | grep -q '"result"' || fail "RPC never responded within 45s"

# ── 4. Create blank wallet w1, restore FIXED seed, derive A1. ──────────────
# createwallet must POST to "/" (the /wallet/<name> path 404s before the
# wallet exists). Args: [name, disable_private_keys=false, blank=true].
log "createwallet w1 (blank) + sethdseed restore"
r=$(rpc "/" createwallet '["w1",false,true]')
echo "$r" | grep -q '"error":{' && fail "createwallet w1: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
r=$(rpc "/wallet/w1" sethdseed "[true,\"$SEED\"]")
echo "$r" | grep -q '"error":{' && fail "sethdseed w1: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

log "getnewaddress on w1 (bech32/p2wpkh) -> A1"
A1=$(result_str "$(rpc "/wallet/w1" getnewaddress "[]")")
[[ -n "$A1" ]] || fail "getnewaddress w1 returned no address"
log "A1=$A1"

# ── 5. Fund A1 with coinbase. ──────────────────────────────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc "/" generatetoaddress "[$NBLOCKS,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc "/" getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# ── 6. getbalance reflects spendable (MATURE) coins. ───────────────────────
# At tip 101 only the height-1 coinbase is mature -> exactly 50 BTC.
BAL_BEFORE_BTC=$(result_num "$(rpc "/wallet/w1" getbalance)")
[[ -n "$BAL_BEFORE_BTC" ]] || fail "getbalance returned no result: $(rpc "/wallet/w1" getbalance | head -c 200)"
BAL_BEFORE_SATS=$(btc_to_sats "$BAL_BEFORE_BTC")
log "getbalance BEFORE = $BAL_BEFORE_BTC BTC ($BAL_BEFORE_SATS sats)"
EXPECT_FUNDED_SATS=$(( FUNDED_BTC * 100000000 ))
[[ "$BAL_BEFORE_SATS" -eq "$EXPECT_FUNDED_SATS" ]] \
    || fail "getbalance $BAL_BEFORE_SATS sats != expected mature $EXPECT_FUNDED_SATS sats (coinbase maturity not enforced?)"

# ── 7. listunspent lists the owned UTXOs. ──────────────────────────────────
LU_BEFORE=$(rpc "/wallet/w1" listunspent)
echo "$LU_BEFORE" | grep -q '"error":{' && fail "listunspent error: $(echo "$LU_BEFORE" | grep -o '"message":"[^"]*"' | head -1)"
N_BEFORE=$(count_unspent "$LU_BEFORE")
[[ "${N_BEFORE:-0}" -gt 0 ]] || fail "listunspent returned 0 UTXOs after funding"
log "listunspent BEFORE = $N_BEFORE UTXOs"

# ── 8. Negative control: foreign recipient holds nothing yet. ──────────────
r=$(rpc "/" scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]")
PRE_RECIP_SATS=$(scan_total_sats "$r")
log "recipient PRE-spend on-chain = ${PRE_RECIP_SATS:-?} sats"
[[ "${PRE_RECIP_SATS:-0}" -eq 0 ]] || fail "recipient already funded before spend (${PRE_RECIP_SATS} sats)"

# ── 9. sendtoaddress -> txid, tx enters mempool. ───────────────────────────
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR (from w1)"
SEND=$(rpc "/wallet/w1" sendtoaddress "[\"$FOREIGN_ADDR\",$SEND_BTC]")
echo "$SEND" | grep -q '"error":{' \
    && fail "sendtoaddress error: $(echo "$SEND" | grep -o '"message":"[^"]*"' | head -1)"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
[[ "$TXID" =~ ^0+$ ]] && fail "sendtoaddress returned an all-zero placeholder txid (tx not built/broadcast)"
log "TXID=$TXID"

MEMPOOL=$(rpc "/" getrawmempool)
echo "$MEMPOOL" | grep -q "$TXID" || fail "tx $TXID not in mempool after sendtoaddress: $(echo "$MEMPOOL" | head -c 200)"
log "tx is in mempool"

# ── 10. Mine 1 block -> the tx CONFIRMS. ───────────────────────────────────
log "generatetoaddress 1 -> $A1 (confirm the spend)"
r=$(rpc "/" generatetoaddress "[1,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "confirm-block generate error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT2=$(result_num "$(rpc "/" getblockcount)")
[[ "${HEIGHT2:-0}" -gt "$HEIGHT" ]] || fail "height did not advance on confirm block"
log "height after confirm = $HEIGHT2"

# ── 11. Mempool no longer lists the confirmed tx (no wedge / re-broadcast). ─
MEMPOOL2=$(rpc "/" getrawmempool)
echo "$MEMPOOL2" | grep -q "$TXID" && fail "tx $TXID STILL in mempool after confirmation (mempool wedge)"
log "mempool cleared the confirmed tx"

# ── 12. Recipient credited <amt> on-chain (scantxoutset oracle). ───────────
r=$(rpc "/" scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]")
echo "$r" | grep -q '"error":{' && fail "scantxoutset recipient error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
RECIP_SATS=$(scan_total_sats "$r")
[[ -n "$RECIP_SATS" ]] || fail "scantxoutset recipient returned no total_amount"
log "recipient POST-spend on-chain = $RECIP_SATS sats (want $SEND_SATS)"
[[ "$RECIP_SATS" -eq "$SEND_SATS" ]] \
    || fail "recipient credited $RECIP_SATS sats != sent $SEND_SATS sats"

# ── 13. Sender getbalance dropped by amount + fee. ─────────────────────────
# Change returns to the wallet, so the net debit is exactly amount + fee.
# NOTE: mining the confirm block to A1 awards a NEW (immature) coinbase that
# does NOT count toward spendable balance, AND matures the height-2 coinbase
# (clearbit depth: tip 102 - height 2 = 100 >= COINBASE_MATURITY) which ADDS
# 50 BTC of newly-spendable balance. So the raw delta is not simply amount+fee.
# We back out the spend debit:
#   expected_after_nofee = before + matured_in - amount
#   debit_fee            = expected_after_nofee - after
# debit_fee must be positive (a real fee was paid) and small.
BAL_AFTER_BTC=$(result_num "$(rpc "/wallet/w1" getbalance)")
[[ -n "$BAL_AFTER_BTC" ]] || fail "getbalance AFTER returned no result"
BAL_AFTER_SATS=$(btc_to_sats "$BAL_AFTER_BTC")
log "getbalance AFTER = $BAL_AFTER_BTC BTC ($BAL_AFTER_SATS sats)"

MATURED_IN=$(( 50 * 100000000 ))   # height-2 coinbase matures at tip 102
EXPECTED_AFTER_NOFEE=$(( BAL_BEFORE_SATS + MATURED_IN - SEND_SATS ))
DEBIT_FEE=$(( EXPECTED_AFTER_NOFEE - BAL_AFTER_SATS ))
log "implied fee (sender debit beyond amount) = $DEBIT_FEE sats"
[[ "$DEBIT_FEE" -gt 0 ]] || fail "no fee debited (sender balance arithmetic wrong: before=$BAL_BEFORE_SATS after=$BAL_AFTER_SATS)"
[[ "$DEBIT_FEE" -lt 100000 ]] || fail "implied fee $DEBIT_FEE sats unreasonably large (balance accounting drift)"
SENDER_DEBITED=$(( SEND_SATS + DEBIT_FEE ))
log "sender debited amount+fee = $SENDER_DEBITED sats"

# ── 14. listunspent reflects the post-spend set. ───────────────────────────
LU_AFTER=$(rpc "/wallet/w1" listunspent)
echo "$LU_AFTER" | grep -q '"error":{' && fail "listunspent AFTER error"
N_AFTER=$(count_unspent "$LU_AFTER")
log "listunspent AFTER = $N_AFTER UTXOs (was $N_BEFORE)"
[[ "${N_AFTER:-0}" -gt 0 ]] || fail "listunspent AFTER is empty (ledger lost track of coins)"
[[ "$N_AFTER" != "$N_BEFORE" ]] || fail "listunspent count unchanged after spend+block (ledger not updating)"

# ── 15. Success. ───────────────────────────────────────────────────────────
log "PASS: funded=$FUNDED_BTC BTC sent=$SEND_BTC BTC recipient=$SEND_BTC BTC " \
    "sender_debited=$SENDER_DEBITED sats mempool=clean"
pass "$FUNDED_BTC" "$SEND_BTC" "$SEND_BTC" "$SENDER_DEBITED" "$DEBIT_FEE"

#!/usr/bin/env bash
#
# nimrod_spend.sh — self-contained wallet-native spend regression test.
#
# Codifies the "wallet can see and spend its own coins" cell for nimrod — the
# successor to the wallet-recovery cell (nimrod_recovery.sh). Proves the full
# on-chain spend round-trip on regtest using ONLY wallet-native RPCs:
#
#   createwallet w1 -> sethdseed <fixed seed> -> getnewaddress -> A1
#   generatetoaddress 101 -> A1        -> fund A1 with mined coinbase
#   getbalance                          -> reflects spendable (MATURE) coins
#                                          (Core wallet rule: a coinbase is
#                                          spendable once chain_depth >=
#                                          COINBASE_MATURITY+1 (101 confs);
#                                          at tip 101 only the height-1 coinbase
#                                          qualifies -> exactly 50 BTC)
#   listunspent                         -> lists the owned UTXOs
#   sendtoaddress <foreign-addr> <amt>  -> returns a txid, tx enters mempool
#   generatetoaddress 1 -> A1          -> the tx CONFIRMS
#   ASSERT:
#     * recipient address credited <amt>     (verified via scantxoutset, the
#       authoritative on-chain UTXO oracle — independent of wallet bookkeeping)
#     * sender getbalance net of the height-2 coinbase maturation dropped by
#       <amt>+fee (change returns to the wallet, so the spend debit is exactly
#       amount + fee)
#     * mempool no longer lists the confirmed tx (no BIP30 wedge / re-broadcast)
#     * listunspent reflects the post-spend set (count changed)
#
# Recipient is a FOREIGN regtest address (not in the nimrod wallet) so the
# recipient credit is proven purely on-chain via scantxoutset, and the single
# loaded wallet's getbalance is an honest sender-side measurement.
#
# STRICT UNIFORM INTERFACE (mirrors beamchain_spend.sh / nimrod_recovery.sh
# exactly): no required args, set -uo pipefail, idempotent, trap cleanup,
# scratch datadir + unique ports, single clean summary line on stdout. All
# noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: SPEND nimrod: PASS funded=<X> sent=<Y> recipient=<Y> sender_debited=<Y+fee> ...
#   FAIL: SPEND nimrod: FAIL <short reason>
#
# Touches ONLY /tmp/spendfleet-nimrod/ and ports 21611 (RPC) / 21631 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASEDIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # meta-repo root
NIMROD_BIN="$BASEDIR/nimrod/bin/nimrod"

DATADIR="/tmp/spendfleet-nimrod"
RPC_PORT=21611
P2P_PORT=21631
NETWORK="regtest"
COOKIE_FILE="$DATADIR/$NETWORK/.cookie"
LOGFILE="$DATADIR/node.log"

# FIXED raw 32-byte BIP-32 hex seed — the SAME seed the recovery cell uses, so
# the two tests share a wallet identity. Determinism is the point.
FIXED_SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

# Coinbase maturity on regtest is 100 blocks. Mine 101 so EXACTLY the first
# reward (height 1) is wallet-mature at tip 101. Core's WALLET rule treats a
# coinbase as spendable once chain_depth >= COINBASE_MATURITY+1 = 101 confs
# (CWallet::GetTxBlocksToMaturity); at tip 101 the height-1 coinbase has 101
# confs (mature -> 50 BTC) and the height-2 coinbase has 100 confs (still 1
# short -> immature). getbalance must therefore report 50 BTC, proving the
# wallet maturity gate is enforced. 50 BTC also funds a clean 10 BTC spend.
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
log() { echo "[spend-nimrod] $*" >&2; }

# ── Emit the single summary line + exit. ───────────────────────────────────
# pass <funded> <sent> <recipient> <sender_debited> <fee>
pass() {
    echo "SPEND nimrod: PASS funded=$1 sent=$2 recipient=$3 sender_debited=$4 fee_sats=$5 mempool=clean"
    exit 0
}
fail() {
    echo "SPEND nimrod: FAIL $*"
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
    rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── RPC helper (cookie auth). usage: rpc <method> [params-json] [wallet] ────
rpc() {
    local method="$1" params="${2:-[]}" wallet="${3:-}"
    local auth=""
    [[ -f "$COOKIE_FILE" ]] && auth="-u $(cat "$COOKIE_FILE")"
    local path="/"
    [[ -n "$wallet" ]] && path="/wallet/$wallet"
    # shellcheck disable=SC2086
    curl -s --max-time 40 $auth \
        -H 'content-type: text/plain' \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT$path" 2>/dev/null
}

# Pull the top-level "result" as a bare scalar string.
result_str() {
    JBLOB="$1" python3 -c '
import os, json
try:
    r = json.loads(os.environ["JBLOB"]).get("result")
    print("" if r is None else r)
except Exception:
    print("")
'
}

# Pull a numeric "result" scalar (int or float) as-is.
result_num() {
    JBLOB="$1" python3 -c '
import os, json
try:
    r = json.loads(os.environ["JBLOB"]).get("result")
    print("" if r is None else r)
except Exception:
    print("")
'
}

# Error message extractor (empty if no error).
err_msg() {
    JBLOB="$1" python3 -c '
import os, json
try:
    e = json.loads(os.environ["JBLOB"]).get("error")
    print(e.get("message","") if e else "")
except Exception:
    print("")
'
}

# Convert a BTC decimal string to integer satoshis (round to nearest sat).
btc_to_sats() {
    AMT="$1" python3 -c '
import os
amt = os.environ["AMT"]
if amt == "":
    raise SystemExit(1)
print(int(round(float(amt) * 100_000_000)))
'
}

# Pull total_amount (BTC) out of a scantxoutset reply, in satoshis.
scan_total_sats() {
    JBLOB="$1" python3 -c '
import os, json
try:
    r = json.loads(os.environ["JBLOB"]).get("result") or {}
    print(int(round(float(r.get("total_amount", 0)) * 100_000_000)))
except Exception:
    print("")
'
}

# Count entries in a listunspent reply.
count_unspent() {
    JBLOB="$1" python3 -c '
import os, json
try:
    print(len(json.loads(os.environ["JBLOB"]).get("result") or []))
except Exception:
    print(0)
'
}

# Whether a getrawmempool reply contains the given txid.
mempool_has() {
    JBLOB="$1" TXID="$2" python3 -c '
import os, json
try:
    r = json.loads(os.environ["JBLOB"]).get("result") or []
    print("yes" if os.environ["TXID"] in r else "no")
except Exception:
    print("no")
'
}

wait_for_rpc() {
    local deadline=$(( $(date +%s) + 45 ))
    while (( $(date +%s) < deadline )); do
        if [[ -f "$COOKIE_FILE" ]]; then
            local r
            r=$(rpc getblockcount)
            if echo "$r" | grep -q '"result"'; then
                return 0
            fi
        fi
        if [[ -n "$NODE_PID" ]] && ! kill -0 "$NODE_PID" 2>/dev/null; then
            return 1
        fi
        sleep 1
    done
    return 1
}

# ── 0. Preconditions. ───────────────────────────────────────────────────────
[[ -x "$NIMROD_BIN" ]] || fail "nimrod binary not found at $NIMROD_BIN (run: cd nimrod && nimble build -d:release -y)"
command -v curl >/dev/null 2>&1    || fail "curl not available"
command -v python3 >/dev/null 2>&1 || fail "python3 not available"

# ── 1. Idempotent reset + launch. ───────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

log "launching nimrod regtest -> $LOGFILE"
"$NIMROD_BIN" --network="$NETWORK" --datadir="$DATADIR" \
    --port="$P2P_PORT" --rpcport="$RPC_PORT" start \
    >"$LOGFILE" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"

kill -0 "$NODE_PID" 2>/dev/null || fail "node process exited immediately (see $LOGFILE)"
wait_for_rpc || fail "RPC did not come up within 45s (see $LOGFILE)"
log "RPC ready"

# ── 2. Create wallet w1, restore FIXED seed (sethdseed), derive A1. ─────────
log "createwallet w1"
r=$(rpc createwallet '["w1"]')
echo "$r" | grep -q '"result"' || fail "createwallet w1 failed: $(err_msg "$r")"

log "sethdseed (fixed seed) on w1"
r=$(rpc sethdseed "[true, \"$FIXED_SEED\"]" "w1")
if echo "$r" | grep -qi 'method not found'; then
    fail "sethdseed RPC missing — rebuild nimrod"
fi
echo "$r" | grep -q '"error":null' || fail "sethdseed w1 failed: $(err_msg "$r")"

log "getnewaddress on w1 (bech32 / P2WPKH) -> A1"
A1=$(result_str "$(rpc getnewaddress '[""]' "w1")")
# nimrod regtest emits the testnet tb1 HRP (a known quirk); accept any
# bech32-style segwit address — the spend semantics are what matter.
[[ -n "$A1" && "$A1" == *1q* ]] || fail "getnewaddress w1 invalid: '$A1'"
log "A1=$A1"

# ── 3. Fund A1 with coinbase. ───────────────────────────────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS, \"$A1\"]" "w1")
echo "$r" | grep -q '"result"' || fail "generatetoaddress failed: $(err_msg "$r")"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# ── 4. getbalance reflects spendable (MATURE) coins. ────────────────────────
# At tip 101 only the height-1 coinbase is wallet-mature -> exactly 50 BTC.
BAL_BEFORE_BTC=$(result_num "$(rpc getbalance '[]' "w1")")
[[ -n "$BAL_BEFORE_BTC" ]] || fail "getbalance returned no result"
BAL_BEFORE_SATS=$(btc_to_sats "$BAL_BEFORE_BTC") || fail "getbalance unparseable: '$BAL_BEFORE_BTC'"
log "getbalance BEFORE = $BAL_BEFORE_BTC BTC ($BAL_BEFORE_SATS sats)"
EXPECT_FUNDED_SATS=$(( FUNDED_BTC * 100000000 ))
[[ "$BAL_BEFORE_SATS" -eq "$EXPECT_FUNDED_SATS" ]] \
    || fail "getbalance $BAL_BEFORE_SATS sats != expected mature $EXPECT_FUNDED_SATS sats (coinbase maturity not enforced?)"

# ── 5. listunspent lists the owned UTXOs. ───────────────────────────────────
LU_BEFORE=$(rpc listunspent '[0]' "w1")
echo "$LU_BEFORE" | grep -q '"error":{' && fail "listunspent error: $(err_msg "$LU_BEFORE")"
N_BEFORE=$(count_unspent "$LU_BEFORE")
[[ "${N_BEFORE:-0}" -gt 0 ]] || fail "listunspent returned 0 UTXOs after funding"
log "listunspent BEFORE = $N_BEFORE UTXOs"

# ── 6. Negative control: foreign recipient holds nothing yet. ───────────────
r=$(rpc scantxoutset "[\"start\", [\"addr($FOREIGN_ADDR)\"]]")
PRE_RECIP_SATS=$(scan_total_sats "$r")
log "recipient PRE-spend on-chain = ${PRE_RECIP_SATS:-?} sats"
[[ "${PRE_RECIP_SATS:-0}" -eq 0 ]] || fail "recipient already funded before spend (${PRE_RECIP_SATS} sats)"

# ── 7. sendtoaddress -> txid, tx enters mempool. ────────────────────────────
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR (from w1)"
SEND=$(rpc sendtoaddress "[\"$FOREIGN_ADDR\", $SEND_BTC]" "w1")
echo "$SEND" | grep -q '"error":{' && fail "sendtoaddress error: $(err_msg "$SEND")"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
log "TXID=$TXID"

MEMPOOL=$(rpc getrawmempool)
[[ "$(mempool_has "$MEMPOOL" "$TXID")" == "yes" ]] \
    || fail "tx $TXID not in mempool after sendtoaddress: $(echo "$MEMPOOL" | head -c 200)"
log "tx is in mempool"

# ── 8. Mine 1 block -> the tx CONFIRMS. ─────────────────────────────────────
log "generatetoaddress 1 -> $A1 (confirm the spend)"
r=$(rpc generatetoaddress "[1, \"$A1\"]" "w1")
echo "$r" | grep -q '"error":{' && fail "confirm-block generate error: $(err_msg "$r")"
HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -gt "${HEIGHT:-0}" ]] || fail "height did not advance on confirm block (spend tx not mined? got $HEIGHT2 want > $HEIGHT)"
log "height after confirm = $HEIGHT2"

# ── 9. Mempool no longer lists the confirmed tx (no wedge / re-broadcast). ──
MEMPOOL2=$(rpc getrawmempool)
[[ "$(mempool_has "$MEMPOOL2" "$TXID")" == "no" ]] \
    || fail "tx $TXID STILL in mempool after confirmation (mempool wedge)"
log "mempool cleared the confirmed tx"

# ── 10. Recipient credited <amt> on-chain (scantxoutset oracle). ────────────
r=$(rpc scantxoutset "[\"start\", [\"addr($FOREIGN_ADDR)\"]]")
echo "$r" | grep -q '"error":{' && fail "scantxoutset recipient error: $(err_msg "$r")"
RECIP_SATS=$(scan_total_sats "$r")
[[ -n "$RECIP_SATS" ]] || fail "scantxoutset recipient returned no total_amount"
log "recipient POST-spend on-chain = $RECIP_SATS sats (want $SEND_SATS)"
[[ "$RECIP_SATS" -eq "$SEND_SATS" ]] \
    || fail "recipient credited $RECIP_SATS sats != sent $SEND_SATS sats"

# ── 11. Sender getbalance dropped by amount + fee. ──────────────────────────
# Change returns to the wallet, so the spend's net debit is exactly amount+fee.
# Mining the confirm block to A1 awards a NEW (immature) coinbase that does NOT
# count toward spendable balance, AND matures the height-2 coinbase (now 101
# confs) which ADDS 50 BTC of newly-spendable balance. So:
#   after = before + MATURED_IN(50 BTC) - SEND_SATS - fee
# We solve for the implied fee and assert it is positive (a real fee was paid)
# and small (regtest, ~1-2 input tx -> well under 100k sats). The on-chain
# transfer is already proven exact via scantxoutset above.
BAL_AFTER_BTC=$(result_num "$(rpc getbalance '[]' "w1")")
[[ -n "$BAL_AFTER_BTC" ]] || fail "getbalance AFTER returned no result"
BAL_AFTER_SATS=$(btc_to_sats "$BAL_AFTER_BTC") || fail "getbalance AFTER unparseable: '$BAL_AFTER_BTC'"
log "getbalance AFTER = $BAL_AFTER_BTC BTC ($BAL_AFTER_SATS sats)"

MATURED_IN=$(( 50 * 100000000 ))   # height-2 coinbase matures at tip 102
EXPECTED_AFTER_NOFEE=$(( BAL_BEFORE_SATS + MATURED_IN - SEND_SATS ))
DEBIT_FEE=$(( EXPECTED_AFTER_NOFEE - BAL_AFTER_SATS ))
log "implied fee (sender debit beyond amount) = $DEBIT_FEE sats"
[[ "$DEBIT_FEE" -gt 0 ]] || fail "no fee debited (sender balance arithmetic wrong: before=$BAL_BEFORE_SATS after=$BAL_AFTER_SATS)"
[[ "$DEBIT_FEE" -lt 100000 ]] || fail "implied fee $DEBIT_FEE sats unreasonably large (balance accounting drift)"
SENDER_DEBITED=$(( SEND_SATS + DEBIT_FEE ))
log "sender debited amount+fee = $SENDER_DEBITED sats"

# ── 12. listunspent reflects the post-spend set. ────────────────────────────
LU_AFTER=$(rpc listunspent '[0]' "w1")
echo "$LU_AFTER" | grep -q '"error":{' && fail "listunspent AFTER error"
N_AFTER=$(count_unspent "$LU_AFTER")
log "listunspent AFTER = $N_AFTER UTXOs (was $N_BEFORE)"
[[ "${N_AFTER:-0}" -gt 0 ]] || fail "listunspent AFTER is empty (ledger lost track of coins)"
[[ "$N_AFTER" != "$N_BEFORE" ]] || fail "listunspent count unchanged after spend+block (ledger not updating)"

# ── 13. Success. ─────────────────────────────────────────────────────────────
log "PASS: funded=$FUNDED_BTC BTC sent=$SEND_BTC BTC recipient=$SEND_BTC BTC sender_debited=$SENDER_DEBITED sats mempool=clean"
pass "$FUNDED_BTC" "$SEND_BTC" "$SEND_BTC" "$SENDER_DEBITED" "$DEBIT_FEE"

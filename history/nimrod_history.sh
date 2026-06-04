#!/usr/bin/env bash
#
# nimrod_history.sh — self-contained wallet transaction-history regression test.
#
# Codifies the "wallet reports its own transaction history" cell for nimrod —
# the successor to the wallet-spend cell (nimrod_spend.sh). Proves that, after
# real on-chain activity, the wallet surfaces its receive / coinbase / send
# transactions through listtransactions + gettransaction, Core-shaped, on
# regtest using ONLY wallet-native RPCs:
#
#   createwallet w1 -> sethdseed <fixed seed> -> getnewaddress -> A1
#   generatetoaddress 101 -> A1        -> coinbase history (generate/immature)
#   sendtoaddress <foreign-addr> 10    -> the wallet-native send (proven by the
#                                         spend cell), returns a txid
#   generatetoaddress 1 -> A1          -> the send tx CONFIRMS
#   ASSERT:
#     * listtransactions shows the SEND entry: category "send", amount == -10,
#       NEGATIVE fee, txid == the send txid (was [] before this cell).
#     * listtransactions shows COINBASE entries: category "generate"/"immature",
#       amount +50.
#     * gettransaction <send-txid> returns amount ~ -10, a NEGATIVE fee,
#       confirmations >= 1, and a details[] containing the send leg
#       (was absent/method-not-found before this cell).
#
# Field shapes + sign conventions match bitcoin-core/src/wallet/rpc/
# transactions.cpp (ListTransactions / WalletTxToJSON / gettransaction) and
# wallet/receive.cpp (CachedTxGetAmounts): send amount negative, send fee
# negative, receive/generate amount positive, generated=true for coinbase.
#
# Recipient is a FOREIGN regtest address (not in the nimrod wallet) so the send
# leg is an honest outbound transfer.
#
# STRICT UNIFORM INTERFACE (mirrors nimrod_spend.sh / nimrod_recovery.sh
# exactly): no required args, set -uo pipefail, idempotent, trap cleanup,
# scratch datadir + unique ports, single clean summary line on stdout. All
# noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: HISTORY nimrod: PASS sent_entry=yes recv_entries=<n> gettx=ok
#   FAIL: HISTORY nimrod: FAIL <short reason>
#
# Touches ONLY /tmp/histfleet-nimrod/ and ports 39761 (RPC) / 39781 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASEDIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # meta-repo root
NIMROD_BIN="$BASEDIR/nimrod/bin/nimrod"

DATADIR="/tmp/histfleet-nimrod"
RPC_PORT=39761
P2P_PORT=39781
NETWORK="regtest"
COOKIE_FILE="$DATADIR/$NETWORK/.cookie"
LOGFILE="$DATADIR/node.log"

# FIXED raw 32-byte BIP-32 hex seed — the SAME seed the recovery + spend cells
# use, so all three tests share a wallet identity. Determinism is the point.
FIXED_SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

# Mine 101 so EXACTLY the height-1 coinbase is wallet-mature at tip 101 (Core
# wallet rule: spendable once chain_depth >= COINBASE_MATURITY+1 = 101 confs).
NBLOCKS=101
SEND_BTC=10            # amount to send
SEND_SATS=1000000000   # 10 BTC in satoshis

# A foreign address NOT derived from our seed — the spend recipient.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""

# ── Logging: everything noisy goes to stderr + logfile, never stdout. ──────
log() { echo "[hist-nimrod] $*" >&2; }

# ── Emit the single summary line + exit. ───────────────────────────────────
pass() {
    # pass <recv_entries>
    echo "HISTORY nimrod: PASS sent_entry=yes recv_entries=$1 gettx=ok"
    exit 0
}
fail() {
    echo "HISTORY nimrod: FAIL $*"
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
fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
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
[[ -n "$A1" && "$A1" == *1q* ]] || fail "getnewaddress w1 invalid: '$A1'"
log "A1=$A1"

# ── 3. Fund A1 with coinbase. ───────────────────────────────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS, \"$A1\"]" "w1")
echo "$r" | grep -q '"result"' || fail "generatetoaddress failed: $(err_msg "$r")"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# ── 4. listtransactions BEFORE the send: must already show coinbase history. ─
# (Was [] before this cell because history was reconstructed from live UTXOs
# only and lacked any persistent ledger; assert coinbase entries are present
# and Core-shaped: category generate/immature, amount +50, generated=true.)
LT_BEFORE=$(rpc listtransactions '["*", 200, 0]' "w1")
echo "$LT_BEFORE" | grep -q '"error":{' && fail "listtransactions BEFORE error: $(err_msg "$LT_BEFORE")"
RECV_N=$(JBLOB="$LT_BEFORE" python3 -c '
import os, json
try:
    arr = json.loads(os.environ["JBLOB"]).get("result") or []
except Exception:
    print(0); raise SystemExit
n = 0
bad = ""
for e in arr:
    cat = e.get("category")
    if cat in ("generate", "immature"):
        amt = e.get("amount")
        gen = e.get("generated")
        if abs(float(amt) - 50.0) > 1e-8:
            bad = "coinbase amount %s != 50" % amt; break
        if gen is not True:
            bad = "coinbase generated flag missing/false"; break
        n += 1
if bad:
    print("ERR:" + bad)
else:
    print(n)
')
case "$RECV_N" in
    ERR:*) fail "coinbase history malformed: ${RECV_N#ERR:}";;
esac
[[ "${RECV_N:-0}" -ge 1 ]] || fail "listtransactions BEFORE shows no coinbase generate/immature entries (history empty?)"
log "listtransactions BEFORE: $RECV_N coinbase entries (generate/immature, +50, generated=true)"

# ── 5. sendtoaddress -> txid, tx enters mempool. ────────────────────────────
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR (from w1)"
SEND=$(rpc sendtoaddress "[\"$FOREIGN_ADDR\", $SEND_BTC]" "w1")
echo "$SEND" | grep -q '"error":{' && fail "sendtoaddress error: $(err_msg "$SEND")"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
log "TXID=$TXID"

MEMPOOL=$(rpc getrawmempool)
[[ "$(mempool_has "$MEMPOOL" "$TXID")" == "yes" ]] \
    || fail "tx $TXID not in mempool after sendtoaddress"
log "tx is in mempool"

# ── 6. Mine 1 block -> the send tx CONFIRMS (scan records the send history). ─
log "generatetoaddress 1 -> $A1 (confirm the spend)"
r=$(rpc generatetoaddress "[1, \"$A1\"]" "w1")
echo "$r" | grep -q '"error":{' && fail "confirm-block generate error: $(err_msg "$r")"
HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -gt "${HEIGHT:-0}" ]] || fail "height did not advance on confirm block (got $HEIGHT2 want > $HEIGHT)"
log "height after confirm = $HEIGHT2"

MEMPOOL2=$(rpc getrawmempool)
[[ "$(mempool_has "$MEMPOOL2" "$TXID")" == "no" ]] \
    || fail "tx $TXID STILL in mempool after confirmation (mempool wedge)"

# ── 7. listtransactions AFTER: must contain the SEND entry, Core-shaped. ────
# Core send leg: category "send", amount = -SEND_BTC (negative), fee negative,
# txid == TXID, confirmations >= 1, generated absent (not a coinbase).
LT_AFTER=$(rpc listtransactions '["*", 200, 0]' "w1")
echo "$LT_AFTER" | grep -q '"error":{' && fail "listtransactions AFTER error: $(err_msg "$LT_AFTER")"
SENT_CHECK=$(JBLOB="$LT_AFTER" TXID="$TXID" SEND_BTC="$SEND_BTC" python3 -c '
import os, json
arr = json.loads(os.environ["JBLOB"]).get("result") or []
txid = os.environ["TXID"]
want = float(os.environ["SEND_BTC"])
sends = [e for e in arr if e.get("category") == "send" and e.get("txid") == txid]
if not sends:
    print("ERR:no send entry for txid in listtransactions"); raise SystemExit
e = sends[0]
amt = float(e.get("amount"))
if abs(amt - (-want)) > 1e-8:
    print("ERR:send amount %s != -%s" % (amt, want)); raise SystemExit
fee = e.get("fee")
if fee is None:
    print("ERR:send entry has no fee field"); raise SystemExit
if float(fee) >= 0:
    print("ERR:send fee %s not negative" % fee); raise SystemExit
if int(e.get("confirmations", 0)) < 1:
    print("ERR:send confirmations < 1"); raise SystemExit
if "vout" not in e:
    print("ERR:send entry missing vout"); raise SystemExit
print("ok")
')
case "$SENT_CHECK" in
    ok) ;;
    ERR:*) fail "listtransactions send entry: ${SENT_CHECK#ERR:}";;
    *) fail "listtransactions send check produced no verdict";;
esac
log "listtransactions AFTER: send entry present (category=send, amount=-$SEND_BTC, fee<0, conf>=1)"

# Re-count coinbase entries AFTER (sanity: history still has them).
RECV_N_AFTER=$(JBLOB="$LT_AFTER" python3 -c '
import os, json
arr = json.loads(os.environ["JBLOB"]).get("result") or []
print(sum(1 for e in arr if e.get("category") in ("generate","immature")))
')
log "listtransactions AFTER: $RECV_N_AFTER coinbase entries"

# ── 8. gettransaction <send-txid>: amount ~ -10, negative fee, conf>=1, details[]. ─
GT=$(rpc gettransaction "[\"$TXID\"]" "w1")
if echo "$GT" | grep -qi 'method not found'; then
    fail "gettransaction RPC missing — rebuild nimrod"
fi
echo "$GT" | grep -q '"error":{' && fail "gettransaction error: $(err_msg "$GT")"
GT_CHECK=$(JBLOB="$GT" TXID="$TXID" SEND_BTC="$SEND_BTC" python3 -c '
import os, json
r = json.loads(os.environ["JBLOB"]).get("result")
if not isinstance(r, dict):
    print("ERR:gettransaction returned no object"); raise SystemExit
txid = os.environ["TXID"]
want = float(os.environ["SEND_BTC"])
amt = r.get("amount")
if amt is None:
    print("ERR:no amount"); raise SystemExit
# Core gettransaction amount for a pure send = nNet - nFee = -(sent) (change
# nets out; fee is excluded from amount and reported separately). Must be
# negative and at least the sent magnitude.
if float(amt) > -want + 1e-8:
    print("ERR:amount %s not <= -%s" % (amt, want)); raise SystemExit
fee = r.get("fee")
if fee is None:
    print("ERR:no fee (send must report fee)"); raise SystemExit
if float(fee) >= 0:
    print("ERR:fee %s not negative" % fee); raise SystemExit
if int(r.get("confirmations", 0)) < 1:
    print("ERR:confirmations < 1"); raise SystemExit
if r.get("txid") != txid:
    print("ERR:txid mismatch %s" % r.get("txid")); raise SystemExit
det = r.get("details")
if not isinstance(det, list) or len(det) == 0:
    print("ERR:details[] missing or empty"); raise SystemExit
sends = [d for d in det if d.get("category") == "send"]
if not sends:
    print("ERR:no send leg in details[]"); raise SystemExit
sd = sends[0]
if abs(float(sd.get("amount")) - (-want)) > 1e-8:
    print("ERR:details send amount %s != -%s" % (sd.get("amount"), want)); raise SystemExit
if "vout" not in sd:
    print("ERR:details send leg missing vout"); raise SystemExit
if not r.get("hex"):
    print("ERR:no hex field"); raise SystemExit
print("ok")
')
case "$GT_CHECK" in
    ok) ;;
    ERR:*) fail "gettransaction shape: ${GT_CHECK#ERR:}";;
    *) fail "gettransaction check produced no verdict";;
esac
log "gettransaction $TXID: amount<=-$SEND_BTC, fee<0, conf>=1, details[] has send leg, hex present"

# ── 9. Negative control: gettransaction on an unknown txid must error. ──────
FAKE_TXID="0000000000000000000000000000000000000000000000000000000000000001"
GT_NEG=$(rpc gettransaction "[\"$FAKE_TXID\"]" "w1")
echo "$GT_NEG" | grep -q '"error":{' \
    || fail "gettransaction on unknown txid did not error (should be 'non-wallet transaction id')"
log "gettransaction unknown-txid correctly errors"

# ── 10. Success. ─────────────────────────────────────────────────────────────
log "PASS: sent_entry=yes recv_entries=$RECV_N_AFTER gettx=ok"
pass "$RECV_N_AFTER"

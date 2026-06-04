#!/usr/bin/env bash
#
# blockbrew_history.sh — wallet TRANSACTION HISTORY regression test for
# blockbrew (Go). The next wallet-completeness cell after recovery (10/10) and
# spend (10/10): listtransactions + gettransaction must report the wallet's own
# receive/send/coinbase transactions in Bitcoin Core's shape.
#
# What this proves on regtest, using ONLY wallet-native RPCs:
#
#   createwallet w1 RESTORED <fixed mnemonic>  -> getnewaddress -> A1
#   generatetoaddress 101 -> A1                -> coinbase history (generate +
#                                                 immature credits)
#   sendtoaddress <foreign> 10  (wallet-native spend, proven by the spend cell)
#   generatetoaddress 1 -> A1                  -> the spend CONFIRMS
#   ASSERT:
#     * listtransactions shows the SEND entry: category "send", amount == -10,
#       NEGATIVE fee, txid == the send txid. (Was [] before — txcount stayed 0.)
#     * listtransactions shows COINBASE credits: category "generate"/"immature",
#       amount +50, generated=true.
#     * gettransaction <send-txid> returns amount ~ -10, a NEGATIVE fee,
#       confirmations >= 1, and a details[] containing the send.
#       (Was ABSENT before — gettransaction was not even dispatched.)
#
# Field shapes + sign conventions match Bitcoin Core's
# src/wallet/rpc/transactions.cpp (ListTransactions / gettransaction /
# WalletTxToJSON): amount NEGATIVE for "send", fee NEGATIVE and send-only,
# generated=true on coinbase credits, coinbase split into generate (>= 100
# confs) vs immature (< 100 confs).
#
# The fix this regresses: blockbrew's block-connect wallet scan
# (Wallet.ScanBlock, wired into chainMgr.SetOnBlockConnected by spend commit
# cbbbbde) already walked each connected block crediting/debiting wallet UTXOs.
# This extends the SAME scan to record a Core-shaped WalletTx history entry per
# wallet-relevant tx (txid, category, net amount, fee, block height/hash/time,
# per-output details, raw hex), with a symmetric removal on block-disconnect
# (UnscanBlock) for reorg safety. listtransactions is rewritten to the Core
# per-detail shape and gettransaction is implemented + dispatched.
#
# STRICT UNIFORM INTERFACE (mirrors blockbrew_spend.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: HISTORY blockbrew: PASS sent_entry=yes recv_entries=<n> gettx=ok
#   FAIL: HISTORY blockbrew: FAIL <short reason>
#
# Touches ONLY /tmp/histfleet-blockbrew/ and ports 39763 (RPC) / 39783 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
BIN="$BASEDIR/blockbrew/blockbrew"
DATADIR="/tmp/histfleet-blockbrew"
RPC_PORT=39763
P2P_PORT=39783
LOGFILE="$DATADIR/history-test.log"
URL="http://127.0.0.1:${RPC_PORT}"

# Canonical BIP-39 all-zero-entropy 12-word test mnemonic (valid checksum).
# Same FIXED seed as the recovery + spend cells so the cells share a wallet id.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# Mine 102 (not 101): the wallet's coin-selection maturity rule (spendable at
# confirmations >= 100, i.e. tipHeight - height + 1 >= 100) and the mempool's
# coinbase-maturity guard (age = tipHeight - height >= 100) differ by one at
# the exact tip-101 boundary, so a 101-block chain can have the wallet offer a
# coinbase the mempool then rejects. Mining one extra block sidesteps that
# pre-existing off-by-one and still produces BOTH matured (heights 1-3) and
# immature (heights 4-102) coinbase history entries plus ample mature coins for
# a clean 10 BTC send.
NBLOCKS=102
SEND_BTC=10              # amount to send
SEND_SATS=1000000000     # 10 BTC in satoshis

# A foreign address NOT derived from our seed — the spend recipient.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""
COOKIE=""
COOKIE_FILE="$DATADIR/regtest/.cookie"

# ── Logging: everything noisy goes to stderr + logfile, never stdout. ──────
log() { echo "[history] $*" >&2; }

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

# ── Emit the single summary line + exit. ───────────────────────────────────
pass() {
    echo "HISTORY blockbrew: PASS sent_entry=yes recv_entries=$1 gettx=ok"
    exit 0
}
fail() {
    echo "HISTORY blockbrew: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth; optional wallet path). ────────────────────────
# usage: rpc <method> <params-json> [wallet-name]
rpc() {
    local method="$1" params="${2:-[]}" wallet="${3:-}"
    local path=""
    [[ -n "$wallet" ]] && path="/wallet/$wallet"
    curl -s --max-time 40 ${COOKIE:+-u "$COOKIE"} \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "${URL}/${path#/}" 2>/dev/null
}

result_str() {
    echo "$1" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//'
}
result_num() {
    echo "$1" | grep -o '"result":[0-9.]*' | head -1 | sed 's/"result"://'
}

# Pull a numeric field out of a JSON object (first match), e.g. amount/fee.
json_num_field() {
    echo "$1" | grep -o "\"$2\":-\{0,1\}[0-9.][0-9.e-]*" | head -1 | sed "s/\"$2\"://"
}

# python helper for robust JSON parsing of listtransactions / gettransaction.
PY=python3

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -x "$BIN" ]] || fail "blockbrew binary not found/executable at $BIN (run build-all.sh blockbrew)"
command -v curl >/dev/null 2>&1 || fail "curl not available"
command -v "$PY" >/dev/null 2>&1 || fail "python3 not available"

# ── 2. Launch blockbrew on regtest. ────────────────────────────────────────
log "launching blockbrew (regtest) -> $DATADIR/node.log"
"$BIN" \
    -network=regtest -datadir="$DATADIR" \
    -listen="127.0.0.1:${P2P_PORT}" -rpcbind="127.0.0.1:${RPC_PORT}" \
    -maxoutbound=0 -nolisten \
    >"$DATADIR/node.log" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"

# ── 3. Locate the cookie + wait for RPC. ───────────────────────────────────
deadline=$(( $(date +%s) + 45 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$COOKIE" && -f "$COOKIE_FILE" ]]; then COOKIE=$(cat "$COOKIE_FILE"); fi
    if [[ -n "$COOKIE" ]]; then
        r=$(rpc getblockcount)
        if echo "$r" | grep -q '"result"'; then
            log "RPC ready: $r"
            break
        fi
    fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node exited during startup (see $DATADIR/node.log)"
    sleep 1
done
[[ -n "$COOKIE" ]] || fail "cookie never appeared within 45s"
r=$(rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "RPC never responded within 45s"

# ── 4. Restore wallet w1, derive A1. ───────────────────────────────────────
log "createwallet w1 RESTORED from fixed mnemonic"
CW="[\"w1\", false, false, \"\", false, true, false, \"\", \"\", \"$MNEMONIC\"]"
r=$(rpc createwallet "$CW")
echo "$r" | grep -q '"error":{' && fail "createwallet w1 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
echo "$r" | grep -q '"name":"w1"' || fail "createwallet w1 did not return name=w1: $(echo "$r" | head -c 200)"

log "getnewaddress on w1 (bech32/p2wpkh) -> A1"
A1=$(result_str "$(rpc getnewaddress "[]" "w1")")
[[ -n "$A1" ]] || fail "getnewaddress w1 returned no address"
case "$A1" in
    bcrt1*) : ;;
    *) fail "A1 not a regtest bech32 address: $A1" ;;
esac
log "A1=$A1"

# ── 5. Fund A1 with coinbase (builds coinbase history). ────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# ── 6. Coinbase history BEFORE the send: listtransactions must be NON-empty
#       and carry coinbase credits (generate/immature, amount +50, generated). ─
# Request the FULL history (count > 102 coinbases) so both matured (oldest,
# heights 1-3) and immature (newest) coinbase entries are in the page; the
# default count=10 would return only the most-recent (all immature) entries.
LT_PRE=$(rpc listtransactions "[\"*\", 200, 0]" "w1")
echo "$LT_PRE" | grep -q '"error":{' && fail "listtransactions(pre) error: $(echo "$LT_PRE" | grep -o '"message":"[^"]*"' | head -1)"
log "listtransactions(pre) = $(echo "$LT_PRE" | head -c 400)"

# Count coinbase credit entries and verify their shape via python.
COINBASE_INFO=$(echo "$LT_PRE" | "$PY" -c '
import sys, json
try:
    o = json.load(sys.stdin)
except Exception as e:
    print("ERR parse"); sys.exit(0)
res = o.get("result")
if not isinstance(res, list):
    print("ERR notlist"); sys.exit(0)
n = 0; bad = ""
gen_seen = imm_seen = False
for e in res:
    cat = e.get("category")
    if cat in ("generate", "immature"):
        n += 1
        if cat == "generate": gen_seen = True
        if cat == "immature": imm_seen = True
        if abs(float(e.get("amount", 0)) - 50.0) > 1e-9:
            bad = "coinbase amount != 50 (%s)" % e.get("amount")
        if e.get("generated") is not True:
            bad = "coinbase entry missing generated=true"
        if not e.get("txid"):
            bad = "coinbase entry missing txid"
if bad:
    print("ERR " + bad); sys.exit(0)
print("OK %d gen=%s imm=%s" % (n, gen_seen, imm_seen))
' )
log "coinbase-entry analysis: $COINBASE_INFO"
case "$COINBASE_INFO" in
    OK\ *) : ;;
    *) fail "coinbase history malformed: $COINBASE_INFO" ;;
esac
RECV_ENTRIES=$(echo "$COINBASE_INFO" | awk '{print $2}')
[[ "${RECV_ENTRIES:-0}" -gt 0 ]] || fail "no coinbase (generate/immature) entries in listtransactions before send"
# Maturity proof: at tip 101 there must be BOTH matured (generate) and immature
# coinbases present.
echo "$COINBASE_INFO" | grep -q "gen=True" || fail "no matured (generate) coinbase entry at tip 101"
echo "$COINBASE_INFO" | grep -q "imm=True" || fail "no immature coinbase entry at tip 101 (maturity split not applied)"

# ── 7. sendtoaddress -> txid, tx enters mempool. ───────────────────────────
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR (from w1)"
SEND=$(rpc sendtoaddress "[\"$FOREIGN_ADDR\",$SEND_BTC]" "w1")
echo "$SEND" | grep -q '"error":{' \
    && fail "sendtoaddress error: $(echo "$SEND" | grep -o '"message":"[^"]*"' | head -1)"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
log "send TXID=$TXID"

# ── 8. Mine 1 block -> the send CONFIRMS (scanned into wallet history). ────
log "generatetoaddress 1 -> $A1 (confirm the spend)"
r=$(rpc generatetoaddress "[1,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "confirm-block generate error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -gt "$HEIGHT" ]] || fail "height did not advance on confirm block"
log "height after confirm = $HEIGHT2"

# ── 9. listtransactions shows the SEND entry: send / -10 / negative fee /
#       txid == send txid. ──────────────────────────────────────────────────
LT_POST=$(rpc listtransactions "[\"*\", 30, 0]" "w1")
echo "$LT_POST" | grep -q '"error":{' && fail "listtransactions(post) error: $(echo "$LT_POST" | grep -o '"message":"[^"]*"' | head -1)"
log "listtransactions(post) = $(echo "$LT_POST" | head -c 600)"

SEND_CHECK=$(echo "$LT_POST" | TXID="$TXID" "$PY" -c '
import sys, os, json
txid = os.environ["TXID"]
try:
    o = json.load(sys.stdin)
except Exception:
    print("ERR parse"); sys.exit(0)
res = o.get("result")
if not isinstance(res, list):
    print("ERR notlist"); sys.exit(0)
hit = None
for e in res:
    if e.get("category") == "send" and e.get("txid") == txid:
        hit = e; break
if hit is None:
    print("ERR no send entry for txid"); sys.exit(0)
amt = float(hit.get("amount", 0))
if abs(amt - (-10.0)) > 1e-9:
    print("ERR send amount %s != -10" % amt); sys.exit(0)
fee = hit.get("fee", None)
if fee is None:
    print("ERR send entry has no fee"); sys.exit(0)
if float(fee) >= 0:
    print("ERR send fee not negative: %s" % fee); sys.exit(0)
if int(hit.get("confirmations", 0)) < 1:
    print("ERR send confs < 1"); sys.exit(0)
print("OK amt=%s fee=%s confs=%s" % (amt, fee, hit.get("confirmations")))
' )
log "send-entry analysis: $SEND_CHECK"
case "$SEND_CHECK" in
    OK\ *) : ;;
    *) fail "listtransactions send entry wrong: $SEND_CHECK" ;;
esac

# ── 10. gettransaction <send-txid>: amount ~ -10, negative fee, confs >= 1,
#        details[] with the send. ──────────────────────────────────────────
GT=$(rpc gettransaction "[\"$TXID\"]" "w1")
echo "$GT" | grep -q '"error":{' && fail "gettransaction error: $(echo "$GT" | grep -o '"message":"[^"]*"' | head -1)"
log "gettransaction = $(echo "$GT" | head -c 600)"

GT_CHECK=$(echo "$GT" | TXID="$TXID" "$PY" -c '
import sys, os, json
txid = os.environ["TXID"]
try:
    o = json.load(sys.stdin)
except Exception:
    print("ERR parse"); sys.exit(0)
r = o.get("result")
if not isinstance(r, dict):
    print("ERR notobj"); sys.exit(0)
if r.get("txid") != txid:
    print("ERR txid mismatch"); sys.exit(0)
amt = float(r.get("amount", 0))
# Core gettransaction amount = nNet - nFee = the value that LEFT the wallet,
# excluding the separately-reported fee. For this 10 BTC send it must be
# exactly -10.0 (the change returns to the wallet; the fee is the "fee" field).
# Allow a hair of float slack only.
if abs(amt - (-10.0)) > 1e-6:
    print("ERR gettx amount %s != -10.0 (Core nNet-nFee convention)" % amt); sys.exit(0)
fee = r.get("fee", None)
if fee is None:
    print("ERR gettx has no fee"); sys.exit(0)
if float(fee) >= 0:
    print("ERR gettx fee not negative: %s" % fee); sys.exit(0)
if int(r.get("confirmations", 0)) < 1:
    print("ERR gettx confs < 1"); sys.exit(0)
det = r.get("details")
if not isinstance(det, list) or len(det) == 0:
    print("ERR gettx details missing/empty"); sys.exit(0)
send_det = [d for d in det if d.get("category") == "send"]
if not send_det:
    print("ERR gettx details has no send"); sys.exit(0)
if not r.get("hex"):
    print("ERR gettx missing hex"); sys.exit(0)
print("OK amt=%s fee=%s confs=%s details=%d" % (amt, fee, r.get("confirmations"), len(det)))
' )
log "gettransaction analysis: $GT_CHECK"
case "$GT_CHECK" in
    OK\ *) : ;;
    *) fail "gettransaction shape wrong: $GT_CHECK" ;;
esac

# ── 11. Negative control: gettransaction on an unknown txid must error. ────
FAKE_TXID="0000000000000000000000000000000000000000000000000000000000000001"
GT_NEG=$(rpc gettransaction "[\"$FAKE_TXID\"]" "w1")
echo "$GT_NEG" | grep -q '"error":{' || fail "gettransaction on unknown txid did NOT error (should be 'non-wallet transaction id')"
log "negative control OK: unknown txid errors"

# ── 12. Success. ───────────────────────────────────────────────────────────
log "PASS: sent_entry=yes recv_entries=$RECV_ENTRIES gettx=ok"
pass "$RECV_ENTRIES"

#!/usr/bin/env bash
#
# beamchain_history.sh — self-contained wallet TRANSACTION-HISTORY regression
# test.
#
# Codifies the "wallet can report its own receive/send/coinbase transactions"
# cell — the successor to the wallet-spend cell (beamchain_spend.sh) and the
# wallet-recovery cell (beamchain_recovery.sh).  Proves that, after a real
# on-chain spend, the wallet surfaces its history Core-shaped via
# listtransactions + gettransaction:
#
#   restorewallet w1 <fixed mnemonic>  -> getnewaddress -> A1
#   generatetoaddress 101 -> A1        -> coinbase history (generate/immature)
#   sendtoaddress <foreign-addr> 10    -> the wallet-native send (txid)
#   generatetoaddress 1 -> A1          -> the send CONFIRMS
#   ASSERT:
#     * listtransactions (was []) now reports:
#         - the SEND entry: category "send", amount == -10.00000000,
#           NEGATIVE fee, txid == the send txid, confirmations >= 1
#         - coinbase entries: category "generate" (matured, +50) AND
#           "immature" (< 101 confs, +50)
#     * gettransaction <send-txid> (was ABSENT) returns:
#         - amount ~ -10 (net wallet effect), a NEGATIVE fee,
#           confirmations >= 1, blockhash/blockheight/blocktime,
#           a details[] containing the send line, and the raw hex.
#
# Field shapes + sign conventions follow Bitcoin Core
# (src/wallet/rpc/transactions.cpp ListTransactions / WalletTxToJSON /
# gettransaction): send amount NEGATIVE, send fee NEGATIVE (ValueFromAmount of
# outputs-inputs), coinbase credits POSITIVE with generated=true, exact
# 8-decimal amounts.
#
# Recipient is a FOREIGN regtest address (not in any beamchain wallet) so the
# send line is an honest out-of-wallet transfer; change returns to the wallet
# as a "receive" line.
#
# STRICT UNIFORM INTERFACE (mirrors beamchain_spend.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout.  All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: HISTORY beamchain: PASS sent_entry=yes recv_entries=<n> gettx=ok
#   FAIL: HISTORY beamchain: FAIL <short reason>
#
# Touches ONLY /tmp/histfleet-beamchain/ and ports 21666 (RPC) / 21686 (P2P).
# Disables the Prometheus metrics endpoint (metrics_port=0) so it never
# collides with a live mainnet beamchain node already bound to the default
# metrics port.  NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
DATADIR="/tmp/histfleet-beamchain"
RPC_PORT=21666
P2P_PORT=21686
LOGFILE="$DATADIR/history-test.log"

# Canonical BIP-39 all-zero-entropy 12-word test mnemonic (valid checksum).
# Same FIXED seed as the recovery + spend cells so the cells share a wallet
# identity.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# Coinbase maturity on regtest is 100 blocks.  Mine 101 so the height-1
# coinbase is mature (a "generate" entry, 50 BTC spendable) while the rest are
# immature ("immature" entries); 50 BTC also funds a clean 10 BTC spend.
NBLOCKS=101
SEND_BTC=10            # amount to send
SEND_SATS=1000000000   # 10 BTC in satoshis

# A foreign address NOT derived from our seed — the spend recipient.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""
COOKIE=""

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
    rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT

# ── Emit the single summary line + exit. ───────────────────────────────────
# pass <recv_entries>
pass() {
    echo "HISTORY beamchain: PASS sent_entry=yes recv_entries=$1 gettx=ok"
    exit 0
}
fail() {
    echo "HISTORY beamchain: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth; optional wallet path). ────────────────────────
# usage: rpc <method> <params-json> [wallet-name]
rpc() {
    local method="$1" params="${2:-[]}" wallet="${3:-}"
    local path="/"
    [[ -n "$wallet" ]] && path="/wallet/$wallet"
    curl -s --max-time 40 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT$path" 2>/dev/null
}

# Extract a numeric "result":N scalar from a JSON reply.
result_num() {
    echo "$1" | grep -o '"result":[0-9.]*' | head -1 | sed 's/"result"://'
}

# Extract a string "result":"..." from a JSON reply.
result_str() {
    echo "$1" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//'
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
rm -rf "$DATADIR"
mkdir -p "$DATADIR"
exec 3>>"$LOGFILE"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -f "$NODE_BIN" ]] || fail "release binary not found at $NODE_BIN (run build-all.sh beamchain)"
command -v python3 >/dev/null 2>&1 || fail "python3 required for JSON assertions"

# ── 2. Launch beamchain on regtest (metrics disabled — see header). ────────
cat >"$DATADIR/sys.config" <<ERLCFG
[
 {beamchain, [
   {network, regtest},
   {datadir, "$DATADIR"},
   {p2pport, $P2P_PORT},
   {rpcport, $RPC_PORT},
   {metrics_port, 0}
 ]},
 {kernel, [{logger_level, info}]},
 {sasl,   [{sasl_error_logger, false}]}
].
ERLCFG
cat >"$DATADIR/vm.args" <<ERLVM
-sname beamchain_histfleet_$$
-setcookie beamchain_histfleet
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest) -> $DATADIR/node.log"
RELX_CONFIG_PATH="$DATADIR/sys.config" VMARGS_PATH="$DATADIR/vm.args" \
    "$NODE_BIN" foreground >"$DATADIR/node.log" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"

# ── 3. Locate the cookie + wait for RPC. ───────────────────────────────────
deadline=$(( $(date +%s) + 45 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$COOKIE" ]]; then
        for c in "$DATADIR/regtest/.cookie" "$DATADIR/.cookie"; do
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
    kill -0 "$NODE_PID" 2>/dev/null || fail "node exited during startup (see $DATADIR/node.log)"
    sleep 1
done
[[ -n "$COOKIE" ]] || fail "cookie never appeared within 45s"
r=$(rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "RPC never responded within 45s"

# ── 4. Restore wallet w1, derive A1. ───────────────────────────────────────
log "restorewallet w1 from fixed mnemonic"
r=$(rpc restorewallet "[\"w1\",\"$MNEMONIC\"]")
echo "$r" | grep -q '"error":{' && fail "restorewallet w1 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

log "getnewaddress on w1 (bech32/p2wpkh) -> A1"
A1=$(result_str "$(rpc getnewaddress "[]" "w1")")
[[ -n "$A1" ]] || fail "getnewaddress w1 returned no address"
log "A1=$A1"

# ── 5. BEFORE control: listtransactions starts empty. ──────────────────────
LT_BEFORE=$(rpc listtransactions "[\"*\",200]" "w1")
echo "$LT_BEFORE" | grep -q '"error":{' && fail "listtransactions BEFORE error: $(echo "$LT_BEFORE" | grep -o '"message":"[^"]*"' | head -1)"
N_BEFORE=$(echo "$LT_BEFORE" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('result',[])))" 2>/dev/null)
log "listtransactions BEFORE funding = ${N_BEFORE:-?} entries"
[[ "${N_BEFORE:-x}" == "0" ]] || fail "listtransactions BEFORE funding expected 0 entries, got ${N_BEFORE:-?}"

# ── 6. Fund A1 with coinbase (generate/immature history). ──────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# ── 7. sendtoaddress -> the wallet-native send. ────────────────────────────
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR (from w1)"
SEND=$(rpc sendtoaddress "[\"$FOREIGN_ADDR\",$SEND_BTC]" "w1")
echo "$SEND" | grep -q '"error":{' \
    && fail "sendtoaddress error: $(echo "$SEND" | grep -o '"message":"[^"]*"' | head -1)"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
log "TXID=$TXID"

# ── 8. Mine 1 block -> the send CONFIRMS. ──────────────────────────────────
log "generatetoaddress 1 -> $A1 (confirm the spend)"
r=$(rpc generatetoaddress "[1,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "confirm-block generate error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -gt "$HEIGHT" ]] || fail "height did not advance on confirm block"
log "height after confirm = $HEIGHT2"

# ── 9. listtransactions now reports the SEND + coinbase history. ───────────
# Request a high count so the matured (oldest) coinbases are in the window.
LT=$(rpc listtransactions "[\"*\",200]" "w1")
echo "$LT" | grep -q '"error":{' && fail "listtransactions error: $(echo "$LT" | grep -o '"message":"[^"]*"' | head -1)"

# Hand the JSON to python3 for precise, sign-aware assertions of the Core shape.
# The reply is written to a file (not piped) so the python heredoc owns stdin
# cleanly — `python3 - <<'PY'` would otherwise consume the program text as stdin
# and leave json.load with nothing to read.
LT_FILE="$DATADIR/listtransactions.json"
printf '%s' "$LT" >"$LT_FILE"
ASSERT=$(python3 - "$TXID" "$SEND_SATS" "$LT_FILE" <<'PY'
import sys, json
txid = sys.argv[1]
send_sats = int(sys.argv[2])
try:
    with open(sys.argv[3]) as fh:
        data = json.load(fh)["result"]
except Exception as e:
    print("PARSE_ERROR " + str(e)); sys.exit(0)

def sats(x):  # BTC float -> integer sats (round to nearest)
    return int(round(float(x) * 1e8))

sends    = [e for e in data if e.get("category") == "send"]
generate = [e for e in data if e.get("category") == "generate"]
immature = [e for e in data if e.get("category") == "immature"]
receive  = [e for e in data if e.get("category") == "receive"]

# (a) exactly one send entry for our txid, amount == -SEND, fee negative.
mysend = [e for e in sends if e.get("txid") == txid]
if len(mysend) != 1:
    print("NO_SEND_ENTRY count=%d" % len(mysend)); sys.exit(0)
s = mysend[0]
if sats(s["amount"]) != -send_sats:
    print("SEND_AMOUNT amount=%s want=-%d" % (s["amount"], send_sats)); sys.exit(0)
if "fee" not in s or float(s["fee"]) >= 0:
    print("SEND_FEE_NOT_NEGATIVE fee=%s" % s.get("fee")); sys.exit(0)
if int(s.get("confirmations", 0)) < 1:
    print("SEND_CONFS confs=%s" % s.get("confirmations")); sys.exit(0)
for k in ("blockhash", "blockheight", "blocktime", "time"):
    if k not in s:
        print("SEND_MISSING_FIELD " + k); sys.exit(0)

# (b) coinbase history present: at least one mature "generate" (+50) and many
#     "immature" (+50) entries, all positive with generated=true.
if len(generate) < 1:
    print("NO_GENERATE_ENTRY"); sys.exit(0)
if len(immature) < 1:
    print("NO_IMMATURE_ENTRY"); sys.exit(0)
g = generate[0]
COINBASE_50BTC = 50 * 100_000_000  # 5_000_000_000 sats
if sats(g["amount"]) != COINBASE_50BTC:
    print("GENERATE_AMOUNT amount=%s want=50BTC" % g["amount"]); sys.exit(0)
if g.get("generated") is not True:
    print("GENERATE_NOT_FLAGGED generated=%s" % g.get("generated")); sys.exit(0)
im = immature[0]
if sats(im["amount"]) != COINBASE_50BTC:
    print("IMMATURE_AMOUNT amount=%s want=50BTC" % im["amount"]); sys.exit(0)

# Report the count of receive-side entries (generate+immature+receive).
recv_entries = len(generate) + len(immature) + len(receive)
print("OK recv_entries=%d generate=%d immature=%d receive=%d"
      % (recv_entries, len(generate), len(immature), len(receive)))
PY
)
log "listtransactions assertion: $ASSERT"
case "$ASSERT" in
    OK\ *) : ;;
    *) fail "listtransactions shape: $ASSERT" ;;
esac
RECV_ENTRIES=$(echo "$ASSERT" | sed -n 's/.*recv_entries=\([0-9]*\).*/\1/p')
[[ "${RECV_ENTRIES:-0}" -ge 1 ]] || fail "no receive-side history entries"

# ── 10. gettransaction <send-txid> returns the Core-shaped wallet view. ────
GT=$(rpc gettransaction "[\"$TXID\"]" "w1")
echo "$GT" | grep -q '"error":{' && fail "gettransaction error: $(echo "$GT" | grep -o '"message":"[^"]*"' | head -1)"

GT_FILE="$DATADIR/gettransaction.json"
printf '%s' "$GT" >"$GT_FILE"
GASSERT=$(python3 - "$TXID" "$SEND_SATS" "$GT_FILE" <<'PY'
import sys, json
txid = sys.argv[1]
send_sats = int(sys.argv[2])
try:
    with open(sys.argv[3]) as fh:
        r = json.load(fh)["result"]
except Exception as e:
    print("PARSE_ERROR " + str(e)); sys.exit(0)

def sats(x):
    return int(round(float(x) * 1e8))

# amount: net wallet effect ~ -10 BTC (send + change returned, minus fee).
if "amount" not in r:
    print("NO_AMOUNT"); sys.exit(0)
# Net amount should equal -(send + fee) = -10 BTC exactly (change cancels the
# matured-coin debit accounting), per Core's nNet - nFee.
if sats(r["amount"]) != -send_sats:
    print("AMOUNT amount=%s want=-%d" % (r["amount"], send_sats)); sys.exit(0)
# fee present and negative (the wallet funded the inputs -> a send).
if "fee" not in r or float(r["fee"]) >= 0:
    print("FEE_NOT_NEGATIVE fee=%s" % r.get("fee")); sys.exit(0)
if int(r.get("confirmations", 0)) < 1:
    print("CONFS confs=%s" % r.get("confirmations")); sys.exit(0)
for k in ("blockhash", "blockheight", "blocktime", "txid", "time", "details", "hex"):
    if k not in r:
        print("MISSING_FIELD " + k); sys.exit(0)
if r["txid"] != txid:
    print("TXID_MISMATCH got=%s" % r["txid"]); sys.exit(0)
det = r["details"]
if not isinstance(det, list) or len(det) < 1:
    print("DETAILS_EMPTY"); sys.exit(0)
# details must contain the send line (negative amount, category send).
sends = [d for d in det if d.get("category") == "send"]
if len(sends) < 1:
    print("DETAILS_NO_SEND"); sys.exit(0)
if sats(sends[0]["amount"]) != -send_sats:
    print("DETAILS_SEND_AMOUNT amount=%s" % sends[0]["amount"]); sys.exit(0)
if not r["hex"]:
    print("EMPTY_HEX"); sys.exit(0)
print("OK fee=%s amount=%s confs=%s" % (r["fee"], r["amount"], r["confirmations"]))
PY
)
log "gettransaction assertion: $GASSERT"
case "$GASSERT" in
    OK\ *) : ;;
    *) fail "gettransaction shape: $GASSERT" ;;
esac

# ── 11. Negative control: gettransaction on a non-wallet txid errors. ──────
BOGUS="0000000000000000000000000000000000000000000000000000000000000001"
NEG=$(rpc gettransaction "[\"$BOGUS\"]" "w1")
echo "$NEG" | grep -q '"error":{' || fail "gettransaction on a non-wallet txid did not error (expected RPC_INVALID_ADDRESS_OR_KEY)"
log "negative control: non-wallet txid correctly errored"

# ── 12. Success. ───────────────────────────────────────────────────────────
log "PASS: sent_entry=yes recv_entries=$RECV_ENTRIES gettx=ok"
pass "$RECV_ENTRIES"

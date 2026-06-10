#!/usr/bin/env bash
#
# hotbuns_history.sh — self-contained wallet TRANSACTION HISTORY regression test.
#
# Codifies the "wallet reports its own receive/send/coinbase history" cell for
# hotbuns — the next wallet-completeness cell after recovery and spend. Proves
# listtransactions + gettransaction report the wallet's own transactions
# Core-shaped, using ONLY wallet-native RPCs on regtest:
#
#   createwallet w1 <fixed mnemonic>   -> getnewaddress -> A1
#   generatetoaddress 101 -> A1        -> coinbase history (generate/immature)
#   sendtoaddress <foreign> 10         -> the wallet-native send (spend cell)
#   generatetoaddress 1 -> A1          -> the send CONFIRMS
#   ASSERT:
#     * listtransactions shows the SEND entry: category "send", amount == -10,
#       negative fee, txid == the send txid. (Was [] before.)
#     * listtransactions shows coinbase entries: category "generate"/"immature",
#       amount +50 each, generated=true.
#     * gettransaction <send-txid> returns amount ~ -10, a NEGATIVE fee,
#       confirmations >= 1, and a details[] containing the send. (Was absent.)
#
# Recipient is a FOREIGN regtest address (not in any hotbuns wallet) so the
# "send" line is an honest outgoing transfer, never confused with change.
#
# STRICT UNIFORM INTERFACE (mirrors hotbuns_spend.sh exactly): no required args,
# idempotent, trap cleanup, scratch datadir + unique ports, single clean summary
# line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: HISTORY hotbuns: PASS sent_entry=yes recv_entries=<n> gettx=ok
#   FAIL: HISTORY hotbuns: FAIL <short reason>
#
# Touches ONLY /tmp/histfleet-hotbuns/ and ports 21664 (RPC) / 21684 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_DIR="$BASEDIR/hotbuns"
DATADIR="/tmp/histfleet-hotbuns"
RPC_PORT=21664
P2P_PORT=21684
LOGFILE="$DATADIR/node.log"

# Canonical BIP-39 all-zero-entropy 12-word test mnemonic (valid checksum) —
# the SAME FIXED seed the recovery + spend cells use (shared wallet identity).
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# Mine 101 so the height-1 coinbase is mature (generate) at tip 101 while the
# rest stay immature; 50 BTC also funds a clean 10 BTC spend.
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
trap cleanup EXIT INT TERM

# ── Emit the single summary line + exit. ───────────────────────────────────
# pass <recv_entries>
pass() {
    echo "HISTORY hotbuns: PASS sent_entry=yes recv_entries=$1 gettx=ok"
    exit 0
}
fail() {
    echo "HISTORY hotbuns: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth). ──────────────────────────────────────────────
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

# Convert a BTC decimal string to integer satoshis (handles a leading '-').
btc_to_sats() {
    local amt="$1" sign=1 whole frac
    [[ -z "$amt" ]] && { echo ""; return 1; }
    if [[ "$amt" == -* ]]; then sign=-1; amt="${amt#-}"; fi
    whole="${amt%%.*}"
    if [[ "$amt" == *.* ]]; then frac="${amt#*.}"; else frac="0"; fi
    frac="${frac}00000000"; frac="${frac:0:8}"
    whole=$((10#${whole:-0})); frac=$((10#${frac:-0}))
    echo $(( sign * (whole * 100000000 + frac) ))
}

# Pull the python json module out to slice JSON precisely — bun nodes emit
# compact JSON but the history entries are nested arrays/objects, so grep alone
# is brittle. Use python3 if present; otherwise fall back to grep heuristics.
HAVE_PY=0
command -v python3 >/dev/null 2>&1 && HAVE_PY=1

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

# ── 2. Launch hotbuns on regtest. ──────────────────────────────────────────
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
log "createwallet w1 from fixed mnemonic"
r=$(rpc createwallet "[\"w1\", false, false, \"\", false, true, false, \"$MNEMONIC\", \"\"]")
echo "$r" | grep -q '"name":"w1"' || fail "createwallet w1 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

log "getnewaddress on w1 -> A1"
A1=$(result_str "$(rpc getnewaddress)")
[[ -n "$A1" ]] || fail "getnewaddress returned no address"
log "A1=$A1"

# ── 5. Fund A1 with coinbase (history of generate/immature entries). ───────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS, \"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# ── 6. listtransactions shows coinbase (generate/immature) entries. ────────
# Ask for a large count so the coinbase history is returned (101 coinbases).
LT=$(rpc listtransactions "[\"*\", 200, 0]")
echo "$LT" | grep -q '"error":{' && fail "listtransactions error: $(echo "$LT" | grep -o '"message":"[^"]*"' | head -1)"
log "listtransactions (post-fund) bytes=${#LT}"

if [[ "$HAVE_PY" -eq 1 ]]; then
    RECV_N=$(echo "$LT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)["result"]
except Exception as e:
    print(0); sys.exit(0)
n = sum(1 for e in d if e.get("category") in ("generate","immature"))
print(n)
')
else
    RECV_N=$(echo "$LT" | grep -o '"category":"generate"\|"category":"immature"' | wc -l | tr -d ' ')
fi
log "coinbase-credit entries in listtransactions = ${RECV_N:-0}"
[[ "${RECV_N:-0}" -gt 0 ]] || fail "listtransactions has no coinbase (generate/immature) entries after funding (was [] before?)"

# Assert at least one MATURE coinbase ('generate') with amount +50.
if [[ "$HAVE_PY" -eq 1 ]]; then
    GEN_OK=$(echo "$LT" | python3 -c '
import sys, json
d = json.load(sys.stdin)["result"]
ok = any(e.get("category")=="generate" and abs(e.get("amount",0)-50.0)<1e-6 and e.get("generated") is True for e in d)
print("yes" if ok else "no")
')
    [[ "$GEN_OK" == "yes" ]] || fail "no mature coinbase entry (category=generate, amount=50, generated=true) in listtransactions"
    log "mature coinbase (generate, +50, generated=true) present"
fi

# ── 7. sendtoaddress -> txid (the wallet-native send). ─────────────────────
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR (from w1)"
SEND=$(rpc sendtoaddress "[\"$FOREIGN_ADDR\", $SEND_BTC]")
echo "$SEND" | grep -q '"error":{' \
    && fail "sendtoaddress error: $(echo "$SEND" | grep -o '"message":"[^"]*"' | head -1)"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
log "send TXID=$TXID"

# ── 8. Mine 1 block -> the send CONFIRMS (and is recorded in history). ─────
log "generatetoaddress 1 -> $A1 (confirm the send)"
r=$(rpc generatetoaddress "[1, \"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "confirm-block generate error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -gt "$HEIGHT" ]] || fail "height did not advance on confirm block"
log "height after confirm = $HEIGHT2"

# ── 9. listtransactions shows the SEND entry (category send, amount -10). ──
LT2=$(rpc listtransactions "[\"*\", 200, 0]")
echo "$LT2" | grep -q '"error":{' && fail "listtransactions (post-send) error"

if [[ "$HAVE_PY" -eq 1 ]]; then
    SEND_CHECK=$(echo "$LT2" | TXID="$TXID" python3 -c '
import sys, os, json
txid = os.environ["TXID"]
d = json.load(sys.stdin)["result"]
sends = [e for e in d if e.get("category")=="send" and e.get("txid")==txid]
if not sends:
    print("FAIL no send entry for txid"); sys.exit(0)
e = sends[0]
amt = e.get("amount")
fee = e.get("fee")
conf = e.get("confirmations", 0)
if amt is None or abs(amt - (-10.0)) > 1e-6:
    print("FAIL send amount %r != -10" % amt); sys.exit(0)
if fee is None or fee >= 0:
    print("FAIL send fee %r not negative" % fee); sys.exit(0)
if conf < 1:
    print("FAIL send confirmations %r < 1" % conf); sys.exit(0)
print("OK")
')
    [[ "$SEND_CHECK" == "OK" ]] || fail "listtransactions send entry wrong: $SEND_CHECK"
    log "listtransactions SEND entry: category=send amount=-10 fee<0 conf>=1 txid matches"
else
    # grep fallback: the send txid must appear alongside a send category.
    echo "$LT2" | grep -q "\"txid\":\"$TXID\"" || fail "send txid $TXID absent from listtransactions"
    echo "$LT2" | grep -q '"category":"send"' || fail "no send-category entry in listtransactions"
    log "listtransactions contains send txid + a send category (grep fallback)"
fi

# Recount coinbase-credit entries (should still be present post-send).
if [[ "$HAVE_PY" -eq 1 ]]; then
    RECV_N=$(echo "$LT2" | python3 -c '
import sys, json
d = json.load(sys.stdin)["result"]
print(sum(1 for e in d if e.get("category") in ("generate","immature","receive")))
')
fi

# ── 10. gettransaction <send-txid> -> amount ~ -10, negative fee, details[]. ─
GT=$(rpc gettransaction "[\"$TXID\"]")
echo "$GT" | grep -q '"error":{' && fail "gettransaction error: $(echo "$GT" | grep -o '"message":"[^"]*"' | head -1)"
log "gettransaction bytes=${#GT}"

if [[ "$HAVE_PY" -eq 1 ]]; then
    GT_CHECK=$(echo "$GT" | TXID="$TXID" python3 -c '
import sys, os, json
txid = os.environ["TXID"]
r = json.load(sys.stdin)["result"]
amt = r.get("amount")
fee = r.get("fee")
conf = r.get("confirmations", 0)
det = r.get("details")
if r.get("txid") != txid:
    print("FAIL gettransaction txid mismatch %r" % r.get("txid")); sys.exit(0)
# amount = net - fee = -(10 + fee_abs); must be <= -10 and close to -10.
if amt is None or amt > -10.0 + 1e-6 or amt < -10.5:
    print("FAIL gettransaction amount %r not ~ -10" % amt); sys.exit(0)
if fee is None or fee >= 0:
    print("FAIL gettransaction fee %r not negative" % fee); sys.exit(0)
if conf < 1:
    print("FAIL gettransaction confirmations %r < 1" % conf); sys.exit(0)
if not isinstance(det, list) or not any(x.get("category")=="send" for x in det):
    print("FAIL gettransaction details[] has no send line: %r" % det); sys.exit(0)
if not r.get("hex"):
    print("FAIL gettransaction missing hex"); sys.exit(0)
print("OK")
')
    [[ "$GT_CHECK" == "OK" ]] || fail "gettransaction shape wrong: $GT_CHECK"
    log "gettransaction: amount~-10, fee<0, conf>=1, details[] has send, hex present"
else
    echo "$GT" | grep -q "\"txid\":\"$TXID\"" || fail "gettransaction did not return the requested txid"
    echo "$GT" | grep -q '"details"' || fail "gettransaction missing details[]"
    echo "$GT" | grep -q '"fee":-' || fail "gettransaction fee not negative"
    log "gettransaction returns txid + details + negative fee (grep fallback)"
fi

# ── 11. Negative control: gettransaction on a non-wallet txid must error. ──
FAKE="0000000000000000000000000000000000000000000000000000000000000001"
GTN=$(rpc gettransaction "[\"$FAKE\"]")
echo "$GTN" | grep -q '"error":{' || fail "gettransaction on unknown txid did not error (got: $(echo "$GTN" | head -c 120))"
log "gettransaction on non-wallet txid correctly errors"

# ── 12. Success. ───────────────────────────────────────────────────────────
log "PASS: sent_entry=yes recv_entries=${RECV_N:-?} gettx=ok"
pass "${RECV_N:-0}"

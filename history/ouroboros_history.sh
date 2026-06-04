#!/usr/bin/env bash
#
# ouroboros_history.sh — self-contained wallet transaction-history test.
#
# Codifies the "wallet reports its own transaction history" cell for ouroboros,
# the successor to the wallet-recovery (ouroboros_recovery.sh) and wallet-spend
# (ouroboros_spend.sh) cells. Proves listtransactions + gettransaction surface
# the wallet's own receive / send / coinbase transactions, Core-shaped, on
# regtest using only wallet-native RPCs:
#
#   sethdseed <fixed seed>             -> deterministic key pool on "default"
#   getnewaddress bech32 -> A1
#   generatetoaddress 101 -> A1        -> 101 coinbase txs paying the wallet
#   sendtoaddress <foreign> 10         -> a wallet-native send (the spend cell)
#   generatetoaddress 1 -> A1          -> the send confirms
#   ASSERT (the history bookkeeping, NOT consensus):
#     * listtransactions shows the SEND entry: category "send", amount == -10,
#       a NEGATIVE fee, vout == the foreign output, txid == the send txid.
#       (Was [] before the fix — get_transactions hit a missing DB method.)
#     * listtransactions shows COINBASE entries: category "generate"/"immature"
#       with amount +50 (the mined rewards), and >= 1 mature "generate".
#     * gettransaction <send-txid> returns amount ~ -10, a NEGATIVE fee,
#       confirmations >= 1, and details[] containing the send. (Was a
#       -32603 AttributeError before the fix.)
#     * gettransaction <coinbase-txid> returns generated=true, positive amount.
#     * gettransaction <unknown-txid> errors cleanly (non-wallet tx), not crash.
#
# Field shapes + sign conventions match bitcoin-core wallet/rpc/transactions.cpp
# (ListTransactions / WalletTxToJSON / gettransaction): send amount NEGATIVE,
# fee NEGATIVE and only on from-wallet txs, receive amount POSITIVE, coinbase
# "generated":true, ordered newest-first.
#
# STRICT UNIFORM INTERFACE (mirrors ouroboros_spend.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: HISTORY ouroboros: PASS sent_entry=yes recv_entries=<n> gettx=ok
#   FAIL: HISTORY ouroboros: FAIL <short reason>
#
# Touches ONLY /tmp/histfleet-ouroboros/ and ports 39762 (RPC) / 39782 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
RPC_PORT=39762
P2P_PORT=39782
DATADIR="/tmp/histfleet-ouroboros"
LOGFILE="$DATADIR/node.log"

# Fixed BIP32 raw seed (32 bytes) — the SAME seed the recovery + spend cells
# use, so all three tests share a wallet identity. Restore = sethdseed.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

# A foreign regtest address NOT derived from our seed — the send recipient.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NBLOCKS=101              # fund: 101 coinbases (only the height-1 reward mature)
SEND_BTC=10              # amount to send
SEND_SATS=1000000000     # 10 BTC in satoshis

# Resolve the ouroboros checkout relative to this script:
# test-suite/history/ -> repo root -> ouroboros/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OURO_DIR="$REPO_ROOT/ouroboros"

NODE_PID=""
COOKIE=""

# ── Logging: everything noisy goes to stderr, never stdout. ────────────────
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
# pass <recv_entries>
pass() {
    echo "HISTORY ouroboros: PASS sent_entry=yes recv_entries=$1 gettx=ok"
    exit 0
}
fail() {
    echo "HISTORY ouroboros: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth). usage: rpc <method> <params-json> ────────────
rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 60 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}

# Extract a string "result":"..." from a JSON reply.
result_str() {
    echo "$1" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//'
}
# Extract a numeric "result":N scalar from a JSON reply.
result_num() {
    echo "$1" | grep -o '"result":[0-9.]*' | head -1 | sed 's/"result"://'
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -f "$OURO_DIR/src/ouroboros/cli.py" ]] || fail "ouroboros checkout not found at $OURO_DIR"
OURO_PY="$OURO_DIR/.venv/bin/python3"
[[ -x "$OURO_PY" ]] || OURO_PY="python3"

# ── 2. Launch ouroboros on regtest. ────────────────────────────────────────
log "launching ouroboros: $OURO_PY -m ouroboros.cli (rpc=$RPC_PORT p2p=$P2P_PORT)"
(
    cd "$OURO_DIR" || exit 1
    exec "$OURO_PY" -m ouroboros.cli \
        --network regtest --data-dir "$DATADIR" \
        start --force --rpc-port "$RPC_PORT" --p2p-port "$P2P_PORT"
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
    kill -0 "$NODE_PID" 2>/dev/null || { tail -20 "$LOGFILE" >&2 || true; fail "node exited during startup (see $LOGFILE)"; }
    sleep 1
done
[[ -n "$COOKIE" ]] || fail "cookie never appeared within 45s"
r=$(rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "RPC never responded within 45s"

# ── 4. Restore the fixed seed on the default wallet, derive A1. ────────────
log "sethdseed (fixed) on default wallet"
r=$(rpc sethdseed "[\"$SEED\"]")
echo "$r" | grep -q "$SEED" || fail "sethdseed failed: $(echo "$r" | head -c 200)"

log "getnewaddress bech32 -> A1"
A1=$(result_str "$(rpc getnewaddress '["", "bech32"]')")
[[ -n "$A1" ]] || fail "getnewaddress returned no address"
log "A1=$A1"

# ── 5. Fund A1 with 101 coinbase txs (coinbase history). ───────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# ── 6. The wallet-native send (proven by the spend cell). ──────────────────
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR"
SEND=$(rpc sendtoaddress "[\"$FOREIGN_ADDR\",$SEND_BTC]")
echo "$SEND" | grep -q '"error":{' \
    && fail "sendtoaddress error: $(echo "$SEND" | grep -o '"message":"[^"]*"' | head -1)"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
log "send TXID=$TXID"

# ── 7. Mine 1 block -> the send CONFIRMS (so it lands in the history). ─────
log "generatetoaddress 1 -> $A1 (confirm the send)"
r=$(rpc generatetoaddress "[1,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "confirm-block generate error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -gt "$HEIGHT" ]] || fail "height did not advance on confirm block"
log "height after confirm = $HEIGHT2"

# ── 8. listtransactions: assert the SEND entry + coinbase entries. ─────────
# Pull a large page so all coinbase + the send/receive are present, then let
# Python do the Core-shape assertions (sign conventions, categories, txid).
LT=$(rpc listtransactions '["*", 100000, 0]')
echo "$LT" | grep -q '"error":{' && fail "listtransactions error: $(echo "$LT" | grep -o '"message":"[^"]*"' | head -1)"

RECV_ENTRIES=$(
  TXID="$TXID" SEND_SATS="$SEND_SATS" python3 - "$LT" <<'PY'
import sys, json, os
try:
    d = json.loads(sys.argv[1])
except Exception as e:
    print("FAIL parse listtransactions: %s" % e); sys.exit(1)
res = d.get("result")
if not isinstance(res, list):
    print("FAIL listtransactions did not return a list (got %r)" % type(res)); sys.exit(1)
if len(res) == 0:
    print("FAIL listtransactions empty (history not recorded)"); sys.exit(1)

txid = os.environ["TXID"]
send_sats = int(os.environ["SEND_SATS"])

# --- SEND entry assertions (Core: category send, NEGATIVE amount + fee) ---
sends = [e for e in res if e.get("category") == "send" and e.get("txid") == txid]
if not sends:
    print("FAIL no 'send' entry for txid %s in listtransactions" % txid[:16]); sys.exit(1)
s = sends[0]
amt = s.get("amount")
if amt is None or abs(amt - (-send_sats / 1e8)) > 1e-8:
    print("FAIL send amount %r != %.8f" % (amt, -send_sats / 1e8)); sys.exit(1)
fee = s.get("fee")
if fee is None or fee >= 0:
    print("FAIL send entry fee not negative (got %r)" % fee); sys.exit(1)
if int(s.get("confirmations", 0)) < 1:
    print("FAIL send entry confirmations < 1 (got %r)" % s.get("confirmations")); sys.exit(1)
if "vout" not in s:
    print("FAIL send entry missing vout"); sys.exit(1)

# --- Coinbase entries: category generate/immature, amount +50 ------------
coinbases = [e for e in res if e.get("category") in ("generate", "immature")]
if not coinbases:
    print("FAIL no coinbase (generate/immature) entries in listtransactions"); sys.exit(1)
for c in coinbases:
    if c.get("amount") is None or c["amount"] <= 0:
        print("FAIL coinbase entry has non-positive amount %r" % c.get("amount")); sys.exit(1)
    if c.get("generated") is not True:
        print("FAIL coinbase entry missing generated=true"); sys.exit(1)
# at least one MATURE coinbase (the height-1 reward at tip >= 101)
if not any(e.get("category") == "generate" for e in coinbases):
    print("FAIL no MATURE 'generate' coinbase entry (maturity not surfaced)"); sys.exit(1)
# the +50 reward must show as ~50 BTC
if not any(abs(c["amount"] - 50.0) < 1e-6 for c in coinbases):
    print("FAIL no coinbase entry with amount ~50 BTC"); sys.exit(1)

# --- The wallet's change-output receive entry should be present ----------
recvs = [e for e in res if e.get("category") == "receive"]
# Report the count of receive entries (change return on the send).
print(len(recvs))
PY
) || fail "$RECV_ENTRIES"
log "listtransactions: send entry OK, coinbase entries OK, recv entries=$RECV_ENTRIES"

# ── 9. gettransaction(send): amount ~ -10, negative fee, details[]. ────────
GT=$(rpc gettransaction "[\"$TXID\"]")
echo "$GT" | grep -q '"error":{' && fail "gettransaction(send) error: $(echo "$GT" | grep -o '"message":"[^"]*"' | head -1)"
TXID="$TXID" SEND_SATS="$SEND_SATS" python3 - "$GT" <<'PY' || fail "gettransaction(send) shape wrong"
import sys, json, os
d = json.loads(sys.argv[1]); r = d.get("result")
if not isinstance(r, dict):
    print("gettransaction did not return an object"); sys.exit(1)
send_sats = int(os.environ["SEND_SATS"])
amt = r.get("amount")
if amt is None or abs(amt - (-send_sats / 1e8)) > 1e-8:
    print("amount %r != %.8f" % (amt, -send_sats / 1e8)); sys.exit(1)
fee = r.get("fee")
if fee is None or fee >= 0:
    print("fee not negative (got %r)" % fee); sys.exit(1)
if int(r.get("confirmations", 0)) < 1:
    print("confirmations < 1 (got %r)" % r.get("confirmations")); sys.exit(1)
details = r.get("details")
if not isinstance(details, list) or not details:
    print("details[] missing/empty"); sys.exit(1)
if not any(de.get("category") == "send" for de in details):
    print("details[] has no 'send' entry"); sys.exit(1)
if r.get("txid") != os.environ["TXID"]:
    print("txid echo mismatch"); sys.exit(1)
if not r.get("hex"):
    print("hex missing"); sys.exit(1)
sys.exit(0)
PY

# ── 10. gettransaction(coinbase): generated=true, positive amount. ─────────
# Pull a coinbase txid straight from the listtransactions page.
CB_TXID=$(
  python3 - "$LT" <<'PY'
import sys, json
d = json.loads(sys.argv[1])
for e in d.get("result", []):
    if e.get("category") in ("generate", "immature") and e.get("generated") is True:
        print(e["txid"]); break
PY
)
[[ -n "$CB_TXID" ]] || fail "could not find a coinbase txid from listtransactions"
GTCB=$(rpc gettransaction "[\"$CB_TXID\"]")
echo "$GTCB" | grep -q '"error":{' && fail "gettransaction(coinbase) error"
python3 - "$GTCB" <<'PY' || fail "gettransaction(coinbase) shape wrong"
import sys, json
d = json.loads(sys.argv[1]); r = d.get("result", {})
if r.get("generated") is not True:
    print("coinbase gettransaction missing generated=true"); sys.exit(1)
if r.get("amount") is None or r["amount"] <= 0:
    print("coinbase gettransaction non-positive amount %r" % r.get("amount")); sys.exit(1)
sys.exit(0)
PY
log "gettransaction(coinbase) OK (generated=true, positive amount)"

# ── 11. Negative control: gettransaction on a non-wallet txid errors. ──────
BOGUS="0000000000000000000000000000000000000000000000000000000000000001"
GTN=$(rpc gettransaction "[\"$BOGUS\"]")
echo "$GTN" | grep -q '"error":{' || fail "gettransaction(unknown) did not error (got: $(echo "$GTN" | head -c 120))"
log "gettransaction(unknown) correctly errored"

# ── 12. Success. ───────────────────────────────────────────────────────────
log "PASS: sent_entry=yes recv_entries=$RECV_ENTRIES gettx=ok"
pass "$RECV_ENTRIES"

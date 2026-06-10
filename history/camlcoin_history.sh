#!/usr/bin/env bash
#
# camlcoin_history.sh — self-contained wallet transaction-history regression test.
#
# Codifies the "wallet reports its own receive/send/coinbase transactions
# Core-shaped" cell for camlcoin — the successor to the spend cell
# (camlcoin_spend.sh) and recovery cell (camlcoin_recovery.sh). Proves
# listtransactions + gettransaction surface the wallet's own on-chain activity
# on regtest using ONLY wallet-native RPCs:
#
#   sethdseed <FIXED hex seed>           -> deterministic HD master key
#   getnewaddress -> A1                   -> a wallet receive address
#   generatetoaddress 101 -> A1           -> 101 coinbase txs paying the wallet
#   sendtoaddress <foreign-addr> 10       -> the wallet-native send (txid)
#   generatetoaddress 1 -> A1             -> the send CONFIRMS
#   ASSERT:
#     * listtransactions shows the SEND entry: category "send", amount == -10
#       (NEGATIVE per Core), a NEGATIVE fee, txid == the send txid, and >= 1
#       confirmation.
#     * listtransactions shows coinbase entries: category "generate"/"immature",
#       amount +50, generated == true.
#     * gettransaction <send-txid> returns amount ~ -10, a negative fee,
#       confirmations >= 1, and a details[] array carrying the send.
#     * gettransaction on an unknown txid errors (Core: "non-wallet" id).
#
# The send recipient is a FOREIGN regtest address (not in any camlcoin wallet),
# so the send is a genuine outflow; the wallet's history must record it.
#
# Field shapes + sign conventions mirror Bitcoin Core
# (bitcoin-core/src/wallet/rpc/transactions.cpp ListTransactions /
# gettransaction): send amount + fee are NEGATIVE; coinbase credits are
# positive with generated==true and category generate/immature by maturity.
#
# STRICT UNIFORM INTERFACE (mirrors camlcoin_spend.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: HISTORY camlcoin: PASS sent_entry=yes recv_entries=<n> gettx=ok
#   FAIL: HISTORY camlcoin: FAIL <short reason>
#
# Touches ONLY /tmp/histfleet-camlcoin/ and ports 21665 (RPC) / 21685 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/camlcoin/_build/default/bin/main.exe"
DATADIR="/tmp/histfleet-camlcoin"
RPC_PORT=21665
P2P_PORT=21685
RPC_URL="http://127.0.0.1:${RPC_PORT}/"
LOGFILE="$DATADIR/history-test.log"

# Fixed BIP-32 seed — the same classic 00..1f test vector the recovery + spend
# cells use, so all three tests share a wallet identity.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

# Mine 101 so the first coinbase (height 1) is mature at tip 101 and 50 BTC is
# spendable, funding a clean 10 BTC send.
NBLOCKS=101
SEND_BTC=10            # amount to send

# A foreign address NOT derived from our seed — the spend recipient.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""

# ── Logging: everything noisy goes to stderr + logfile, never stdout. ──────
log() { echo "[history:camlcoin] $*" >&2; }

# ── Emit the single summary line + exit. ───────────────────────────────────
pass() {
    echo "HISTORY camlcoin: PASS sent_entry=yes recv_entries=$1 gettx=ok"
    exit 0
}
fail() {
    echo "HISTORY camlcoin: FAIL $*"
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
trap cleanup EXIT

# ── RPC helper (cookie auth). ──────────────────────────────────────────────
COOKIE=""
rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 40 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "$RPC_URL" 2>/dev/null
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
pkill -f "histfleet-camlcoin" 2>/dev/null || true
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

# ── 5. Fund A1 with coinbase (builds coinbase history). ────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A1\"]")
echo "$r" | grep -q '"result":\[' || fail "generatetoaddress error: $r"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?})"
log "height=$HEIGHT"

# ── 6. The wallet-native send (proven by the spend cell). ──────────────────
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR"
SEND=$(rpc sendtoaddress "[\"$FOREIGN_ADDR\",$SEND_BTC]")
echo "$SEND" | grep -q '"error":{' \
    && fail "sendtoaddress error: $(echo "$SEND" | grep -o '"message":"[^"]*"' | head -1)"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
log "send TXID=$TXID"

# ── 7. Confirm the send. ───────────────────────────────────────────────────
log "generatetoaddress 1 -> $A1 (confirm the send)"
r=$(rpc generatetoaddress "[1,\"$A1\"]")
echo "$r" | grep -q '"result":\[' || fail "confirm-block generate error: $r"

# ── 8. listtransactions: send entry must be present, Core-shaped. ──────────
# Fetch a generous window so the send entry (newest) and coinbase entries are
# all visible regardless of count default.
LT=$(rpc listtransactions "[\"*\",200]")
echo "$LT" | grep -q '"error":{' && fail "listtransactions error: $(echo "$LT" | grep -o '"message":"[^"]*"' | head -1)"
echo "$LT" | grep -q '"result":\[' || fail "listtransactions returned no array: $(echo "$LT" | head -c 200)"

# Isolate the send entry's object: the one whose txid == the send txid AND
# category == send. Use python for robust JSON parsing of the sign + fields.
SEND_CHECK=$(echo "$LT" | python3 -c '
import sys, json
d = json.load(sys.stdin)
txs = d.get("result", [])
send_txid = sys.argv[1]
recv = 0
send_ok = False
for t in txs:
    cat = t.get("category")
    if cat in ("receive", "generate", "immature"):
        recv += 1
    if t.get("txid") == send_txid and cat == "send":
        amt = t.get("amount")
        fee = t.get("fee")
        confs = t.get("confirmations", 0)
        # Core conventions: send amount negative, fee negative, confs >= 1.
        if amt is not None and amt < 0 and abs(amt + 10.0) < 1e-6 \
           and fee is not None and fee < 0 and confs >= 1:
            send_ok = True
print(("OK" if send_ok else "NO") + " " + str(recv))
' "$TXID" 2>/dev/null)

SEND_FLAG=$(echo "$SEND_CHECK" | awk '{print $1}')
RECV_N=$(echo "$SEND_CHECK" | awk '{print $2}')
log "listtransactions: send_entry=$SEND_FLAG recv_entries=${RECV_N:-?}"
[[ "$SEND_FLAG" == "OK" ]] || fail "send entry missing/misshaped in listtransactions (want category=send amount=-10 fee<0 confs>=1)"
[[ "${RECV_N:-0}" -ge 1 ]] || fail "no coinbase/receive entries in listtransactions (want generate/immature +50)"

# Coinbase entries must carry generated=true + a positive ~50 amount.
GEN_OK=$(echo "$LT" | python3 -c '
import sys, json
d = json.load(sys.stdin)
ok = False
for t in d.get("result", []):
    if t.get("category") in ("generate", "immature"):
        if t.get("generated") is True and t.get("amount", 0) > 0 \
           and abs(t.get("amount", 0) - 50.0) < 0.001:
            ok = True
print("OK" if ok else "NO")
' 2>/dev/null)
[[ "$GEN_OK" == "OK" ]] || fail "no coinbase entry with generated=true amount~50 (category generate/immature)"

# ── 9. gettransaction <send-txid>: Core-shaped detail object. ──────────────
GT=$(rpc gettransaction "[\"$TXID\"]")
echo "$GT" | grep -q '"error":{' && fail "gettransaction error: $(echo "$GT" | grep -o '"message":"[^"]*"' | head -1)"
GT_OK=$(echo "$GT" | python3 -c '
import sys, json
d = json.load(sys.stdin)
r = d.get("result")
if not r:
    print("NO no-result"); sys.exit()
amt = r.get("amount")
fee = r.get("fee")
confs = r.get("confirmations", 0)
details = r.get("details", [])
if amt is None or amt >= 0 or abs(amt + 10.0) >= 1e-6:
    print("NO amount=%r" % amt); sys.exit()
if fee is None or fee >= 0:
    print("NO fee=%r" % fee); sys.exit()
if confs < 1:
    print("NO confs=%r" % confs); sys.exit()
# details must include a send row to the foreign address.
has_send = any(x.get("category") == "send" for x in details)
if not has_send:
    print("NO details=%r" % details); sys.exit()
print("OK")
' 2>/dev/null)
log "gettransaction: $GT_OK"
[[ "$GT_OK" == "OK" ]] || fail "gettransaction <send-txid> misshaped: $GT_OK"

# ── 10. gettransaction on an unknown txid must error (non-wallet id). ──────
BAD=$(rpc gettransaction "[\"0000000000000000000000000000000000000000000000000000000000000000\"]")
echo "$BAD" | grep -q '"error":{' || fail "gettransaction on unknown txid did not error (Core rejects non-wallet ids)"

# ── 11. Success. ───────────────────────────────────────────────────────────
log "PASS: sent_entry=yes recv_entries=$RECV_N gettx=ok"
pass "$RECV_N"

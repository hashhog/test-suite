#!/usr/bin/env bash
#
# rustoshi_history.sh — self-contained wallet transaction-history regression test.
#
# Codifies the "wallet reports its own transaction history" cell for rustoshi —
# the successor to the wallet-spend cell (rustoshi_spend.sh). Proves that
# listtransactions + gettransaction report the wallet's own receive / send /
# coinbase activity Core-shaped, landed by the feat(wallet) commit that extends
# the block-connect -> wallet scan to record a transaction-history ledger:
#
#   createwallet w1 -> sethdseed(FIXED 64-byte seed) -> getnewaddress -> A1
#   generatetoaddress 101 -> A1        -> coinbase history (generate/immature)
#   sendtoaddress <foreign> 10          -> the wallet-native send
#   generatetoaddress 1 -> A1          -> the send CONFIRMS
#   ASSERT:
#     * listtransactions shows the SEND entry: category "send", amount == -10,
#       a NEGATIVE fee, txid == the send txid.  (Was [] before this fix —
#       the old impl iterated only current UTXOs, so a spent coin's send
#       never appeared.)
#     * listtransactions also shows coinbase entries: category
#       "generate"/"immature", amount +50 (the per-block subsidy).
#     * gettransaction <send-txid> returns amount ~ -10 (negative), a NEGATIVE
#       fee, confirmations >= 1, a details[] array containing the send, and the
#       raw hex.  (Was absent / -32601 before this fix.)
#
# Field shapes + sign conventions are checked against Bitcoin Core's
# wallet/rpc/transactions.cpp (ListTransactions / gettransaction): send amount
# negative, send fee negative, generated:true on coinbase, blockhash/blockheight/
# blocktime present on confirmed txs, details[] per output/recipient.
#
# Recipient is a FOREIGN regtest address (not in the wallet) so the send is an
# honest outbound payment and the send detail carries the recipient's address.
#
# Restore mechanism: `sethdseed` takes a 64-byte (128 hex char) master seed
# (documented Core divergence). RPC auth is cookie-based (<datadir>/.cookie),
# matching rustoshi_spend.sh / rustoshi_recovery.sh.
#
# STRICT UNIFORM INTERFACE (mirrors rustoshi_spend.sh): no required args,
# idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: HISTORY rustoshi: PASS sent_entry=yes recv_entries=<n> gettx=ok
#   FAIL: HISTORY rustoshi: FAIL <short reason>
#
# Touches ONLY /tmp/histfleet-rustoshi/ and ports 39760 (RPC) / 39780 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
BIN="$BASEDIR/rustoshi/target/release/rustoshi"
DATADIR="/tmp/histfleet-rustoshi"
RPC_PORT=39760
P2P_PORT=39780
LOG="$DATADIR/node.log"

# FIXED 64-byte master seed (128 hex chars) — the same seed the recovery +
# spend cells use, so the three tests share a deterministic wallet identity.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"

# Coinbase maturity on regtest is 100 blocks. Mine 101 so EXACTLY the first
# reward (height 1, 50 BTC) is mature/spendable at tip 101 -> a 10 BTC spend is
# funded.
NBLOCKS=101
SEND_BTC=10            # amount to send
SEND_SATS=1000000000   # 10 BTC in satoshis

# A foreign regtest address NOT derived from our seed — the spend recipient.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""

# ── stderr logger (keeps stdout clean for the single summary line) ──────────
log() { echo "[history] $*" >&2; }

# ── Emit the one summary line + exit ────────────────────────────────────────
# pass <recv_entries>
pass() {
    echo "HISTORY rustoshi: PASS sent_entry=yes recv_entries=$1 gettx=ok"
    exit 0
}
fail() {
    echo "HISTORY rustoshi: FAIL $*"
    exit 1
}

# ── Cleanup: always kill node + wipe scratch datadir ────────────────────────
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

# ── RPC helper (cookie auth) ────────────────────────────────────────────────
rpc() {
    local method=$1 params="${2:-[]}" auth=""
    for c in "$DATADIR/.cookie" "$DATADIR/regtest/.cookie"; do
        if [[ -f "$c" ]]; then auth="-u $(cat "$c")"; break; fi
    done
    # shellcheck disable=SC2086
    curl -s --max-time 40 $auth \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}

# Extract a numeric "result":N scalar from a JSON reply.
result_num() {
    echo "$1" | grep -o '"result":-\?[0-9.]*' | head -1 | sed 's/"result"://'
}
# Extract a string "result":"..." from a JSON reply.
result_str() {
    echo "$1" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//'
}

# Convert a (possibly negative) BTC decimal string to integer satoshis.
btc_to_sats() {
    local amt="$1" sign="" whole frac
    [[ -z "$amt" ]] && { echo ""; return 1; }
    if [[ "$amt" == -* ]]; then sign="-"; amt="${amt#-}"; fi
    whole="${amt%%.*}"
    if [[ "$amt" == *.* ]]; then frac="${amt#*.}"; else frac="0"; fi
    frac="${frac}00000000"; frac="${frac:0:8}"
    whole=$((10#${whole:-0})); frac=$((10#${frac:-0}))
    echo "${sign}$(( whole * 100000000 + frac ))"
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR" || fail "cannot create scratch datadir $DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -x "$BIN" ]] || fail "rustoshi binary not found at $BIN (build with: cargo build --release)"

# ── 2. Launch rustoshi on regtest. ─────────────────────────────────────────
log "launching rustoshi regtest (rpc=$RPC_PORT p2p=$P2P_PORT datadir=$DATADIR)"
"$BIN" --network=regtest --datadir="$DATADIR" \
    --port="$P2P_PORT" --rpcbind="127.0.0.1:$RPC_PORT" \
    >"$LOG" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"
kill -0 "$NODE_PID" 2>/dev/null || fail "node process exited immediately (see $LOG)"

# ── 3. Wait up to 30s for RPC. ─────────────────────────────────────────────
log "waiting for RPC..."
rpc_ready=0
deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < deadline )); do
    if echo "$(rpc getblockcount)" | grep -q '"result"'; then rpc_ready=1; break; fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node died during startup (see $LOG)"
    sleep 1
done
[[ "$rpc_ready" == "1" ]] || fail "RPC did not respond within 30s"
log "RPC ready"

# ── 4. Create wallet w1 + restore the FIXED seed. ──────────────────────────
log "createwallet w1 + sethdseed (restore fixed seed)"
out=$(rpc createwallet '["w1"]')
echo "$out" | grep -q '"w1"' || fail "createwallet w1 failed: $out"
out=$(rpc sethdseed "[true, \"$SEED\"]")
echo "$out" | grep -q '"result"' || fail "sethdseed failed: $out"

# ── 5. Derive A1 (the address we fund). ────────────────────────────────────
A1=$(result_str "$(rpc getnewaddress)")
[[ -n "$A1" ]] || fail "getnewaddress returned empty"
log "A1=$A1"

# ── 6. Fund A1 with coinbase (101 blocks => coinbase history). ─────────────
log "generatetoaddress $NBLOCKS -> $A1"
out=$(rpc generatetoaddress "[$NBLOCKS, \"$A1\"]")
echo "$out" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$out" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# ── 7. listtransactions shows coinbase history (was [] before). ────────────
LT_PRE=$(rpc listtransactions '["*", 200, 0]')
echo "$LT_PRE" | grep -q '"error":{' && fail "listtransactions error: $(echo "$LT_PRE" | grep -o '"message":"[^"]*"' | head -1)"
# Count generate + immature coinbase entries.
N_GEN=$(echo "$LT_PRE" | grep -o '"category":"generate"' | wc -l | tr -d ' ')
N_IMM=$(echo "$LT_PRE" | grep -o '"category":"immature"' | wc -l | tr -d ' ')
N_RECV=$(( N_GEN + N_IMM ))
log "coinbase history entries: generate=$N_GEN immature=$N_IMM (total recv=$N_RECV)"
[[ "$N_RECV" -gt 0 ]] || fail "listtransactions shows NO coinbase entries after 101 blocks (history empty?): $(echo "$LT_PRE" | head -c 200)"
# generated:true must appear on coinbase entries (Core parity).
echo "$LT_PRE" | grep -q '"generated":true' || fail "coinbase entries missing generated:true"
# At tip 101 the height-1 coinbase is mature -> at least one 'generate'.
[[ "$N_GEN" -ge 1 ]] || fail "no mature 'generate' coinbase at tip 101 (maturity split wrong)"
# Coinbase amount must be the +50 BTC subsidy on a generate entry.
echo "$LT_PRE" | grep -o '"category":"generate","amount":[0-9.]*' | grep -q '"amount":50' \
    || fail "mature coinbase entry amount is not +50 BTC: $(echo "$LT_PRE" | grep -o '"category":"generate","amount":[0-9.]*' | head -1)"

# ── 8. sendtoaddress -> the wallet-native send. ────────────────────────────
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR (from w1)"
SEND=$(rpc sendtoaddress "[\"$FOREIGN_ADDR\", $SEND_BTC]")
echo "$SEND" | grep -q '"error":{' \
    && fail "sendtoaddress error: $(echo "$SEND" | grep -o '"message":"[^"]*"' | head -1)"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
log "send TXID=$TXID"

# ── 9. Mine 1 block -> the send CONFIRMS (and gets recorded in history). ───
log "generatetoaddress 1 -> $A1 (confirm the send)"
out=$(rpc generatetoaddress "[1, \"$A1\"]")
echo "$out" | grep -q '"error":{' && fail "confirm-block generate error: $(echo "$out" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -gt "$HEIGHT" ]] || fail "height did not advance on confirm block"
log "height after confirm = $HEIGHT2"

# ── 10. listtransactions shows the SEND entry. ─────────────────────────────
LT=$(rpc listtransactions '["*", 200, 0]')
echo "$LT" | grep -q '"error":{' && fail "listtransactions (post-send) error"
# Isolate the send-txid entries. Python is used for robust JSON parsing of the
# single send entry (category send, amount/fee sign + txid match).
SEND_CHECK=$(SEND_TXID="$TXID" SEND_SATS="$SEND_SATS" python3 - "$LT" <<'PY'
import json, os, sys
data = json.loads(sys.argv[1])
res = data.get("result")
if not isinstance(res, list):
    print("FAIL listtransactions result not an array"); sys.exit(0)
txid = os.environ["SEND_TXID"]
send_sats = int(os.environ["SEND_SATS"])
sends = [e for e in res if e.get("category") == "send" and e.get("txid") == txid]
if not sends:
    print("FAIL no send entry for txid in listtransactions"); sys.exit(0)
e = sends[0]
amt = e.get("amount")
if amt is None or amt >= 0:
    print(f"FAIL send amount not negative: {amt}"); sys.exit(0)
amt_sats = round(amt * 1e8)
if abs(abs(amt_sats) - send_sats) > 2:
    print(f"FAIL send amount {amt} BTC != -{send_sats/1e8} BTC"); sys.exit(0)
fee = e.get("fee")
if fee is None or fee >= 0:
    print(f"FAIL send fee not present/negative: {fee}"); sys.exit(0)
# blockhash / blockheight / blocktime present on a confirmed send.
for k in ("blockhash", "blockheight", "blocktime", "confirmations"):
    if e.get(k) is None:
        print(f"FAIL send entry missing {k}"); sys.exit(0)
if e.get("confirmations", 0) < 1:
    print(f"FAIL send confirmations < 1: {e.get('confirmations')}"); sys.exit(0)
# recipient address surfaced on the send line.
if e.get("address") != "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080":
    print(f"FAIL send address != recipient: {e.get('address')}"); sys.exit(0)
print("OK")
PY
)
[[ "$SEND_CHECK" == "OK" ]] || fail "listtransactions send check: $SEND_CHECK"
log "listtransactions: send entry OK (category=send, amount=-$SEND_BTC, negative fee, txid match)"

# ── 11. gettransaction <send-txid> returns the Core shape. ─────────────────
GT=$(rpc gettransaction "[\"$TXID\"]")
echo "$GT" | grep -q '"error":{' && fail "gettransaction error: $(echo "$GT" | grep -o '"message":"[^"]*"' | head -1)"
GT_CHECK=$(SEND_TXID="$TXID" SEND_SATS="$SEND_SATS" python3 - "$GT" <<'PY'
import json, os, sys
data = json.loads(sys.argv[1])
e = data.get("result")
if not isinstance(e, dict):
    print(f"FAIL gettransaction result not an object: {data}"); sys.exit(0)
txid = os.environ["SEND_TXID"]
send_sats = int(os.environ["SEND_SATS"])
if e.get("txid") != txid:
    print(f"FAIL gettransaction txid mismatch: {e.get('txid')}"); sys.exit(0)
amt = e.get("amount")
if amt is None or amt >= 0:
    print(f"FAIL gettransaction amount not negative: {amt}"); sys.exit(0)
# amount ~ -10 (negative, close to the send; Core's nNet-nFee may add one fee).
if not (-10.01 <= amt <= -9.99):
    print(f"FAIL gettransaction amount {amt} not ~ -10"); sys.exit(0)
fee = e.get("fee")
if fee is None or fee >= 0:
    print(f"FAIL gettransaction fee not present/negative: {fee}"); sys.exit(0)
if e.get("confirmations", 0) < 1:
    print(f"FAIL gettransaction confirmations < 1: {e.get('confirmations')}"); sys.exit(0)
det = e.get("details")
if not isinstance(det, list) or not det:
    print(f"FAIL gettransaction details[] empty: {det}"); sys.exit(0)
if not any(d.get("category") == "send" for d in det):
    print(f"FAIL gettransaction details has no send line: {det}"); sys.exit(0)
if not e.get("hex"):
    print("FAIL gettransaction missing hex"); sys.exit(0)
for k in ("blockhash", "blockheight", "blocktime"):
    if e.get(k) is None:
        print(f"FAIL gettransaction missing {k}"); sys.exit(0)
print("OK")
PY
)
[[ "$GT_CHECK" == "OK" ]] || fail "gettransaction check: $GT_CHECK"
log "gettransaction: OK (amount ~ -$SEND_BTC, negative fee, confirmations>=1, details[] has send, hex present)"

# ── 12. Negative control: gettransaction on an unknown txid errors. ────────
BOGUS="0000000000000000000000000000000000000000000000000000000000000001"
GT_NEG=$(rpc gettransaction "[\"$BOGUS\"]")
echo "$GT_NEG" | grep -q '"error":{' \
    || fail "gettransaction on unknown txid did NOT error (must reject non-wallet txid)"
log "gettransaction on unknown txid correctly errors"

# ── 13. Success. ───────────────────────────────────────────────────────────
log "PASS: sent_entry=yes recv_entries=$N_RECV gettx=ok"
pass "$N_RECV"

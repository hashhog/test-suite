#!/usr/bin/env bash
#
# haskoin_history.sh — wallet transaction-history regression test (regtest).
#
# Codifies the "wallet reports its own transaction history" cell for haskoin —
# the successor to the wallet-spend cell (haskoin_spend.sh).  Proves that
# listtransactions + gettransaction surface the wallet's own receive / send /
# coinbase txs Core-shaped, driven by the block-connect -> wallet scan landed in
# haskoin 7a0efef and extended to record a per-tx history entry.
#
#   restorewallet w1 <fixed mnemonic>   -> getnewaddress -> A1
#   generatetoaddress 101 -> A1         -> 101 coinbase history rows
#                                          (height-1 mature => "generate",
#                                           the rest immature => "immature")
#   sendtoaddress <foreign-addr> 10     -> the wallet-native send (spend cell)
#   generatetoaddress 1 -> A1           -> the send CONFIRMS
#   ASSERT:
#     * listtransactions shows the SEND entry (category "send",
#       amount == -10 BTC, NEGATIVE fee, txid == the send txid).  Was [] before.
#     * listtransactions shows coinbase entries (category generate/immature,
#       amount +50 BTC each, generated=true).
#     * gettransaction <send-txid> returns amount ~ -10 BTC, a NEGATIVE fee,
#       confirmations >= 1, blockhash/blockheight present, and a details[]
#       array containing the send.  Was absent/empty before.
#
# Field shapes + sign conventions follow bitcoin-core/src/wallet/rpc/
# transactions.cpp (ListTransactions / gettransaction): negative amount + fee
# for "send", positive for credits; "generate" when a coinbase is mature
# (>=100 confs), "immature" otherwise.
#
# STRICT UNIFORM INTERFACE (mirrors haskoin_spend.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout.  All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: HISTORY haskoin: PASS sent_entry=yes recv_entries=<n> gettx=ok
#   FAIL: HISTORY haskoin: FAIL <short reason>
#
# Touches ONLY /tmp/histfleet-haskoin/ and ports 21669 (RPC) / 21689 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
HASKOIN_REPO="$BASEDIR/haskoin"
DATADIR="/tmp/histfleet-haskoin"
RPC_PORT=21669
P2P_PORT=21689
LOGFILE="$DATADIR/history-test.log"

# Same FIXED all-zero-entropy BIP-39 test mnemonic as the recovery + spend
# cells, so the three tests share a wallet identity.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# Regtest coinbase maturity = 100.  Mine 101 so the height-1 coinbase is
# mature ("generate") at tip 101 and the rest are "immature".
NBLOCKS=101
SEND_BTC=10
SEND_SATS=1000000000   # 10 BTC in satoshis

# A foreign address NOT derived from our seed — the spend recipient.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""
COOKIE=""

# ── Logging: everything noisy -> stderr + logfile, never stdout. ──────────
log() { echo "[history] $*" >&2; }

# ── Cleanup trap: always kill node + wipe scratch datadir on any exit. ────
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

# ── Emit the single summary line + exit. ──────────────────────────────────
pass() {
    echo "HISTORY haskoin: PASS sent_entry=yes recv_entries=$1 gettx=ok"
    exit 0
}
fail() {
    echo "HISTORY haskoin: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth; JSON-RPC 1.0). ───────────────────────────────
rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 40 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}

result_str() { echo "$1" | sed 's/.*"result":"//; s/".*//'; }
result_num() { echo "$1" | grep -o '"result":[0-9.]*' | head -1 | sed 's/"result"://'; }
has_error()  { echo "$1" | grep -q '"error":null' && return 1 || return 0; }

# Convert a (possibly negative) BTC decimal string to integer satoshis.
btc_to_sats() {
    local amt="$1" sign=1 whole frac
    [[ -z "$amt" ]] && { echo ""; return 1; }
    if [[ "${amt:0:1}" == "-" ]]; then sign=-1; amt="${amt:1}"; fi
    whole="${amt%%.*}"
    if [[ "$amt" == *.* ]]; then frac="${amt#*.}"; else frac="0"; fi
    frac="${frac}00000000"; frac="${frac:0:8}"
    whole=$((10#${whole:-0})); frac=$((10#${frac:-0}))
    echo $(( sign * (whole * 100000000 + frac) ))
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Locate the haskoin binary. ─────────────────────────────────────────
HB=$(find "$HASKOIN_REPO/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)
[[ -n "$HB" && -x "$HB" ]] || fail "haskoin binary not found under $HASKOIN_REPO/dist-newstyle (run build-all.sh haskoin)"

# ── 2. Launch haskoin on regtest. ─────────────────────────────────────────
log "launching $HB (regtest) -> $DATADIR/node.log"
haskoin_datadir="$HASKOIN_REPO" \
    "$HB" --network Regtest --datadir "$DATADIR" \
    node --port "$P2P_PORT" --rpcport "$RPC_PORT" \
    >"$DATADIR/node.log" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"

# ── 3. Locate the cookie + wait for RPC. ──────────────────────────────────
deadline=$(( $(date +%s) + 45 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$COOKIE" ]]; then
        for c in "$DATADIR/regtest/.cookie" "$DATADIR/.cookie"; do
            if [[ -f "$c" ]]; then COOKIE=$(cat "$c"); break; fi
        done
    fi
    if [[ -n "$COOKIE" ]]; then
        r=$(rpc getblockcount)
        echo "$r" | grep -q '"result"' && { log "RPC ready: $r"; break; }
    fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node exited during startup (see $DATADIR/node.log)"
    sleep 1
done
[[ -n "$COOKIE" ]] || fail "cookie never appeared within 45s"
r=$(rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "RPC never responded within 45s"
h0=$(echo "$r" | grep -o '"result":[0-9]*' | grep -o '[0-9]*')
[[ "$h0" == "0" ]] || fail "fresh regtest not at height 0 (got ${h0:-none})"

# ── 4. Restore wallet w1, derive A1. ──────────────────────────────────────
log "restorewallet w1 from fixed mnemonic"
r=$(rpc restorewallet "[\"w1\",\"$MNEMONIC\"]")
has_error "$r" && fail "restorewallet w1 error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

A1=$(result_str "$(rpc getnewaddress "[]")")
[[ "$A1" == bcrt1q* ]] || fail "getnewaddress A1 not a regtest bech32 addr (got '${A1:0:40}')"
log "A1=$A1"

# ── 5. PROBE: listtransactions BEFORE any blocks must be empty. ───────────
LT_PRE=$(rpc listtransactions "[\"*\",10,0]")
has_error "$LT_PRE" && fail "listtransactions (pre) error: $(echo "$LT_PRE" | grep -o '"message":"[^"]*"' | head -1)"
PRE_ROWS=$(echo "$LT_PRE" | grep -o '"txid"' | wc -l | tr -d ' ')
[[ "${PRE_ROWS:-0}" -eq 0 ]] || fail "listtransactions non-empty before any wallet tx (got $PRE_ROWS rows)"
log "listtransactions BEFORE = [] (0 rows), as expected"

# ── 6. Fund A1 with 101 coinbases. ────────────────────────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A1\"]")
has_error "$r" && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# ── 6b. Sanity: the UTXO scan ran (listunspent credited the coinbases). ───
# This guards against a stale/empty node answering on the port: if funding
# did not credit the wallet at all, fail HERE with a clear cause rather than
# later mislabelling it as "history not recording".
LU=$(rpc listunspent "[1]")
LU_COUNT=$(echo "$LU" | grep -o '"txid"' | wc -l | tr -d ' ')
[[ "${LU_COUNT:-0}" -gt 0 ]] \
    || fail "listunspent empty after funding (block-connect wallet scan did not run; stale node on port?)"
log "listunspent after funding = $LU_COUNT UTXOs (scan ran)"

# ── 7. listtransactions now reports coinbase history. ─────────────────────
# Request a large count so we see both mature (generate) and immature rows.
LT_CB=$(rpc listtransactions "[\"*\",1000,0]")
has_error "$LT_CB" && fail "listtransactions (coinbase) error: $(echo "$LT_CB" | grep -o '"message":"[^"]*"' | head -1)"
RECV_ROWS=$(echo "$LT_CB" | grep -o '"txid"' | wc -l | tr -d ' ')
[[ "${RECV_ROWS:-0}" -gt 0 ]] || fail "listtransactions empty after 101 coinbases (scan->history not recording)"
log "listtransactions after funding = $RECV_ROWS rows"

# At least one mature coinbase => a "generate" row; the rest "immature".
echo "$LT_CB" | grep -q '"category":"generate"' \
    || fail "no \"generate\" (mature coinbase) row in listtransactions"
echo "$LT_CB" | grep -q '"category":"immature"' \
    || fail "no \"immature\" coinbase row in listtransactions (maturity split missing)"
# Coinbase credit must be +50 BTC and flagged generated.
echo "$LT_CB" | grep -q '"amount":50.00000000' \
    || fail "no +50.00000000 coinbase credit in listtransactions"
echo "$LT_CB" | grep -q '"generated":true' \
    || fail "coinbase rows not flagged generated=true"
log "coinbase history shape OK (generate + immature + amount=50 + generated=true)"

# ── 8. sendtoaddress -> txid, tx enters mempool. ──────────────────────────
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR (from w1)"
SEND=$(rpc sendtoaddress "[\"$FOREIGN_ADDR\",$SEND_BTC]")
has_error "$SEND" && fail "sendtoaddress error: $(echo "$SEND" | grep -o '"message":"[^"]*"' | head -1)"
TXID=$(result_str "$SEND")
[[ -n "$TXID" && "${#TXID}" -eq 64 ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
log "send TXID=$TXID"

# ── 9. Mine 1 block -> the send CONFIRMS (and records its history row). ───
log "generatetoaddress 1 -> $A1 (confirm the spend)"
r=$(rpc generatetoaddress "[1,\"$A1\"]")
has_error "$r" && fail "confirm-block generate error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -gt "$HEIGHT" ]] || fail "height did not advance on confirm block"
log "height after confirm = $HEIGHT2"

# ── 10. listtransactions shows the SEND entry, Core-shaped. ───────────────
# Ask for the most recent rows; the send + new coinbase are the newest.
LT_ALL=$(rpc listtransactions "[\"*\",2000,0]")
has_error "$LT_ALL" && fail "listtransactions (post-send) error"
# Pull out the JSON object whose txid matches the send (display order).
# All rows are concatenated objects; isolate the one carrying our txid.
SEND_OBJ=$(echo "$LT_ALL" | tr '{' '\n' | grep "$TXID")
[[ -n "$SEND_OBJ" ]] || fail "send txid $TXID not present in listtransactions after confirm"
echo "$SEND_OBJ" | grep -q '"category":"send"' \
    || fail "send row not categorised \"send\" (got: $(echo "$SEND_OBJ" | head -c 200))"
# amount must be NEGATIVE 10 BTC.
echo "$SEND_OBJ" | grep -q '"amount":-10.00000000' \
    || fail "send row amount != -10.00000000 (got: $(echo "$SEND_OBJ" | grep -o '"amount":[-0-9.]*' | head -1))"
# fee must be present and NEGATIVE.
SEND_FEE=$(echo "$SEND_OBJ" | grep -o '"fee":-[0-9.]*' | head -1 | sed 's/"fee"://')
[[ -n "$SEND_FEE" ]] || fail "send row has no NEGATIVE fee field (got: $(echo "$SEND_OBJ" | grep -o '"fee":[-0-9.]*' | head -1))"
log "listtransactions SEND row OK (category=send amount=-10 fee=$SEND_FEE txid=$TXID)"

# ── 11. gettransaction <send-txid> Core-shaped. ───────────────────────────
GT=$(rpc gettransaction "[\"$TXID\"]")
has_error "$GT" && fail "gettransaction error: $(echo "$GT" | grep -o '"message":"[^"]*"' | head -1)"
# amount ~ -10 BTC (value sent OUT of the wallet, excl. fee).
GT_AMT=$(echo "$GT" | grep -o '"amount":[-0-9.]*' | head -1 | sed 's/"amount"://')
GT_AMT_SATS=$(btc_to_sats "$GT_AMT")
[[ -n "$GT_AMT_SATS" ]] || fail "gettransaction returned no amount: $(echo "$GT" | head -c 200)"
[[ "$GT_AMT_SATS" -eq "$(( -SEND_SATS ))" ]] \
    || fail "gettransaction amount $GT_AMT (=$GT_AMT_SATS sats) != -$SEND_SATS sats"
# fee must be present and NEGATIVE.
GT_FEE=$(echo "$GT" | grep -o '"fee":-[0-9.]*' | head -1 | sed 's/"fee"://')
[[ -n "$GT_FEE" ]] || fail "gettransaction has no NEGATIVE fee (got: $(echo "$GT" | grep -o '"fee":[-0-9.]*' | head -1))"
# confirmations >= 1.
GT_CONF=$(echo "$GT" | grep -o '"confirmations":[0-9]*' | head -1 | sed 's/"confirmations"://')
[[ "${GT_CONF:-0}" -ge 1 ]] || fail "gettransaction confirmations < 1 (got ${GT_CONF:-none})"
# blockhash + blockheight present.
echo "$GT" | grep -q '"blockhash":"[0-9a-f]' || fail "gettransaction missing blockhash"
echo "$GT" | grep -q '"blockheight":[0-9]'   || fail "gettransaction missing blockheight"
# details[] array carrying the send.
echo "$GT" | grep -q '"details":\[' || fail "gettransaction missing details[] array"
DETAILS=$(echo "$GT" | sed 's/.*"details":\[//; s/\].*//')
echo "$DETAILS" | grep -q '"category":"send"' \
    || fail "gettransaction details[] has no \"send\" entry"
log "gettransaction OK (amount=$GT_AMT fee=$GT_FEE confirmations=$GT_CONF details=send)"

# ── 12. Negative control: a non-wallet txid must be rejected. ─────────────
BOGUS="0000000000000000000000000000000000000000000000000000000000000001"
GT_BOGUS=$(rpc gettransaction "[\"$BOGUS\"]")
has_error "$GT_BOGUS" || fail "gettransaction for a non-wallet txid did NOT error (must reject)"
log "gettransaction rejects non-wallet txid, as expected"

# ── 13. Success. ──────────────────────────────────────────────────────────
log "PASS: sent_entry=yes recv_entries=$RECV_ROWS gettx=ok"
pass "$RECV_ROWS"

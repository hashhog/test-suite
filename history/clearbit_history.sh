#!/usr/bin/env bash
#
# clearbit_history.sh — self-contained wallet transaction-history regression
# test.
#
# Codifies the "wallet reports its own receive/send/coinbase transactions
# Core-shaped" cell for clearbit, the successor to the wallet-spend cell
# (clearbit_spend.sh). Proves listtransactions + gettransaction surface the
# wallet's own history on regtest using ONLY wallet-native RPCs:
#
#   createwallet w1 (blank) -> sethdseed(FIXED SEED) -> getnewaddress -> A1
#   generatetoaddress 101 -> A1        -> coinbase history (generate/immature)
#   sendtoaddress <foreign> 10          -> the wallet-native send (spend cell)
#   generatetoaddress 1 -> A1          -> the send CONFIRMS
#   ASSERT (vs Bitcoin Core wallet/rpc/transactions.cpp shapes):
#     * listtransactions shows the SEND entry: category "send", amount == -10,
#       NEGATIVE fee, txid == the send txid.  (Was [] before this cell.)
#     * listtransactions shows COINBASE entries: category "generate"
#       (mature, depth >= 100) and/or "immature", amount +50, generated:true.
#     * gettransaction <send-txid> returns amount ~ -10, a NEGATIVE fee,
#       confirmations >= 1, and a details[] containing the send (category
#       "send", negative amount, negative fee).  (Was absent before.)
#     * gettransaction on a bogus txid returns a -5 wallet error.
#
# Sign conventions verified against Core: send amount and send fee are both
# NEGATIVE (ListTransactions: ValueFromAmount(-s.amount) / ValueFromAmount(-nFee);
# gettransaction: nNet - nFee with nFee = GetValueOut - nDebit < 0). Coinbase
# category is depth-dependent (orphan < 1 conf, immature < COINBASE_MATURITY,
# else generate) and recomputed at query time, matching CWallet.
#
# The recipient is a FOREIGN regtest address (not in any clearbit wallet) so the
# send leaves the wallet to an external party — the change returns as a
# "receive" detail of the same tx, exactly as Core records it.
#
# STRICT UNIFORM INTERFACE (mirrors clearbit_spend.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: HISTORY clearbit: PASS sent_entry=yes recv_entries=<n> gettx=ok
#   FAIL: HISTORY clearbit: FAIL <short reason>
#
# Touches ONLY /tmp/histfleet-clearbit/ and ports 21667 (RPC) / 21687 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
IMPL="clearbit"
RPC_PORT=21667
P2P_PORT=21687
DATADIR="/tmp/histfleet-clearbit"
NETDIR="$DATADIR/regtest"          # clearbit appends the network subdir
COOKIE_FILE="$NETDIR/.cookie"
LOGFILE="$DATADIR/node.log"
BASE="http://127.0.0.1:$RPC_PORT"

# Resolve the binary the same way build-all.sh / smoke-harness.sh do.
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"

# The FIXED 16-byte BIP-32 test seed (hex) the recovery + spend cells use, so
# the history cell shares the same wallet identity. clearbit's sethdseed takes
# a HEX seed (documented divergence from Core's WIF).
SEED="000102030405060708090a0b0c0d0e0f"

# Mine 101 so the early coinbases (depth >= 100) are MATURE -> "generate", the
# rest "immature", and the wallet has a spendable 50 BTC for the send.
NBLOCKS=101
SEND_BTC=10            # amount to send
SEND_SATS=1000000000   # 10 BTC in satoshis

# A foreign address NOT derived from our seed — the spend recipient.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""
COOKIE=""

# ── Logging: everything noisy goes to stderr, never stdout. ────────────────
log() { echo "[history] $*" >&2; }

# ── Cleanup trap: always kill node + wipe scratch datadir on any exit. ─────
kill_port() {
    # Port-kill removed (2026-06-10 fuser incident): wait briefly for OUR ports to be
    # released after the PID-scoped kill. NEVER kills by port.
    local __hp
    for __hp in "$RPC_PORT" "$P2P_PORT"; do
        for _ in $(seq 1 15); do
            ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
            sleep 1
        done
    done
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
# pass <recv_entries>
pass() {
    echo "HISTORY $IMPL: PASS sent_entry=yes recv_entries=$1 gettx=ok"
    exit 0
}
fail() {
    echo "HISTORY $IMPL: FAIL $*"
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
    echo "$1" | grep -o '"result":[0-9.-]*' | head -1 | sed 's/"result"://'
}
# Extract a string "result":"..." from a JSON reply.
result_str() {
    echo "$1" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//'
}

# Extract the JSON object (single { ... } block) for the listtransactions entry
# whose "txid" matches $2, from the listtransactions array in $1. Greedy on the
# inner object boundaries. Returns "" if not found.
entry_for_txid() {
    echo "$1" | grep -o "{[^{}]*\"txid\":\"$2\"[^{}]*}"
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
kill_port
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
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
log "createwallet w1 (blank) + sethdseed restore"
r=$(rpc "/" createwallet '["w1",false,true]')
echo "$r" | grep -q '"error":{' && fail "createwallet w1: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
r=$(rpc "/wallet/w1" sethdseed "[true,\"$SEED\"]")
echo "$r" | grep -q '"error":{' && fail "sethdseed w1: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

log "getnewaddress on w1 (bech32/p2wpkh) -> A1"
A1=$(result_str "$(rpc "/wallet/w1" getnewaddress "[]")")
[[ -n "$A1" ]] || fail "getnewaddress w1 returned no address"
log "A1=$A1"

# ── 5. EMPTY history precondition (was [] before this cell). ───────────────
LT0=$(rpc "/wallet/w1" listtransactions '["*",10,0]')
echo "$LT0" | grep -q '"error":{' && fail "listtransactions errored before funding: $(echo "$LT0" | grep -o '"message":"[^"]*"' | head -1)"
N0=$(echo "$LT0" | grep -o '"txid"' | wc -l | tr -d ' ')
[[ "${N0:-0}" -eq 0 ]] || fail "listtransactions not empty before any block (got $N0 entries)"
log "listtransactions empty before funding (as expected)"

# ── 6. Fund A1 with coinbase -> coinbase history. ──────────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc "/" generatetoaddress "[$NBLOCKS,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc "/" getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# Coinbase entries must be present. Across the full history there must be at
# least one mature "generate" (depth >= 100) and at least one "immature".
LT_CB=$(rpc "/wallet/w1" listtransactions '["*",300,0]')
echo "$LT_CB" | grep -q '"error":{' && fail "listtransactions errored after funding"
N_GEN=$(echo "$LT_CB" | grep -o '"category":"generate"' | wc -l | tr -d ' ')
N_IMM=$(echo "$LT_CB" | grep -o '"category":"immature"' | wc -l | tr -d ' ')
log "coinbase categories: generate=$N_GEN immature=$N_IMM"
[[ "${N_GEN:-0}" -ge 1 ]] || fail "no mature 'generate' coinbase entry (depth-based category not computed?)"
[[ "${N_IMM:-0}" -ge 1 ]] || fail "no 'immature' coinbase entry"
# A generate entry must carry +50 BTC and generated:true.
echo "$LT_CB" | grep -q '"category":"generate","amount":50.00000000' \
    || fail "mature coinbase entry not +50.00000000 BTC"
echo "$LT_CB" | grep -q '"generated":true' \
    || fail "coinbase entry missing generated:true"
RECV_ENTRIES=$(( N_GEN + N_IMM ))

# ── 7. sendtoaddress -> txid (the wallet-native send, proven by spend cell). ─
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR (from w1)"
SEND=$(rpc "/wallet/w1" sendtoaddress "[\"$FOREIGN_ADDR\",$SEND_BTC]")
echo "$SEND" | grep -q '"error":{' \
    && fail "sendtoaddress error: $(echo "$SEND" | grep -o '"message":"[^"]*"' | head -1)"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
[[ "$TXID" =~ ^0+$ ]] && fail "sendtoaddress returned an all-zero placeholder txid"
log "TXID=$TXID"

# ── 8. Mine 1 block -> the send CONFIRMS -> enters wallet history. ─────────
log "generatetoaddress 1 -> $A1 (confirm the spend)"
r=$(rpc "/" generatetoaddress "[1,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "confirm-block generate error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"

# ── 9. listtransactions shows the SEND entry, Core-shaped. ─────────────────
LT=$(rpc "/wallet/w1" listtransactions '["*",300,0]')
echo "$LT" | grep -q '"error":{' && fail "listtransactions errored after send"
SEND_ENTRY=$(entry_for_txid "$LT" "$TXID")
[[ -n "$SEND_ENTRY" ]] || fail "send txid $TXID not present in listtransactions"
echo "$SEND_ENTRY" | grep -q '"category":"send"' \
    || fail "send entry not category 'send': $SEND_ENTRY"
echo "$SEND_ENTRY" | grep -q '"amount":-10.00000000' \
    || fail "send entry amount != -10.00000000 (sign convention?): $SEND_ENTRY"
# Fee must be present and NEGATIVE on a send entry.
echo "$SEND_ENTRY" | grep -qE '"fee":-[0-9]' \
    || fail "send entry fee missing or non-negative: $SEND_ENTRY"
log "send entry OK: $SEND_ENTRY"

# ── 10. gettransaction <send-txid> Core-shaped. ────────────────────────────
GT=$(rpc "/wallet/w1" gettransaction "[\"$TXID\"]")
echo "$GT" | grep -q '"error":{' && fail "gettransaction errored: $(echo "$GT" | grep -o '"message":"[^"]*"' | head -1)"
# amount ~ -10
echo "$GT" | grep -q '"amount":-10.00000000' \
    || fail "gettransaction amount != -10.00000000: $(echo "$GT" | head -c 300)"
# fee negative
echo "$GT" | grep -qE '"fee":-[0-9]' \
    || fail "gettransaction fee missing or non-negative: $(echo "$GT" | head -c 300)"
# confirmations >= 1
GT_CONF=$(echo "$GT" | grep -o '"confirmations":[0-9]*' | head -1 | sed 's/.*://')
[[ "${GT_CONF:-0}" -ge 1 ]] || fail "gettransaction confirmations < 1 (got ${GT_CONF:-?})"
# txid matches
echo "$GT" | grep -q "\"txid\":\"$TXID\"" \
    || fail "gettransaction txid mismatch"
# details[] contains the send (category send + negative amount + negative fee)
echo "$GT" | grep -q '"details":\[' || fail "gettransaction missing details[]"
echo "$GT" | grep -q '"category":"send","amount":-10.00000000,"vout":0,"fee":-' \
    || fail "gettransaction details missing a Core-shaped send line: $(echo "$GT" | head -c 400)"
# raw hex present
echo "$GT" | grep -qE '"hex":"[0-9a-f]+"' || fail "gettransaction missing raw hex"
log "gettransaction OK (amount -10, negative fee, confirmations=$GT_CONF, details + hex present)"

# ── 11. Negative control: gettransaction on a non-wallet txid -> -5 error. ─
GT_BAD=$(rpc "/wallet/w1" gettransaction '["0000000000000000000000000000000000000000000000000000000000000000"]')
echo "$GT_BAD" | grep -q '"code":-5' \
    || fail "gettransaction on bogus txid did not return a -5 wallet error: $(echo "$GT_BAD" | head -c 200)"
log "gettransaction bogus-txid -> -5 error (as expected)"

# ── 12. Success. ───────────────────────────────────────────────────────────
log "PASS: sent_entry=yes recv_entries=$RECV_ENTRIES gettx=ok"
pass "$RECV_ENTRIES"

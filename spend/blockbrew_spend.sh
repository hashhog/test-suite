#!/usr/bin/env bash
#
# blockbrew_spend.sh — self-contained wallet-native spend regression test.
#
# Codifies the "wallet can see and spend its own coins" cell for blockbrew (Go),
# the successor to the wallet-recovery cell (blockbrew_recovery.sh). Proves the
# full on-chain spend round-trip on regtest using ONLY wallet-native RPCs:
#
#   createwallet w1 RESTORED <fixed mnemonic>  -> getnewaddress -> A1
#   generatetoaddress 101 -> A1                -> fund A1 with mined coinbase
#   getbalance                                  -> reflects spendable (MATURE)
#                                                  coins; immature coinbase is
#                                                  excluded (maturity ENFORCED)
#   listunspent                                 -> lists the owned UTXOs
#   sendtoaddress <foreign-addr> <amt>          -> returns a txid, tx -> mempool
#   generatetoaddress 1 -> A1                   -> the tx CONFIRMS
#   ASSERT:
#     * recipient address credited EXACTLY <amt>  (scantxoutset — the
#       authoritative on-chain UTXO oracle, independent of wallet bookkeeping)
#     * sender getbalance dropped by <amt>+fee     (change returns to the wallet)
#     * mempool no longer lists the confirmed tx   (no wedge / re-broadcast)
#     * listunspent reflects the post-spend set    (count changed)
#
# The fix this regresses: blockbrew's wallet had a complete UTXO ledger + signer,
# and Wallet.ScanBlock was wired — but ONLY to the P2P inbound-block path
# (SyncManager.onBlockConnected). Locally mined generatetoaddress blocks go
# through chainMgr.ConnectBlock, whose connect hook only did txindex/blockfilter
# and NEVER scanned the wallet. So getbalance/listunspent stayed 0/[] and
# sendtoaddress failed "insufficient funds". The fix moves the full per-connect
# fan-out (wallet scan + fee estimator + mempool BlockConnected + ZMQ + prune)
# into the single chainMgr.SetOnBlockConnected hook so it fires on EVERY connect
# path exactly once — mirroring Bitcoin Core's BlockConnected notification.
#
# Bitcoin Core's WALLET matures a coinbase at COINBASE_MATURITY+1 = 101
# confirmations — one MORE than the consensus spendability rule. See
# bitcoin-core/src/wallet/wallet.cpp:3342 GetTxBlocksToMaturity:
# max(0, (COINBASE_MATURITY+1) - chain_depth), where chain_depth is
# GetTxDepthInMainChain = tip - height + 1 (wallet.cpp:3319-3325), and
# src/consensus/consensus.h:19 COINBASE_MATURITY = 100. Immature coinbases are
# routed to m_mine_immature and never counted in the m_mine_trusted total that
# getbalance reports (src/wallet/receive.cpp:263-266).
#
# So at tip 101 EXACTLY ONE coinbase is mature: height 1 (depth 101). The
# height-2 coinbase (depth 100) is NOT. getbalance MUST report exactly 50 BTC,
# and the remaining 100 coinbases (5000 BTC) MUST show up as `immature` in
# getbalances. 50 BTC comfortably funds the clean 10 BTC spend below.
#
# We assert BOTH halves on purpose. Asserting only "trusted == 50" would also
# pass if the wallet credited just ONE coinbase and silently dropped the other
# 100 — a real defect. Requiring trusted + immature == 5050 BTC (every one of
# the 101 coinbases accounted for) is what separates "maturity correctly
# enforced" from "coins missing", and holds the node to Core's boundary rather
# than to whatever it happens to report.
#
# HISTORY: this test asserted 100 BTC until 2026-09-02, encoding the pre-fix
# rule (confirmations >= 100). blockbrew moved to Core's rule on 2026-07-21
# (b47a0ca; internal/wallet/wallet.go:296 coinbaseWalletMatureConfs =
# CoinbaseMaturity + 1), so the arm went red against a CORRECT node and stayed
# red for six weeks. The node was right and this file was wrong.
#
# Recipient is a FOREIGN regtest address (not in any blockbrew wallet) so the
# recipient credit is proven purely on-chain via scantxoutset, and the single
# loaded wallet's getbalance is an honest sender-side measurement.
#
# STRICT UNIFORM INTERFACE (mirrors beamchain_spend.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: SPEND blockbrew: PASS funded=<X> sent=<Y> recipient=<Y> sender_debited=<...> mempool=clean
#   FAIL: SPEND blockbrew: FAIL <short reason>
#
# Touches ONLY /tmp/spendfleet-blockbrew/ and ports 21613 (RPC) / 21633 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
BIN="$BASEDIR/blockbrew/blockbrew"
DATADIR="/tmp/spendfleet-blockbrew"
RPC_PORT=21613
P2P_PORT=21633
LOGFILE="$DATADIR/spend-test.log"
URL="http://127.0.0.1:${RPC_PORT}"

# Canonical BIP-39 all-zero-entropy 12-word test mnemonic (valid checksum).
# Same FIXED seed as the recovery cell so the two tests share a wallet identity.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# Mine 101 blocks. Under Core's wallet rule (COINBASE_MATURITY+1 = 101
# confirmations, wallet.cpp:3342) exactly ONE coinbase — height 1, depth 101 —
# is mature at tip 101, so getbalance must report exactly 50 BTC. The other 100
# coinbases (5000 BTC) must be reported as immature, not dropped.
NBLOCKS=101
FUNDED_BTC=50            # expected MATURE (spendable) balance at tip 101
FUNDED_SATS=5000000000   # 50 BTC in satoshis  (1 mature coinbase)
IMMATURE_SATS=500000000000  # 5000 BTC in satoshis (100 immature coinbases)
TOTAL_MINED_SATS=505000000000  # 5050 BTC — all 101 coinbases must be accounted for
SEND_BTC=10              # amount to send
SEND_SATS=1000000000     # 10 BTC in satoshis

# A foreign address NOT derived from our seed — the spend recipient. Proving
# this address is credited on-chain (scantxoutset) demonstrates a real transfer
# of value out of the wallet to an external party.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

NODE_PID=""
COOKIE=""
COOKIE_FILE="$DATADIR/regtest/.cookie"

# ── Logging: everything noisy goes to stderr + logfile, never stdout. ──────
log() { echo "[spend] $*" >&2; }

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
# pass <funded> <sent> <recipient> <sender_debited> <fee>
pass() {
    echo "SPEND blockbrew: PASS funded=$1 sent=$2 recipient=$3 sender_debited=$4 fee_sats=$5 mempool=clean"
    exit 0
}
fail() {
    echo "SPEND blockbrew: FAIL $*"
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

# Extract a numeric "result":N scalar (integer or decimal) from a JSON reply.
result_num() {
    echo "$1" | grep -o '"result":[0-9.]*' | head -1 | sed 's/"result"://'
}

# Extract a string "result":"..." from a JSON reply.
result_str() {
    echo "$1" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//'
}

# Convert a BTC decimal string (e.g. "100.00000000") to integer satoshis without
# bc: split on the dot, pad/truncate the fractional part to 8 digits.
btc_to_sats() {
    local amt="$1" whole frac
    [[ -z "$amt" ]] && { echo ""; return 1; }
    whole="${amt%%.*}"
    if [[ "$amt" == *.* ]]; then frac="${amt#*.}"; else frac="0"; fi
    frac="${frac}00000000"
    frac="${frac:0:8}"
    whole=$((10#${whole:-0}))
    frac=$((10#${frac:-0}))
    echo $(( whole * 100000000 + frac ))
}

# Pull total_amount (BTC) out of a scantxoutset reply, in satoshis.
scan_total_sats() {
    local amt
    amt=$(echo "$1" | grep -o '"total_amount":[^,}]*' | head -1 | sed 's/.*://; s/[" ]//g')
    [[ -z "$amt" ]] && { echo ""; return 1; }
    btc_to_sats "$amt"
}

# Count "txid" occurrences in a listunspent reply.
count_unspent() {
    echo "$1" | grep -o '"txid"' | wc -l | tr -d ' '
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -x "$BIN" ]] || fail "blockbrew binary not found/executable at $BIN (run build-all.sh blockbrew)"
command -v curl >/dev/null 2>&1 || fail "curl not available"

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
# createwallet positional args (blockbrew seed-restore extension, arg 10 = mnemonic):
#   name, disable_private_keys, blank, passphrase, avoid_reuse,
#   descriptors, load_on_startup, external_signer, seed_passphrase, mnemonic
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

# ── 5. Fund A1 with coinbase. ──────────────────────────────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# ── 6. getbalance reflects spendable (MATURE) coins. ───────────────────────
# At tip 101 exactly the height-1 coinbase is mature (depth 101) -> 50 BTC.
BAL_BEFORE_BTC=$(result_num "$(rpc getbalance "[]" "w1")")
[[ -n "$BAL_BEFORE_BTC" ]] || fail "getbalance returned no result: $(rpc getbalance "[]" "w1" | head -c 200)"
BAL_BEFORE_SATS=$(btc_to_sats "$BAL_BEFORE_BTC")
log "getbalance BEFORE = $BAL_BEFORE_BTC BTC ($BAL_BEFORE_SATS sats)"
if [[ "$BAL_BEFORE_SATS" -lt "$FUNDED_SATS" ]]; then
    fail "getbalance $BAL_BEFORE_SATS sats < expected mature $FUNDED_SATS sats at tip $HEIGHT (UNDER-counting: mature coinbase(s) missing or wallet did not credit them)"
elif [[ "$BAL_BEFORE_SATS" -gt "$FUNDED_SATS" ]]; then
    fail "getbalance $BAL_BEFORE_SATS sats > expected mature $FUNDED_SATS sats at tip $HEIGHT (OVER-counting: coinbase maturity not enforced at Core's COINBASE_MATURITY+1 boundary)"
fi

# ── 6b. The immature remainder must be ACCOUNTED FOR, not dropped. ───────
# Without this, step 6 alone would also pass on a wallet that credited a single
# coinbase and lost the other 100. trusted + immature must equal every satoshi
# mined (5050 BTC), with the split landing exactly on Core's 101-conf boundary.
GB=$(rpc getbalances "[]" "w1")
echo "$GB" | grep -q '"error":{' && fail "getbalances error: $(echo "$GB" | grep -o '"message":"[^"]*"' | head -1)"
IMM_BTC=$(echo "$GB" | grep -o '"immature":[0-9.]*' | head -1 | sed 's/"immature"://')
[[ -n "$IMM_BTC" ]] || fail "getbalances returned no mine.immature field: $(echo "$GB" | head -c 300)"
IMM_SATS=$(btc_to_sats "$IMM_BTC")
log "getbalances immature = $IMM_BTC BTC ($IMM_SATS sats)"
[[ "$IMM_SATS" -eq "$IMMATURE_SATS" ]] \
    || fail "getbalances immature $IMM_SATS sats != expected $IMMATURE_SATS sats at tip $HEIGHT (the 100 immature coinbases are not all being tracked)"
ACCOUNTED=$(( BAL_BEFORE_SATS + IMM_SATS ))
[[ "$ACCOUNTED" -eq "$TOTAL_MINED_SATS" ]] \
    || fail "trusted+immature = $ACCOUNTED sats != $TOTAL_MINED_SATS sats mined in $NBLOCKS blocks (coins unaccounted for)"
log "maturity boundary OK: 1 mature ($BAL_BEFORE_SATS) + 100 immature ($IMM_SATS) = all $NBLOCKS coinbases"

# ── 7. listunspent lists the owned UTXOs. ──────────────────────────────────
LU_BEFORE=$(rpc listunspent "[]" "w1")
echo "$LU_BEFORE" | grep -q '"error":{' && fail "listunspent error: $(echo "$LU_BEFORE" | grep -o '"message":"[^"]*"' | head -1)"
N_BEFORE=$(count_unspent "$LU_BEFORE")
[[ "${N_BEFORE:-0}" -gt 0 ]] || fail "listunspent returned 0 UTXOs after funding"
log "listunspent BEFORE = $N_BEFORE UTXOs"

# ── 8. Negative control: foreign recipient holds nothing yet. ──────────────
r=$(rpc scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]")
PRE_RECIP_SATS=$(scan_total_sats "$r")
log "recipient PRE-spend on-chain = ${PRE_RECIP_SATS:-?} sats"
[[ "${PRE_RECIP_SATS:-0}" -eq 0 ]] || fail "recipient already funded before spend (${PRE_RECIP_SATS} sats)"

# ── 9. sendtoaddress -> txid, tx enters mempool. ───────────────────────────
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR (from w1)"
SEND=$(rpc sendtoaddress "[\"$FOREIGN_ADDR\",$SEND_BTC]" "w1")
echo "$SEND" | grep -q '"error":{' \
    && fail "sendtoaddress error: $(echo "$SEND" | grep -o '"message":"[^"]*"' | head -1)"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
log "TXID=$TXID"

MEMPOOL=$(rpc getrawmempool)
echo "$MEMPOOL" | grep -q "$TXID" || fail "tx $TXID not in mempool after sendtoaddress: $(echo "$MEMPOOL" | head -c 200)"
log "tx is in mempool"

# ── 10. Mine 1 block -> the tx CONFIRMS. ───────────────────────────────────
log "generatetoaddress 1 -> $A1 (confirm the spend)"
r=$(rpc generatetoaddress "[1,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "confirm-block generate error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -gt "$HEIGHT" ]] || fail "height did not advance on confirm block"
log "height after confirm = $HEIGHT2"

# ── 11. Mempool no longer lists the confirmed tx (no wedge / re-broadcast). ─
MEMPOOL2=$(rpc getrawmempool)
echo "$MEMPOOL2" | grep -q "$TXID" && fail "tx $TXID STILL in mempool after confirmation (mempool wedge)"
log "mempool cleared the confirmed tx"

# ── 12. Recipient credited EXACTLY <amt> on-chain (scantxoutset oracle). ────
r=$(rpc scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]")
echo "$r" | grep -q '"error":{' && fail "scantxoutset recipient error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
RECIP_SATS=$(scan_total_sats "$r")
[[ -n "$RECIP_SATS" ]] || fail "scantxoutset recipient returned no total_amount"
log "recipient POST-spend on-chain = $RECIP_SATS sats (want $SEND_SATS)"
[[ "$RECIP_SATS" -eq "$SEND_SATS" ]] \
    || fail "recipient credited $RECIP_SATS sats != sent $SEND_SATS sats"

# ── 13. Sender getbalance dropped by amount + fee. ─────────────────────────
# Change returns to the wallet, so the net debit of the SPEND is exactly
# amount + fee. But mining the confirm block to A1 also matures the next
# coinbase, which ADDS 50 BTC of newly-spendable balance. At tip 102 the mature
# set is heights {2,3} coinbases (height 1 was consumed by the spend) + the
# change output. So:
#   balance_after = before - (height-1 coinbase consumed) + (height-3 matured)
#                            + change_returned
#   where change_returned = (height-1 coinbase) - amount - fee.
# Net: balance_after = before + 50BTC(matured) - amount - fee.
# Solve for the implied fee:
BAL_AFTER_BTC=$(result_num "$(rpc getbalance "[]" "w1")")
[[ -n "$BAL_AFTER_BTC" ]] || fail "getbalance AFTER returned no result"
BAL_AFTER_SATS=$(btc_to_sats "$BAL_AFTER_BTC")
log "getbalance AFTER = $BAL_AFTER_BTC BTC ($BAL_AFTER_SATS sats)"

MATURED_IN=$(( 50 * 100000000 ))   # the next coinbase matures at the confirm block
EXPECTED_AFTER_NOFEE=$(( BAL_BEFORE_SATS + MATURED_IN - SEND_SATS ))
DEBIT_FEE=$(( EXPECTED_AFTER_NOFEE - BAL_AFTER_SATS ))
log "implied fee (sender debit beyond amount) = $DEBIT_FEE sats"
[[ "$DEBIT_FEE" -gt 0 ]] || fail "no fee debited (sender balance arithmetic wrong: before=$BAL_BEFORE_SATS after=$BAL_AFTER_SATS)"
[[ "$DEBIT_FEE" -lt 100000 ]] || fail "implied fee $DEBIT_FEE sats unreasonably large (balance accounting drift)"
SENDER_DEBITED=$(( SEND_SATS + DEBIT_FEE ))
log "sender debited amount+fee = $SENDER_DEBITED sats"

# ── 14. listunspent reflects the post-spend set. ───────────────────────────
LU_AFTER=$(rpc listunspent "[]" "w1")
echo "$LU_AFTER" | grep -q '"error":{' && fail "listunspent AFTER error"
N_AFTER=$(count_unspent "$LU_AFTER")
log "listunspent AFTER = $N_AFTER UTXOs (was $N_BEFORE)"
[[ "${N_AFTER:-0}" -gt 0 ]] || fail "listunspent AFTER is empty (ledger lost track of coins)"
[[ "$N_AFTER" != "$N_BEFORE" ]] || fail "listunspent count unchanged after spend+block (ledger not updating)"

# ── 15. Success. ───────────────────────────────────────────────────────────
log "PASS: funded=$FUNDED_BTC BTC sent=$SEND_BTC BTC recipient=$SEND_BTC BTC sender_debited=$SENDER_DEBITED sats mempool=clean"
pass "$FUNDED_BTC" "$SEND_BTC" "$SEND_BTC" "$SENDER_DEBITED" "$DEBIT_FEE"

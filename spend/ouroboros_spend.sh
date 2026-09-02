#!/usr/bin/env bash
#
# ouroboros_spend.sh — self-contained wallet-native spend regression test.
#
# Codifies the "wallet can see and spend its own coins" cell for ouroboros,
# the successor to the wallet-recovery cell (ouroboros_recovery.sh). Proves the
# full on-chain spend round-trip on regtest using ONLY wallet-native RPCs:
#
#   createwallet w1                    -> Core auto-creates no wallet (-18
#                                        until one exists; util.cpp:82)
#   sethdseed <fixed seed>             -> deterministic key pool on w1, which
#                                        the base "/" endpoint resolves to
#   getnewaddress bech32 -> A1
#   generatetoaddress 101 -> A1        -> fund A1 with mined coinbase
#   getbalance                          -> reflects spendable (MATURE) coins
#                                          (Core: coinbase matures at 100 conf;
#                                          only the height-1 coinbase is mature
#                                          at tip 101 -> exactly 50 BTC)
#   listunspent [A1]                    -> lists the owned UTXOs
#   sendtoaddress <foreign-addr> <amt>  -> returns a txid, tx enters mempool
#   generatetoaddress 1 -> A1          -> the tx CONFIRMS (miner includes it)
#   ASSERT:
#     * recipient address credited <amt>     (verified via scantxoutset, the
#       authoritative on-chain UTXO oracle — independent of wallet bookkeeping)
#     * sender getbalance dropped by <amt>+fee (change returns to the wallet,
#       net of the height-2 coinbase that matures on the confirm block)
#     * mempool no longer lists the confirmed tx (no BIP30 wedge / re-broadcast,
#       proven by mining a further block successfully)
#     * listunspent reflects the post-spend set (count changed)
#
# Recipient is a FOREIGN regtest address (not derivable from our seed) so the
# recipient credit is proven purely on-chain via scantxoutset.
#
# STRICT UNIFORM INTERFACE (mirrors beamchain_spend.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: SPEND ouroboros: PASS funded=<X> sent=<Y> recipient=<Y> sender_debited=<...> mempool=clean
#   FAIL: SPEND ouroboros: FAIL <short reason>
#
# Touches ONLY /tmp/spendfleet-ouroboros/ and ports 21612 (RPC) / 21632 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
RPC_PORT=21612
P2P_PORT=21632
DATADIR="/tmp/spendfleet-ouroboros"
LOGFILE="$DATADIR/node.log"

# Fixed BIP32 raw seed (32 bytes) — the same seed the recovery cell uses, so
# the two tests share a wallet identity. Restore mechanism = sethdseed.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

# A foreign regtest address NOT derived from our seed — the spend recipient.
FOREIGN_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

# Coinbase maturity on regtest is 100. Mine 101 so EXACTLY the first reward
# (height 1, subsidy 50 BTC) is mature/spendable at tip 101 — getbalance must
# report 50 BTC, proving maturity is enforced (the other 100 are immature).
NBLOCKS=101
FUNDED_BTC=50            # expected spendable balance after funding
SEND_BTC=10              # amount to send
SEND_SATS=1000000000     # 10 BTC in satoshis

# Resolve the ouroboros checkout relative to this script:
# test-suite/spend/ -> repo root -> ouroboros/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OURO_DIR="$REPO_ROOT/ouroboros"

NODE_PID=""
COOKIE=""

# ── Logging: everything noisy goes to stderr, never stdout. ────────────────
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
    echo "SPEND ouroboros: PASS funded=$1 sent=$2 recipient=$3 sender_debited=$4 fee_sats=$5 mempool=clean"
    exit 0
}
fail() {
    echo "SPEND ouroboros: FAIL $*"
    exit 1
}

# ── RPC helper (cookie auth). usage: rpc <method> <params-json> ────────────
rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 60 -u "$COOKIE" \
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
# Convert a BTC decimal string to integer satoshis without bc.
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
    amt=$(echo "$1" | grep -o '"total_amount":[0-9.]*' | head -1 | sed 's/.*://; s/[" ]//g')
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
# 150s (not 45s): ouroboros is Python — slowest startup — and under the nightly
# guard it launches after many other regtest nodes, so its RPC can take well over
# 45s to come up under that accumulated load.
deadline=$(( $(date +%s) + 150 ))
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
[[ -n "$COOKIE" ]] || fail "cookie never appeared within 150s"
r=$(rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "RPC never responded within 150s"

# ── 4. Create the wallet, restore the fixed seed on it, derive A1. ─────────
# Core auto-creates NO default wallet (bitcoin-core/src/wallet/rpc/util.cpp:82
# — "No wallet is loaded. Load a wallet using loadwallet or create a new one
# with createwallet. (Note: A default wallet is no longer automatically
# created)", RPC_WALLET_NOT_FOUND = -18, src/rpc/protocol.h:80). ouroboros is
# faithful to that: a freshly booted node has zero loaded wallets, so every
# wallet RPC on the base "/" endpoint answers -18 until a wallet exists.
# Assert that Core-shaped precondition FIRST (a node that silently auto-creates
# a keyed default wallet is diverging from Core, and this arm must not hide
# it), then create the wallet explicitly. With exactly one wallet loaded the
# base "/" endpoint resolves to it (GetWalletForJSONRPCRequest ->
# GetDefaultWallet), so the rest of this test keeps using "/" unchanged.
log "precondition: no wallet loaded on a fresh node"
r=$(rpc listwallets)
echo "$r" | grep -q '"result":\[\]' \
    || fail "fresh node should have zero loaded wallets (Core auto-creates none), got: $(echo "$r" | head -c 200)"
r=$(rpc sethdseed "[\"$SEED\"]")
echo "$r" | grep -q '"code":-18' \
    || fail "wallet RPC with no wallet loaded should be -18 (Core util.cpp:82), got: $(echo "$r" | head -c 200)"

log "createwallet w1"
r=$(rpc createwallet '["w1"]')
echo "$r" | grep -q '"name":"w1"' || fail "createwallet w1 failed: $(echo "$r" | head -c 200)"
r=$(rpc listwallets)
echo "$r" | grep -q '"w1"' \
    || fail "listwallets does not report w1 after createwallet: $(echo "$r" | head -c 200)"

log "sethdseed (fixed) on the default (single loaded) wallet"
r=$(rpc sethdseed "[\"$SEED\"]")
echo "$r" | grep -q "$SEED" || fail "sethdseed failed: $(echo "$r" | head -c 200)"

log "getnewaddress bech32 -> A1"
A1=$(result_str "$(rpc getnewaddress '["", "bech32"]')")
[[ -n "$A1" ]] || fail "getnewaddress returned no address"
log "A1=$A1"

# ── 5. Fund A1 with coinbase. ──────────────────────────────────────────────
log "generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# ── 6. getbalance reflects spendable (MATURE) coins. ───────────────────────
# At tip 101 only the height-1 coinbase is mature -> exactly 50 BTC.
BAL_BEFORE_BTC=$(result_num "$(rpc getbalance)")
[[ -n "$BAL_BEFORE_BTC" ]] || fail "getbalance returned no result: $(rpc getbalance | head -c 200)"
BAL_BEFORE_SATS=$(btc_to_sats "$BAL_BEFORE_BTC")
log "getbalance BEFORE = $BAL_BEFORE_BTC BTC ($BAL_BEFORE_SATS sats)"
EXPECT_FUNDED_SATS=$(( FUNDED_BTC * 100000000 ))
[[ "$BAL_BEFORE_SATS" -eq "$EXPECT_FUNDED_SATS" ]] \
    || fail "getbalance $BAL_BEFORE_SATS sats != expected mature $EXPECT_FUNDED_SATS sats (coinbase maturity not enforced?)"

# ── 7. listunspent lists the owned UTXOs. ──────────────────────────────────
LU_BEFORE=$(rpc listunspent "[1,9999999,[\"$A1\"]]")
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
log "sendtoaddress $SEND_BTC -> $FOREIGN_ADDR"
SEND=$(rpc sendtoaddress "[\"$FOREIGN_ADDR\",$SEND_BTC]")
echo "$SEND" | grep -q '"error":{' \
    && fail "sendtoaddress error: $(echo "$SEND" | grep -o '"message":"[^"]*"' | head -1)"
TXID=$(result_str "$SEND")
[[ -n "$TXID" ]] || fail "sendtoaddress returned no txid: $(echo "$SEND" | head -c 200)"
log "TXID=$TXID"

MEMPOOL=$(rpc getrawmempool)
echo "$MEMPOOL" | grep -q "$TXID" || fail "tx $TXID not in mempool after sendtoaddress: $(echo "$MEMPOOL" | head -c 200)"
log "tx is in mempool"

# ── 10. Mine 1 block -> the tx CONFIRMS (miner must include it). ───────────
log "generatetoaddress 1 -> $A1 (confirm the spend)"
r=$(rpc generatetoaddress "[1,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "confirm-block generate error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT2=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT2:-0}" -gt "$HEIGHT" ]] || fail "height did not advance on confirm block"
log "height after confirm = $HEIGHT2"

# ── 11. Mempool no longer lists the confirmed tx (no wedge). ───────────────
MEMPOOL2=$(rpc getrawmempool)
echo "$MEMPOOL2" | grep -q "$TXID" && fail "tx $TXID STILL in mempool after confirmation (mempool wedge)"
log "mempool cleared the confirmed tx"

# ── 11b. Mining a further block must still succeed (no BIP30 wedge). ───────
r=$(rpc generatetoaddress "[1,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "BIP30 wedge: block after the spend failed: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT3=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT3:-0}" -gt "$HEIGHT2" ]] || fail "BIP30 wedge: height did not advance on post-spend block"
log "post-spend block connected (height $HEIGHT3)"

# ── 12. Recipient credited <amt> on-chain (scantxoutset oracle). ───────────
r=$(rpc scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]")
echo "$r" | grep -q '"success":true' || fail "scantxoutset recipient did not succeed"
RECIP_SATS=$(scan_total_sats "$r")
[[ -n "$RECIP_SATS" ]] || fail "scantxoutset recipient returned no total_amount"
log "recipient POST-spend on-chain = $RECIP_SATS sats (want $SEND_SATS)"
[[ "$RECIP_SATS" -eq "$SEND_SATS" ]] \
    || fail "recipient credited $RECIP_SATS sats != sent $SEND_SATS sats"

# ── 13. Sender getbalance dropped by amount + fee. ─────────────────────────
# Mining the confirm + post-spend blocks to A1 matures the height-2 and
# height-3 coinbases (+50 BTC each) and adds new immature coinbases (excluded).
# So: after = before + matured_in - SEND - fee, where matured_in is the count
# of coinbases that crossed the maturity line. We assert the fee component is
# positive and small (a real fee was paid) and that the recipient on-chain
# credit is exactly SEND (the load-bearing transfer assertion in step 12).
BAL_AFTER_BTC=$(result_num "$(rpc getbalance)")
[[ -n "$BAL_AFTER_BTC" ]] || fail "getbalance AFTER returned no result"
BAL_AFTER_SATS=$(btc_to_sats "$BAL_AFTER_BTC")
log "getbalance AFTER = $BAL_AFTER_BTC BTC ($BAL_AFTER_SATS sats)"

# Three blocks were mined to A1 after funding (1 confirm + 1 BIP30 + the funding
# tip itself already counted). Between tip $HEIGHT (101) and $HEIGHT3 (103) two
# coinbases (heights 2 and 3) matured -> +100 BTC. The change returned to the
# wallet, so the only net loss is SEND + fee.
MATURED_IN=$(( (HEIGHT3 - HEIGHT) * 50 * 100000000 ))
EXPECTED_AFTER_NOFEE=$(( BAL_BEFORE_SATS + MATURED_IN - SEND_SATS ))
DEBIT_FEE=$(( EXPECTED_AFTER_NOFEE - BAL_AFTER_SATS ))
log "implied fee (sender debit beyond amount) = $DEBIT_FEE sats"
[[ "$DEBIT_FEE" -gt 0 ]] || fail "no fee debited (balance arithmetic wrong: before=$BAL_BEFORE_SATS after=$BAL_AFTER_SATS matured=$MATURED_IN)"
[[ "$DEBIT_FEE" -lt 100000 ]] || fail "implied fee $DEBIT_FEE sats unreasonably large (balance accounting drift)"
SENDER_DEBITED=$(( SEND_SATS + DEBIT_FEE ))
log "sender debited amount+fee = $SENDER_DEBITED sats"

# ── 14. listunspent reflects the post-spend set. ───────────────────────────
LU_AFTER=$(rpc listunspent "[1,9999999,[\"$A1\"]]")
echo "$LU_AFTER" | grep -q '"error":{' && fail "listunspent AFTER error"
N_AFTER=$(count_unspent "$LU_AFTER")
log "listunspent AFTER = $N_AFTER UTXOs (was $N_BEFORE)"
[[ "${N_AFTER:-0}" -gt 0 ]] || fail "listunspent AFTER is empty (ledger lost track of coins)"
[[ "$N_AFTER" != "$N_BEFORE" ]] || fail "listunspent count unchanged after spend+blocks (ledger not updating)"

# ── 15. Success. ───────────────────────────────────────────────────────────
log "PASS: funded=$FUNDED_BTC sent=$SEND_BTC recipient=$SEND_BTC sender_debited=$SENDER_DEBITED fee=$DEBIT_FEE"
pass "$FUNDED_BTC" "$SEND_BTC" "$SEND_BTC" "$SENDER_DEBITED" "$DEBIT_FEE"

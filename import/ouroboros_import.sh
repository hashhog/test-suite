#!/usr/bin/env bash
#
# ouroboros_import.sh — self-contained wallet IMPORT+RESCAN test.
#
# Codifies the "wallet rescans the existing chain to (re)discover its funds"
# cell for ouroboros, the successor to recovery (ouroboros_recovery.sh), spend
# (ouroboros_spend.sh) and history (ouroboros_history.sh). Proves a REAL wallet
# rescan — rescanblockchain — credits the wallet's own on-chain funds, plus
# importprivkey adopting a FOREIGN key's funds, on regtest using only
# wallet-native RPCs. This is wallet bookkeeping, NOT consensus.
#
#   CORE CAPABILITY — rescanblockchain (REQUIRED for green):
#     * Restore the FIXED seed into wallet W1 -> getnewaddress A1 ->
#       generatetoaddress 101 A1 (W1 mature balance M).
#     * Create a FRESH wallet W2 restored from the SAME seed -> getbalance == 0
#       (restore derives keys but does NOT scan the chain).
#     * rescanblockchain on W2 -> getbalance == M and listunspent shows A1's
#       UTXOs (the wallet rediscovered its funds via a REAL wallet rescan, not
#       scantxoutset). THE HEADLINE PROOF.
#     * rescanblockchain returns the Core shape {start_height, stop_height}.
#     * Re-running the rescan is idempotent (no double-count).
#
#   SECOND CAPABILITY — importprivkey (TARGET):
#     * Derive a foreign key K_ext + its address A_ext from a FIXED scalar via
#       ouroboros's own WIF/address encoding (NOT in W2's seed).
#     * generatetoaddress to A_ext to fund it.
#     * importprivkey(K_ext, rescan=true) into W2 -> W2 now also sees A_ext's
#       mature funds (foreign-key adoption).
#
# rescanblockchain / importprivkey shapes + semantics mirror bitcoin-core
# wallet/rpc/transactions.cpp (rescanblockchain), wallet/rpc/backup.cpp
# (importprivkey) and CWallet::ScanForWalletTransactions.
#
# STRICT UNIFORM INTERFACE (mirrors ouroboros_history.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: IMPORT ouroboros: PASS rescan=ok importprivkey=<ok|partial|absent> rediscovered=<M>
#   FAIL: IMPORT ouroboros: FAIL <short reason>
# Green REQUIRES rescan=ok. exit 0 = PASS, exit 1 = FAIL.
#
# Touches ONLY /tmp/importfleet-ouroboros/ and ports 21712 (RPC) / 21732 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
RPC_PORT=21712
P2P_PORT=21732
DATADIR="/tmp/importfleet-ouroboros"
LOGFILE="$DATADIR/node.log"

# Fixed BIP32 raw seed (32 bytes) — the SAME seed the recovery + spend +
# history cells use, so all four tests share a wallet identity.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

# A foreign key derived from a FIXED scalar (NOT from SEED), via ouroboros's
# own WalletKey WIF/address encoding (regtest). Generated once and hard-coded
# here so the test is deterministic and needs no dumpprivkey:
#   WalletKey(0x1111..11, "regtest"):
K_EXT="cN9spWsvaxA8taS7DFMxnk1yJD2gaF2PX1npuTpy3vuZFJdwavaw"
A_EXT="tb1ql3e9pgs3mmwuwrh95fecme0s0qtn28804khrk8"

NBLOCKS=101              # fund: 101 coinbases to A1 (only height-1 reward mature)

# Resolve the ouroboros checkout relative to this script:
# test-suite/import/ -> repo root -> ouroboros/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OURO_DIR="$REPO_ROOT/ouroboros"

NODE_PID=""
COOKIE=""

# ── Logging: everything noisy goes to stderr, never stdout. ────────────────
log() { echo "[import] $*" >&2; }

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
# pass <importprivkey-state> <rediscovered-M>
pass() {
    echo "IMPORT ouroboros: PASS rescan=ok importprivkey=$1 rediscovered=$2"
    exit 0
}
fail() {
    echo "IMPORT ouroboros: FAIL $*"
    exit 1
}

# ── RPC helpers (cookie auth). ─────────────────────────────────────────────
# rpc <method> <params-json>            -> default (no wallet) endpoint
rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 120 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}
# wrpc <wallet> <method> <params-json>  -> /wallet/<name> endpoint
wrpc() {
    local wallet="$1" method="$2" params="${3:-[]}"
    curl -s --max-time 120 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/wallet/$wallet" 2>/dev/null
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

# ── 3. Locate the cookie + wait for RPC (generous: ouroboros is Python). ───
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

# ── 4. Create W1 + W2, restore the SAME fixed seed on W1. ──────────────────
log "createwallet W1, W2"
echo "$(rpc createwallet '["W1"]')" | grep -q '"name":"W1"' || fail "createwallet W1 failed"
echo "$(rpc createwallet '["W2"]')" | grep -q '"name":"W2"' || fail "createwallet W2 failed"

log "W1 sethdseed (fixed)"
r=$(wrpc W1 sethdseed "[\"$SEED\"]")
echo "$r" | grep -q "$SEED" || fail "W1 sethdseed failed: $(echo "$r" | head -c 200)"

log "W1 getnewaddress bech32 -> A1"
A1=$(result_str "$(wrpc W1 getnewaddress '["", "bech32"]')")
[[ -n "$A1" ]] || fail "W1 getnewaddress returned no address"
log "A1=$A1"

# ── 5. Fund A1 with 101 coinbase txs (only height-1 reward matures). ───────
log "W1 generatetoaddress $NBLOCKS -> A1"
r=$(wrpc W1 generatetoaddress "[$NBLOCKS,\"$A1\"]")
echo "$r" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(wrpc W1 getblockcount)")
[[ "${HEIGHT%.*}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# W1's mature balance M (the height-1 coinbase, now matured at tip>=101 = 50).
M=$(result_num "$(wrpc W1 getbalance)")
[[ -n "$M" ]] || fail "W1 getbalance returned nothing"
# M must be positive (at least one matured coinbase).
awk -v m="$M" 'BEGIN{exit !(m+0 > 0)}' || fail "W1 mature balance not positive (got $M)"
log "W1 mature balance M=$M"

# ── 6. W2 restored from the SAME seed: balance 0 BEFORE any rescan. ────────
log "W2 sethdseed (restore SAME seed)"
r=$(wrpc W2 sethdseed "[\"$SEED\"]")
echo "$r" | grep -q "$SEED" || fail "W2 sethdseed failed: $(echo "$r" | head -c 200)"

B2_BEFORE=$(result_num "$(wrpc W2 getbalance)")
log "W2 balance BEFORE rescan=$B2_BEFORE (expect 0)"
awk -v b="$B2_BEFORE" 'BEGIN{exit !(b+0 == 0)}' \
    || fail "W2 restore alone credited funds without a rescan (got $B2_BEFORE, want 0) — rescan would be a no-op proof"

LU_BEFORE=$(wrpc W2 listunspent)
echo "$LU_BEFORE" | grep -q '"result":\[\]' \
    || fail "W2 listunspent non-empty before rescan: $(echo "$LU_BEFORE" | head -c 160)"

# ── 7. THE HEADLINE PROOF: rescanblockchain on W2. ─────────────────────────
log "W2 rescanblockchain"
RS=$(wrpc W2 rescanblockchain)
echo "$RS" | grep -q '"error":{' && fail "rescanblockchain error: $(echo "$RS" | grep -o '"message":"[^"]*"' | head -1)"
# Core shape: {start_height, stop_height}.
echo "$RS" | grep -q '"start_height"' || fail "rescanblockchain missing start_height: $(echo "$RS" | head -c 160)"
echo "$RS" | grep -q '"stop_height"'  || fail "rescanblockchain missing stop_height: $(echo "$RS" | head -c 160)"
RS_STOP=$(echo "$RS" | grep -o '"stop_height":[0-9]*' | head -1 | sed 's/.*://')
[[ "${RS_STOP:-0}" -ge "$NBLOCKS" ]] || fail "rescan stop_height $RS_STOP < $NBLOCKS"
log "rescanblockchain -> $RS"

# After the rescan, W2 must have rediscovered EXACTLY M.
B2_AFTER=$(result_num "$(wrpc W2 getbalance)")
log "W2 balance AFTER rescan=$B2_AFTER (expect M=$M)"
awk -v a="$B2_AFTER" -v m="$M" 'BEGIN{exit !(((a-m)<0?(m-a):(a-m)) < 1e-6)}' \
    || fail "W2 balance after rescan ($B2_AFTER) != W1 mature balance M ($M)"

# And listunspent must now surface A1's UTXOs.
LU_AFTER=$(wrpc W2 listunspent)
echo "$LU_AFTER" | grep -q "$A1" \
    || fail "W2 listunspent after rescan does not show A1 ($A1): $(echo "$LU_AFTER" | head -c 200)"
log "W2 listunspent after rescan shows A1's UTXOs"

# Idempotency: re-running the rescan must NOT change the balance.
wrpc W2 rescanblockchain >/dev/null
B2_AGAIN=$(result_num "$(wrpc W2 getbalance)")
awk -v a="$B2_AFTER" -v b="$B2_AGAIN" 'BEGIN{exit !(((a-b)<0?(b-a):(a-b)) < 1e-6)}' \
    || fail "rescan not idempotent: balance changed $B2_AFTER -> $B2_AGAIN on re-run"
log "rescan idempotent (re-run kept balance $B2_AGAIN)"

# RESCAN is now proven green. Anything below is the importprivkey target.
RESCAN_OK=1

# ── 8. importprivkey TARGET: adopt a FOREIGN key's funds into W2. ──────────
IMPORT_STATE="absent"

# Ownership is measured via the wallet's OWN balance / no-filter listunspent
# (which require the key to be in the wallet), NOT an address-filtered
# listunspent — that latter queries the chainstate by address and would see
# the coins whether or not the wallet owns the key, so it cannot prove
# adoption. A_ext is derived from a fixed scalar, NOT SEED, so it is not yet
# in W2's no-filter view.
if wrpc W2 listunspent | grep -q "$A_EXT"; then
    log "WARN: A_ext unexpectedly already owned by W2 before import — skipping import proof"
else
    # Fund A_ext with coinbases so it carries real mature on-chain value.
    log "W1 generatetoaddress 101 -> A_ext (fund the foreign key)"
    r=$(wrpc W1 generatetoaddress "[101,\"$A_EXT\"]")
    if echo "$r" | grep -q '"error":{'; then
        log "WARN: funding A_ext failed: $(echo "$r" | grep -o '"message":"[^"]*"' | head -1)"
    else
        # Chain truly holds A_ext funds (independent witness via scantxoutset).
        EXT_CHAIN=$(wrpc W1 scantxoutset "[\"start\",[\"addr($A_EXT)\"]]")
        EXT_TOTAL=$(echo "$EXT_CHAIN" | grep -o '"total_amount":[0-9.]*' | head -1 | sed 's/.*://')
        log "A_ext chain total (scantxoutset)=$EXT_TOTAL"
        awk -v t="$EXT_TOTAL" 'BEGIN{exit !(t+0 > 0)}' || log "WARN: A_ext chain total not positive"

        # W2's OWN total balance immediately BEFORE the import. No blocks are
        # mined between this and the post-import read, so W2's own A1 funds are
        # frozen — the only balance delta is A_ext's adoption by the import.
        OWN_BEFORE=$(result_num "$(wrpc W2 getbalance)")
        log "W2 total balance before import=$OWN_BEFORE"

        # Sanity: A_ext is NOT in W2's owned (no-filter) listunspent yet.
        wrpc W2 listunspent | grep -q "$A_EXT" \
            && log "WARN: A_ext already in W2 owned UTXOs before import"

        log "W2 importprivkey K_ext (rescan=true)"
        IMP=$(wrpc W2 importprivkey "[\"$K_EXT\",\"ext\",true]")
        if echo "$IMP" | grep -q '"error":{'; then
            log "WARN: importprivkey errored: $(echo "$IMP" | grep -o '"message":"[^"]*"' | head -1)"
            IMPORT_STATE="partial"
        else
            # importprivkey returns null on success (Core shape).
            echo "$IMP" | grep -q '"result":null' || log "note: importprivkey result=$(echo "$IMP" | head -c 80)"

            OWN_AFTER=$(result_num "$(wrpc W2 getbalance)")
            log "W2 total balance after import=$OWN_AFTER (was $OWN_BEFORE)"

            # Proof of adoption (both must hold):
            #  (a) W2's no-filter (owned) listunspent now contains A_ext — only
            #      possible if the imported key made A_ext wallet-owned.
            #  (b) W2's total balance grew by A_ext's mature amount.
            OWNED_NOW=$(wrpc W2 listunspent)
            if echo "$OWNED_NOW" | grep -q "$A_EXT" \
               && awk -v a="$OWN_AFTER" -v b="$OWN_BEFORE" 'BEGIN{exit !(a+0 > b+0)}'; then
                IMPORT_STATE="ok"
                ADOPTED=$(awk -v a="$OWN_AFTER" -v b="$OWN_BEFORE" 'BEGIN{printf "%.8f", a-b}')
                log "importprivkey adopted A_ext into W2 (owned listunspent has A_ext; balance +$ADOPTED BTC)"
            else
                log "WARN: A_ext not adopted into W2's owned view after import"
                IMPORT_STATE="partial"
            fi
        fi
    fi
fi

# ── 9. Success (rescan green is required; importprivkey state is reported). ─
[[ "${RESCAN_OK:-0}" -eq 1 ]] || fail "rescan did not reach green"
log "PASS: rescan=ok importprivkey=$IMPORT_STATE rediscovered=$M"
pass "$IMPORT_STATE" "$M"

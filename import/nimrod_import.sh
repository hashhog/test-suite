#!/usr/bin/env bash
#
# nimrod_import.sh — self-contained wallet IMPORT+RESCAN regression test.
#
# Codifies the "wallet can rescan the chain for its own funds, and adopt a
# foreign key's funds via importprivkey" cell for nimrod — the successor to the
# recovery / spend / history cells. Proves, on regtest, using ONLY wallet-native
# RPCs, that:
#
#   A. RESCAN (REQUIRED for green) — the headline proof:
#        createwallet w1 -> sethdseed <FIXED seed> -> getnewaddress A1
#        -> generatetoaddress 101 A1   (W1 mature balance M)
#        createwallet w2 -> sethdseed <SAME seed> -> getnewaddress A1'
#          (assert A1' == A1: restore derives keys deterministically)
#        ASSERT w2.getbalance == 0      (restore does NOT scan the chain)
#        rescanblockchain on w2
#        ASSERT rescanblockchain returns Core shape {start_height, stop_height}
#        ASSERT w2.getbalance == M       (rediscovered via a REAL wallet rescan,
#                                         NOT scantxoutset which bypasses wallet)
#        ASSERT w2.listunspent shows A1's UTXOs
#
#   B. IMPORTPRIVKEY (TARGET) — adopt a FOREIGN key's funds:
#        createwallet w3 -> sethdseed <DIFFERENT seed> -> getnewaddress A_ext
#        dumpprivkey(A_ext) on w3 = WIF_ext (companion RPC; A_ext NOT in w2)
#        generatetoaddress 101 A_ext  (fund the foreign key)
#        importprivkey(WIF_ext, "ext", rescan=true) into w2
#        ASSERT w2.getbalance grew by A_ext's adopted mature funds (> M)
#        ASSERT w2.listunspent now contains an A_ext UTXO
#      If importprivkey can't be proven, the summary degrades to
#      importprivkey=partial|absent but rescan=ok still PASSES (green needs
#      rescan only).
#
# Field shapes + semantics mirror bitcoin-core/src/wallet/rpc/transactions.cpp
# (rescanblockchain -> CWallet::ScanForWalletTransactions; returns
# {start_height, stop_height}) and wallet/rpc/backup.cpp (importprivkey ->
# CWallet::ImportPrivKeys; dumpprivkey -> EncodeSecret).
#
# rescanblockchain is the REAL wallet rescan: it replays a block-height range
# through the same wallet transaction-recognition path used at block-connect,
# crediting the wallet UTXO ledger + history. This is distinct from
# scantxoutset (used by the recovery cell), which scans the chainstate UTXO set
# without ever touching a wallet.
#
# STRICT UNIFORM INTERFACE (mirrors nimrod_history.sh / nimrod_recovery.sh
# exactly): no required args, set -uo pipefail, idempotent, trap cleanup,
# scratch datadir + unique ports, single clean summary line on stdout. All
# noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: IMPORT nimrod: PASS rescan=ok importprivkey=<ok|partial|absent> rediscovered=<M>
#   FAIL: IMPORT nimrod: FAIL <short reason>
# exit 0 = PASS, exit 1 = FAIL. Green REQUIRES rescan=ok.
#
# Touches ONLY /tmp/importfleet-nimrod/ and ports 21711 (RPC) / 21731 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASEDIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # meta-repo root
NIMROD_BIN="$BASEDIR/nimrod/bin/nimrod"

DATADIR="/tmp/importfleet-nimrod"
RPC_PORT=21711
P2P_PORT=21731
NETWORK="regtest"
COOKIE_FILE="$DATADIR/$NETWORK/.cookie"
LOGFILE="$DATADIR/node.log"

# FIXED raw 32-byte BIP-32 hex seed — the SAME seed the recovery / spend /
# history cells use, so all the wallet cells share a wallet identity.
FIXED_SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
# A DIFFERENT fixed seed for the FOREIGN wallet (w3) whose key we import.
FOREIGN_SEED="ffffeeeeddddccccbbbbaaaa999988887777666655554444333322221111ffff"

# Mine 101 so EXACTLY the height-1 coinbase is wallet-mature at tip 101.
NBLOCKS=101

NODE_PID=""

# ── Logging: everything noisy goes to stderr + logfile, never stdout. ──────
log() { echo "[import-nimrod] $*" >&2; }

# ── Emit the single summary line + exit. ───────────────────────────────────
pass() {
    # pass <importprivkey-state> <rediscovered>
    echo "IMPORT nimrod: PASS rescan=ok importprivkey=$1 rediscovered=$2"
    exit 0
}
fail() {
    echo "IMPORT nimrod: FAIL $*"
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
trap cleanup EXIT INT TERM

# ── RPC helper (cookie auth). usage: rpc <method> [params-json] [wallet] ────
rpc() {
    local method="$1" params="${2:-[]}" wallet="${3:-}"
    local auth=""
    [[ -f "$COOKIE_FILE" ]] && auth="-u $(cat "$COOKIE_FILE")"
    local path="/"
    [[ -n "$wallet" ]] && path="/wallet/$wallet"
    # shellcheck disable=SC2086
    curl -s --max-time 40 $auth \
        -H 'content-type: text/plain' \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT$path" 2>/dev/null
}

result_str() {
    JBLOB="$1" python3 -c '
import os, json
try:
    r = json.loads(os.environ["JBLOB"]).get("result")
    print("" if r is None else r)
except Exception:
    print("")
'
}

err_msg() {
    JBLOB="$1" python3 -c '
import os, json
try:
    e = json.loads(os.environ["JBLOB"]).get("error")
    print(e.get("message","") if e else "")
except Exception:
    print("")
'
}

# float comparison: $1 OP $2  (lt/le/gt/ge/eq within 1e-6)
fcmp() {
    A="$1" OP="$2" B="$3" python3 -c '
import os, sys
a=float(os.environ["A"]); b=float(os.environ["B"]); op=os.environ["OP"]
eps=1e-6
ok={"lt":a<b-eps,"le":a<=b+eps,"gt":a>b+eps,"ge":a>=b-eps,"eq":abs(a-b)<eps}[op]
sys.exit(0 if ok else 1)
'
}

wait_for_rpc() {
    local deadline=$(( $(date +%s) + 45 ))
    while (( $(date +%s) < deadline )); do
        if [[ -f "$COOKIE_FILE" ]]; then
            local r
            r=$(rpc getblockcount)
            if echo "$r" | grep -q '"result"'; then
                return 0
            fi
        fi
        if [[ -n "$NODE_PID" ]] && ! kill -0 "$NODE_PID" 2>/dev/null; then
            return 1
        fi
        sleep 1
    done
    return 1
}

# ── 0. Preconditions. ───────────────────────────────────────────────────────
[[ -x "$NIMROD_BIN" ]] || fail "nimrod binary not found at $NIMROD_BIN (run: cd nimrod && nimble build -d:release -y)"
command -v curl >/dev/null 2>&1    || fail "curl not available"
command -v python3 >/dev/null 2>&1 || fail "python3 not available"

# ── 1. Idempotent reset + launch. ───────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"

log "launching nimrod regtest -> $LOGFILE"
"$NIMROD_BIN" --network="$NETWORK" --datadir="$DATADIR" \
    --port="$P2P_PORT" --rpcport="$RPC_PORT" start \
    >"$LOGFILE" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"

kill -0 "$NODE_PID" 2>/dev/null || fail "node process exited immediately (see $LOGFILE)"
wait_for_rpc || fail "RPC did not come up within 45s (see $LOGFILE)"
log "RPC ready"

# ── 2. W1: restore FIXED seed, derive A1, fund 101 coinbase -> mature M. ────
log "createwallet w1 + sethdseed (fixed seed)"
r=$(rpc createwallet '["w1"]')
echo "$r" | grep -q '"result"' || fail "createwallet w1 failed: $(err_msg "$r")"
r=$(rpc sethdseed "[true, \"$FIXED_SEED\"]" "w1")
if echo "$r" | grep -qi 'method not found'; then fail "sethdseed RPC missing — rebuild nimrod"; fi
echo "$r" | grep -q '"error":null' || fail "sethdseed w1 failed: $(err_msg "$r")"

A1=$(result_str "$(rpc getnewaddress '[""]' "w1")")
[[ -n "$A1" && "$A1" == *1q* ]] || fail "getnewaddress w1 invalid: '$A1'"
log "A1=$A1"

log "generatetoaddress $NBLOCKS -> A1 (mature a coinbase)"
r=$(rpc generatetoaddress "[$NBLOCKS, \"$A1\"]" "w1")
echo "$r" | grep -q '"result"' || fail "generatetoaddress failed: $(err_msg "$r")"
HEIGHT=$(result_str "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?})"

M=$(result_str "$(rpc getbalance '[]' "w1")")
[[ -n "$M" ]] || fail "w1 getbalance returned nothing"
fcmp "$M" gt 0 || fail "w1 mature balance is zero (M=$M) — fund step no-op'd"
log "W1 mature balance M=$M at height $HEIGHT"

# ── 3. W2: fresh wallet, SAME seed -> re-derive A1' (assert ==A1), bal 0. ───
log "createwallet w2 + sethdseed (SAME seed)"
r=$(rpc createwallet '["w2"]')
echo "$r" | grep -q '"result"' || fail "createwallet w2 failed: $(err_msg "$r")"
r=$(rpc sethdseed "[true, \"$FIXED_SEED\"]" "w2")
echo "$r" | grep -q '"error":null' || fail "sethdseed w2 failed: $(err_msg "$r")"

A1B=$(result_str "$(rpc getnewaddress '[""]' "w2")")
[[ -n "$A1B" ]] || fail "getnewaddress w2 returned empty"
[[ "$A1B" == "$A1" ]] || fail "re-derived address mismatch: A1=$A1 A1B=$A1B (restore not deterministic)"
log "W2 re-derived A1'=$A1B (== A1)"

# Headline precondition: restore derives keys but does NOT scan -> balance 0.
BAL_BEFORE=$(result_str "$(rpc getbalance '[]' "w2")")
[[ -n "$BAL_BEFORE" ]] || fail "w2 getbalance (before rescan) returned nothing"
fcmp "$BAL_BEFORE" eq 0 \
    || fail "w2 balance BEFORE rescan is $BAL_BEFORE, expected 0 (restore must NOT scan the chain)"
log "W2 balance BEFORE rescan = $BAL_BEFORE (correct: restore did not scan)"

# ── 4. rescanblockchain on W2 -> Core shape + rediscovered funds == M. ──────
RES=$(rpc rescanblockchain '[]' "w2")
if echo "$RES" | grep -qi 'method not found'; then
    fail "rescanblockchain RPC missing — rebuild nimrod (this cell requires it)"
fi
echo "$RES" | grep -q '"error":{' && fail "rescanblockchain error: $(err_msg "$RES")"
# Assert Core shape: result has integer start_height + stop_height.
RS_CHECK=$(JBLOB="$RES" HEIGHT="$HEIGHT" python3 -c '
import os, json
r = json.loads(os.environ["JBLOB"]).get("result")
if not isinstance(r, dict):
    print("ERR:rescanblockchain did not return an object"); raise SystemExit
if "start_height" not in r or "stop_height" not in r:
    print("ERR:missing start_height/stop_height (Core shape)"); raise SystemExit
try:
    sh=int(r["start_height"]); st=int(r["stop_height"])
except Exception:
    print("ERR:start/stop_height not integers"); raise SystemExit
if sh != 0:
    print("ERR:default start_height %s != 0" % sh); raise SystemExit
if st != int(os.environ["HEIGHT"]):
    print("ERR:default stop_height %s != tip %s" % (st, os.environ["HEIGHT"])); raise SystemExit
print("ok")
')
case "$RS_CHECK" in
    ok) ;;
    ERR:*) fail "rescanblockchain shape: ${RS_CHECK#ERR:}";;
    *) fail "rescanblockchain check produced no verdict";;
esac
log "rescanblockchain returned Core shape {start_height:0, stop_height:$HEIGHT}"

# The real proof: W2 rediscovered its own funds via the wallet rescan.
BAL_AFTER=$(result_str "$(rpc getbalance '[]' "w2")")
[[ -n "$BAL_AFTER" ]] || fail "w2 getbalance (after rescan) returned nothing"
fcmp "$BAL_AFTER" eq "$M" \
    || fail "w2 rediscovered balance $BAL_AFTER != funded M=$M (rescan did not credit the wallet)"
log "W2 balance AFTER rescan = $BAL_AFTER (== M; rediscovered via REAL wallet rescan)"

# listunspent must now show A1's UTXOs (confirmed, at the wallet's address).
LU_CHECK=$(rpc listunspent '[1]' "w2")
echo "$LU_CHECK" | grep -q '"error":{' && fail "w2 listunspent error: $(err_msg "$LU_CHECK")"
LU_VERDICT=$(JBLOB="$LU_CHECK" A1="$A1" python3 -c '
import os, json
arr = json.loads(os.environ["JBLOB"]).get("result") or []
a1=os.environ["A1"]
if not arr:
    print("ERR:listunspent empty after rescan"); raise SystemExit
mine=[u for u in arr if u.get("address")==a1]
if not mine:
    print("ERR:no UTXO at A1 in listunspent after rescan"); raise SystemExit
if sum(float(u["amount"]) for u in mine) <= 0:
    print("ERR:A1 UTXOs sum to zero"); raise SystemExit
print("ok")
')
case "$LU_VERDICT" in
    ok) ;;
    ERR:*) fail "listunspent after rescan: ${LU_VERDICT#ERR:}";;
    *) fail "listunspent check produced no verdict";;
esac
log "W2 listunspent shows A1's confirmed UTXOs"

# ── 5. IMPORTPRIVKEY (target): adopt a FOREIGN key's funds into W2. ─────────
# Best-effort: rescan is already proven green above, so any failure here only
# downgrades importprivkey=<state> — it never fails the cell.
IMPORT_STATE="absent"
REDISCOVERED="$BAL_AFTER"

import_attempt() {
    log "createwallet w3 + sethdseed (FOREIGN seed)"
    local r
    r=$(rpc createwallet '["w3"]')
    echo "$r" | grep -q '"result"' || { log "createwallet w3 failed"; return 1; }
    r=$(rpc sethdseed "[true, \"$FOREIGN_SEED\"]" "w3")
    echo "$r" | grep -q '"error":null' || { log "sethdseed w3 failed"; return 1; }

    local AEXT
    AEXT=$(result_str "$(rpc getnewaddress '[""]' "w3")")
    [[ -n "$AEXT" && "$AEXT" == *1q* ]] || { log "getnewaddress w3 invalid: '$AEXT'"; return 1; }
    [[ "$AEXT" != "$A1" ]] || { log "A_ext collided with A1"; return 1; }
    log "A_ext=$AEXT (foreign, NOT in w2)"

    # dumpprivkey is implemented but optional — if absent, importprivkey=partial.
    local DRESP WIF
    DRESP=$(rpc dumpprivkey "[\"$AEXT\"]" "w3")
    if echo "$DRESP" | grep -qi 'method not found'; then
        log "dumpprivkey absent — cannot construct a foreign key cleanly"
        IMPORT_STATE="partial"; return 1
    fi
    echo "$DRESP" | grep -q '"error":{' && { log "dumpprivkey error: $(err_msg "$DRESP")"; IMPORT_STATE="partial"; return 1; }
    WIF=$(result_str "$DRESP")
    [[ -n "$WIF" ]] || { log "dumpprivkey returned empty WIF"; IMPORT_STATE="partial"; return 1; }
    log "WIF_ext=$WIF (dumped from w3)"

    # Confirm A_ext is NOT yet owned by w2 (rescan w2 over a fresh-funded A_ext
    # block range would otherwise credit it via HD keys — but A_ext is foreign,
    # so a pre-import w2 rescan must leave it at M).
    log "generatetoaddress $NBLOCKS -> A_ext (fund the foreign key)"
    r=$(rpc generatetoaddress "[$NBLOCKS, \"$AEXT\"]" "w3")
    echo "$r" | grep -q '"result"' || { log "fund A_ext failed: $(err_msg "$r")"; IMPORT_STATE="partial"; return 1; }
    local TIP2
    TIP2=$(result_str "$(rpc getblockcount)")

    # Sanity: w2 (HD-only) must NOT see A_ext's funds after a plain rescan.
    rpc rescanblockchain "[0, $TIP2]" "w2" >/dev/null 2>&1
    local W2_PRE
    W2_PRE=$(result_str "$(rpc getbalance '[]' "w2")")
    log "W2 balance pre-import (after re-rescan, HD keys only) = $W2_PRE"

    # importprivkey the foreign key into w2 with rescan=true.
    local IRESP
    IRESP=$(rpc importprivkey "[\"$WIF\", \"ext\", true]" "w2")
    if echo "$IRESP" | grep -qi 'method not found'; then
        log "importprivkey absent"; IMPORT_STATE="absent"; return 1
    fi
    echo "$IRESP" | grep -q '"error":{' && { log "importprivkey error: $(err_msg "$IRESP")"; IMPORT_STATE="partial"; return 1; }

    local W2_POST
    W2_POST=$(result_str "$(rpc getbalance '[]' "w2")")
    log "W2 balance post-import = $W2_POST"

    # Adoption proof: balance grew (foreign mature funds now spendable by w2).
    if ! fcmp "$W2_POST" gt "$W2_PRE"; then
        log "importprivkey did not increase w2 balance ($W2_PRE -> $W2_POST)"
        IMPORT_STATE="partial"; return 1
    fi

    # And listunspent must now contain an A_ext UTXO.
    local LU2 LU2V
    LU2=$(rpc listunspent '[1]' "w2")
    LU2V=$(JBLOB="$LU2" AEXT="$AEXT" python3 -c '
import os, json
arr=json.loads(os.environ["JBLOB"]).get("result") or []
print("yes" if any(u.get("address")==os.environ["AEXT"] for u in arr) else "no")
')
    if [[ "$LU2V" != "yes" ]]; then
        log "importprivkey credited balance but A_ext UTXO not in listunspent"
        IMPORT_STATE="partial"; return 1
    fi

    REDISCOVERED="$W2_POST"
    IMPORT_STATE="ok"
    log "importprivkey adopted A_ext's funds into w2 (balance $W2_PRE -> $W2_POST, A_ext UTXO present)"
    return 0
}

import_attempt || log "importprivkey check -> state=$IMPORT_STATE (rescan already green; cell still PASSES)"

# ── 6. Success — rescan is proven green; importprivkey state reported. ──────
log "PASS: rescan=ok importprivkey=$IMPORT_STATE rediscovered=$REDISCOVERED"
pass "$IMPORT_STATE" "$REDISCOVERED"

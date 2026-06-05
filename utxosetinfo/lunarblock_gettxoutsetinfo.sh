#!/usr/bin/env bash
#
# lunarblock_gettxoutsetinfo.sh — self-contained gettxoutsetinfo Core-parity
#   differential test. INDEXING-depth, the DEEPEST cell yet.
#
# The UTXO-set HASH is a fingerprint of the entire UTXO set. Matching it
# byte-for-byte against a REAL bitcoind proves lunarblock's consensus STATE
# (its UTXO set) is byte-identical to Core's — not just an RPC shape. This is
# why the set-hash equality is THE point of this test.
#
# Core refs:
#   bitcoin-core/src/rpc/blockchain.cpp:1010-1179  gettxoutsetinfo
#     SIGNATURE: gettxoutsetinfo ( "hash_type" hash_or_height use_index )
#       hash_type default "hash_serialized_3"; "hash_serialized_3"|"muhash"|"none".
#       hash_or_height + use_index need coinstatsindex (OUT OF SCOPE — tip only).
#     OUTPUT (base): { height, bestblock, txouts, bogosize,
#       hash_serialized_3 (when hash_serialized_3), muhash (when muhash),
#       transactions, disk_size, total_amount }.
#     ERRORS: hash_serialized_3 with a specific block -> -8
#       "hash_serialized_3 hash type cannot be queried for a specific block";
#       unrecognized hash_type -> -8 "'<x>' is not a valid hash_type".
#   bitcoin-core/src/kernel/coinstats.cpp  ComputeUTXOStats / TxOutSer / ApplyHash
#     hash_serialized_3 = SHA256d (HashWriter::GetHash) over the UTXO set in
#       coin-cursor order (txid lex-asc, then vout uint32-asc). per-coin =
#       (txid, vout, height<<1|coinbase, txout).
#     bogosize = 32+4+4+8+2+spk.size() (GetBogoSize) — "meaningless" metric.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind on its OWN scratch regtest instance +
#   OWN ports, launched -listen=0. Core MINES the chain (coinbase to bare
#   OP_TRUE via generateblock, anyone-can-spend) and SPENDS a matured coinbase
#   so the UTXO set has a spent output REMOVED and new outputs ADDED — not just
#   coinbases. lunarblock receives the BYTE-IDENTICAL blocks via submitblock
#   (getblock <h> 0 -> submitblock). Replaying Core's own serialized blocks
#   gives lunarblock the EXACT same chain, so the UTXO sets must be identical
#   and the set hash must match byte-for-byte.
#
# ASSERTIONS (both nodes, same chain):
#   1. fields : gettxoutsetinfo (default hash_type) -> height, bestblock,
#               txouts, total_amount ALL EXACT vs Core, AND the set hash
#               (hash_serialized_3) byte-EXACT vs Core. bogosize/transactions/
#               disk_size asserted PRESENT + typed (NOT byte-equal: bogosize is
#               meaningless, disk_size impl-specific).
#   2. hash   : the set hash is byte-EXACT vs Core (this is the same field as
#               #1 but called out separately — it is the consensus-state proof).
#   3. mutate : mine ONE more block -> height+1, bestblock changed, set hash
#               changed on BOTH nodes and STILL matches between impl and Core.
#   4. errors : gettxoutsetinfo hash_serialized_3 <height> -> -8 (cannot query a
#               specific block); gettxoutsetinfo bogustype -> error.
#
# STRICT UNIFORM INTERFACE (mirrors blockfilter/lunarblock_getblockfilter.sh):
#   set -uo pipefail, no required args, idempotent, trap cleanup, scratch /tmp
#   datadirs + unique ports, ONE clean summary line on stdout, all noise ->
#   stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTSETINFO lunarblock: PASS fields=ok hash=ok mutate=ok errors=ok
#   FAIL: GETTXOUTSETINFO lunarblock: FAIL <short reason>
#   SKIP: GETTXOUTSETINFO lunarblock: SKIP <reason>
#
# Touches ONLY /tmp/gtxo-lunarblock + /tmp/gtxo-core and ports
#   40278/40298 (lunarblock RPC/P2P) + 40276/40296 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node. Never
#   broad-pkills bitcoind by name; only frees its OWN fixed ports / scratch dir.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

LB_DATADIR="/tmp/gtxo-lunarblock"
LB_RPC=40278
LB_P2P=40298
LB_LOG="$LB_DATADIR/node.log"

CORE_DATADIR="/tmp/gtxo-core"
CORE_RPC=40276
CORE_P2P=40296
CORE_LOG="$CORE_DATADIR/core.log"

# Chain shape: 1 OP_TRUE coinbase block, then 100 maturity blocks, then 1
# block with the SPEND. Total height 102. The spend REMOVES the OP_TRUE
# coinbase output from the UTXO set and ADDS a new p2wpkh output, so the set
# is not just coinbases.
MATURITY=100
MINE_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

LB_PID=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutsetinfo:lunarblock] $*" >&2; }

# ── Port free helper: kill + POLL until the socket is actually released. ──
free_port() {
    local port="$1"
    fuser -k "${port}/tcp" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        fuser "${port}/tcp" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    return 0
}

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$LB_PID" ]] && kill -0 "$LB_PID" 2>/dev/null; then
        kill -TERM "-${LB_PID}" 2>/dev/null || kill -TERM "$LB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$LB_PID" 2>/dev/null || break; sleep 1; done
        kill -KILL "-${LB_PID}" 2>/dev/null || kill -KILL "$LB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    free_port "$LB_RPC"
    free_port "$LB_P2P"
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$LB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <fields> <hash> <mutate> <errors>
pass() {
    echo "GETTXOUTSETINFO lunarblock: PASS fields=$1 hash=$2 mutate=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETTXOUTSETINFO lunarblock: FAIL $*"
    exit 1
}
skip() {
    echo "GETTXOUTSETINFO lunarblock: SKIP $*"
    exit 0
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gtxo-lunarblock" 2>/dev/null || true
free_port "$LB_RPC"
free_port "$LB_P2P"
free_port "$CORE_RPC"
free_port "$CORE_P2P"
rm -rf "$LB_DATADIR" "$CORE_DATADIR"
mkdir -p "$LB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
command -v luajit  >/dev/null 2>&1 || fail "luajit not found on PATH"
[[ -f "$LB_DIR/src/main.lua" ]]    || fail "lunarblock entrypoint not found at $LB_DIR/src/main.lua"
[[ -x "$CORE_BIN" ]]               || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]               || fail "bitcoin-cli not found at $CORE_CLI"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# core_rpc <method> <json-params-array> -> full JSON-RPC envelope on stdout.
core_rpc() {
    local method="$1" params="$2" cookie out
    for _ in 1 2 3 4 5 6 7 8; do
        cookie=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null)
        if [[ -n "$cookie" ]]; then
            out=$(curl -s --max-time 90 -u "$cookie" \
                --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
                "http://127.0.0.1:$CORE_RPC/" 2>/dev/null)
            if [[ -n "$out" ]] && ! echo "$out" | grep -qi "incorrect password\|unauthorized"; then
                echo "$out"; return 0
            fi
        fi
        sleep 1
    done
    return 1
}

# lb_rpc <method> <json-params-array> -> raw JSON-RPC envelope on stdout
# (lunarblock defaults to an EMPTY rpcpassword on regtest -> no auth header).
lb_rpc() {
    curl -s --max-time 90 \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$LB_RPC/" 2>/dev/null
}

# jres <json-rpc-envelope> <python-expr-on-`r`> -> value (errors swallowed).
jres() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    r = d.get('result')
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    elif v is None: print('')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# jerr <json-rpc-envelope> -> the .error.code (or empty)
jerr() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    e = d.get('error')
    if isinstance(e, dict): print(e.get('code',''))
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# jerrmsg <json-rpc-envelope> -> the .error.message (or empty)
jerrmsg() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    e = d.get('error')
    if isinstance(e, dict): print(e.get('message',''))
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# field <json-rpc-result-obj> <key> -> value from .result object (or __ABSENT__)
# Numbers are printed via repr so we can distinguish int vs float in the typed
# assertions below (e.g. total_amount must be a JSON number, txouts an int).
field() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    r = d.get('result')
    if not isinstance(r, dict):
        print('__NORESULT__'); sys.exit()
    v = r.get('$2')
    if v is None and '$2' not in r: print('__ABSENT__')
    elif isinstance(v, bool): print('true' if v else 'false')
    elif v is None: print('null')
    else: print(v)
except Exception:
    print('__ERR__')
" <<<"$1" 2>/dev/null
}

# field_type <json-rpc-result-obj> <key> -> python type name of .result[key]
field_type() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    r = d.get('result')
    if not isinstance(r, dict):
        print('__NORESULT__'); sys.exit()
    if '$2' not in r: print('__ABSENT__'); sys.exit()
    print(type(r['$2']).__name__)
except Exception:
    print('__ERR__')
" <<<"$1" 2>/dev/null
}

# amount_eq <a> <b> -> exit 0 if a and b are equal as Decimal BTC amounts.
amount_eq() {
    python3 -c "
import sys
from decimal import Decimal
try:
    print('ok' if Decimal(str('$1')) == Decimal(str('$2')) else 'no')
except Exception:
    print('no')
" 2>/dev/null
}

# ── 2. Launch the Core regtest oracle (-listen=0). ─────────────────────────
launch_core_once() {
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -listen=0 -acceptnonstdtxn=1 -fallbackfee=0.0002 \
        >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if core_cli getblockcount >/dev/null 2>&1; then return 0; fi
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
CORE_OK=0
for attempt in 1 2 3; do
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Build the chain on Core: OP_TRUE coinbase, maturity, then a SPEND. ──
# 3a. Resolve the canonical "raw(51)#<checksum>" descriptor (bare OP_TRUE spk).
DESC=$(jres "$(core_rpc getdescriptorinfo '["raw(51)"]')" "r['descriptor']")
[[ -n "$DESC" ]] || fail "Core getdescriptorinfo raw(51) failed (see $CORE_LOG)"
log "OP_TRUE descriptor: $DESC"

# 3b. Mine block 1 with the coinbase paying to bare OP_TRUE (anyone-can-spend).
B1=$(jres "$(core_rpc generateblock "[\"$DESC\", []]")" "r['hash']")
[[ "$B1" =~ ^[0-9a-f]{64}$ ]] || fail "Core generateblock (OP_TRUE coinbase) failed: $B1 (see $CORE_LOG)"

# 3c. Mature the coinbase: $MATURITY blocks to a standard p2wpkh address.
GEN=$(core_rpc generatetoaddress "[$MATURITY, \"$MINE_ADDR\"]")
echo "$GEN" | grep -q '"result"' || fail "Core generatetoaddress (maturity) failed: $GEN"

# 3d. Build a raw tx spending the OP_TRUE coinbase (empty scriptSig) -> p2wpkh.
CBTXID=$(jres "$(core_rpc getblock "[\"$B1\", 1]")" "r['tx'][0]")
[[ "$CBTXID" =~ ^[0-9a-f]{64}$ ]] || fail "could not resolve OP_TRUE coinbase txid: '$CBTXID'"
# value 49.99 (0.01 BTC fee; the OP_TRUE input requires no signature).
RAW=$(jres "$(core_rpc createrawtransaction "[[{\"txid\":\"$CBTXID\",\"vout\":0}], [{\"$MINE_ADDR\":49.99}]]")" "r")
[[ -n "$RAW" ]] || fail "Core createrawtransaction failed (see $CORE_LOG)"
SPENDTXID=$(jres "$(core_rpc sendrawtransaction "[\"$RAW\", 0]")" "r")
[[ "$SPENDTXID" =~ ^[0-9a-f]{64}$ ]] || fail "Core sendrawtransaction (OP_TRUE spend) failed: '$SPENDTXID' (see $CORE_LOG)"
log "spend txid: $SPENDTXID (removes the OP_TRUE coinbase output, adds a p2wpkh output)"

# 3e. Mine a block INCLUDING the spend (coinbase OP_TRUE + the spend tx).
BSPEND=$(jres "$(core_rpc generateblock "[\"$DESC\", [\"$SPENDTXID\"]]")" "r['hash']")
[[ "$BSPEND" =~ ^[0-9a-f]{64}$ ]] || fail "Core generateblock (spend block) failed: $BSPEND (see $CORE_LOG)"

CORE_H=$(jres "$(core_rpc getblockcount '[]')" "r")
EXPECT_H=$(( 1 + MATURITY + 1 ))
[[ "$CORE_H" == "$EXPECT_H" ]] || fail "Core height=$CORE_H expected $EXPECT_H"
log "Core chain built to height $CORE_H (spend block $BSPEND removes+adds UTXOs)"

# Confirm the spend block really has 2 transactions (coinbase + the spend).
SPEND_NTX=$(jres "$(core_rpc getblock "[\"$BSPEND\", 1]")" "len(r['tx'])")
[[ "$SPEND_NTX" == "2" ]] || fail "spend block ntx=$SPEND_NTX expected 2"

# ── 4. Fetch ALL raw serialized blocks 1..H from Core (batched). ──────────
RAW_FILE="$LB_DATADIR/core_raw_blocks.txt"
log "fetching Core's $CORE_H raw blocks (batched)"
python3 - "$CORE_DATADIR/regtest/.cookie" "$CORE_RPC" "$CORE_H" "$RAW_FILE" <<'PY' 2>/dev/null || fail "Core batched raw-block fetch failed (see $CORE_LOG)"
import sys, json, base64, time, urllib.request
cookie_path, rpc_port, nblocks, out_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
url = 'http://127.0.0.1:%s/' % rpc_port
def call(batch):
    for _ in range(8):
        try:
            cookie = open(cookie_path).read().strip()
            auth = base64.b64encode(cookie.encode()).decode()
            req = urllib.request.Request(url, data=json.dumps(batch).encode(),
                headers={'Authorization':'Basic '+auth,'Content-Type':'application/json'})
            resp = json.loads(urllib.request.urlopen(req, timeout=120).read())
            if isinstance(resp, list) and all('result' in r and r['result'] is not None for r in resp):
                return resp
        except Exception:
            pass
        time.sleep(1)
    raise SystemExit("batched RPC call failed after retries")
hb = call([{'jsonrpc':'1.0','id':h,'method':'getblockhash','params':[h]} for h in range(1, nblocks+1)])
hashes = {r['id']: r['result'] for r in hb}
bb = call([{'jsonrpc':'1.0','id':h,'method':'getblock','params':[hashes[h], 0]} for h in range(1, nblocks+1)])
raws = {r['id']: r['result'] for r in bb}
with open(out_path, 'w') as f:
    for h in range(1, nblocks+1):
        f.write(raws[h] + "\n")
PY
[[ -s "$RAW_FILE" ]] || fail "Core raw-block file empty: $RAW_FILE"
mapfile -t RAW_ARR <"$RAW_FILE"
[[ "${#RAW_ARR[@]}" == "$CORE_H" ]] || fail "expected $CORE_H raw blocks, got ${#RAW_ARR[@]}"

# ── 5. Launch lunarblock on regtest. ──────────────────────────────────────
log "launching lunarblock (regtest) rpc=:$LB_RPC p2p=:$LB_P2P -> $LB_LOG"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$LB_DATADIR' \
    --port '$LB_P2P' --rpcport '$LB_RPC' --nov2transport" \
    >"$LB_LOG" 2>&1 &
LB_PID=$!
log "lunarblock pid=$LB_PID"
lb_deadline=$(( $(date +%s) + 120 ))
lb_up=0
while (( $(date +%s) < lb_deadline )); do
    if ! kill -0 "$LB_PID" 2>/dev/null; then
        tail -n 20 "$LB_LOG" >&2 2>/dev/null || true
        fail "lunarblock exited during startup (see $LB_LOG)"
    fi
    r=$(lb_rpc getblockchaininfo '[]')
    if echo "$r" | grep -q '"regtest"'; then lb_up=1; break; fi
    sleep 1
done
[[ "$lb_up" -eq 1 ]] || { tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock RPC never reported chain=regtest within 120s"; }
log "lunarblock RPC ready"

# ── 6. Replay Core's blocks into lunarblock via submitblock. ──────────────
log "replaying Core's $CORE_H blocks into lunarblock via submitblock"
for ((h=1; h<=CORE_H; h++)); do
    raw="${RAW_ARR[$((h-1))]}"
    [[ -n "$raw" ]] || fail "empty raw block at height $h"
    sub=$(lb_rpc submitblock "[\"$raw\"]")
    res=$(jres "$sub" "r")
    if [[ -n "$res" && "$res" != "duplicate" ]]; then
        log "lunarblock submitblock rejected block $h: $sub"
        tail -n 40 "$LB_LOG" >&2 2>/dev/null || true
        fail "lunarblock submitblock failed at height $h: '$res'"
    fi
done

lb_h=$(jres "$(lb_rpc getblockcount '[]')" "r")
[[ "$lb_h" == "$CORE_H" ]] || { tail -n 40 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock height=$lb_h expected $CORE_H after replay"; }
log "both nodes at height $CORE_H (identical chain)"

# Sanity: tip hashes equal on both nodes (chain truly identical).
CORE_TIP=$(jres "$(core_rpc getbestblockhash '[]')" "r")
LB_TIP=$(jres "$(lb_rpc getbestblockhash '[]')" "r")
[[ "$CORE_TIP" == "$LB_TIP" && "$CORE_TIP" =~ ^[0-9a-f]{64}$ ]] \
    || fail "tip hash mismatch after replay: core=$CORE_TIP lb=$LB_TIP"

# ── Decide which set hash to compare like-for-like. ───────────────────────
# Prefer hash_serialized_3 (Core's default). If lunarblock omits it (only
# present when hash_type=hash_serialized_3) we fall back to muhash. Both nodes
# are queried with the SAME hash_type so the comparison is like-for-like.
HASH_TYPE="hash_serialized_3"
HASH_KEY="hash_serialized_3"

# ── 7. CHECK 1+2 — FIELDS + SET HASH byte-exact vs Core at the tip. ───────
FIELDS_T="ok"; HASH_T="ok"

C_INFO=$(core_rpc gettxoutsetinfo "[\"$HASH_TYPE\"]")
L_INFO=$(lb_rpc   gettxoutsetinfo "[\"$HASH_TYPE\"]")

# If lunarblock errors on hash_serialized_3, retry with muhash for both.
L_INFO_ERR=$(jerr "$L_INFO")
if [[ -n "$L_INFO_ERR" ]]; then
    log "lunarblock gettxoutsetinfo hash_serialized_3 errored (code $L_INFO_ERR): $L_INFO"
    log "falling back to muhash for the like-for-like comparison"
    HASH_TYPE="muhash"; HASH_KEY="muhash"
    C_INFO=$(core_rpc gettxoutsetinfo "[\"$HASH_TYPE\"]")
    L_INFO=$(lb_rpc   gettxoutsetinfo "[\"$HASH_TYPE\"]")
    L_INFO_ERR=$(jerr "$L_INFO")
    [[ -z "$L_INFO_ERR" ]] || fail "lunarblock gettxoutsetinfo errored for both hash types: $L_INFO"
fi

# 7a. Exact-match scalar fields: height, bestblock, txouts, total_amount.
C_HEIGHT=$(field "$C_INFO" height);       L_HEIGHT=$(field "$L_INFO" height)
C_BEST=$(field "$C_INFO" bestblock);      L_BEST=$(field "$L_INFO" bestblock)
C_TXOUTS=$(field "$C_INFO" txouts);       L_TXOUTS=$(field "$L_INFO" txouts)
C_TOTAL=$(field "$C_INFO" total_amount);  L_TOTAL=$(field "$L_INFO" total_amount)

[[ "$L_HEIGHT" == "$C_HEIGHT" && "$C_HEIGHT" == "$CORE_H" ]] \
    || { FIELDS_T="bad"; log "height mismatch: core=$C_HEIGHT lb=$L_HEIGHT (expected $CORE_H)"; }
[[ "$L_BEST" == "$C_BEST" && "$C_BEST" == "$CORE_TIP" ]] \
    || { FIELDS_T="bad"; log "bestblock mismatch: core=$C_BEST lb=$L_BEST (expected $CORE_TIP)"; }
[[ "$L_TXOUTS" == "$C_TXOUTS" && "$C_TXOUTS" =~ ^[0-9]+$ ]] \
    || { FIELDS_T="bad"; log "txouts mismatch: core=$C_TXOUTS lb=$L_TXOUTS"; }
[[ "$(amount_eq "$L_TOTAL" "$C_TOTAL")" == "ok" ]] \
    || { FIELDS_T="bad"; log "total_amount mismatch: core=$C_TOTAL lb=$L_TOTAL"; }

# 7b. Present-and-typed fields (NOT byte-equal): bogosize, transactions, disk_size.
for fld in bogosize transactions disk_size; do
    lt=$(field_type "$L_INFO" "$fld")
    case "$lt" in
        int) : ;;  # OK — integer metric present
        __ABSENT__) FIELDS_T="bad"; log "$fld absent on lunarblock result" ;;
        *) FIELDS_T="bad"; log "$fld wrong type on lunarblock: $lt (want int)" ;;
    esac
done

# 7c. THE SET HASH — byte-EXACT vs Core. This is the consensus-state proof.
C_HASH=$(field "$C_INFO" "$HASH_KEY")
L_HASH=$(field "$L_INFO" "$HASH_KEY")
if [[ ! "$C_HASH" =~ ^[0-9a-f]{64}$ ]]; then
    HASH_T="bad"; log "Core $HASH_KEY not 64-hex: '$C_HASH' (env: $C_INFO)"
elif [[ "$L_HASH" != "$C_HASH" ]]; then
    HASH_T="bad"
    log "SET HASH ($HASH_KEY) mismatch — UTXO sets differ!"
    log "  core = $C_HASH"
    log "  lb   = $L_HASH"
else
    log "set hash ($HASH_KEY) byte-EXACT vs Core: $C_HASH"
    log "  height=$C_HEIGHT txouts=$C_TXOUTS transactions=$(field "$L_INFO" transactions) total_amount=$C_TOTAL"
fi

[[ "$FIELDS_T" == "ok" ]] || fail "field parity (height/bestblock/txouts/total_amount/typed) failed (see log)"
[[ "$HASH_T"   == "ok" ]] || fail "UTXO set hash not byte-exact vs Core (UTXO state diverges; see log)"

# ── 8. CHECK 3 — MUTATE: mine one more block, hash must change + still match. ─
MUTATE_T="ok"
PREV_HASH="$C_HASH"
PREV_HEIGHT="$C_HEIGHT"
PREV_BEST="$C_BEST"

# Mine one more block on Core (changes the UTXO set: adds a coinbase output).
BNEW=$(jres "$(core_rpc generateblock "[\"$DESC\", []]")" "r['hash']")
[[ "$BNEW" =~ ^[0-9a-f]{64}$ ]] || fail "Core generateblock (mutate) failed: $BNEW"
NEW_RAW=$(jres "$(core_rpc getblock "[\"$BNEW\", 0]")" "r")
[[ -n "$NEW_RAW" ]] || fail "Core getblock raw (mutate) failed"
sub=$(lb_rpc submitblock "[\"$NEW_RAW\"]")
res=$(jres "$sub" "r")
[[ -z "$res" || "$res" == "duplicate" ]] || fail "lunarblock submitblock (mutate) failed: '$res' ($sub)"

NEW_H=$(( CORE_H + 1 ))
lb_h2=$(jres "$(lb_rpc getblockcount '[]')" "r")
[[ "$lb_h2" == "$NEW_H" ]] || fail "lunarblock height=$lb_h2 expected $NEW_H after mutate"

C_INFO2=$(core_rpc gettxoutsetinfo "[\"$HASH_TYPE\"]")
L_INFO2=$(lb_rpc   gettxoutsetinfo "[\"$HASH_TYPE\"]")

C_HEIGHT2=$(field "$C_INFO2" height);  L_HEIGHT2=$(field "$L_INFO2" height)
C_BEST2=$(field "$C_INFO2" bestblock); L_BEST2=$(field "$L_INFO2" bestblock)
C_HASH2=$(field "$C_INFO2" "$HASH_KEY"); L_HASH2=$(field "$L_INFO2" "$HASH_KEY")

# height+1 on both.
[[ "$C_HEIGHT2" == "$NEW_H" && "$L_HEIGHT2" == "$NEW_H" ]] \
    || { MUTATE_T="bad"; log "mutate height: core=$C_HEIGHT2 lb=$L_HEIGHT2 expected $NEW_H"; }
# bestblock changed on both and equal.
[[ "$C_BEST2" == "$BNEW" && "$L_BEST2" == "$BNEW" && "$C_BEST2" != "$PREV_BEST" ]] \
    || { MUTATE_T="bad"; log "mutate bestblock: core=$C_BEST2 lb=$L_BEST2 expected $BNEW (prev $PREV_BEST)"; }
# set hash changed on BOTH.
[[ "$C_HASH2" != "$PREV_HASH" ]] \
    || { MUTATE_T="bad"; log "mutate: Core set hash did not change ($C_HASH2)"; }
[[ "$L_HASH2" != "$PREV_HASH" ]] \
    || { MUTATE_T="bad"; log "mutate: lunarblock set hash did not change ($L_HASH2)"; }
# set hash STILL matches between impl and Core.
if [[ ! "$C_HASH2" =~ ^[0-9a-f]{64}$ ]]; then
    MUTATE_T="bad"; log "mutate: Core $HASH_KEY not 64-hex: '$C_HASH2'"
elif [[ "$L_HASH2" != "$C_HASH2" ]]; then
    MUTATE_T="bad"
    log "mutate: set hash diverged after mutate — core=$C_HASH2 lb=$L_HASH2"
else
    log "mutate: height $PREV_HEIGHT->$C_HEIGHT2, hash $PREV_HASH -> $C_HASH2 (still byte-exact vs Core)"
fi

[[ "$MUTATE_T" == "ok" ]] || fail "mutate check failed (height+1 / bestblock-changed / hash-changed-and-matches; see log)"

# ── 9. CHECK 4 — ERRORS. ──────────────────────────────────────────────────
ERRORS_T="ok"

# 9a. hash_serialized_3 with a specific block/height -> -8 "cannot be queried
#     for a specific block". Use a concrete height (the tip).
E1=$(lb_rpc gettxoutsetinfo "[\"hash_serialized_3\", $NEW_H]")
E1_CODE=$(jerr "$E1"); E1_MSG=$(jerrmsg "$E1")
[[ "$E1_CODE" == "-8" ]] || { ERRORS_T="bad"; log "hash_serialized_3 <height>: expected code -8, got '$E1_CODE' ($E1)"; }
echo "$E1_MSG" | grep -qi "cannot be queried for a specific block" \
    || { ERRORS_T="bad"; log "hash_serialized_3 <height>: message not 'cannot be queried for a specific block': '$E1_MSG'"; }

# 9b. unrecognized hash_type -> error (Core: -8 "'<x>' is not a valid hash_type").
E2=$(lb_rpc gettxoutsetinfo "[\"bogus_hash_type\"]")
E2_CODE=$(jerr "$E2"); E2_MSG=$(jerrmsg "$E2")
[[ -n "$E2_CODE" && "$E2_CODE" != "0" ]] \
    || { ERRORS_T="bad"; log "bogus hash_type: expected an error code, got '$E2_CODE' ($E2)"; }

# Cross-check Core agrees on both error codes (oracle parity for the error path).
C_E1_CODE=$(jerr "$(core_rpc gettxoutsetinfo "[\"hash_serialized_3\", $NEW_H]")")
[[ "$C_E1_CODE" == "-8" ]] || { ERRORS_T="bad"; log "Core hash_serialized_3 <height> code != -8: '$C_E1_CODE'"; }
C_E2_CODE=$(jerr "$(core_rpc gettxoutsetinfo "[\"bogus_hash_type\"]")")
[[ "$C_E2_CODE" == "-8" ]] || { ERRORS_T="bad"; log "Core bogus hash_type code != -8: '$C_E2_CODE'"; }
# lunarblock should ideally match Core's -8 for the bogus hash_type too.
[[ "$E2_CODE" == "-8" ]] || log "note: lunarblock bogus-hash_type code=$E2_CODE (Core uses -8); accepted as 'an error'"

[[ "$ERRORS_T" == "ok" ]] || fail "error-code/message check failed (see log)"

# ── 10. All checks green. ─────────────────────────────────────────────────
log "PASS: lunarblock gettxoutsetinfo matches Core (fields + UTXO set hash + mutate + errors)"
pass "ok" "ok" "ok" "ok"

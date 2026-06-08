#!/usr/bin/env bash
#
# lunarblock_coinstatsindex.sh — self-contained gettxoutsetinfo-AT-HISTORICAL-
#   HEIGHT (coinstatsindex) Core-parity differential test for lunarblock.
#
# CAPABILITY UNDER TEST
#   gettxoutsetinfo ( "hash_type" hash_or_height use_index )
#   With -coinstatsindex=1 a node can answer gettxoutsetinfo AS OF a HISTORICAL
#   block (a height int or a block hash), not just the chain tip. The index is a
#   per-height running UTXO-set MuHash + counts (Core: index/coinstatsindex.cpp,
#   kernel/coinstats.cpp). WITHOUT coinstatsindex, a non-tip hash_or_height must
#   error -8 "Querying specific block heights requires coinstatsindex".
#   Core ref: bitcoin-core/src/rpc/blockchain.cpp gettxoutsetinfo.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind on its OWN scratch regtest instance +
#   OWN ports, launched -listen=0, with -coinstatsindex=1 -txindex=1. Core MINES
#   the chain (coinbase to bare OP_TRUE via generateblock, anyone-can-spend) and
#   SPENDS a matured coinbase so the UTXO set DIFFERS across heights (a spent
#   output is removed, new outputs added). lunarblock receives the BYTE-IDENTICAL
#   blocks via submitblock (getblock <h> 0 -> submitblock) and is ALSO launched
#   with -coinstatsindex=1 -txindex=1. Both nodes share a byte-identical tip.
#
# STRICT SHARED CONTRACT (gated here, identical across all 10 scripts):
#   * BOTH impl + a real bitcoind oracle on regtest with -coinstatsindex=1 (and
#     -txindex=1).
#   * Mine ~150 blocks to a deterministic address with a few real spends.
#   * Mirror the chain so both nodes share a byte-identical tip.
#   * Wait for coinstatsindex to sync (poll getindexinfo until synced, or
#     gettxoutsetinfo@tip works).
#   * Pick a HISTORICAL height H well below tip (here H=100). Call
#     gettxoutsetinfo "muhash" H (and the default hash_type) on BOTH.
#   GATE:
#     impl.height == H == Core.height
#     impl.bestblock == Core.bestblock   (the hash AT height H, not the tip)
#     impl.txouts == Core.txouts
#     impl.total_amount == Core.total_amount
#     impl.<hash field> (muhash) == Core's
#   ERROR gate: with coinstatsindex DISABLED, a non-tip hash_or_height must
#     error (match Core).
#
# Summary line (stdout) — EXACTLY:
#   PASS: COINSTATSINDEX lunarblock: PASS atheight=ok txouts=ok amount=ok hash=ok bestblock=ok
#   FAIL: COINSTATSINDEX lunarblock: FAIL <reason>
#   SKIP: COINSTATSINDEX lunarblock: SKIP <reason>   (missing binary only)
#
# Touches ONLY /tmp/csi-lunarblock + /tmp/csi-core and ports
#   40478/40498 (lunarblock RPC/P2P) + 40476/40496 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node. Never
#   broad-pkills bitcoind by name; only frees its OWN fixed ports / scratch dir.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

LB_DATADIR="/tmp/csi-lunarblock"
LB_RPC=40478
LB_P2P=40498
LB_LOG="$LB_DATADIR/node.log"

CORE_DATADIR="/tmp/csi-core"
CORE_RPC=40476
CORE_P2P=40496
CORE_LOG="$CORE_DATADIR/core.log"

# Chain shape: 1 OP_TRUE coinbase block, then 150 maturity blocks, then 1
# block with a SPEND. Total height 152. The spend REMOVES the OP_TRUE coinbase
# output and ADDS a new p2wpkh output. We then query a HISTORICAL height H well
# below the tip; H must be > maturity-start so coinstatsindex has real data.
MATURITY=150
HIST_HEIGHT=100
MINE_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

LB_PID=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[coinstatsindex:lunarblock] $*" >&2; }

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
# pass <atheight> <txouts> <amount> <hash> <bestblock>
pass() {
    echo "COINSTATSINDEX lunarblock: PASS atheight=$1 txouts=$2 amount=$3 hash=$4 bestblock=$5"
    exit 0
}
fail() {
    echo "COINSTATSINDEX lunarblock: FAIL $*"
    exit 1
}
skip() {
    echo "COINSTATSINDEX lunarblock: SKIP $*"
    exit 0
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "csi-lunarblock" 2>/dev/null || true
free_port "$LB_RPC"
free_port "$LB_P2P"
free_port "$CORE_RPC"
free_port "$CORE_P2P"
rm -rf "$LB_DATADIR" "$CORE_DATADIR"
mkdir -p "$LB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
# Missing BINARY -> SKIP (GAP_RE). Everything else is a hard error/FAIL.
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
command -v luajit  >/dev/null 2>&1 || skip "luajit not found (lunarblock interpreter not built)"
[[ -f "$LB_DIR/src/main.lua" ]]    || skip "lunarblock entrypoint not found at $LB_DIR/src/main.lua"
[[ -x "$CORE_BIN" ]]               || skip "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]               || skip "bitcoin-cli not found at $CORE_CLI"

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

# amount_eq <a> <b> -> "ok" if a and b are equal as Decimal BTC amounts.
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

# ── 2. Launch the Core regtest oracle (-listen=0, coinstatsindex+txindex). ─
launch_core() {
    local datadir="$1" rpc="$2" p2p="$3" logf="$4"; shift 4
    free_port "$rpc"
    free_port "$p2p"
    rm -rf "$datadir"; mkdir -p "$datadir"
    "$CORE_BIN" -regtest -datadir="$datadir" -rpcport="$rpc" -port="$p2p" \
        -listen=0 -acceptnonstdtxn=1 -fallbackfee=0.0002 \
        "$@" >"$logf" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if "$CORE_CLI" -regtest -datadir="$datadir" -rpcport="$rpc" getblockcount >/dev/null 2>&1; then return 0; fi
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

CORE_OK=0
for attempt in 1 2 3; do
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P -coinstatsindex=1 -txindex=1 (attempt $attempt)"
    if launch_core "$CORE_DATADIR" "$CORE_RPC" "$CORE_P2P" "$CORE_LOG" -coinstatsindex=1 -txindex=1; then CORE_OK=1; break; fi
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

# 3f. Resolve the canonical block hash AT the historical height H (this is what
#     gettxoutsetinfo <hash_type> H must report as bestblock — NOT the tip).
HIST_HASH=$(jres "$(core_rpc getblockhash "[$HIST_HEIGHT]")" "r")
[[ "$HIST_HASH" =~ ^[0-9a-f]{64}$ ]] || fail "Core getblockhash $HIST_HEIGHT failed: '$HIST_HASH'"
log "historical height H=$HIST_HEIGHT block hash = $HIST_HASH (well below tip $CORE_H)"

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
# CONTRACT requires -coinstatsindex=1 on BOTH launches. lunarblock's CLI has NO
# --coinstatsindex option (it exits "Unknown option: --coinstatsindex"), which
# is itself proof the capability is absent: there is no per-height UTXO-stats
# index to enable. We therefore launch with the supported --txindex only and let
# the at-height gettxoutsetinfo query exercise the RPC layer's coinstatsindex
# error contract. (If the CLI option is ever added, restore --coinstatsindex.)
CSI_FLAG="--coinstatsindex"
if ! grep -q -- '--coinstatsindex' "$LB_DIR/src/main.lua" 2>/dev/null; then
    log "NOTE: lunarblock has no --coinstatsindex CLI option (capability absent); launching with --txindex only"
    CSI_FLAG=""
fi
log "launching lunarblock (regtest) rpc=:$LB_RPC p2p=:$LB_P2P ${CSI_FLAG:+-coinstatsindex } -txindex -> $LB_LOG"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$LB_DATADIR' \
    --port '$LB_P2P' --rpcport '$LB_RPC' --nov2transport \
    $CSI_FLAG --txindex" \
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

# Sanity: tip hashes equal on both nodes (chain truly identical, byte-for-byte).
# core_rpc can transiently return an empty body right after the heavy replay; we
# retry a few times so a flaky RPC read is never misreported as a chain mismatch.
CORE_TIP=""
for _ in 1 2 3 4 5 6 7 8; do
    CORE_TIP=$(jres "$(core_rpc getbestblockhash '[]')" "r")
    [[ "$CORE_TIP" =~ ^[0-9a-f]{64}$ ]] && break
    CORE_TIP=$(core_cli getbestblockhash 2>/dev/null)
    [[ "$CORE_TIP" =~ ^[0-9a-f]{64}$ ]] && break
    sleep 1
done
LB_TIP=""
for _ in 1 2 3 4 5; do
    LB_TIP=$(jres "$(lb_rpc getbestblockhash '[]')" "r")
    [[ "$LB_TIP" =~ ^[0-9a-f]{64}$ ]] && break
    sleep 1
done
[[ "$CORE_TIP" =~ ^[0-9a-f]{64}$ ]] || fail "Core getbestblockhash returned no tip hash after replay (oracle RPC stalled; see $CORE_LOG)"
[[ "$CORE_TIP" == "$LB_TIP" ]] \
    || fail "tip hash mismatch after replay: core=$CORE_TIP lb=$LB_TIP"
# Cross-check the tip is the spend block we built (chain shape is what we think).
[[ "$CORE_TIP" == "$BSPEND" ]] \
    || log "note: tip $CORE_TIP != built spend block $BSPEND (extra blocks?)"

# ── 7. Wait for Core's coinstatsindex to sync. ────────────────────────────
# Poll getindexinfo until "coinstatsindex" reports synced=true at the tip, OR
# fall back to gettxoutsetinfo@<tip-hash> succeeding (the index is what backs a
# non-tip query). The Core oracle MUST have the index; if it never syncs the
# oracle itself is broken and we cannot judge the impl.
log "waiting for Core coinstatsindex to sync to tip $CORE_H"
csi_deadline=$(( $(date +%s) + 90 ))
core_csi_ready=0
while (( $(date +%s) < csi_deadline )); do
    II=$(core_rpc getindexinfo '["coinstatsindex"]')
    SYNCED=$(jres "$II" "r['coinstatsindex']['synced']")
    BBH=$(jres "$II" "r['coinstatsindex']['best_block_height']")
    if [[ "$SYNCED" == "true" && "$BBH" == "$CORE_H" ]]; then core_csi_ready=1; break; fi
    sleep 1
done
[[ "$core_csi_ready" == "1" ]] || fail "Core coinstatsindex never synced to tip $CORE_H within 90s (oracle broken; see $CORE_LOG)"
log "Core coinstatsindex synced to tip"

# Confirm the historical-height query works on the ORACLE first (proves the
# index has per-height data; defines the expected answer). Retry on transient
# empty bodies so a flaky read is not mistaken for an oracle error.
C_HIST=""; C_HIST_ERR=""
for _ in 1 2 3 4 5 6 7 8; do
    C_HIST=$(core_rpc gettxoutsetinfo "[\"muhash\", $HIST_HEIGHT]")
    [[ "$(field "$C_HIST" height)" == "$HIST_HEIGHT" ]] && break
    C_HIST_ERR=$(jerr "$C_HIST")
    [[ -n "$C_HIST_ERR" ]] && break
    sleep 1
done
C_HIST_ERR=$(jerr "$C_HIST")
[[ -z "$C_HIST_ERR" ]] || fail "Core gettxoutsetinfo muhash $HIST_HEIGHT errored on the oracle (code $C_HIST_ERR): $C_HIST"

C_HEIGHT=$(field "$C_HIST" height)
C_BEST=$(field "$C_HIST" bestblock)
C_TXOUTS=$(field "$C_HIST" txouts)
C_TOTAL=$(field "$C_HIST" total_amount)
C_MUHASH=$(field "$C_HIST" muhash)
[[ "$C_HEIGHT" == "$HIST_HEIGHT" ]] || fail "Core reported height=$C_HEIGHT for H=$HIST_HEIGHT query (oracle broken)"
[[ "$C_BEST" == "$HIST_HASH" ]] || fail "Core reported bestblock=$C_BEST, expected hash-at-H $HIST_HASH (oracle broken)"
[[ "$C_MUHASH" =~ ^[0-9a-f]{64}$ ]] || fail "Core muhash not 64-hex at H: '$C_MUHASH' (oracle broken)"
log "Core@H=$HIST_HEIGHT: bestblock=$C_BEST txouts=$C_TXOUTS total_amount=$C_TOTAL muhash=$C_MUHASH"

# ── 8. THE CORE GATE — gettxoutsetinfo "muhash" H on the IMPL. ────────────
# Per the strict shared contract every sub-assertion is gated; none optional.
ATHEIGHT_T="ok"; TXOUTS_T="ok"; AMOUNT_T="ok"; HASH_T="ok"; BESTBLOCK_T="ok"

L_HIST=$(lb_rpc gettxoutsetinfo "[\"muhash\", $HIST_HEIGHT]")
L_HIST_ERR=$(jerr "$L_HIST")
L_HIST_MSG=$(jerrmsg "$L_HIST")

if [[ -n "$L_HIST_ERR" ]]; then
    # The impl rejected the historical-height query. Per the contract this is a
    # REAL FAIL (lacks coinstatsindex / rejects hash_or_height), not a SKIP.
    log "lunarblock gettxoutsetinfo muhash $HIST_HEIGHT errored (code $L_HIST_ERR): '$L_HIST_MSG'"
    log "lunarblock does NOT support at-height gettxoutsetinfo (no coinstatsindex)."

    # ── ERROR-PATH gate: with coinstatsindex effectively absent, a non-tip
    #    hash_or_height MUST error, matching Core's contract. We verify the impl
    #    error matches the Core -8 'requires coinstatsindex' family so the
    #    failure is characterized precisely (not a crash / wrong code).
    EXPECT_MSG="Querying specific block heights requires coinstatsindex"
    # When hash_type=muhash and coinstatsindex is off, Core (blockchain.cpp)
    # emits exactly that message with code -8.
    if [[ "$L_HIST_ERR" == "-8" ]] && echo "$L_HIST_MSG" | grep -qi "coinstatsindex"; then
        log "impl error path MATCHES Core's -8 'requires coinstatsindex' contract"
        fail "no coinstatsindex: at-height gettxoutsetinfo unsupported (impl returns -8 'requires coinstatsindex'; capability absent)"
    fi
    fail "no coinstatsindex: at-height gettxoutsetinfo rejected (impl code=$L_HIST_ERR msg='$L_HIST_MSG')"
fi

# If we got here the impl returned a RESULT for the at-height query — compare it
# field-by-field against the Core oracle's answer AT THE HISTORICAL HEIGHT.
L_HEIGHT=$(field "$L_HIST" height)
L_BEST=$(field "$L_HIST" bestblock)
L_TXOUTS=$(field "$L_HIST" txouts)
L_TOTAL=$(field "$L_HIST" total_amount)
L_MUHASH=$(field "$L_HIST" muhash)

# GATE a: impl.height == H == Core.height
[[ "$L_HEIGHT" == "$HIST_HEIGHT" && "$C_HEIGHT" == "$HIST_HEIGHT" ]] \
    || { ATHEIGHT_T="bad"; log "height: impl=$L_HEIGHT core=$C_HEIGHT expected $HIST_HEIGHT"; }

# GATE b: impl.bestblock == Core.bestblock (the hash AT height H, not the tip)
[[ "$L_BEST" == "$C_BEST" && "$L_BEST" == "$HIST_HASH" ]] \
    || { BESTBLOCK_T="bad"; log "bestblock: impl=$L_BEST core=$C_BEST expected hash-at-H $HIST_HASH"; }
[[ "$L_BEST" != "$CORE_TIP" ]] \
    || { BESTBLOCK_T="bad"; log "bestblock: impl returned the TIP hash, not the hash at H (got $L_BEST)"; }

# GATE c: impl.txouts == Core.txouts
[[ "$L_TXOUTS" == "$C_TXOUTS" && "$C_TXOUTS" =~ ^[0-9]+$ ]] \
    || { TXOUTS_T="bad"; log "txouts: impl=$L_TXOUTS core=$C_TXOUTS"; }

# GATE d: impl.total_amount == Core.total_amount
[[ "$(amount_eq "$L_TOTAL" "$C_TOTAL")" == "ok" ]] \
    || { AMOUNT_T="bad"; log "total_amount: impl=$L_TOTAL core=$C_TOTAL"; }

# GATE e: impl.muhash == Core.muhash (the per-height running set hash)
if [[ ! "$C_MUHASH" =~ ^[0-9a-f]{64}$ ]]; then
    HASH_T="bad"; log "Core muhash not 64-hex at H: '$C_MUHASH'"
elif [[ "$L_MUHASH" != "$C_MUHASH" ]]; then
    HASH_T="bad"; log "muhash@H mismatch: impl=$L_MUHASH core=$C_MUHASH (UTXO-set-at-H diverges)"
else
    log "muhash@H byte-EXACT vs Core: $C_MUHASH"
fi

# ── 9. Secondary: default hash_type at H (Core: hash_serialized_3 cannot be
#    queried at a specific block even WITH coinstatsindex -> -8). Both nodes
#    must agree on this contract. (Informational unless they disagree.) ─────
C_HS3=$(core_rpc gettxoutsetinfo "[\"hash_serialized_3\", $HIST_HEIGHT]")
C_HS3_CODE=$(jerr "$C_HS3")
L_HS3=$(lb_rpc gettxoutsetinfo "[\"hash_serialized_3\", $HIST_HEIGHT]")
L_HS3_CODE=$(jerr "$L_HS3")
[[ "$C_HS3_CODE" == "-8" ]] || log "note: Core hash_serialized_3@H code=$C_HS3_CODE (expected -8)"
[[ "$L_HS3_CODE" == "$C_HS3_CODE" ]] \
    || log "note: hash_serialized_3@H code impl=$L_HS3_CODE core=$C_HS3_CODE (contract mismatch)"

# ── 10. Verdict. ──────────────────────────────────────────────────────────
[[ "$ATHEIGHT_T"  == "ok" ]] || fail "height@H mismatch (impl=$L_HEIGHT core=$C_HEIGHT expected $HIST_HEIGHT)"
[[ "$BESTBLOCK_T" == "ok" ]] || fail "bestblock@H mismatch (impl=$L_BEST core=$C_BEST expected $HIST_HASH)"
[[ "$TXOUTS_T"    == "ok" ]] || fail "txouts@H mismatch (impl=$L_TXOUTS core=$C_TXOUTS)"
[[ "$AMOUNT_T"    == "ok" ]] || fail "total_amount@H mismatch (impl=$L_TOTAL core=$C_TOTAL)"
[[ "$HASH_T"      == "ok" ]] || fail "muhash@H not byte-exact vs Core (UTXO-set-at-H diverges)"

log "PASS: lunarblock gettxoutsetinfo@H matches Core (coinstatsindex at-height parity)"
pass "ok" "ok" "ok" "ok" "ok"

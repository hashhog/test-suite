#!/usr/bin/env bash
#
# lunarblock_getblockheader.sh — self-contained getblockheader Core-parity test.
#
# A clean, deterministic RPC-surface green-cell. getblockheader is READ-ONLY
# block-index serialization — NOT consensus — but must match Bitcoin Core's
# output shape EXACTLY for a given chain shape.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:599-666 (getblockheader)
#           + :154-182 (blockheaderToJSON) + :116-124 (ComputeNextBlockAndDepth).
#   SIGNATURE: getblockheader "blockhash" ( verbose ). verbose default TRUE.
#   verbose=false -> the 80-byte serialized block HEADER as HEX (byte-EXACT).
#   verbose=true  -> an OBJECT with: hash, confirmations, height, version,
#     versionHex, merkleroot, time, mediantime, nonce, bits, target, difficulty,
#     chainwork, nTx, previousblockhash (absent for genesis),
#     nextblockhash (absent for the tip).
#   ERROR: a blockhash not in the index -> RPC code -5 "Block not found".
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports. Core MINES the blocks; lunarblock receives
#   the BYTE-IDENTICAL blocks via submitblock (getblock <h> 0 -> submitblock).
#   Mining independently is NOT enough: two implementations build different
#   coinbase scriptSigs (BIP34 height push + extranonce), so the block hashes
#   would diverge and no byte-exact field could match. Replaying Core's own
#   serialized blocks gives lunarblock the EXACT same chain — identical header
#   bytes, merkleroot, time, nonce, hash at every height.
#
# WHAT MUST MATCH CORE EXACTLY (per identical chain shape):
#   verbose=false : the 160-char (80-byte) header hex.
#   verbose=true  : hash, height, version, versionHex, merkleroot, time,
#                   mediantime, nonce, bits, nTx, previousblockhash,
#                   nextblockhash, confirmations, chainwork.
# PRESENT + CORRECTLY-TYPED (not byte-equal):
#   difficulty (float, can format differently), target (newer field).
# STRUCTURAL RULES:
#   genesis -> NO previousblockhash key, nextblockhash present.
#   tip     -> nextblockhash ABSENT, confirmations == 1.
#   bad-hash-> RPC error code -5.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/rustoshi_chaintxstats.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKHEADER lunarblock: PASS hex=ok verbose=ok genesis=ok tip=ok errors=ok
#   FAIL: GETBLOCKHEADER lunarblock: FAIL <short reason>
#
# Touches ONLY /tmp/gbh-lunarblock + /tmp/gbh-core and ports
#   22058/22078 (lunarblock RPC/P2P) + 22056/22076 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

LB_DATADIR="/tmp/gbh-lunarblock"
LB_RPC=22058
LB_P2P=22078
LB_LOG="$LB_DATADIR/node.log"

CORE_DATADIR="/tmp/gbh-core"
CORE_RPC=22056
CORE_P2P=22076
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=120        # mine 120 empty blocks on both nodes (identical chain shape)
TEST_HEIGHT=60     # the in-chain block whose header we diff field-by-field

# A fixed, well-formed regtest p2wpkh address. Coinbase outputs go here; blocks
# stay empty (1 coinbase tx each) on both nodes.
MINE_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

LB_PID=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockheader:lunarblock] $*" >&2; }

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
    rm -rf "$LB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <hex> <verbose> <genesis> <tip> <errors>
pass() {
    echo "GETBLOCKHEADER lunarblock: PASS hex=$1 verbose=$2 genesis=$3 tip=$4 errors=$5"
    exit 0
}
fail() {
    echo "GETBLOCKHEADER lunarblock: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gbh-lunarblock" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${LB_RPC}/${LB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
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

# core_cli_retry: tolerant of the bitcoin-cli .cookie read race under concurrent
# fleet load (a fresh daemon rewrites regtest/.cookie and a CLI that reads it
# mid-write logs "incorrect password" + returns empty). Up to 8 tries, 1s apart.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# core_rpc <method> <json-params-array> -> full JSON-RPC envelope on stdout.
# Direct curl JSON-RPC against Core using the regtest .cookie. Far cheaper than
# spawning bitcoin-cli per call (the replay loop makes hundreds of calls) and
# sidesteps bitcoin-cli's own cookie-read race. Re-reads the cookie fresh each
# call and retries on auth/empty so a daemon-restart cookie rotation is
# tolerated.
core_rpc() {
    local method="$1" params="$2" cookie out
    for _ in 1 2 3 4 5 6 7 8; do
        cookie=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null)
        if [[ -n "$cookie" ]]; then
            out=$(curl -s --max-time 90 -u "$cookie" \
                --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
                "http://127.0.0.1:$CORE_RPC/" 2>/dev/null)
            # Accept any non-empty body that is NOT an auth rejection.
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
# `r` is the parsed .result; for primitive results it is the value itself.
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

# cf <core-json-object> <key> -> value from a Core CLI JSON object (or empty)
cf() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = d.get('$2')
    if v is None: print('__ABSENT__')
    elif isinstance(v, bool): print('true' if v else 'false')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# lf <lunarblock-result-json-object> <key> -> value (or __ABSENT__)
lf() { cf "$1" "$2"; }

# ── 2. Launch the Core regtest oracle (-listen=0: RPC-only, no 0.0.0.0 P2P). ─
launch_core_once() {
    # PID-scoped stop of OUR previous attempt (port-kill removed: 2026-06-10 fuser incident).
    if [[ -n "${CORE_BG:-}" ]]; then
        kill "$CORE_BG" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CORE_BG" 2>/dev/null || break; sleep 1; done
        kill -9 "$CORE_BG" 2>/dev/null || true
    fi
    for __hp in "${CORE_RPC}" "${CORE_P2P}"; do
        for _ in $(seq 1 15); do
            ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
            sleep 1
        done
    done
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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

# ── 3. Launch lunarblock on regtest. ──────────────────────────────────────
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

# ── 4. Mine NBLOCKS empty blocks on Core, then REPLAY them into lunarblock. ─
log "mining $NBLOCKS blocks on Core"
GEN=$(core_rpc generatetoaddress "[$NBLOCKS, \"$MINE_ADDR\"]") \
    || fail "Core generatetoaddress failed (see $CORE_LOG)"
echo "$GEN" | grep -q '"result"' || fail "Core generatetoaddress errored: $GEN"
core_h=$(jres "$(core_rpc getblockcount '[]')" "r")
[[ "$core_h" == "$NBLOCKS" ]] || fail "Core height=$core_h expected $NBLOCKS"

# Fetch ALL raw serialized blocks 1..NBLOCKS from Core in ONE batched JSON-RPC
# call (getblockhash batch -> getblock verbosity=0 batch), height-ordered, into a
# temp file. A single batched call (with internal retry) is far more robust than
# hundreds of individual curl round-trips under sandbox load.
RAW_FILE="$LB_DATADIR/core_raw_blocks.txt"
log "fetching Core's $NBLOCKS raw blocks (batched)"
python3 - "$CORE_DATADIR/regtest/.cookie" "$CORE_RPC" "$NBLOCKS" "$RAW_FILE" <<'PY' 2>/dev/null || fail "Core batched raw-block fetch failed (see $CORE_LOG)"
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
[[ "${#RAW_ARR[@]}" == "$NBLOCKS" ]] || fail "expected $NBLOCKS raw blocks, got ${#RAW_ARR[@]}"

log "replaying Core's $NBLOCKS blocks into lunarblock via submitblock"
for ((h=1; h<=NBLOCKS; h++)); do
    raw="${RAW_ARR[$((h-1))]}"
    [[ -n "$raw" ]] || fail "empty raw block at height $h"
    sub=$(lb_rpc submitblock "[\"$raw\"]")
    # submitblock success = result:null; "duplicate" is also acceptable (idempotent).
    res=$(jres "$sub" "r")
    if [[ -n "$res" && "$res" != "duplicate" ]]; then
        log "lunarblock submitblock rejected block $h: $sub"
        tail -n 30 "$LB_LOG" >&2 2>/dev/null || true
        fail "lunarblock submitblock failed at height $h: '$res'"
    fi
done

lb_h=$(jres "$(lb_rpc getblockcount '[]')" "r")
[[ "$lb_h" == "$NBLOCKS" ]] || { tail -n 30 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock height=$lb_h expected $NBLOCKS after replay"; }
log "both nodes at height $NBLOCKS (identical chain)"

# ── 5. Resolve the block hash at TEST_HEIGHT on BOTH nodes (must be EQUAL). ─
CORE_H60=$(jres "$(core_rpc getblockhash "[$TEST_HEIGHT]")" "r")
LB_H60=$(jres "$(lb_rpc getblockhash "[$TEST_HEIGHT]")" "r")
[[ "$CORE_H60" =~ ^[0-9a-f]{64}$ ]] || fail "Core getblockhash $TEST_HEIGHT not 64-hex: '$CORE_H60'"
[[ "$LB_H60"   =~ ^[0-9a-f]{64}$ ]] || fail "lunarblock getblockhash $TEST_HEIGHT not 64-hex: '$LB_H60'"
[[ "$CORE_H60" == "$LB_H60" ]] || fail "chains diverge at height $TEST_HEIGHT after replay: core=$CORE_H60 lb=$LB_H60"
log "block@$TEST_HEIGHT hash (both): $CORE_H60"

# ── 6. CHECK 1 — verbose=false: 80-byte (160-char) header hex byte-EXACT. ──
HEX_T="ok"
CORE_HEX=$(jres "$(core_rpc getblockheader "[\"$CORE_H60\", false]")" "r")
LB_HEX=$(jres "$(lb_rpc getblockheader "[\"$LB_H60\", false]")" "r")
[[ "$CORE_HEX" =~ ^[0-9a-f]{160}$ ]] || fail "Core verbose=false header hex not 160-char: '$CORE_HEX'"
if [[ "$LB_HEX" != "$CORE_HEX" ]]; then
    HEX_T="bad"
    log "verbose=false header hex MISMATCH:"
    log "  core = $CORE_HEX"
    log "  lb   = $LB_HEX"
fi
[[ "$HEX_T" == "ok" ]] || fail "verbose=false header hex not byte-exact vs Core"

# ── 7. CHECK 2 — verbose=true: field-by-field EXACT match vs Core. ─────────
VERBOSE_T="ok"
CORE_V=$(jres "$(core_rpc getblockheader "[\"$CORE_H60\", true]")" "json.dumps(r)")
LB_V=$(jres "$(lb_rpc getblockheader "[\"$LB_H60\", true]")" "json.dumps(r)")
[[ -n "$CORE_V" ]] || fail "Core verbose=true returned no object"
[[ -n "$LB_V"   ]] || { tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock verbose=true returned no object"; }
log "core verbose : $CORE_V"
log "lb   verbose : $LB_V"

# Default verbose (omitted arg) must also yield an OBJECT (verbose default TRUE).
LB_VDEF=$(lb_rpc getblockheader "[\"$LB_H60\"]")
echo "$LB_VDEF" | grep -q '"hash"' || { VERBOSE_T="bad"; log "default-verbose did not return an object: $LB_VDEF"; }

# Byte-exact fields.
EXACT_KEYS=(hash height version versionHex merkleroot time mediantime nonce bits nTx previousblockhash nextblockhash confirmations chainwork)
for k in "${EXACT_KEYS[@]}"; do
    cv=$(cf "$CORE_V" "$k")
    lv=$(lf "$LB_V" "$k")
    if [[ "$cv" != "$lv" ]]; then
        VERBOSE_T="bad"
        log "field '$k' MISMATCH: core='$cv' lb='$lv'"
    fi
done

# difficulty: PRESENT + correctly-typed float (NOT byte-equal).
LD=$(lf "$LB_V" difficulty)
if [[ "$LD" == "__ABSENT__" || -z "$LD" ]]; then
    VERBOSE_T="bad"; log "difficulty absent"
elif ! [[ "$LD" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
    VERBOSE_T="bad"; log "difficulty not a float: '$LD'"
fi

# target: PRESENT + correctly-typed 64-hex (NOT byte-equal requirement, but
# regtest target is constant so it will in fact match — assert shape only).
LT=$(lf "$LB_V" target)
if ! [[ "$LT" =~ ^[0-9a-f]{64}$ ]]; then
    VERBOSE_T="bad"; log "target absent/not-64-hex: '$LT'"
fi

[[ "$VERBOSE_T" == "ok" ]] || fail "verbose=true field-by-field check failed (see log)"

# ── 8. CHECK 3 — GENESIS: no previousblockhash, nextblockhash present. ─────
GENESIS_T="ok"
CORE_G=$(jres "$(core_rpc getblockhash "[0]")" "r")
LB_G=$(jres "$(lb_rpc getblockhash "[0]")" "r")
[[ "$CORE_G" == "$LB_G" && "$CORE_G" =~ ^[0-9a-f]{64}$ ]] || fail "genesis hash mismatch: core=$CORE_G lb=$LB_G"
LB_GV=$(jres "$(lb_rpc getblockheader "[\"$LB_G\", true]")" "json.dumps(r)")
[[ -n "$LB_GV" ]] || fail "lunarblock genesis verbose returned nothing"
G_PREV=$(lf "$LB_GV" previousblockhash)
G_NEXT=$(lf "$LB_GV" nextblockhash)
G_HEIGHT=$(lf "$LB_GV" height)
[[ "$G_PREV" == "__ABSENT__" ]] || { GENESIS_T="bad"; log "genesis has previousblockhash (must be absent): '$G_PREV'"; }
[[ "$G_NEXT" =~ ^[0-9a-f]{64}$ ]] || { GENESIS_T="bad"; log "genesis nextblockhash absent/not-64-hex: '$G_NEXT'"; }
[[ "$G_HEIGHT" == "0" ]] || { GENESIS_T="bad"; log "genesis height != 0: '$G_HEIGHT'"; }
# chainwork at genesis must equal Core's (exact).
CORE_G_V=$(jres "$(core_rpc getblockheader "[\"$CORE_G\", true]")" "json.dumps(r)")
CG_CW=$(cf "$CORE_G_V" chainwork)
LG_CW=$(lf "$LB_GV" chainwork)
[[ "$CG_CW" == "$LG_CW" ]] || { GENESIS_T="bad"; log "genesis chainwork mismatch: core='$CG_CW' lb='$LG_CW'"; }
[[ "$GENESIS_T" == "ok" ]] || fail "genesis structural check failed (see log)"

# ── 9. CHECK 4 — TIP: nextblockhash absent, confirmations == 1. ───────────
TIP_T="ok"
CORE_TIP=$(jres "$(core_rpc getbestblockhash "[]")" "r")
LB_TIP=$(jres "$(lb_rpc getbestblockhash '[]')" "r")
[[ "$CORE_TIP" == "$LB_TIP" && "$CORE_TIP" =~ ^[0-9a-f]{64}$ ]] || fail "tip hash mismatch: core=$CORE_TIP lb=$LB_TIP"
LB_TV=$(jres "$(lb_rpc getblockheader "[\"$LB_TIP\", true]")" "json.dumps(r)")
[[ -n "$LB_TV" ]] || fail "lunarblock tip verbose returned nothing"
T_NEXT=$(lf "$LB_TV" nextblockhash)
T_CONF=$(lf "$LB_TV" confirmations)
T_PREV=$(lf "$LB_TV" previousblockhash)
[[ "$T_NEXT" == "__ABSENT__" ]] || { TIP_T="bad"; log "tip has nextblockhash (must be absent): '$T_NEXT'"; }
[[ "$T_CONF" == "1" ]] || { TIP_T="bad"; log "tip confirmations != 1: '$T_CONF'"; }
[[ "$T_PREV" =~ ^[0-9a-f]{64}$ ]] || { TIP_T="bad"; log "tip previousblockhash absent/not-64-hex: '$T_PREV'"; }
# tip chainwork must equal Core's (exact).
CORE_T_V=$(jres "$(core_rpc getblockheader "[\"$CORE_TIP\", true]")" "json.dumps(r)")
CT_CW=$(cf "$CORE_T_V" chainwork)
LT_CW=$(lf "$LB_TV" chainwork)
[[ "$CT_CW" == "$LT_CW" ]] || { TIP_T="bad"; log "tip chainwork mismatch: core='$CT_CW' lb='$LT_CW'"; }
[[ "$TIP_T" == "ok" ]] || fail "tip structural check failed (see log)"

# ── 10. CHECK 5 — ERROR: unknown blockhash -> RPC code -5. ────────────────
ERRORS_T="ok"
BAD_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
E5=$(jerr "$(lb_rpc getblockheader "[\"$BAD_HASH\"]")")
[[ "$E5" == "-5" ]] || { ERRORS_T="bad"; log "expected -5 for unknown blockhash, got '$E5'"; }
# also verify with explicit verbose=false.
E5F=$(jerr "$(lb_rpc getblockheader "[\"$BAD_HASH\", false]")")
[[ "$E5F" == "-5" ]] || { ERRORS_T="bad"; log "expected -5 (verbose=false) for unknown blockhash, got '$E5F'"; }
[[ "$ERRORS_T" == "ok" ]] || fail "error-code check failed (see log)"

# ── 11. All checks green. ─────────────────────────────────────────────────
log "PASS: lunarblock getblockheader matches Core (hex + verbose fields + structure + error code)"
pass "$HEX_T" "$VERBOSE_T" "$GENESIS_T" "$TIP_T" "$ERRORS_T"

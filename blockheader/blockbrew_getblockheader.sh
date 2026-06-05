#!/usr/bin/env bash
#
# blockbrew_getblockheader.sh — self-contained getblockheader Core-parity test.
#
# An RPC-surface green-cell. getblockheader is a READ-ONLY header query — NOT
# consensus — but must match Bitcoin Core EXACTLY for a given chain shape.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:599-666 (getblockheader)
#           + :154-182 (blockheaderToJSON).
#   SIGNATURE: getblockheader "blockhash" ( verbose ).  verbose default TRUE.
#   OUTPUT:
#     verbose=false -> the 80-byte serialized block HEADER as HEX (160 chars):
#                      version LE + prev hash + merkle root + time + bits + nonce.
#     verbose=true  -> an OBJECT with: hash, confirmations (= tipHeight-height+1
#                      for an in-chain block, -1 if not in active chain), height,
#                      version, versionHex (8-hex "%08x"), merkleroot, time,
#                      mediantime (11-block MTP), nonce, bits (8-hex "%08x"),
#                      target (256-bit target hex), difficulty (float),
#                      chainwork (32-byte hex), nTx, previousblockhash (present
#                      ONLY if the block has a parent — ABSENT for genesis),
#                      nextblockhash (present ONLY if a next block exists —
#                      ABSENT for the tip).
#   ERROR: a blockhash not in the index -> RPC -5 (RPC_INVALID_ADDRESS_OR_KEY)
#          "Block not found".
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports.  To make the content-dependent header
#   fields (hash / merkleroot / time / nonce / previousblockhash /
#   nextblockhash and the serialized header hex) BYTE-EXACT across the two
#   nodes, we mine NBLOCKS empty blocks on Core, then REPLICATE the identical
#   blocks to blockbrew via submitblock(getblock(h, 0)).  That gives both nodes
#   the IDENTICAL chain (same coinbase scriptSig, same timestamps, same nonces)
#   — so every header byte matches.  (Two independently-mined regtest chains
#   would diverge in coinbase scriptSig + wall-clock and could only be compared
#   on shape, not on literal bytes; the byte-exact requirement of this cell
#   demands an identical chain, hence the replicate-via-submitblock approach.)
#
# WHAT MUST MATCH CORE EXACTLY (identical chain shape):
#   verbose=false @h60: the full 160-char serialized header hex == Core's.
#   verbose=true  @h60: hash, height, version, versionHex, merkleroot, time,
#                       mediantime, nonce, bits, nTx, previousblockhash,
#                       nextblockhash, confirmations, chainwork == Core's.
# WHAT MUST BE PRESENT + CORRECTLY-TYPED (not byte-equal):
#   difficulty: present + a float (Core uses C double; JSON formatting can vary).
#   target:     present + 64-hex (newer field; some impls clamp/format differently).
# OPTIONAL-KEY RULES:
#   GENESIS (height 0): NO previousblockhash key; nextblockhash present.
#   TIP:                NO nextblockhash key; confirmations == 1.
# ERROR-CODE RULE: a syntactically-valid but unknown blockhash -> -5.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/rustoshi_chaintxstats.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKHEADER blockbrew: PASS hex=ok verbose=ok genesis=ok tip=ok errors=ok
#   FAIL: GETBLOCKHEADER blockbrew: FAIL <short reason>
#
# Touches ONLY /tmp/gbh-blockbrew/ + /tmp/gbh-core/ and ports
#   40153/40173 (blockbrew RPC/P2P) + 40155/40175 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/blockbrew/blockbrew"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

BB_DATADIR="/tmp/gbh-blockbrew"
BB_RPC=40153
BB_P2P=40173
BB_LOG="$BB_DATADIR/node.log"
BB_COOKIE=""
BB_PID=""

CORE_DATADIR="/tmp/gbh-core"
CORE_RPC=40155
CORE_P2P=40175
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

# Deterministic test secret -> one p2wpkh bcrt1 address Core mines to.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=120        # mine 120 empty blocks; we query height 60 (has prev + next).
QH=60              # the in-chain height we assert byte-exact against Core.

ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockheader:blockbrew] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BB_PID" ]] && kill -0 "$BB_PID" 2>/dev/null; then
        kill "$BB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${BB_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${BB_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$BB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <hex> <verbose> <genesis> <tip> <errors>
pass() {
    echo "GETBLOCKHEADER blockbrew: PASS hex=$1 verbose=$2 genesis=$3 tip=$4 errors=$5"
    exit 0
}
fail() {
    echo "GETBLOCKHEADER blockbrew: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gbh-blockbrew" 2>/dev/null || true
fuser -k "${BB_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${BB_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 3
rm -rf "$BB_DATADIR" "$CORE_DATADIR"
mkdir -p "$BB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "blockbrew binary not found at $NODE_BIN (build with: go build -o blockbrew ./cmd/blockbrew)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive the deterministic bcrt1 p2wpkh mining address. ──────────────
ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive deterministic mining address (Core test_framework import failed)"
[[ "$ADDR" == bcrt1* ]] || fail "derived address is not a regtest bech32 address: '$ADDR'"
log "deterministic mining address: $ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# core_cli_retry: tolerant of the bitcoin-cli .cookie read race under
# concurrent fleet load (a fresh daemon rewrites regtest/.cookie; a CLI that
# reads it mid-write returns empty) and of transient RPC-busy stalls during a
# tight per-block replication loop. Up to 20 attempts, 1s apart.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 20); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# bb_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
bb_rpc() {
    curl -s --max-time 90 -u "$BB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$BB_RPC/" 2>/dev/null
}

# jpy <json> <expr>  -- expr references parsed object as `d`. Errors -> empty.
jpy() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# bb_result <method> <params> -> the JSON-RPC result, dumped as JSON (or empty).
bb_result() { jpy "$(bb_rpc "$1" "$2")" "json.dumps(d['result'])"; }
# bb_scalar <method> <params> -> the scalar JSON-RPC result (or empty).
bb_scalar() { jpy "$(bb_rpc "$1" "$2")" "d['result']"; }
# bb_errcode <method> <params> -> the JSON-RPC error code (or empty).
bb_errcode() { jpy "$(bb_rpc "$1" "$2")" "d['error']['code']"; }

# ── 3. Launch the Core regtest oracle (-listen=0: RPC-only). ──────────────
# The sandbox SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener ~2s after
# load, so launch with -listen=0 (RPC-only is fine). Retry up to 3 times on a
# fresh datadir to absorb crossing port-cleanup / cookie races.
launch_core_once() {
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -listen=0 \
        -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if core_cli getblockcount >/dev/null 2>&1; then
            core_cli_retry getblockcount >/dev/null && return 0
        fi
        kill -0 "$CORE_BG" 2>/dev/null || return 1   # exited during startup
        sleep 1
    done
    return 1
}
CORE_OK=0
for attempt in 1 2 3; do
    log "launching Core regtest oracle rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch blockbrew on regtest (retryable). ───────────────────────────
# -metricsport=0 avoids the default 0.0.0.0:9332 metrics bind (collides with a
#   sibling node AND draws the sandbox's 0.0.0.0-listener SIGKILL).
# -nolisten: no inbound P2P needed — every block arrives via submitblock RPC.
#   This also removes the P2P listener entirely, so nothing binds a wildcard
#   address and the sandbox listener-killer has no target.
# Retry up to 3 times on a fresh datadir: under heavy concurrent fleet load the
# sandbox can OOM/SIGKILL a freshly-launched node during its startup window.
launch_bb_once() {
    BB_COOKIE=""
    fuser -k "${BB_RPC}/tcp" >/dev/null 2>&1 || true
    rm -rf "$BB_DATADIR"; mkdir -p "$BB_DATADIR"
    "$NODE_BIN" -network=regtest -datadir="$BB_DATADIR" \
        -rpcbind="127.0.0.1:$BB_RPC" -nolisten \
        -metricsport=0 >"$BB_LOG" 2>&1 &
    BB_PID=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if [[ -z "$BB_COOKIE" ]]; then
            for c in "$BB_DATADIR/regtest/.cookie" "$BB_DATADIR/.cookie"; do
                [[ -f "$c" ]] && BB_COOKIE=$(cat "$c") && break
            done
        fi
        if [[ -n "$BB_COOKIE" ]] && echo "$(bb_rpc getblockcount '[]')" | grep -q '"result"'; then
            return 0
        fi
        kill -0 "$BB_PID" 2>/dev/null || return 1   # died during startup
        sleep 1
    done
    return 1
}
BB_OK=0
for attempt in 1 2 3; do
    log "launching blockbrew (regtest, nolisten) rpc=:$BB_RPC -> $BB_LOG (attempt $attempt)"
    if launch_bb_once; then BB_OK=1; break; fi
    log "blockbrew launch attempt $attempt failed (see $BB_LOG); retrying after settle"
    [[ -n "$BB_PID" ]] && kill "$BB_PID" 2>/dev/null || true
    BB_PID=""
    sleep 3
done
[[ "$BB_OK" == "1" ]] || { tail -n 20 "$BB_LOG" >&2 2>/dev/null || true; fail "blockbrew failed to start within 3 attempts (see $BB_LOG)"; }
log "blockbrew RPC ready"

# ── 5. Mine NBLOCKS empty blocks on Core, then REPLICATE to blockbrew. ────
log "mining $NBLOCKS empty blocks to $ADDR on Core"
core_cli_retry generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $NBLOCKS"

log "replicating $NBLOCKS Core blocks to blockbrew via submitblock"
# Fetch all raw block hexes from Core in ONE Python pass over the Core RPC
# (single persistent process; avoids forking bitcoin-cli ~240x, which was
# load-sensitive under concurrent fleet pressure). Read the Core cookie and
# talk JSON-RPC directly. Emits one "<height> <rawhex>" line per block.
CORE_COOKIE_FILE="$CORE_DATADIR/regtest/.cookie"
[[ -f "$CORE_COOKIE_FILE" ]] || fail "Core cookie not found at $CORE_COOKIE_FILE"
RAW_LIST=$(python3 -c "
import sys, json, base64, urllib.request
cookie=open('$CORE_COOKIE_FILE').read().strip()
auth='Basic '+base64.b64encode(cookie.encode()).decode()
def rpc(method, params):
    body=json.dumps({'jsonrpc':'1.0','id':1,'method':method,'params':params}).encode()
    req=urllib.request.Request('http://127.0.0.1:$CORE_RPC/', data=body,
        headers={'Content-Type':'application/json','Authorization':auth})
    return json.load(urllib.request.urlopen(req, timeout=60))['result']
for h in range(1, $NBLOCKS+1):
    bh=rpc('getblockhash',[h])
    raw=rpc('getblock',[bh,0])
    print('%d %s'%(h, raw))
" 2>/dev/null) || fail "Core raw-block fetch (python JSON-RPC) failed"
GOT=$(echo "$RAW_LIST" | grep -c .)
[[ "$GOT" == "$NBLOCKS" ]] || fail "fetched $GOT raw blocks from Core, expected $NBLOCKS"
while read -r h RAW; do
    [[ -n "$RAW" ]] || continue
    # Liveness guard: if blockbrew died (e.g. sandbox OOM/listener SIGKILL),
    # fail fast with a clear message instead of looping over empty responses.
    kill -0 "$BB_PID" 2>/dev/null || fail "blockbrew process died during replication at h=$h (see $BB_LOG)"
    SUB=$(bb_rpc submitblock "[\"$RAW\"]")
    echo "$SUB" | grep -q '"error":null' || { log "submitblock h=$h -> $SUB"; }
done <<< "$RAW_LIST"
BB_HEIGHT=$(bb_scalar getblockcount '[]')
[[ "$BB_HEIGHT" == "$NBLOCKS" ]] || fail "blockbrew height after replicate is $BB_HEIGHT, expected $NBLOCKS (submitblock did not take)"

# Sanity: identical chains -> identical tip hash.
CORE_TIP=$(core_cli_retry getbestblockhash)
BB_TIP=$(bb_scalar getbestblockhash '[]')
[[ -n "$CORE_TIP" && "$CORE_TIP" == "$BB_TIP" ]] \
    || fail "tip hash mismatch after replicate (core=$CORE_TIP bb=$BB_TIP) — chains not identical"
log "chains identical at tip $BB_TIP (height $NBLOCKS)"

# ── 6. TEST 1 — verbose=false @h$QH: serialized header hex byte-EXACT. ─────
QHASH=$(core_cli_retry getblockhash "$QH") || fail "Core getblockhash $QH failed"
CORE_HDRHEX=$(core_cli_retry getblockheader "$QHASH" false) || fail "Core getblockheader false failed"
BB_HDRHEX=$(bb_scalar getblockheader "[\"$QHASH\", false]")
HEX_T="ok"
[[ "${#CORE_HDRHEX}" == "160" ]] || fail "Core header hex is ${#CORE_HDRHEX} chars, expected 160 (oracle unexpected)"
if [[ "$BB_HDRHEX" != "$CORE_HDRHEX" ]]; then
    HEX_T="bad"
    log "verbose=false header hex MISMATCH @h$QH:"
    log "  core: $CORE_HDRHEX"
    log "  bb  : $BB_HDRHEX"
fi
[[ "$HEX_T" == "ok" ]] || fail "verbose=false serialized header hex != Core @h$QH (len bb=${#BB_HDRHEX})"

# ── 7. TEST 2 — verbose=true @h$QH: byte-exact fields + present-typed extras. ─
CORE_JSON=$(core_cli_retry getblockheader "$QHASH" true) || fail "Core getblockheader true failed"
BB_JSON=$(bb_result getblockheader "[\"$QHASH\", true]")
[[ -n "$CORE_JSON" && -n "$BB_JSON" ]] || fail "could not read both verbose headers (core/bb empty)"
log "core verbose @h$QH: $CORE_JSON"
log "bb   verbose @h$QH: $BB_JSON"

VERBOSE_T=$(python3 -c "
import json,sys
c=json.loads('''$CORE_JSON'''); b=json.loads('''$BB_JSON''')
# Fields that MUST be byte-exact vs Core on the identical chain.
exact=['hash','height','version','versionHex','merkleroot','time','mediantime',
       'nonce','bits','nTx','previousblockhash','nextblockhash',
       'confirmations','chainwork']
bad=[]
for k in exact:
    if k not in b: bad.append(k+':absent'); continue
    if k not in c: continue  # Core doesn't have it; skip (shouldn't happen at h60)
    if b[k]!=c[k]: bad.append(k+f'(bb={b[k]} core={c[k]})')
# difficulty: present + float/int (NOT byte-equal — float formatting varies).
if 'difficulty' not in b: bad.append('difficulty:absent')
elif not isinstance(b['difficulty'],(int,float)) or isinstance(b['difficulty'],bool):
    bad.append('difficulty:not-numeric')
# target: present + 64-hex (NOT byte-equal — newer field, may clamp/format).
import re
if 'target' not in b: bad.append('target:absent')
elif not re.fullmatch(r'[0-9a-f]{64}', str(b['target'])): bad.append('target:not-64hex')
# At h60 of a 120-block chain BOTH prev+next must be present.
if 'previousblockhash' not in b: bad.append('previousblockhash:absent-at-h$QH')
if 'nextblockhash' not in b: bad.append('nextblockhash:absent-at-h$QH')
print('ok' if not bad else 'bad:'+';'.join(bad))
" 2>/dev/null)
[[ "$VERBOSE_T" == "ok" ]] || fail "verbose=true field check @h$QH: ${VERBOSE_T:-python-error}"

# ── 8. TEST 3 — GENESIS: NO previousblockhash; nextblockhash present. ──────
GENHASH=$(core_cli_retry getblockhash 0) || fail "Core getblockhash 0 failed"
BB_GEN=$(bb_result getblockheader "[\"$GENHASH\", true]")
[[ -n "$BB_GEN" ]] || fail "blockbrew genesis header empty"
GENESIS_T=$(python3 -c "
import json
g=json.loads('''$BB_GEN''')
bad=[]
if 'previousblockhash' in g: bad.append('previousblockhash-present-on-genesis')
if 'nextblockhash' not in g: bad.append('nextblockhash-absent-on-genesis')
if g.get('height')!=0: bad.append('genesis-height!=0(%r)'%g.get('height'))
print('ok' if not bad else 'bad:'+';'.join(bad))
" 2>/dev/null)
[[ "$GENESIS_T" == "ok" ]] || fail "genesis optional-key check: ${GENESIS_T:-python-error}"

# ── 9. TEST 4 — TIP: nextblockhash ABSENT; confirmations == 1. ────────────
BB_TIPJSON=$(bb_result getblockheader "[\"$BB_TIP\", true]")
[[ -n "$BB_TIPJSON" ]] || fail "blockbrew tip header empty"
TIP_T=$(python3 -c "
import json
t=json.loads('''$BB_TIPJSON''')
bad=[]
if 'nextblockhash' in t: bad.append('nextblockhash-present-on-tip')
if t.get('confirmations')!=1: bad.append('confirmations!=1(%r)'%t.get('confirmations'))
if 'previousblockhash' not in t: bad.append('previousblockhash-absent-on-tip')
print('ok' if not bad else 'bad:'+';'.join(bad))
" 2>/dev/null)
[[ "$TIP_T" == "ok" ]] || fail "tip optional-key/confirmations check: ${TIP_T:-python-error}"

# ── 10. TEST 5 — ERROR: unknown blockhash -> RPC -5. ──────────────────────
# A syntactically-valid 64-hex that is not in the index.
ERR_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
E5=$(bb_errcode getblockheader "[\"$ERR_HASH\", true]")
ERRORS_T="ok"
[[ "$E5" == "-5" ]] || { ERRORS_T="bad"; log "expected -5 for unknown blockhash, got '$E5'"; }
[[ "$ERRORS_T" == "ok" ]] || fail "error-code check: unknown blockhash expected -5, got '$E5'"

log "PASS: blockbrew getblockheader matches Core (hex byte-exact + verbose fields + genesis/tip optional-keys + error -5)"
pass "$HEX_T" "ok" "$GENESIS_T" "$TIP_T" "$ERRORS_T"

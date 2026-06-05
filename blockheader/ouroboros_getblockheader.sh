#!/usr/bin/env bash
#
# ouroboros_getblockheader.sh — self-contained getblockheader Core-parity test.
#
# A clean, deterministic RPC-surface green-cell. getblockheader is READ-ONLY
# header serialisation — NOT consensus — but its output SHAPE must match Bitcoin
# Core EXACTLY for a given chain shape.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:599-666 (getblockheader) +
#           :154-182 (blockheaderToJSON).
#   SIGNATURE: getblockheader "blockhash" ( verbose ). verbose default TRUE (bool).
#   OUTPUT:
#     verbose=false -> the 80-byte serialized block HEADER as HEX (byte-EXACT:
#       version LE + prev hash + merkle root + time + bits + nonce).
#     verbose=true  -> an OBJECT (blockheaderToJSON) with keys:
#       hash, confirmations (= tipHeight - height + 1 in-chain, -1 if not active),
#       height, version, versionHex ("%08x"), merkleroot, time, mediantime
#       (11-block MTP), nonce, bits ("%08x"), target (256-bit, derived from bits
#       vs powLimit), difficulty (float), chainwork (32-byte hex), nTx,
#       previousblockhash (ONLY if the block has a parent — absent for genesis),
#       nextblockhash (ONLY if a next block exists — absent for the tip).
#   ERROR: a blockhash not in the index -> RPC code -5
#          (RPC_INVALID_ADDRESS_OR_KEY) "Block not found".
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports. Core MINES NBLOCKS empty blocks to a
#   deterministic p2wpkh address; ouroboros then REPLAYS Core's EXACT raw
#   blocks via submitblock (getblock <h> 0 -> submitblock), so the two chains
#   are BYTE-IDENTICAL — same coinbase, merkle root, time, AND nonce at every
#   height. (Independent mining would diverge: different coinbase scriptSig +
#   wall-clock nTime + nonce -> different merkleroot/hash, defeating the
#   byte-exact header check.) With byte-identical chains the header bytes,
#   hash, height, version, versionHex, merkleroot, time, mediantime, nonce,
#   bits, nTx, previousblockhash, nextblockhash, confirmations, chainwork are
#   ALL asserted EXACTLY against Core. difficulty + target are asserted
#   PRESENT + correctly-typed (NOT byte-equal — difficulty is a float that can
#   format differently; target is a newer field).
#
# WHAT MUST MATCH CORE EXACTLY (per chain shape, at height 60):
#   * verbose=false 160-char header hex (byte-EXACT)
#   * hash, height, version, versionHex, merkleroot, time, mediantime, nonce,
#     bits, nTx, previousblockhash, nextblockhash, confirmations, chainwork
# WHAT MUST BE PRESENT + TYPED (not byte-equal):
#   * difficulty (float/number, > 0), target (64-hex string)
# STRUCTURAL RULES:
#   * GENESIS: NO previousblockhash key; nextblockhash present.
#   * TIP:     NO nextblockhash key; confirmations == 1.
# ERROR-CODE RULE: an unknown 64-hex blockhash -> -5.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/rustoshi_chaintxstats.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKHEADER ouroboros: PASS hex=ok verbose=ok genesis=ok tip=ok errors=ok
#   FAIL: GETBLOCKHEADER ouroboros: FAIL <short reason>
#
# Touches ONLY /tmp/gbh-ouroboros/ + /tmp/gbh-core/ and ports
#   40152/40172 (ouroboros RPC/P2P) + 40154/40174 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
OURO_DIR="$BASEDIR/ouroboros"
OURO_PY="$OURO_DIR/.venv/bin/python3"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

OU_DATADIR="/tmp/gbh-ouroboros"
OU_RPC=40152
OU_P2P=40172
OU_LOG="$OU_DATADIR/node.log"

CORE_DATADIR="/tmp/gbh-core"
CORE_RPC=40154
CORE_P2P=40174
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test secret -> one p2wpkh bcrt1 address BOTH nodes mine to, so
# both chains have the identical SHAPE (empty blocks, 1 coinbase tx each).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=120        # mine 120 empty blocks
PROBE_HEIGHT=60    # the in-chain height whose header we compare byte-for-byte

OU_PID=""
OU_COOKIE=""
CORE_BG=""
ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockheader:ouroboros] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$OU_PID" ]] && kill -0 "$OU_PID" 2>/dev/null; then
        kill "$OU_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$OU_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$OU_PID" 2>/dev/null || true
    fi
    pkill -f "gbh-ouroboros" 2>/dev/null || true
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${OU_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${OU_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$OU_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <hex> <verbose> <genesis> <tip> <errors>
pass() {
    echo "GETBLOCKHEADER ouroboros: PASS hex=$1 verbose=$2 genesis=$3 tip=$4 errors=$5"
    exit 0
}
fail() {
    echo "GETBLOCKHEADER ouroboros: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gbh-ouroboros" 2>/dev/null || true
fuser -k "${OU_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${OU_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 3
rm -rf "$OU_DATADIR" "$CORE_DATADIR"
mkdir -p "$OU_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$OURO_PY" ]]                  || OURO_PY="python3"
[[ -f "$OURO_DIR/src/ouroboros/cli.py" ]] || fail "ouroboros cli.py not found under $OURO_DIR"
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
# concurrent fleet load. Up to 8 attempts, 1s apart.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# ou_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
ou_rpc() {
    curl -s --max-time 90 -u "$OU_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$OU_RPC/" 2>/dev/null
}

# jpy <json> <expr>   (expr references parsed object as `d`); empty on error.
jpy() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    elif v is None: print('')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# ── 3. Launch the Core regtest oracle (-listen=0; RPC-only). ──────────────
# The sandbox SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener ~2s after
# load — so we launch with -listen=0. RPC-only is fine for this oracle.
launch_core_once() {
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if core_cli getblockcount >/dev/null 2>&1; then
            core_cli_retry getblockcount >/dev/null && return 0
        fi
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
CORE_OK=0
for attempt in 1 2 3; do
    log "launching Core regtest oracle rpc=:$CORE_RPC -listen=0 (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch ouroboros on regtest (unique ports, --nolisten). ────────────
log "launching ouroboros (regtest) rpc=:$OU_RPC p2p=:$OU_P2P -> $OU_LOG"
(
    cd "$OURO_DIR"
    exec "$OURO_PY" -m ouroboros.cli \
        --network regtest --data-dir "$OU_DATADIR" \
        start --force --nolisten --nodnsseed \
        --rpc-port "$OU_RPC" --p2p-port "$OU_P2P"
) >"$OU_LOG" 2>&1 &
OU_PID=$!

# ouroboros (Python) — generous (>=90s) RPC-startup wait.
ou_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < ou_deadline )); do
    if [[ -z "$OU_COOKIE" ]]; then
        for c in "$OU_DATADIR/.cookie" "$OU_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && OU_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$OU_COOKIE" ]]; then
        echo "$(ou_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$OU_PID" 2>/dev/null || { tail -n 30 "$OU_LOG" >&2 2>/dev/null || true; fail "ouroboros exited during startup (see $OU_LOG)"; }
    sleep 2
done
[[ -n "$OU_COOKIE" ]] || fail "ouroboros cookie never appeared within 120s"
echo "$(ou_rpc getblockcount '[]')" | grep -q '"result"' || fail "ouroboros RPC never responded within 120s"
log "ouroboros RPC ready"

# ── 5. Mine NBLOCKS empty blocks on Core; REPLAY them into ouroboros. ──────
# Core is the miner; ouroboros replays Core's EXACT raw blocks via submitblock
# so the chains are byte-identical (same nonce/coinbase/merkleroot/time).
log "mining $NBLOCKS empty blocks to $ADDR on Core"
core_cli_retry generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $NBLOCKS"

log "replaying Core's $NBLOCKS raw blocks into ouroboros via submitblock"
for ((h=1; h<=NBLOCKS; h++)); do
    BH=$(core_cli_retry getblockhash "$h") || fail "Core getblockhash $h failed"
    RAW=$(core_cli_retry getblock "$BH" 0) || fail "Core getblock $BH 0 failed"
    [[ -n "$RAW" ]] || fail "Core returned empty raw block at height $h"
    SUB_ENV=$(ou_rpc submitblock "[\"$RAW\"]")
    echo "$SUB_ENV" | grep -q '"result"' || fail "ouroboros submitblock errored at height $h: $SUB_ENV"
    # BIP-22: result is null on success, a short reject string on failure.
    SUB_RES=$(jpy "$SUB_ENV" "d.get('result')")
    if [[ -n "$SUB_RES" && "$SUB_RES" != "None" ]]; then
        fail "ouroboros rejected Core block at height $h: '$SUB_RES'"
    fi
done
OU_HEIGHT=$(jpy "$(ou_rpc getblockcount '[]')" "d['result']")
[[ "$OU_HEIGHT" == "$NBLOCKS" ]] || fail "ouroboros height after replay is $OU_HEIGHT, expected $NBLOCKS"

# ── 6. Resolve the canonical hashes on Core (ground truth). ───────────────
# The chains are byte-identical, so Core's hash-at-height == ouroboros's.
CORE_PROBE_HASH=$(core_cli_retry getblockhash "$PROBE_HEIGHT")
CORE_GENESIS_HASH=$(core_cli_retry getblockhash 0)
CORE_TIP_HASH=$(core_cli_retry getbestblockhash)
[[ -n "$CORE_PROBE_HASH" && -n "$CORE_GENESIS_HASH" && -n "$CORE_TIP_HASH" ]] \
    || fail "could not read Core probe/genesis/tip hashes"

OU_PROBE_HASH=$(jpy "$(ou_rpc getblockhash "[$PROBE_HEIGHT]")" "d['result']")
OU_GENESIS_HASH=$(jpy "$(ou_rpc getblockhash "[0]")" "d['result']")
OU_TIP_HASH=$(jpy "$(ou_rpc getbestblockhash '[]')" "d['result']")
[[ -n "$OU_PROBE_HASH" && -n "$OU_GENESIS_HASH" && -n "$OU_TIP_HASH" ]] \
    || fail "could not read ouroboros probe/genesis/tip hashes"

# Byte-identical chains => hash-at-height matches Core exactly at every probe.
[[ "$OU_GENESIS_HASH" == "$CORE_GENESIS_HASH" ]] \
    || fail "genesis hash mismatch ou=$OU_GENESIS_HASH core=$CORE_GENESIS_HASH"
[[ "$OU_PROBE_HASH" == "$CORE_PROBE_HASH" ]] \
    || fail "probe-height($PROBE_HEIGHT) hash mismatch ou=$OU_PROBE_HASH core=$CORE_PROBE_HASH (replay did not produce an identical chain)"
[[ "$OU_TIP_HASH" == "$CORE_TIP_HASH" ]] \
    || fail "tip hash mismatch ou=$OU_TIP_HASH core=$CORE_TIP_HASH (replay did not produce an identical chain)"

# ── 7. CASE 1 — verbose=false: 160-char header hex byte-EXACT vs Core. ────
HEX_T="ok"
CORE_HEX=$(core_cli_retry getblockheader "$CORE_PROBE_HASH" false)
OU_HEX=$(jpy "$(ou_rpc getblockheader "[\"$OU_PROBE_HASH\", false]")" "d['result']")
[[ "$CORE_HEX" =~ ^[0-9a-f]{160}$ ]] || fail "Core header hex not 160-hex: '$CORE_HEX'"
[[ "$OU_HEX" =~ ^[0-9a-f]{160}$ ]]   || { HEX_T="bad"; log "ouroboros header hex not 160-hex: '$OU_HEX'"; }
[[ "$OU_HEX" == "$CORE_HEX" ]]       || { HEX_T="bad"; log "verbose=false header hex mismatch:
  core=$CORE_HEX
  ouro=$OU_HEX"; }
[[ "$HEX_T" == "ok" ]] || fail "verbose=false header hex not byte-exact vs Core (see log)"
log "verbose=false header hex byte-exact at height $PROBE_HEIGHT"

# ── 8. CASE 2 — verbose=true object: exact fields + present/typed extras. ──
VERBOSE_T="ok"
CORE_OBJ=$(core_cli_retry getblockheader "$CORE_PROBE_HASH" true)
OU_OBJ_ENV=$(ou_rpc getblockheader "[\"$OU_PROBE_HASH\", true]")
echo "$OU_OBJ_ENV" | grep -q '"result"' || fail "ouroboros getblockheader verbose errored: $OU_OBJ_ENV"
OU_OBJ=$(jpy "$OU_OBJ_ENV" "json.dumps(d['result'])")
[[ -n "$CORE_OBJ" && -n "$OU_OBJ" ]] || fail "empty verbose object (core or ouroboros)"

log "Core   obj: $CORE_OBJ"
log "ouro   obj: $OU_OBJ"

cobj() { jpy "$CORE_OBJ" "d.get('$1')"; }
oobj() { jpy "$OU_OBJ"   "d.get('$1')"; }

# Fields that MUST match Core EXACTLY for the same chain shape.
EXACT_FIELDS=(hash confirmations height version versionHex merkleroot time \
              mediantime nonce bits nTx previousblockhash nextblockhash chainwork)
for f in "${EXACT_FIELDS[@]}"; do
    CV=$(cobj "$f"); OV=$(oobj "$f")
    if [[ "$CV" != "$OV" ]]; then
        VERBOSE_T="bad"; log "field '$f' mismatch: core='$CV' ouro='$OV'"
    fi
done

# Spot-check the chain shape (sanity that the oracle/shape is as expected).
[[ "$(cobj height)" == "$PROBE_HEIGHT" ]] || fail "Core height != $PROBE_HEIGHT (oracle/shape unexpected)"
[[ "$(cobj nTx)" == "1" ]]                || fail "Core nTx != 1 for empty block (oracle/shape unexpected)"
# in-chain confirmations = tipHeight - height + 1 = 120 - 60 + 1 = 61.
EXP_CONF=$(( NBLOCKS - PROBE_HEIGHT + 1 ))
[[ "$(cobj confirmations)" == "$EXP_CONF" ]] || fail "Core confirmations != $EXP_CONF (oracle/shape unexpected)"

# difficulty + target: PRESENT + correctly-typed, NOT byte-equal.
OU_DIFF=$(oobj difficulty)
if ! [[ "$OU_DIFF" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
    VERBOSE_T="bad"; log "difficulty absent/non-numeric: '$OU_DIFF'"
fi
OU_TARGET=$(oobj target)
if ! [[ "$OU_TARGET" =~ ^[0-9a-f]{64}$ ]]; then
    VERBOSE_T="bad"; log "target absent/not-64-hex: '$OU_TARGET'"
fi

[[ "$VERBOSE_T" == "ok" ]] || fail "verbose=true field/shape check failed (see log)"
log "verbose=true object matches Core on all exact fields + difficulty/target typed"

# ── 9. CASE 3 — GENESIS: no previousblockhash; nextblockhash present. ──────
GENESIS_T="ok"
OU_GEN_ENV=$(ou_rpc getblockheader "[\"$OU_GENESIS_HASH\", true]")
echo "$OU_GEN_ENV" | grep -q '"result"' || fail "ouroboros getblockheader(genesis) errored: $OU_GEN_ENV"
OU_GEN=$(jpy "$OU_GEN_ENV" "json.dumps(d['result'])")
HAS_PREV=$(jpy "$OU_GEN" "'previousblockhash' in d")
HAS_NEXT=$(jpy "$OU_GEN" "'nextblockhash' in d")
GEN_HEIGHT=$(jpy "$OU_GEN" "d.get('height')")
[[ "$HAS_PREV" == "false" ]] || { GENESIS_T="bad"; log "genesis has a previousblockhash key (should be absent)"; }
[[ "$HAS_NEXT" == "true"  ]] || { GENESIS_T="bad"; log "genesis missing nextblockhash key (should be present)"; }
[[ "$GEN_HEIGHT" == "0"   ]] || { GENESIS_T="bad"; log "genesis height != 0: '$GEN_HEIGHT'"; }
# Cross-check vs Core: Core genesis also omits previousblockhash + has nextblockhash.
CORE_GEN=$(core_cli_retry getblockheader "$CORE_GENESIS_HASH" true)
C_HAS_PREV=$(jpy "$CORE_GEN" "'previousblockhash' in d")
[[ "$C_HAS_PREV" == "false" ]] || fail "Core genesis unexpectedly has previousblockhash (oracle sanity)"
[[ "$GENESIS_T" == "ok" ]] || fail "genesis structural check failed (see log)"
log "genesis: no previousblockhash, nextblockhash present, height 0"

# ── 10. CASE 4 — TIP: no nextblockhash; confirmations == 1. ───────────────
TIP_T="ok"
OU_TIP_ENV=$(ou_rpc getblockheader "[\"$OU_TIP_HASH\", true]")
echo "$OU_TIP_ENV" | grep -q '"result"' || fail "ouroboros getblockheader(tip) errored: $OU_TIP_ENV"
OU_TIPOBJ=$(jpy "$OU_TIP_ENV" "json.dumps(d['result'])")
TIP_HAS_NEXT=$(jpy "$OU_TIPOBJ" "'nextblockhash' in d")
TIP_CONF=$(jpy "$OU_TIPOBJ" "d.get('confirmations')")
TIP_HEIGHT=$(jpy "$OU_TIPOBJ" "d.get('height')")
[[ "$TIP_HAS_NEXT" == "false" ]] || { TIP_T="bad"; log "tip has a nextblockhash key (should be absent)"; }
[[ "$TIP_CONF" == "1" ]]         || { TIP_T="bad"; log "tip confirmations != 1: '$TIP_CONF'"; }
[[ "$TIP_HEIGHT" == "$NBLOCKS" ]] || { TIP_T="bad"; log "tip height != $NBLOCKS: '$TIP_HEIGHT'"; }
[[ "$TIP_T" == "ok" ]] || fail "tip structural check failed (see log)"
log "tip: no nextblockhash, confirmations == 1"

# ── 11. CASE 5 — ERROR: unknown 64-hex blockhash -> RPC -5. ───────────────
ERRORS_T="ok"
ERR_BAD_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
E5=$(jpy "$(ou_rpc getblockheader "[\"$ERR_BAD_HASH\"]")" "d['error']['code']")
[[ "$E5" == "-5" ]] || { ERRORS_T="bad"; log "expected error -5 (Block not found) for unknown blockhash, got '$E5'"; }
# Cross-check Core also returns -5 (oracle sanity).
CORE_E5=$(core_cli getblockheader "$ERR_BAD_HASH" 2>&1 | grep -oE '\-5' | head -1)
[[ "$CORE_E5" == "-5" ]] || log "(note) Core getblockheader bad-hash did not surface -5 via CLI text; relying on documented behaviour"
[[ "$ERRORS_T" == "ok" ]] || fail "error-code parity check failed (see log)"
log "error: unknown blockhash -> -5 (RPC_INVALID_ADDRESS_OR_KEY)"

log "PASS: ouroboros getblockheader matches Core (hex + verbose + genesis + tip + errors)"
pass "$HEX_T" "$VERBOSE_T" "$GENESIS_T" "$TIP_T" "$ERRORS_T"

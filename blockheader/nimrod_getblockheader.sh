#!/usr/bin/env bash
#
# nimrod_getblockheader.sh — self-contained getblockheader Core-parity test.
#
# An RPC-surface green-cell. getblockheader is a READ-ONLY block-index query —
# NOT consensus — but its output SHAPE + field values must match Bitcoin Core
# EXACTLY for a given chain shape.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:599-666 (getblockheader) +
#   :154-182 (blockheaderToJSON).
#   SIGNATURE: getblockheader "blockhash" ( verbose ). verbose default TRUE.
#   OUTPUT:
#     verbose=false -> the 80-byte serialized block HEADER as HEX (160 chars):
#                      version LE + prev hash + merkle root + time + bits + nonce.
#     verbose=true  -> OBJECT with keys: hash, confirmations (= tip-height -
#                      height + 1 for an in-chain block, -1 if not in the active
#                      chain), height, version, versionHex ("%08x"), merkleroot,
#                      time, mediantime (11-block MTP), nonce, bits ("%08x"),
#                      target (full 256-bit target hex from bits vs powLimit),
#                      difficulty (float), chainwork (32-byte hex), nTx,
#                      previousblockhash (ONLY if the block has a parent — absent
#                      for genesis), nextblockhash (ONLY if a next block exists —
#                      absent for the tip).
#   ERROR: a blockhash not in the index -> RPC -5 (RPC_INVALID_ADDRESS_OR_KEY)
#          "Block not found".
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports. Core MINES NBLOCKS empty blocks to a
#   deterministic p2wpkh address; nimrod then IMPORTS the exact same blocks via
#   submitblock (raw block hex from Core's `getblock <hash> 0`). The two nodes
#   therefore hold a BYTE-IDENTICAL chain block-for-block, so getblockheader on
#   one MUST be byte-EXACT against the other. (Independent mining would NOT be
#   byte-identical: implementations construct the coinbase scriptSig + witness
#   commitment + nonce-grind differently, so the merkleroot/header diverge —
#   importing the same blocks is what makes the byte comparison meaningful.)
#   bitcoind is launched -listen=0 because the sandbox SIGKILLs any bitcoind
#   binding a 0.0.0.0 P2P listener ~2s after load; RPC-only is fine for an
#   oracle.
#
# WHAT MUST MATCH CORE EXACTLY (deterministic, identical chain shape):
#   verbose=false:
#     * the 160-char header hex at height 60 is byte-EXACT vs Core
#   verbose=true (at height 60):
#     * hash, height, version, versionHex, merkleroot, time, mediantime, nonce,
#       bits, nTx, previousblockhash, nextblockhash, confirmations, chainwork
#       ALL byte-EXACT vs Core
#     * difficulty + target PRESENT + correctly-typed (NOT byte-equal: difficulty
#       is a float that can format differently; target is a newer field)
#   GENESIS (height 0): NO previousblockhash key; nextblockhash present.
#   TIP: nextblockhash ABSENT; confirmations == 1.
#   ERROR: a random 64-hex hash not in the index -> RPC -5.
#
# Why height 60 byte-matches: nimrod imports Core's exact serialized blocks via
# submitblock, so the two chains are bit-identical block-for-block (we assert the
# height-60 hash agrees before byte-comparing the header).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/rustoshi_chaintxstats.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKHEADER nimrod: PASS hex=ok verbose=ok genesis=ok tip=ok errors=ok
#   FAIL: GETBLOCKHEADER nimrod: FAIL <short reason>
#
# Touches ONLY /tmp/gbh-nimrod/ + /tmp/gbh-core/ and ports 22051/22071 (nimrod
#   RPC/P2P) + 22053/22073 (Core RPC/P2P). NEVER touches /data/nvme1/ or
#   testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/nimrod/bin/nimrod"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

NR_DATADIR="/tmp/gbh-nimrod"
NR_RPC=22051
NR_P2P=22071
NR_LOG="$NR_DATADIR/node.log"

# NOTE: datadir name is node-unique (`-nimrod` suffix), NOT the generic
# `/tmp/gbh-core` — sibling getblockheader harnesses for other impls run
# concurrently on this box and a shared datadir name causes mutual rm -rf
# destruction. Keep this isolated.
CORE_DATADIR="/tmp/gbh-core-nimrod"
CORE_RPC=22053
CORE_P2P=22073
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test secret -> one p2wpkh bcrt1 address BOTH nodes mine to, so
# both chains have the identical SHAPE (empty blocks, 1 coinbase tx each).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=120        # mine 120 empty blocks
TEST_HEIGHT=60     # the in-chain block we byte-compare against Core

NR_PID=""
NR_COOKIE=""
CORE_BG=""
ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockheader:nimrod] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$NR_PID" ]] && kill -0 "$NR_PID" 2>/dev/null; then
        kill "$NR_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NR_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NR_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$NR_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <hex> <verbose> <genesis> <tip> <errors>
pass() {
    echo "GETBLOCKHEADER nimrod: PASS hex=$1 verbose=$2 genesis=$3 tip=$4 errors=$5"
    exit 0
}
fail() {
    echo "GETBLOCKHEADER nimrod: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gbh-nimrod" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${NR_RPC}|${NR_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${NR_RPC}|${NR_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${NR_RPC}/${NR_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$NR_DATADIR" "$CORE_DATADIR"
mkdir -p "$NR_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "nimrod binary not found at $NODE_BIN (build with: nimble build -d:release -y)"
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

# core_cli_retry: tolerant of the bitcoin-cli .cookie read race under concurrent
# fleet load (a fresh daemon rewrites regtest/.cookie; a CLI reading it mid-write
# logs "incorrect password" + returns empty). Up to 8 attempts, 1s apart.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# nr_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
nr_rpc() {
    curl -s --max-time 90 -u "$NR_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$NR_RPC/" 2>/dev/null
}

# jpy <json> <expr>   (expr references parsed object as `d`) -> value or empty.
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

# ── 3. Launch the Core regtest oracle (RPC-only, -listen=0). ──────────────
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
    # -listen=0 (no P2P listener) + -rpcbind=127.0.0.1: the sandbox SIGKILLs any
    # bitcoind that binds a 0.0.0.0 P2P listener ~2s after load; an RPC-only,
    # loopback-bound oracle survives. NO -port (no P2P socket to bind).
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        -listen=0 -rpcbind=127.0.0.1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if core_cli getblockcount >/dev/null 2>&1; then
            # Confirm with a retrying read, then a short settle + liveness check
            # so a transient post-ready SIGKILL doesn't masquerade as success.
            if core_cli_retry getblockcount >/dev/null; then
                sleep 4
                kill -0 "$CORE_BG" 2>/dev/null && core_cli getblockcount >/dev/null 2>&1 && return 0
                return 1
            fi
        fi
        kill -0 "$CORE_BG" 2>/dev/null || return 1   # exited during startup
        sleep 1
    done
    return 1
}
CORE_OK=0
# Up to 6 attempts: the sandbox SIGKILLs bitcoind during the first ~2s after
# load with some probability even RPC-only, so a few relaunches may be needed.
for attempt in 1 2 3 4 5 6; do
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 6 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch nimrod on regtest. ──────────────────────────────────────────
log "launching nimrod (regtest) rpc=:$NR_RPC p2p=:$NR_P2P -> $NR_LOG"
"$NODE_BIN" --network=regtest --datadir="$NR_DATADIR" \
    --port="$NR_P2P" --rpcport="$NR_RPC" start >"$NR_LOG" 2>&1 &
NR_PID=$!
nr_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < nr_deadline )); do
    if [[ -z "$NR_COOKIE" ]]; then
        for c in "$NR_DATADIR/regtest/.cookie" "$NR_DATADIR/.cookie"; do
            [[ -f "$c" ]] && NR_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$NR_COOKIE" ]]; then
        echo "$(nr_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$NR_PID" 2>/dev/null || { tail -n 20 "$NR_LOG" >&2 2>/dev/null || true; fail "nimrod exited during startup (see $NR_LOG)"; }
    sleep 1
done
[[ -n "$NR_COOKIE" ]] || fail "nimrod cookie never appeared within 120s"
echo "$(nr_rpc getblockcount '[]')" | grep -q '"result"' || fail "nimrod RPC never responded within 120s"
log "nimrod RPC ready"

# ── 5. Mine NBLOCKS empty blocks on Core; IMPORT them into nimrod. ────────
log "mining $NBLOCKS empty blocks to $ADDR on Core"
core_cli_retry generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $NBLOCKS"

# Pull ALL raw blocks out of Core ONCE, up front, into a file — one block per
# line "height<TAB>rawhex". Doing every Core read before the submit loop keeps
# the oracle's live window short and avoids per-iteration cookie-read races.
RAWFILE="$NR_DATADIR/core-blocks.tsv"
log "exporting $NBLOCKS raw blocks from Core"
: > "$RAWFILE"
for ((h=1; h<=NBLOCKS; h++)); do
    CH=$(core_cli_retry getblockhash "$h")
    [[ -n "$CH" ]] || fail "Core getblockhash $h returned empty"
    RAW=$(core_cli_retry getblock "$CH" 0)
    [[ -n "$RAW" ]] || fail "Core getblock $CH 0 returned empty raw hex"
    printf '%s\t%s\n' "$h" "$RAW" >> "$RAWFILE"
done
[[ "$(wc -l < "$RAWFILE")" == "$NBLOCKS" ]] || fail "exported $(wc -l < "$RAWFILE") raw blocks, expected $NBLOCKS"

log "importing $NBLOCKS Core blocks into nimrod via submitblock (byte-identical chain)"
while IFS=$'\t' read -r h RAW; do
    SB=$(nr_rpc submitblock "[\"$RAW\"]")
    # submitblock returns null on success; a non-null/non-empty string is a
    # rejection reason. (A duplicate is fine on an idempotent re-run.)
    SB_RES=$(jpy "$SB" "d.get('result')")
    SB_ERR=$(jpy "$SB" "d.get('error')")
    if [[ -n "$SB_RES" && "$SB_RES" != "None" && "$SB_RES" != "duplicate" ]]; then
        fail "nimrod submitblock height $h rejected: result='$SB_RES' err='$SB_ERR'"
    fi
    if [[ -n "$SB_ERR" && "$SB_ERR" != "None" ]]; then
        fail "nimrod submitblock height $h errored: '$SB_ERR'"
    fi
done < "$RAWFILE"
NR_HEIGHT=$(jpy "$(nr_rpc getblockcount '[]')" "d['result']")
[[ "$NR_HEIGHT" == "$NBLOCKS" ]] || fail "nimrod height after import is $NR_HEIGHT, expected $NBLOCKS"

# Confirm the two chains are bit-identical at TEST_HEIGHT (import succeeded).
CORE_H60=$(core_cli_retry getblockhash "$TEST_HEIGHT")
NR_H60=$(jpy "$(nr_rpc getblockhash "[$TEST_HEIGHT]")" "d['result']")
[[ -n "$CORE_H60" && -n "$NR_H60" ]] || fail "could not read height-$TEST_HEIGHT hashes (core='$CORE_H60' nimrod='$NR_H60')"
[[ "$CORE_H60" == "$NR_H60" ]] || fail "chains diverge at height $TEST_HEIGHT (core=$CORE_H60 nimrod=$NR_H60); import did not produce a byte-identical chain"
log "chains bit-identical at height $TEST_HEIGHT: $NR_H60"

# ── 6. TEST 1 — verbose=false: 160-char header hex byte-EXACT vs Core. ────
HEX_T="bad"
CORE_HEX=$(core_cli_retry getblockheader "$CORE_H60" false)
NR_HEX_ENV=$(nr_rpc getblockheader "[\"$NR_H60\", false]")
echo "$NR_HEX_ENV" | grep -q '"result"' || fail "nimrod getblockheader verbose=false errored: $NR_HEX_ENV"
NR_HEX=$(jpy "$NR_HEX_ENV" "d['result']")
[[ "$CORE_HEX" =~ ^[0-9a-f]{160}$ ]] || fail "Core header hex not 160 lowercase-hex chars: '$CORE_HEX'"
if [[ "$NR_HEX" == "$CORE_HEX" ]]; then
    HEX_T="ok"
else
    fail "verbose=false header hex mismatch vs Core: nimrod='$NR_HEX' core='$CORE_HEX'"
fi
log "verbose=false header hex byte-EXACT: $NR_HEX"

# ── 7. TEST 2 — verbose=true: exact-field parity at height 60. ────────────
CORE_OBJ=$(core_cli_retry getblockheader "$CORE_H60" true)
[[ -n "$CORE_OBJ" ]] || fail "Core getblockheader verbose=true produced no output"
NR_OBJ_ENV=$(nr_rpc getblockheader "[\"$NR_H60\", true]")
echo "$NR_OBJ_ENV" | grep -q '"result"' || fail "nimrod getblockheader verbose=true errored: $NR_OBJ_ENV"
NR_OBJ=$(jpy "$NR_OBJ_ENV" "json.dumps(d['result'])")
[[ -n "$NR_OBJ" ]] || fail "nimrod getblockheader verbose=true result empty"
log "Core   obj: $CORE_OBJ"
log "nimrod obj: $NR_OBJ"

c() { jpy "$CORE_OBJ" "d.get('$1')"; }
r() { jpy "$NR_OBJ"   "d.get('$1')"; }

VERBOSE_T="ok"
# Fields that MUST be byte-EXACT vs Core (deterministic for identical chain shape).
for f in hash confirmations height version versionHex merkleroot time mediantime nonce bits nTx previousblockhash nextblockhash chainwork; do
    CV=$(c "$f"); RV=$(r "$f")
    if [[ "$CV" != "$RV" ]]; then
        VERBOSE_T="bad"; log "field '$f' mismatch: nimrod='$RV' core='$CV'"
    fi
done
# Sanity-anchor a couple of values against the known chain shape.
[[ "$(c height)" == "$TEST_HEIGHT" ]] || { VERBOSE_T="bad"; log "Core height field != $TEST_HEIGHT (oracle unexpected): '$(c height)'"; }
EXP_CONF=$(( NBLOCKS - TEST_HEIGHT + 1 ))
[[ "$(c confirmations)" == "$EXP_CONF" ]] || { VERBOSE_T="bad"; log "Core confirmations != $EXP_CONF (oracle unexpected): '$(c confirmations)'"; }

# difficulty: PRESENT + numeric (NOT byte-equal — float formatting can differ).
R_DIFF=$(r difficulty)
if ! [[ "$R_DIFF" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
    VERBOSE_T="bad"; log "difficulty absent/non-numeric: '$R_DIFF'"
fi
# target: PRESENT + 64-hex (NOT byte-equal — newer field; treat as present-typed).
R_TGT=$(r target)
if ! [[ "$R_TGT" =~ ^[0-9a-f]{64}$ ]]; then
    VERBOSE_T="bad"; log "target absent/not-64-hex: '$R_TGT'"
fi
[[ "$VERBOSE_T" == "ok" ]] || fail "verbose=true field-parity check failed (see log)"
log "verbose=true field parity OK (incl difficulty present-typed, target present-typed)"

# ── 8. TEST 3 — GENESIS: no previousblockhash; nextblockhash present. ─────
GENESIS_T="ok"
CORE_GEN=$(core_cli_retry getblockhash 0)
NR_GEN=$(jpy "$(nr_rpc getblockhash '[0]')" "d['result']")
[[ -n "$NR_GEN" ]] || fail "nimrod getblockhash 0 returned empty"
NR_GENOBJ_ENV=$(nr_rpc getblockheader "[\"$NR_GEN\", true]")
echo "$NR_GENOBJ_ENV" | grep -q '"result"' || fail "nimrod getblockheader(genesis) errored: $NR_GENOBJ_ENV"
NR_GENOBJ=$(jpy "$NR_GENOBJ_ENV" "json.dumps(d['result'])")
HAS_PREV=$(jpy "$NR_GENOBJ" "'previousblockhash' in d")
[[ "$HAS_PREV" == "false" ]] || { GENESIS_T="bad"; log "genesis has previousblockhash (must be absent): $NR_GENOBJ"; }
HAS_NEXT=$(jpy "$NR_GENOBJ" "'nextblockhash' in d")
[[ "$HAS_NEXT" == "true" ]] || { GENESIS_T="bad"; log "genesis missing nextblockhash (must be present): $NR_GENOBJ"; }
GEN_HEIGHT=$(jpy "$NR_GENOBJ" "d.get('height')")
[[ "$GEN_HEIGHT" == "0" ]] || { GENESIS_T="bad"; log "genesis height != 0: '$GEN_HEIGHT'"; }
# Cross-check vs Core's own genesis behaviour (must agree on key presence).
CORE_GENOBJ=$(core_cli_retry getblockheader "$CORE_GEN" true)
C_HAS_PREV=$(jpy "$CORE_GENOBJ" "'previousblockhash' in d")
C_HAS_NEXT=$(jpy "$CORE_GENOBJ" "'nextblockhash' in d")
[[ "$C_HAS_PREV" == "false" && "$C_HAS_NEXT" == "true" ]] || fail "Core genesis key-presence unexpected (prev=$C_HAS_PREV next=$C_HAS_NEXT)"
[[ "$GENESIS_T" == "ok" ]] || fail "genesis key-presence check failed (see log)"
log "genesis: no previousblockhash, nextblockhash present (matches Core)"

# ── 9. TEST 4 — TIP: nextblockhash absent; confirmations == 1. ────────────
TIP_T="ok"
NR_TIP=$(jpy "$(nr_rpc getbestblockhash '[]')" "d['result']")
[[ -n "$NR_TIP" ]] || fail "nimrod getbestblockhash returned empty"
NR_TIPOBJ_ENV=$(nr_rpc getblockheader "[\"$NR_TIP\", true]")
echo "$NR_TIPOBJ_ENV" | grep -q '"result"' || fail "nimrod getblockheader(tip) errored: $NR_TIPOBJ_ENV"
NR_TIPOBJ=$(jpy "$NR_TIPOBJ_ENV" "json.dumps(d['result'])")
TIP_HAS_NEXT=$(jpy "$NR_TIPOBJ" "'nextblockhash' in d")
[[ "$TIP_HAS_NEXT" == "false" ]] || { TIP_T="bad"; log "tip has nextblockhash (must be absent): $NR_TIPOBJ"; }
TIP_CONF=$(jpy "$NR_TIPOBJ" "d.get('confirmations')")
[[ "$TIP_CONF" == "1" ]] || { TIP_T="bad"; log "tip confirmations != 1: '$TIP_CONF'"; }
TIP_HAS_PREV=$(jpy "$NR_TIPOBJ" "'previousblockhash' in d")
[[ "$TIP_HAS_PREV" == "true" ]] || { TIP_T="bad"; log "tip missing previousblockhash (must be present): $NR_TIPOBJ"; }
[[ "$TIP_T" == "ok" ]] || fail "tip check failed (see log)"
log "tip: nextblockhash absent, confirmations==1, previousblockhash present"

# ── 10. TEST 5 — ERROR: random 64-hex not in index -> RPC -5. ─────────────
ERRORS_T="ok"
ERR_BAD_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
E5=$(jpy "$(nr_rpc getblockheader "[\"$ERR_BAD_HASH\", true]")" "d['error']['code']")
[[ "$E5" == "-5" ]] || { ERRORS_T="bad"; log "expected error -5 (Block not found) for unknown blockhash, got '$E5'"; }
# Cross-check Core returns the same code for the same unknown hash.
CORE_E5=$(core_cli getblockheader "$ERR_BAD_HASH" true 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ "$CORE_E5" == "-5" ]] || fail "Core did not return -5 for unknown blockhash (got '$CORE_E5') — oracle unexpected"
[[ "$ERRORS_T" == "ok" ]] || fail "error-code check failed (see log)"
log "error: unknown blockhash -> RPC -5 (matches Core)"

log "PASS: nimrod getblockheader matches Core on hex + verbose fields + genesis/tip key-presence + error code"
pass "$HEX_T" "$VERBOSE_T" "$GENESIS_T" "$TIP_T" "$ERRORS_T"

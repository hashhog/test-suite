#!/usr/bin/env bash
#
# haskoin_getblockheader.sh — self-contained getblockheader Core-parity test.
#
# An RPC-surface green-cell. getblockheader is READ-ONLY header introspection —
# NOT consensus — but its output shape must match Bitcoin Core EXACTLY for a
# given chain.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:599-666 (getblockheader) +
#           :154-182 (blockheaderToJSON).
#   SIGNATURE: getblockheader "blockhash" ( verbose ). verbose default TRUE.
#   OUTPUT:
#     verbose=false -> the 80-byte serialized header as HEX (160 hex chars):
#                      version(LE) || prev hash || merkle root || time || bits ||
#                      nonce.
#     verbose=true  -> an OBJECT (blockheaderToJSON) with:
#       hash, confirmations (= tipH - height + 1 on the active chain, else -1),
#       height, version, versionHex ("%08x"), merkleroot, time, mediantime
#       (11-block MTP), nonce, bits ("%08x"), target (256-bit target hex),
#       difficulty (float), chainwork (32-byte hex), nTx, previousblockhash
#       (ONLY if the block has a parent — ABSENT for genesis), nextblockhash
#       (ONLY if a next block exists — ABSENT for the tip).
#   ERROR: a blockhash not in the index -> RPC -5 (RPC_INVALID_ADDRESS_OR_KEY)
#          "Block not found".
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports. Core mines NBLOCKS empty blocks to a
#   deterministic p2wpkh address; we then FEED Core's exact block bytes to
#   haskoin via submitblock so BOTH nodes hold the BYTE-IDENTICAL chain. That
#   makes every getblockheader field (hash / merkleroot / time / nonce /
#   prev+next / chainwork / confirmations) directly EXACT-comparable — not just
#   "same shape". (Independently-mined chains would diverge on timestamp +
#   coinbase, so submitblock-from-Core is the deterministic oracle.)
#
# WHAT THE TEST ASSERTS:
#   1. verbose=false @ height 60: the 160-char header hex is BYTE-EXACT vs Core.
#   2. verbose=true  @ height 60: hash, height, version, versionHex, merkleroot,
#      time, mediantime, nonce, bits, nTx, previousblockhash, nextblockhash,
#      confirmations, chainwork ALL EXACT vs Core; difficulty + target PRESENT +
#      correctly-typed (difficulty is a float that can format differently;
#      target is a newer field) — NOT byte-equal.
#   3. GENESIS: NO previousblockhash key; nextblockhash present.
#   4. TIP: nextblockhash ABSENT; confirmations == 1.
#   5. ERROR: a random 64-hex non-index hash -> RPC -5.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/rustoshi_chaintxstats.sh):
#   set -uo pipefail, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKHEADER haskoin: PASS hex=ok verbose=ok genesis=ok tip=ok errors=ok
#   FAIL: GETBLOCKHEADER haskoin: FAIL <short reason>
#
# Touches ONLY /tmp/gbh-haskoin/ + /tmp/gbh-core/ and ports 22059/22079
#   (haskoin RPC/P2P) + 22061/22081 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
HK_DIR="$BASEDIR/haskoin"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

# Locate the built haskoin binary (cabal build exe:haskoin).
HK_BIN="$(find "$HK_DIR/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"

# rocksdb_compat shim + secp/format shared libs.
export LD_LIBRARY_PATH="${HOME}/.local/lib64:/usr/local/lib:${LD_LIBRARY_PATH:-}"

HK_DATADIR="/tmp/gbh-haskoin"
HK_RPC=22059
HK_P2P=22079
HK_LOG="$HK_DATADIR/node.log"
HK_COOKIE=""
HK_PID=""

CORE_DATADIR="/tmp/gbh-core"
CORE_RPC=22061
CORE_P2P=22081
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

# haskoin uses haskoin_datadir as an env hint in some build configs.
export haskoin_datadir="$HK_DATADIR"

# Deterministic test secret -> one p2wpkh bcrt1 address Core mines to.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=120        # mine 120 empty blocks; query the header at height 60.
QHEIGHT=60         # the height whose header we assert exactly.
ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockheader:haskoin] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$HK_PID" ]] && kill -0 "$HK_PID" 2>/dev/null; then
        kill "$HK_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HK_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HK_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$HK_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <hex> <verbose> <genesis> <tip> <errors>
pass() {
    echo "GETBLOCKHEADER haskoin: PASS hex=$1 verbose=$2 genesis=$3 tip=$4 errors=$5"
    exit 0
}
fail() {
    echo "GETBLOCKHEADER haskoin: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gbh-haskoin" >/dev/null 2>&1 || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${HK_RPC}|${HK_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${HK_RPC}|${HK_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${HK_RPC}/${HK_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$HK_DATADIR" "$CORE_DATADIR"
mkdir -p "$HK_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -n "$HK_BIN" && -x "$HK_BIN" ]]   || fail "haskoin binary not found under $HK_DIR/dist-newstyle (build with: cabal build exe:haskoin)"
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

# ── RPC helpers ───────────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# core_cli_retry: tolerant of the bitcoin-cli .cookie read race under load.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# hk_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
hk_rpc() {
    curl -s --max-time 90 -u "$HK_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$HK_RPC/" 2>/dev/null
}

# jpy <json> <expr>  (expr references parsed object as `d`); errors swallowed.
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

# ── 3. Launch the Core regtest oracle (RPC-only; -listen=0). ──────────────
# The sandbox SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener ~2s after
# load, so we MUST pass -listen=0 (RPC-only is fine). Retry up to 3 times.
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
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch haskoin on regtest (RPC-only; --listen=False). ──────────────
log "launching haskoin (regtest) rpc=:$HK_RPC p2p=:$HK_P2P -> $HK_LOG"
"$HK_BIN" --network Regtest --datadir "$HK_DATADIR" \
    node --rpcport="$HK_RPC" --port="$HK_P2P" --listen=False --metricsport 0 \
    >"$HK_LOG" 2>&1 &
HK_PID=$!
# haskoin needs a generous startup wait (rocksdb open + index init).
hk_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < hk_deadline )); do
    if [[ -z "$HK_COOKIE" ]]; then
        for c in "$HK_DATADIR/regtest/.cookie" "$HK_DATADIR/.cookie"; do
            [[ -f "$c" ]] && HK_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HK_COOKIE" ]]; then
        hk_rpc getblockcount '[]' | grep -q '"result"' && break
    fi
    kill -0 "$HK_PID" 2>/dev/null || { tail -n 20 "$HK_LOG" >&2 2>/dev/null || true; fail "haskoin exited during startup (see $HK_LOG)"; }
    sleep 2
done
[[ -n "$HK_COOKIE" ]] || fail "haskoin cookie never appeared within 120s"
hk_rpc getblockcount '[]' | grep -q '"result"' || fail "haskoin RPC never responded within 120s"
log "haskoin RPC ready"

# ── 5. Mine NBLOCKS on Core, then FEED the exact block bytes to haskoin. ──
log "mining $NBLOCKS empty blocks to $ADDR on Core"
core_cli_retry generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $NBLOCKS"

log "submitting $NBLOCKS Core blocks to haskoin via submitblock"
for h in $(seq 1 "$NBLOCKS"); do
    bh=$(core_cli_retry getblockhash "$h")  || fail "Core getblockhash $h failed"
    raw=$(core_cli_retry getblock "$bh" 0)  || fail "Core getblock $bh 0 failed"
    sb=$(hk_rpc submitblock "[\"$raw\"]")
    # submitblock returns null result + null error on accept; any non-null
    # JSON-RPC error, or a non-null string result (Core's reject reason),
    # means the block was rejected. jpy prints the literal Python repr, so a
    # JSON null surfaces as the string "None" — treat that as accepted.
    err=$(jpy "$sb" "d.get('error')")
    res=$(jpy "$sb" "d.get('result')")
    if [[ -n "$err" && "$err" != "None" ]]; then
        fail "haskoin submitblock rejected block $h (error): $sb"
    fi
    if [[ -n "$res" && "$res" != "None" ]]; then
        fail "haskoin submitblock rejected block $h (result '$res'): $sb"
    fi
done
HK_HEIGHT=$(jpy "$(hk_rpc getblockcount '[]')" "d['result']")
[[ "$HK_HEIGHT" == "$NBLOCKS" ]] || fail "haskoin height after submitblock is $HK_HEIGHT, expected $NBLOCKS (chain shape mismatch)"
log "both nodes at height $NBLOCKS with byte-identical chains"

# Resolve the canonical hashes from Core (the oracle); both chains agree.
QHASH=$(core_cli_retry getblockhash "$QHEIGHT")  || fail "Core getblockhash $QHEIGHT failed"
GENESIS=$(core_cli_retry getblockhash 0)         || fail "Core getblockhash 0 failed"
TIP=$(core_cli_retry getbestblockhash)           || fail "Core getbestblockhash failed"
[[ -n "$QHASH" && -n "$GENESIS" && -n "$TIP" ]]  || fail "could not resolve query/genesis/tip hashes"

# ── 6. verbose=false: 160-char header hex BYTE-EXACT vs Core. ─────────────
HEX_T="ok"
CORE_HEX=$(core_cli_retry getblockheader "$QHASH" false)
[[ -n "$CORE_HEX" ]] || fail "Core getblockheader (verbose=false) produced no output"
HK_HEX=$(jpy "$(hk_rpc getblockheader "[\"$QHASH\", false]")" "d['result']")
[[ "$CORE_HEX" =~ ^[0-9a-f]{160}$ ]] || fail "Core header hex is not 160-hex: '$CORE_HEX' (oracle unexpected)"
if [[ "$HK_HEX" != "$CORE_HEX" ]]; then
    HEX_T="bad"
    log "verbose=false header hex MISMATCH:"
    log "  core=$CORE_HEX"
    log "  hask=$HK_HEX"
    fail "verbose=false header hex not byte-exact vs Core (height $QHEIGHT)"
fi
log "verbose=false header hex byte-exact vs Core ($CORE_HEX)"

# ── 7. verbose=true: assert the EXACT-comparable fields vs Core. ──────────
VERBOSE_T="ok"
CORE_V=$(core_cli_retry getblockheader "$QHASH" true)
[[ -n "$CORE_V" ]] || fail "Core getblockheader (verbose=true) produced no output"
HK_V_ENV=$(hk_rpc getblockheader "[\"$QHASH\", true]")
echo "$HK_V_ENV" | grep -q '"result"' || fail "haskoin getblockheader (verbose=true) errored: $HK_V_ENV"
HK_V=$(jpy "$HK_V_ENV" "json.dumps(d['result'])")
[[ -n "$HK_V" ]] || fail "haskoin getblockheader verbose result empty"
log "Core   verbose: $CORE_V"
log "haskoin verbose: $HK_V"

cf() { jpy "$CORE_V" "d.get('$1')"; }
hf() { jpy "$HK_V"   "d.get('$1')"; }

# These fields MUST be byte-EXACT vs Core (identical chain via submitblock).
EXACT_FIELDS="hash height version versionHex merkleroot time mediantime nonce bits nTx previousblockhash nextblockhash confirmations chainwork"
for fld in $EXACT_FIELDS; do
    cv=$(cf "$fld"); hv=$(hf "$fld")
    if [[ "$cv" != "$hv" ]]; then
        VERBOSE_T="bad"
        log "verbose field '$fld' MISMATCH: core='$cv' haskoin='$hv'"
    fi
done

# difficulty: PRESENT + numeric (float; format may differ — NOT byte-equal).
HK_DIFF=$(hf difficulty)
if ! [[ "$HK_DIFF" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
    VERBOSE_T="bad"; log "difficulty absent/non-numeric: '$HK_DIFF'"
fi

# target: PRESENT + 64-hex (newer field; present-not-byte-equal per spec).
HK_TARGET=$(hf target)
if ! [[ "$HK_TARGET" =~ ^[0-9a-f]{64}$ ]]; then
    VERBOSE_T="bad"; log "target absent/not-64-hex: '$HK_TARGET'"
fi

# Sanity: the asserted hash must equal the queried hash (self-consistency).
[[ "$(hf hash)" == "$QHASH" ]] || { VERBOSE_T="bad"; log "haskoin hash field != queried hash"; }
[[ "$(hf height)" == "$QHEIGHT" ]] || { VERBOSE_T="bad"; log "haskoin height field != $QHEIGHT"; }

[[ "$VERBOSE_T" == "ok" ]] || fail "verbose=true field check failed (see log)"
log "verbose=true: all EXACT fields match Core; difficulty + target present + typed"

# ── 8. GENESIS: NO previousblockhash; nextblockhash present. ──────────────
GENESIS_T="ok"
HK_GEN_ENV=$(hk_rpc getblockheader "[\"$GENESIS\", true]")
echo "$HK_GEN_ENV" | grep -q '"result"' || fail "haskoin getblockheader(genesis) errored: $HK_GEN_ENV"
HK_GEN=$(jpy "$HK_GEN_ENV" "json.dumps(d['result'])")
HAS_PREV=$(jpy "$HK_GEN" "'previousblockhash' in d")
HAS_NEXT=$(jpy "$HK_GEN" "'nextblockhash' in d")
GEN_HEIGHT=$(jpy "$HK_GEN" "d.get('height')")
[[ "$HAS_PREV" == "false" ]] || { GENESIS_T="bad"; log "genesis WRONGLY has previousblockhash: $HK_GEN"; }
[[ "$HAS_NEXT" == "true"  ]] || { GENESIS_T="bad"; log "genesis MISSING nextblockhash: $HK_GEN"; }
[[ "$GEN_HEIGHT" == "0"   ]] || { GENESIS_T="bad"; log "genesis height != 0: '$GEN_HEIGHT'"; }
# Confirm the same against Core (oracle invariant).
CORE_GEN_HASPREV=$(jpy "$(core_cli_retry getblockheader "$GENESIS" true)" "'previousblockhash' in d")
[[ "$CORE_GEN_HASPREV" == "false" ]] || fail "Core genesis unexpectedly has previousblockhash (oracle)"
[[ "$GENESIS_T" == "ok" ]] || fail "genesis previousblockhash/nextblockhash check failed (see log)"
log "genesis: no previousblockhash, nextblockhash present (matches Core)"

# ── 9. TIP: nextblockhash ABSENT; confirmations == 1. ─────────────────────
TIP_T="ok"
HK_TIP_ENV=$(hk_rpc getblockheader "[\"$TIP\", true]")
echo "$HK_TIP_ENV" | grep -q '"result"' || fail "haskoin getblockheader(tip) errored: $HK_TIP_ENV"
HK_TIP=$(jpy "$HK_TIP_ENV" "json.dumps(d['result'])")
TIP_HASNEXT=$(jpy "$HK_TIP" "'nextblockhash' in d")
TIP_CONF=$(jpy "$HK_TIP" "d.get('confirmations')")
[[ "$TIP_HASNEXT" == "false" ]] || { TIP_T="bad"; log "tip WRONGLY has nextblockhash: $HK_TIP"; }
[[ "$TIP_CONF" == "1" ]]        || { TIP_T="bad"; log "tip confirmations != 1: '$TIP_CONF'"; }
[[ "$TIP_T" == "ok" ]] || fail "tip nextblockhash/confirmations check failed (see log)"
log "tip: no nextblockhash, confirmations==1 (matches Core)"

# ── 10. ERROR: a random 64-hex non-index hash -> RPC -5. ──────────────────
ERRORS_T="ok"
RAND_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
E5=$(jpy "$(hk_rpc getblockheader "[\"$RAND_HASH\"]")" "d['error']['code']")
[[ "$E5" == "-5" ]] || { ERRORS_T="bad"; log "expected error -5 for unknown blockhash, got '$E5'"; }
# Confirm Core agrees (oracle): -5 RPC_INVALID_ADDRESS_OR_KEY.
CORE_E=$(core_cli getblockheader "$RAND_HASH" 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ "$CORE_E" == "-5" ]] || log "note: Core error code for unknown hash was '$CORE_E' (expected -5)"
[[ "$ERRORS_T" == "ok" ]] || fail "error-code check failed (see log)"
log "error: unknown blockhash -> RPC -5 (matches Core)"

# ── 11. All green. ────────────────────────────────────────────────────────
log "PASS: haskoin getblockheader matches Core (hex + verbose fields + genesis/tip/error)"
pass "$HEX_T" "$VERBOSE_T" "$GENESIS_T" "$TIP_T" "$ERRORS_T"

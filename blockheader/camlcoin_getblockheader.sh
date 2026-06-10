#!/usr/bin/env bash
#
# camlcoin_getblockheader.sh — self-contained getblockheader Core-parity test.
#
# An RPC-surface green-cell. getblockheader is a READ-ONLY blockheader query —
# NOT consensus — but its output SHAPE + values must match Bitcoin Core EXACTLY
# for a given chain.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:599-666 (getblockheader) +
#           :154-182 (blockheaderToJSON).
#   SIGNATURE: getblockheader "blockhash" ( verbose ).  verbose default TRUE.
#   OUTPUT:
#     - verbose=false -> the 80-byte serialized block HEADER as HEX (160 chars):
#         version(LE) + prev hash + merkle root + time + bits + nonce.
#     - verbose=true  -> an OBJECT (blockheaderToJSON) with keys, in order:
#         hash, confirmations (= tipHeight-height+1 for an in-chain block, -1 if
#         not in active chain), height, version, versionHex (8-hex "%08x"),
#         merkleroot, time, mediantime (11-block MTP), nonce, bits (8-hex),
#         target (256-bit target from bits clamped to powLimit), difficulty
#         (float), chainwork (32-byte hex), nTx, previousblockhash (ONLY if the
#         block has a parent — ABSENT for genesis), nextblockhash (ONLY if a next
#         block exists — ABSENT for the tip).
#   ERROR: a blockhash not in the index -> RPC code -5 (RPC_INVALID_ADDRESS_OR_KEY)
#          "Block not found".
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports. To make EVERY header byte-identical (so
#   time / nonce / merkleroot match EXACTLY, not just shape), we MINE on Core
#   and REPLAY each block into camlcoin via submitblock — both nodes end up with
#   the SAME chain bit-for-bit. (Independent mining would diverge on nTime /
#   nonce / coinbase, so we don't do that here.)
#
# Core is launched -listen=0 (RPC-only): the sandbox SIGKILLs any bitcoind that
# binds a 0.0.0.0 P2P listener ~2s after load. camlcoin binds its P2P listener
# on loopback and is unaffected.
#
# WHAT MUST MATCH CORE EXACTLY (height-60 block, identical chain):
#   * verbose=false: the 160-char header hex is BYTE-EXACT vs Core.
#   * verbose=true : hash, height, version, versionHex, merkleroot, time,
#                    mediantime, nonce, bits, nTx, previousblockhash,
#                    nextblockhash, confirmations, chainwork — ALL EXACT.
# WHAT MUST BE PRESENT + CORRECTLY-TYPED (not byte-equal):
#   * difficulty present + a float (Core formats floats differently).
#   * target     present + 64-hex string (newer field; present-not-byte-equal).
# GENESIS RULE: NO previousblockhash key; nextblockhash present.
# TIP RULE    : nextblockhash ABSENT; confirmations == 1.
# ERROR RULE  : unknown blockhash -> RPC error code -5.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/rustoshi_chaintxstats.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKHEADER camlcoin: PASS hex=ok verbose=ok genesis=ok tip=ok errors=ok
#   FAIL: GETBLOCKHEADER camlcoin: FAIL <short reason>
#
# Touches ONLY /tmp/gbh-camlcoin/ + /tmp/gbh-core-camlcoin/ and ports
#   22055/22075 (camlcoin RPC/P2P) + 22057/22077 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/camlcoin/_build/default/bin/main.exe"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

CC_DATADIR="/tmp/gbh-camlcoin"
CC_RPC=22055
CC_P2P=22075
CC_LOG="$CC_DATADIR/node.log"

CORE_DATADIR="/tmp/gbh-core-camlcoin"
CORE_RPC=22057
CORE_P2P=22077
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test secret -> one p2wpkh bcrt1 address Core mines to. (The chain
# is mined on Core and replayed into camlcoin, so the address only affects Core's
# coinbase — camlcoin gets the identical bytes back via submitblock.)
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=120        # mine 120 empty blocks; we inspect the header at height 60
HEIGHT_AT=60       # the in-chain block we assert byte-for-byte vs Core

CC_PID=""
CC_COOKIE=""
CORE_BG=""
ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockheader:camlcoin] $*" >&2; }

# ── Wait (up to ~30s) for a TCP port to become free before binding. ────────
wait_port_free() {  # wait_port_free <port>
    # WAIT-ONLY (port-kill removed: 2026-06-10 fuser incident): NEVER kills by port.
    local port="$1"
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -qE ":${port} " || return 0
        sleep 1
    done
    return 1
}

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$CC_PID" ]] && kill -0 "$CC_PID" 2>/dev/null; then
        kill "$CC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CC_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$CC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <hex> <verbose> <genesis> <tip> <errors>
pass() {
    echo "GETBLOCKHEADER camlcoin: PASS hex=$1 verbose=$2 genesis=$3 tip=$4 errors=$5"
    exit 0
}
fail() {
    echo "GETBLOCKHEADER camlcoin: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gbh-camlcoin" >/dev/null 2>&1 || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${CC_RPC}|${CC_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${CC_RPC}|${CC_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${CC_RPC}/${CC_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$CC_DATADIR" "$CORE_DATADIR"
mkdir -p "$CC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "camlcoin binary not found at $NODE_BIN (build with: dune build)"
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

# cc_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
# Retries up to 3x on a transient EMPTY response (dropped connection / RPC server
# momentarily not accepting): an empty body carries neither "result" nor "error",
# so a genuine JSON-RPC error response is returned immediately and never retried.
cc_rpc() {
    local attempt resp
    for attempt in 1 2 3; do
        resp=$(curl -s --max-time 90 -u "$CC_COOKIE" \
            --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
            "http://127.0.0.1:$CC_RPC/" 2>/dev/null)
        if echo "$resp" | grep -q '"result"\|"error"'; then
            echo "$resp"; return 0
        fi
        sleep 1
    done
    echo "$resp"  # last (possibly empty) attempt; caller surfaces the failure
}

# jpy <json> <expr>   (expr references parsed object as `d`)
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

# ── 3. Launch the Core regtest oracle (-listen=0: RPC-only). ──────────────
wait_port_free "$CORE_RPC" || fail "Core RPC port $CORE_RPC still busy after 30s (another node holds it)"
wait_port_free "$CORE_P2P" || fail "Core P2P port $CORE_P2P still busy after 30s (another node holds it)"
log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P (-listen=0)"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < core_deadline )); do
    if core_cli getblockcount >/dev/null 2>&1; then break; fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
core_cli getblockcount >/dev/null 2>&1 || fail "Core oracle RPC never responded within 120s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch camlcoin on regtest (metrics disabled to avoid 9332 collision). ─
wait_port_free "$CC_RPC" || fail "camlcoin RPC port $CC_RPC still busy after 30s (another node holds it)"
wait_port_free "$CC_P2P" || fail "camlcoin P2P port $CC_P2P still busy after 30s (another node holds it)"
log "launching camlcoin (regtest) rpc=:$CC_RPC p2p=:$CC_P2P -> $CC_LOG"
"$NODE_BIN" --network regtest --datadir "$CC_DATADIR" \
    --port "$CC_P2P" --rpcport "$CC_RPC" --metricsport 0 >"$CC_LOG" 2>&1 &
CC_PID=$!
cc_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < cc_deadline )); do
    if [[ -z "$CC_COOKIE" && -f "$CC_DATADIR/.cookie" ]]; then
        CC_COOKIE=$(cat "$CC_DATADIR/.cookie")
    fi
    if [[ -n "$CC_COOKIE" ]]; then
        echo "$(cc_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$CC_PID" 2>/dev/null || { tail -n 20 "$CC_LOG" >&2 2>/dev/null || true; fail "camlcoin exited during startup (see $CC_LOG)"; }
    sleep 1
done
[[ -n "$CC_COOKIE" ]] || fail "camlcoin cookie never appeared within 120s"
echo "$(cc_rpc getblockcount '[]')" | grep -q '"result"' || fail "camlcoin RPC never responded within 120s"
log "camlcoin RPC ready"

# ── 5. Mine NBLOCKS empty blocks on Core, then REPLAY each into camlcoin. ──
log "mining $NBLOCKS empty blocks to $ADDR on Core"
core_cli generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null 2>&1 \
    || fail "Core generatetoaddress failed"
CORE_HEIGHT=$(core_cli getblockcount 2>/dev/null)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $NBLOCKS"

log "replaying $NBLOCKS blocks into camlcoin via submitblock (identical chain)"
for h in $(seq 1 "$NBLOCKS"); do
    bh=$(core_cli getblockhash "$h" 2>/dev/null)
    [[ -n "$bh" ]] || fail "Core getblockhash $h returned empty"
    raw=$(core_cli getblock "$bh" 0 2>/dev/null)
    [[ -n "$raw" ]] || fail "Core getblock $bh 0 returned empty"
    sb=$(cc_rpc submitblock "[\"$raw\"]")
    # submitblock returns result:null on accept; a non-null result is a reject reason.
    SBR=$(jpy "$sb" "d.get('result')")
    if [[ -n "$SBR" && "$SBR" != "None" ]]; then
        fail "camlcoin submitblock rejected block at height $h: $SBR"
    fi
done
CC_HEIGHT=$(jpy "$(cc_rpc getblockcount '[]')" "d['result']")
[[ "$CC_HEIGHT" == "$NBLOCKS" ]] || fail "camlcoin height after replay is $CC_HEIGHT, expected $NBLOCKS (submitblock did not advance chain)"

# Sanity: tips must be byte-identical (the whole point of replay).
CORE_TIP=$(core_cli getbestblockhash 2>/dev/null)
CC_TIP=$(jpy "$(cc_rpc getbestblockhash '[]')" "d['result']")
[[ -n "$CORE_TIP" && "$CORE_TIP" == "$CC_TIP" ]] \
    || fail "tip mismatch after replay: core=$CORE_TIP camlcoin=$CC_TIP (chains diverged)"
log "chains identical at tip $CC_TIP (height $NBLOCKS)"

# Resolve the block hash + genesis hash from Core (camlcoin shares them).
H_HASH=$(core_cli getblockhash "$HEIGHT_AT" 2>/dev/null)
[[ -n "$H_HASH" ]] || fail "Core getblockhash $HEIGHT_AT returned empty"
GEN_HASH=$(core_cli getblockhash 0 2>/dev/null)
[[ -n "$GEN_HASH" ]] || fail "Core getblockhash 0 (genesis) returned empty"

# ── 6. verbose=false: 160-char header hex BYTE-EXACT vs Core. ─────────────
HEX_T="ok"
CORE_HEX=$(core_cli getblockheader "$H_HASH" false 2>/dev/null)
CC_HEX=$(jpy "$(cc_rpc getblockheader "[\"$H_HASH\", false]")" "d['result']")
if ! [[ "$CC_HEX" =~ ^[0-9a-f]{160}$ ]]; then
    HEX_T="bad"; log "camlcoin getblockheader false is not 160-hex: '$CC_HEX'"
elif [[ "$CC_HEX" != "$CORE_HEX" ]]; then
    HEX_T="bad"; log "header hex mismatch vs Core:"; log "  core: $CORE_HEX"; log "  caml: $CC_HEX"
fi
[[ "$HEX_T" == "ok" ]] || fail "verbose=false header hex not byte-exact vs Core (see log)"

# ── 7. verbose=true: full object; exact fields + present/typed difficulty,target. ─
VERBOSE_T="ok"
CORE_V=$(core_cli getblockheader "$H_HASH" true 2>/dev/null)
CC_V_ENV=$(cc_rpc getblockheader "[\"$H_HASH\", true]")
echo "$CC_V_ENV" | grep -q '"result"' || fail "camlcoin getblockheader true errored: $CC_V_ENV"
CC_V=$(jpy "$CC_V_ENV" "json.dumps(d['result'])")
[[ -n "$CC_V" ]] || fail "camlcoin getblockheader true result empty"
log "Core     header(h=$HEIGHT_AT): $CORE_V"
log "camlcoin header(h=$HEIGHT_AT): $CC_V"

cv() { jpy "$CORE_V" "d.get('$1')"; }
rv() { jpy "$CC_V"   "d.get('$1')"; }

# Fields that MUST match Core EXACTLY (identical chain -> byte-identical headers).
for k in hash height version versionHex merkleroot time mediantime nonce bits \
         nTx previousblockhash nextblockhash confirmations chainwork; do
    CVAL=$(cv "$k"); RVAL=$(rv "$k")
    if [[ "$CVAL" != "$RVAL" ]]; then
        VERBOSE_T="bad"; log "verbose field '$k' mismatch: core='$CVAL' camlcoin='$RVAL'"
    fi
done

# Sanity: confirmations for an in-chain block at HEIGHT_AT == NBLOCKS-HEIGHT_AT+1.
EXP_CONF=$(( NBLOCKS - HEIGHT_AT + 1 ))
R_CONF=$(rv confirmations)
[[ "$R_CONF" == "$EXP_CONF" ]] || { VERBOSE_T="bad"; log "confirmations=$R_CONF != expected $EXP_CONF"; }

# previousblockhash present for a non-genesis block.
R_PREV=$(rv previousblockhash)
[[ "$R_PREV" =~ ^[0-9a-f]{64}$ ]] || { VERBOSE_T="bad"; log "previousblockhash absent/malformed at height $HEIGHT_AT: '$R_PREV'"; }
# nextblockhash present for a non-tip block.
R_NEXT=$(rv nextblockhash)
[[ "$R_NEXT" =~ ^[0-9a-f]{64}$ ]] || { VERBOSE_T="bad"; log "nextblockhash absent/malformed at height $HEIGHT_AT: '$R_NEXT'"; }

# difficulty PRESENT + a float (NOT byte-equal — formatting can differ).
R_DIFF=$(rv difficulty)
if ! [[ "$R_DIFF" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
    VERBOSE_T="bad"; log "difficulty absent/non-numeric: '$R_DIFF'"
fi
# target PRESENT + 64-hex string (newer field; present-not-byte-equal).
R_TGT=$(rv target)
[[ "$R_TGT" =~ ^[0-9a-f]{64}$ ]] || { VERBOSE_T="bad"; log "target absent/not-64-hex: '$R_TGT'"; }

[[ "$VERBOSE_T" == "ok" ]] || fail "verbose=true field parity check failed (see log)"

# ── 8. GENESIS: NO previousblockhash; nextblockhash PRESENT. ──────────────
GENESIS_T="ok"
CC_GEN_ENV=$(cc_rpc getblockheader "[\"$GEN_HASH\", true]")
echo "$CC_GEN_ENV" | grep -q '"result"' || fail "camlcoin getblockheader genesis errored: $CC_GEN_ENV"
CC_GEN=$(jpy "$CC_GEN_ENV" "json.dumps(d['result'])")
HAS_PREV=$(jpy "$CC_GEN" "'previousblockhash' in d")
[[ "$HAS_PREV" == "false" ]] || { GENESIS_T="bad"; log "genesis WRONGLY has previousblockhash: $CC_GEN"; }
HAS_NEXT=$(jpy "$CC_GEN" "'nextblockhash' in d")
[[ "$HAS_NEXT" == "true" ]]  || { GENESIS_T="bad"; log "genesis MISSING nextblockhash: $CC_GEN"; }
# genesis height must be 0 and hash must match.
G_HEIGHT=$(jpy "$CC_GEN" "d.get('height')")
[[ "$G_HEIGHT" == "0" ]] || { GENESIS_T="bad"; log "genesis height != 0: '$G_HEIGHT'"; }
G_HASH=$(jpy "$CC_GEN" "d.get('hash')")
[[ "$G_HASH" == "$GEN_HASH" ]] || { GENESIS_T="bad"; log "genesis hash mismatch: '$G_HASH' != '$GEN_HASH'"; }
[[ "$GENESIS_T" == "ok" ]] || fail "genesis previous/next handling check failed (see log)"

# ── 9. TIP: nextblockhash ABSENT; confirmations == 1. ─────────────────────
TIP_T="ok"
CC_TIP_ENV=$(cc_rpc getblockheader "[\"$CC_TIP\", true]")
echo "$CC_TIP_ENV" | grep -q '"result"' || fail "camlcoin getblockheader tip errored: $CC_TIP_ENV"
CC_TIP_V=$(jpy "$CC_TIP_ENV" "json.dumps(d['result'])")
TIP_HAS_NEXT=$(jpy "$CC_TIP_V" "'nextblockhash' in d")
[[ "$TIP_HAS_NEXT" == "false" ]] || { TIP_T="bad"; log "tip WRONGLY has nextblockhash: $CC_TIP_V"; }
TIP_CONF=$(jpy "$CC_TIP_V" "d.get('confirmations')")
[[ "$TIP_CONF" == "1" ]] || { TIP_T="bad"; log "tip confirmations != 1: '$TIP_CONF'"; }
# tip must still have previousblockhash (it is not genesis).
TIP_HAS_PREV=$(jpy "$CC_TIP_V" "'previousblockhash' in d")
[[ "$TIP_HAS_PREV" == "true" ]] || { TIP_T="bad"; log "tip MISSING previousblockhash: $CC_TIP_V"; }
[[ "$TIP_T" == "ok" ]] || fail "tip next/confirmations handling check failed (see log)"

# ── 10. ERROR: unknown blockhash -> RPC error code -5. ────────────────────
ERRORS_T="ok"
ERR_BAD_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
E5=$(jpy "$(cc_rpc getblockheader "[\"$ERR_BAD_HASH\", true]")" "d['error']['code']")
[[ "$E5" == "-5" ]] || { ERRORS_T="bad"; log "expected error -5 for unknown blockhash, got '$E5'"; }
# also for verbose=false (hex path).
E5F=$(jpy "$(cc_rpc getblockheader "[\"$ERR_BAD_HASH\", false]")" "d['error']['code']")
[[ "$E5F" == "-5" ]] || { ERRORS_T="bad"; log "expected error -5 for unknown blockhash (verbose=false), got '$E5F'"; }
[[ "$ERRORS_T" == "ok" ]] || fail "error-code parity check failed (see log)"

log "PASS: camlcoin getblockheader matches Core on hex + verbose fields + genesis/tip + error codes"
pass "$HEX_T" "$VERBOSE_T" "$GENESIS_T" "$TIP_T" "$ERRORS_T"

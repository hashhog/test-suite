#!/usr/bin/env bash
#
# hotbuns_gettxout.sh — self-contained gettxout Core-parity differential.
#
# gettxout queries the live UTXO set for ONE output (txid, vout); existing coin
# -> { bestblock, confirmations(=tip-coin_height+1), value, scriptPubKey{asm,hex,
# type,address}, coinbase }; spent/nonexistent -> JSON null.
# Core ref: bitcoin-core/src/rpc/blockchain.cpp (gettxout).
#
# hotbuns has a slow Bun cold start, so this harness is two-phase:
#   PHASE A: launch the Core oracle, mine to a FIXED depth (block 1 -> MINE_ADDR,
#            5 maturity -> SINK), CAPTURE Core's gettxout outputs + raw blocks +
#            tip into a scratch manifest, then STOP Core.
#   PHASE B: launch hotbuns, replay the captured blocks via submitblock so its
#            UTXO set is byte-identical, run the SAME gettxout calls, and assert
#            against the captured Core values (Core need not be alive).
#
# Summary line (stdout):
#   PASS: GETTXOUT hotbuns: PASS existing=ok null=ok bestblock=ok confs=ok coinbase=ok
#   FAIL: GETTXOUT hotbuns: FAIL <short reason>

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_DIR="$BASEDIR/hotbuns"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

SECRET="1111111111111111111111111111111111111111111111111111111111111112"
SINK_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

HB_DATADIR="/tmp/gto-hotbuns"
HB_RPC=22544
HB_P2P=22564
HB_LOG="$HB_DATADIR/node.log"

CORE_DATADIR="/tmp/gto-core-hb"
CORE_RPC=22546
CORE_P2P=22566
CORE_LOG="$CORE_DATADIR/core.log"

CAP_DIR="/tmp/gto-cap-hb"
BLOCKS_FILE="$CAP_DIR/blocks.hex"        # one raw block hex per line (1..NBLOCKS)

NBLOCKS=6
COIN_HEIGHT=1
EXP_CONFS=6

HB_PID=""
HB_COOKIE=""
CORE_BG=""

log() { echo "[gettxout:hotbuns] $*" >&2; }

cleanup() {
    local ec=$?
    if [[ -n "$HB_PID" ]] && kill -0 "$HB_PID" 2>/dev/null; then
        kill "$HB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$HB_DATADIR" "$CORE_DATADIR" "$CAP_DIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "GETTXOUT hotbuns: PASS existing=ok null=ok bestblock=ok confs=ok coinbase=ok"
    exit 0
}
fail() {
    echo "GETTXOUT hotbuns: FAIL $*"
    exit 1
}

jpy() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    elif v is None: print('null')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gto-hotbuns" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${HB_RPC}|${HB_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${HB_RPC}|${HB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${HB_RPC}/${HB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$HB_DATADIR" "$CORE_DATADIR" "$CAP_DIR"
mkdir -p "$HB_DATADIR" "$CORE_DATADIR" "$CAP_DIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
command -v bun     >/dev/null 2>&1   || fail "bun runtime not found on PATH"
[[ -f "$NODE_DIR/src/index.ts" ]]    || fail "hotbuns entrypoint not found at $NODE_DIR/src/index.ts"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

derive_p2wpkh() {
    python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$1'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))" 2>/dev/null
}
MINE_ADDR=$(derive_p2wpkh "$SECRET")   || fail "could not derive mining address (test_framework import failed)"
[[ "$MINE_ADDR" == bcrt1* ]] || fail "mining address not regtest bech32: '$MINE_ADDR'"
SINK_ADDR=$(derive_p2wpkh "$SINK_SECRET") || fail "could not derive sink address"
[[ "$SINK_ADDR" == bcrt1* ]] || fail "sink address not regtest bech32: '$SINK_ADDR'"
log "mine=$MINE_ADDR sink=$SINK_ADDR"

# ── RPC helpers. ──────────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }
hb_rpc() {
    curl -s --max-time 120 -u "$HB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$HB_RPC/" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════
# PHASE A — Core mines to FIXED depth; capture coinbase, gettxout, blocks, tip.
# ══════════════════════════════════════════════════════════════════════════
log "launching Core oracle rpc=:$CORE_RPC p2p=:$CORE_P2P -listen=0"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < core_deadline )); do
    core_cli getblockcount >/dev/null 2>&1 && break
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
core_cli getblockcount >/dev/null 2>&1 || fail "Core oracle RPC never responded within 90s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

log "mining block 1 coinbase -> $MINE_ADDR on Core"
core_cli generatetoaddress 1 "$MINE_ADDR" >/dev/null 2>&1 || fail "Core generatetoaddress (funding) failed"
log "mining 5 maturity blocks -> $SINK_ADDR on Core"
core_cli generatetoaddress 5 "$SINK_ADDR" >/dev/null 2>&1 || fail "Core generatetoaddress (maturity) failed"
CORE_HEIGHT=$(core_cli getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

# Capture the block-1 coinbase txid + tip + raw blocks.
COIN_BH=$(core_cli getblockhash "$COIN_HEIGHT") || fail "Core getblockhash $COIN_HEIGHT failed"
COIN_TXID=$(core_cli getblock "$COIN_BH" 1 | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
[[ -n "$COIN_TXID" && "${#COIN_TXID}" == "64" ]] || fail "could not resolve block-1 coinbase txid (got '$COIN_TXID')"
CORE_TIP=$(core_cli getbestblockhash)
log "coinbase txid=$COIN_TXID Core captured; tip $CORE_TIP"

: > "$BLOCKS_FILE"
for ((h=1; h<=NBLOCKS; h++)); do
    BH=$(core_cli getblockhash "$h")  || fail "Core getblockhash $h failed"
    RAW=$(core_cli getblock "$BH" 0)  || fail "Core getblock $h (raw) failed"
    echo "$RAW" >> "$BLOCKS_FILE"
done

# Capture Core's gettxout outputs (existing coin + the two null cases).
CORE_GTO=$(core_cli gettxout "$COIN_TXID" 0 true)
[[ -n "$CORE_GTO" && "$CORE_GTO" != "null" ]] || fail "Core gettxout returned null for an UNSPENT coinbase (oracle anomaly)"
CORE_NULL=$(core_cli gettxout "$COIN_TXID" 9 true)
ABSENT_TXID="0000000000000000000000000000000000000000000000000000000000000001"
CORE_NULL2=$(core_cli gettxout "$ABSENT_TXID" 0 true)
[[ -z "$CORE_NULL"  || "$CORE_NULL"  == "null" ]] || fail "Core gettxout(absent vout) not null (oracle anomaly): '$CORE_NULL'"
[[ -z "$CORE_NULL2" || "$CORE_NULL2" == "null" ]] || fail "Core gettxout(absent txid) not null (oracle anomaly): '$CORE_NULL2'"
log "Core gettxout captured; stopping Core"

# Stop Core — hotbuns does not need it alive from here on.
core_cli stop >/dev/null 2>&1 || true
for _ in $(seq 1 15); do core_cli getblockcount >/dev/null 2>&1 || break; sleep 1; done
[[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
CORE_BG=""

# ══════════════════════════════════════════════════════════════════════════
# PHASE B — launch hotbuns, replay captured chain, run the SAME gettxout calls.
# ══════════════════════════════════════════════════════════════════════════
log "launching hotbuns (regtest) rpc=:$HB_RPC p2p=:$HB_P2P -> $HB_LOG"
(
    cd "$NODE_DIR" || exit 1
    exec bun run src/index.ts \
        --network=regtest --datadir="$HB_DATADIR" \
        --port="$HB_P2P" --rpcport="$HB_RPC"
) >"$HB_LOG" 2>&1 &
HB_PID=$!
log "hotbuns pid=$HB_PID"
hb_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < hb_deadline )); do
    if [[ -z "$HB_COOKIE" ]]; then
        for c in "$HB_DATADIR/.cookie" "$HB_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && HB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HB_COOKIE" ]]; then
        echo "$(hb_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$HB_PID" 2>/dev/null || { tail -n 20 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns exited during startup (see $HB_LOG)"; }
    sleep 1
done
[[ -n "$HB_COOKIE" ]] || fail "hotbuns cookie never appeared within 90s"
echo "$(hb_rpc getblockcount '[]')" | grep -q '"result"' || fail "hotbuns RPC never responded within 90s"
log "hotbuns RPC ready"

log "mirroring $NBLOCKS captured blocks into hotbuns via submitblock"
h=0
while IFS= read -r RAW; do
    [[ -z "$RAW" ]] && continue
    h=$((h+1))
    SB=$(hb_rpc submitblock "[\"$RAW\"]")
    if echo "$SB" | grep -q '"error":{'; then
        ECODE=$(jpy "$SB" "d.get('error') and d['error'].get('code')")
        [[ -z "$ECODE" || "$ECODE" == "None" || "$ECODE" == "null" ]] || fail "hotbuns submitblock height=$h error: $SB"
    fi
done < "$BLOCKS_FILE"
HB_HEIGHT=$(jpy "$(hb_rpc getblockcount '[]')" "d['result']")
[[ "$HB_HEIGHT" == "$NBLOCKS" ]] || fail "hotbuns height $HB_HEIGHT != $NBLOCKS after mirror (submitblock did not connect chain)"
HB_TIP=$(jpy "$(hb_rpc getbestblockhash '[]')" "d['result']")
[[ "$HB_TIP" == "$CORE_TIP" ]] || fail "tip mismatch after mirror: hotbuns=$HB_TIP captured-core=$CORE_TIP"
log "hotbuns at identical tip $HB_TIP (height $NBLOCKS)"

hb_gettxout() {
    local resp; resp=$(hb_rpc gettxout "[\"$1\", $2, true]")
    echo "$resp" | grep -q '"result"' || { echo "<ERR>$resp"; return 0; }
    jpy "$resp" "json.dumps(d['result'])"
}

# ════════════════════════════════════════════════════════════════════════
# CHECK 1 — existing UTXO: full-shape parity vs CAPTURED Core output.
# ════════════════════════════════════════════════════════════════════════
EXIST_T="ok"; NULL_T="ok"; BEST_T="ok"; CONF_T="ok"; CB_T="ok"

HB_GTO=$(hb_gettxout "$COIN_TXID" 0)
case "$HB_GTO" in "<ERR>"*) fail "hotbuns gettxout errored: ${HB_GTO#<ERR>}";; esac
[[ -n "$HB_GTO" && "$HB_GTO" != "null" ]] || { EXIST_T="bad"; log "hotbuns gettxout returned null for an UNSPENT coinbase"; }

log "Core:    $CORE_GTO"
log "hotbuns: $HB_GTO"

CORE_BEST=$(jpy "$CORE_GTO" "d['bestblock']")
HB_BEST=$(jpy "$HB_GTO"   "d.get('bestblock','')")
[[ "$CORE_BEST" == "$CORE_TIP" ]] || fail "Core bestblock != tip (oracle anomaly): '$CORE_BEST'"
[[ "$HB_BEST" == "$CORE_BEST" ]] || { BEST_T="bad"; log "bestblock mismatch: impl='$HB_BEST' core='$CORE_BEST'"; }

CORE_CONF=$(jpy "$CORE_GTO" "d['confirmations']")
HB_CONF=$(jpy "$HB_GTO"   "d.get('confirmations')")
[[ "$CORE_CONF" == "$EXP_CONFS" ]] || fail "Core confirmations != $EXP_CONFS (oracle anomaly): '$CORE_CONF'"
[[ "$HB_CONF" == "$CORE_CONF" ]] || { CONF_T="bad"; log "confirmations mismatch: impl='$HB_CONF' core='$CORE_CONF'"; }

CORE_VAL=$(jpy "$CORE_GTO" "format(float(d['value']),'.8f')")
HB_VAL=$(jpy "$HB_GTO"   "format(float(d.get('value',0)),'.8f')")
[[ "$HB_VAL" == "$CORE_VAL" ]] || { EXIST_T="bad"; log "value mismatch: impl='$HB_VAL' core='$CORE_VAL'"; }

for f in asm hex type; do
    CV=$(jpy "$CORE_GTO" "d['scriptPubKey'].get('$f','')")
    IV=$(jpy "$HB_GTO"   "d.get('scriptPubKey',{}).get('$f','')")
    [[ "$IV" == "$CV" ]] || { EXIST_T="bad"; log "scriptPubKey.$f mismatch: impl='$IV' core='$CV'"; }
done
CORE_HASADDR=$(jpy "$CORE_GTO" "'address' in d['scriptPubKey']")
if [[ "$CORE_HASADDR" == "true" ]]; then
    HB_HASADDR=$(jpy "$HB_GTO" "'address' in d.get('scriptPubKey',{})")
    [[ "$HB_HASADDR" == "true" ]] || { EXIST_T="bad"; log "hotbuns scriptPubKey missing 'address' (Core emits one)"; }
fi

CORE_CB=$(jpy "$CORE_GTO" "d['coinbase']")
HB_CB=$(jpy "$HB_GTO"   "d.get('coinbase')")
[[ "$CORE_CB" == "true" ]] || fail "Core coinbase flag not true for a coinbase coin (oracle anomaly): '$CORE_CB'"
[[ "$HB_CB" == "$CORE_CB" ]] || { CB_T="bad"; log "coinbase flag mismatch: impl='$HB_CB' core='$CORE_CB'"; }

# ════════════════════════════════════════════════════════════════════════
# CHECK 2 — spent/nonexistent output -> JSON null on hotbuns (Core captured null).
# ════════════════════════════════════════════════════════════════════════
HB_NULL=$(hb_gettxout "$COIN_TXID" 9)
case "$HB_NULL" in "<ERR>"*) fail "hotbuns gettxout(null-case) errored: ${HB_NULL#<ERR>}";; esac
[[ -z "$HB_NULL" || "$HB_NULL" == "null" ]] || { NULL_T="bad"; log "hotbuns gettxout(absent vout) not null: '$HB_NULL'"; }

HB_NULL2=$(hb_gettxout "$ABSENT_TXID" 0)
case "$HB_NULL2" in "<ERR>"*) fail "hotbuns gettxout(absent txid) errored: ${HB_NULL2#<ERR>}";; esac
[[ -z "$HB_NULL2" || "$HB_NULL2" == "null" ]] || { NULL_T="bad"; log "hotbuns gettxout(absent txid) not null: '$HB_NULL2'"; }

# ── Verdict. ──────────────────────────────────────────────────────────────
if [[ "$EXIST_T" == "ok" && "$NULL_T" == "ok" && "$BEST_T" == "ok" && "$CONF_T" == "ok" && "$CB_T" == "ok" ]]; then
    log "PASS: hotbuns gettxout matches Core on existing coin + bestblock + confs + coinbase + null"
    pass
fi

REASON=""
[[ "$EXIST_T" != "ok" ]] && REASON+="existing-UTXO shape diverges from Core; "
[[ "$BEST_T"  != "ok" ]] && REASON+="bestblock diverges from Core; "
[[ "$CONF_T"  != "ok" ]] && REASON+="confirmations diverges from Core; "
[[ "$CB_T"    != "ok" ]] && REASON+="coinbase flag diverges from Core; "
[[ "$NULL_T"  != "ok" ]] && REASON+="spent/nonexistent output not null; "
fail "${REASON% }"

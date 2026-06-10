#!/usr/bin/env bash
#
# lunarblock_gettxout.sh — self-contained gettxout Core-parity differential.
#
# gettxout queries the live UTXO set for ONE output (txid, vout); existing coin
# -> { bestblock, confirmations(=tip-coin_height+1), value, scriptPubKey{asm,hex,
# type,address}, coinbase }; spent/nonexistent -> JSON null.
# Core ref: bitcoin-core/src/rpc/blockchain.cpp (gettxout).
#
# Core mines the chain to a FIXED address (-listen=0 oracle); lunarblock ingests
# each block via submitblock so both nodes carry the identical UTXO set + tip.
# NOTE: lunarblock's RPC uses NO cookie auth (open loopback), so lb_rpc has no -u.
#
# Summary line (stdout):
#   PASS: GETTXOUT lunarblock: PASS existing=ok null=ok bestblock=ok confs=ok coinbase=ok
#   FAIL: GETTXOUT lunarblock: FAIL <short reason>

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

SECRET="1111111111111111111111111111111111111111111111111111111111111112"
SINK_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

LB_DATADIR="/tmp/gto-lunarblock"
LB_RPC=22572
LB_P2P=22592
LB_LOG="$LB_DATADIR/node.log"

CORE_DATADIR="/tmp/gto-lb-core"
CORE_RPC=22574
CORE_P2P=22594
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=6
COIN_HEIGHT=1
EXP_CONFS=6

LB_PID=""
CORE_BG=""

log() { echo "[gettxout:lunarblock] $*" >&2; }

cleanup() {
    local ec=$?
    if [[ -n "$LB_PID" ]] && kill -0 "$LB_PID" 2>/dev/null; then
        kill "$LB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$LB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$LB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    pkill -9 -f "gto-lunarblock" >/dev/null 2>&1 || true
    rm -rf "$LB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "GETTXOUT lunarblock: PASS existing=ok null=ok bestblock=ok confs=ok coinbase=ok"
    exit 0
}
fail() {
    echo "GETTXOUT lunarblock: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gto-lunarblock" 2>/dev/null || true
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
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
command -v luajit  >/dev/null 2>&1   || fail "luajit not found on PATH"
[[ -f "$LB_DIR/src/main.lua" ]]      || fail "lunarblock entrypoint not found at $LB_DIR/src/main.lua"
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
core_cli_retry() {
    local out="" rc=1
    for _ in $(seq 1 20); do
        out=$(core_cli "$@" 2>/dev/null); rc=$?
        [[ $rc -eq 0 && -n "$out" ]] && { echo "$out"; return 0; }
        [[ -n "$CORE_BG" ]] && ! kill -0 "$CORE_BG" 2>/dev/null && return 1
        sleep 3
    done
    return 1
}
# lunarblock RPC: NO cookie auth (open loopback).
lb_rpc() {
    curl -s --max-time 90 \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$LB_RPC/" 2>/dev/null
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

# ── 2. Launch the Core regtest oracle (RPC-only). ─────────────────────────
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
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P -listen=0 (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
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

# ── 4. Mine to FIXED depth; mirror EVERY block into lunarblock. ───────────
log "mining block 1 coinbase -> $MINE_ADDR on Core"
core_cli_retry generatetoaddress 1 "$MINE_ADDR" >/dev/null || fail "Core generatetoaddress (funding) failed"
log "mining 5 maturity blocks -> $SINK_ADDR on Core"
core_cli_retry generatetoaddress 5 "$SINK_ADDR" >/dev/null || fail "Core generatetoaddress (maturity) failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

log "mirroring Core's $NBLOCKS blocks into lunarblock via submitblock"
for ((h=1; h<=NBLOCKS; h++)); do
    BH=$(core_cli_retry getblockhash "$h")  || fail "Core getblockhash $h failed"
    RAW=$(core_cli_retry getblock "$BH" 0)  || fail "Core getblock $h (raw) failed"
    SB=$(lb_rpc submitblock "[\"$RAW\"]")
    if echo "$SB" | grep -q '"error":{'; then
        ECODE=$(jpy "$SB" "d.get('error') and d['error'].get('code')")
        [[ -z "$ECODE" || "$ECODE" == "None" || "$ECODE" == "null" ]] || { log "lunarblock submitblock height=$h rejected: $SB"; fail "lunarblock submitblock failed at height $h"; }
    fi
done
LB_HEIGHT=$(jpy "$(lb_rpc getblockcount '[]')" "d['result']")
[[ "$LB_HEIGHT" == "$NBLOCKS" ]] || { tail -n 40 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock height $LB_HEIGHT != $NBLOCKS after mirror (submitblock did not connect chain)"; }

CORE_TIP=$(core_cli_retry getbestblockhash)
LB_TIP=$(jpy "$(lb_rpc getbestblockhash '[]')" "d['result']")
[[ "$CORE_TIP" == "$LB_TIP" ]] || fail "tip mismatch after mirror: core=$CORE_TIP lunarblock=$LB_TIP"
log "both at identical tip $LB_TIP (height $NBLOCKS)"

COIN_BH=$(core_cli_retry getblockhash "$COIN_HEIGHT") || fail "Core getblockhash $COIN_HEIGHT failed"
COIN_TXID=$(core_cli_retry getblock "$COIN_BH" 1 | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
[[ -n "$COIN_TXID" && "${#COIN_TXID}" == "64" ]] || fail "could not resolve block-1 coinbase txid (got '$COIN_TXID')"
log "coinbase txid=$COIN_TXID expected_confs=$EXP_CONFS"

core_gettxout() { core_cli_retry gettxout "$1" "$2" true; }
lb_gettxout() {
    local resp; resp=$(lb_rpc gettxout "[\"$1\", $2, true]")
    echo "$resp" | grep -q '"result"' || { echo "<ERR>$resp"; return 0; }
    jpy "$resp" "json.dumps(d['result'])"
}

# ════════════════════════════════════════════════════════════════════════
# CHECK 1 — existing UTXO: full-shape parity for the coinbase coin.
# ════════════════════════════════════════════════════════════════════════
EXIST_T="ok"; NULL_T="ok"; BEST_T="ok"; CONF_T="ok"; CB_T="ok"

CORE_GTO=$(core_gettxout "$COIN_TXID" 0) || fail "Core gettxout failed (see $CORE_LOG)"
[[ -n "$CORE_GTO" && "$CORE_GTO" != "null" ]] || fail "Core gettxout returned null for an UNSPENT coinbase (oracle anomaly)"
LB_GTO=$(lb_gettxout "$COIN_TXID" 0)
case "$LB_GTO" in "<ERR>"*) fail "lunarblock gettxout errored: ${LB_GTO#<ERR>}";; esac
[[ -n "$LB_GTO" && "$LB_GTO" != "null" ]] || { EXIST_T="bad"; log "lunarblock gettxout returned null for an UNSPENT coinbase"; }

log "Core:       $CORE_GTO"
log "lunarblock: $LB_GTO"

CORE_BEST=$(jpy "$CORE_GTO" "d['bestblock']")
LB_BEST=$(jpy "$LB_GTO"   "d.get('bestblock','')")
[[ "$CORE_BEST" == "$CORE_TIP" ]] || fail "Core bestblock != tip (oracle anomaly): '$CORE_BEST'"
[[ "$LB_BEST" == "$CORE_BEST" ]] || { BEST_T="bad"; log "bestblock mismatch: impl='$LB_BEST' core='$CORE_BEST'"; }

CORE_CONF=$(jpy "$CORE_GTO" "d['confirmations']")
LB_CONF=$(jpy "$LB_GTO"   "d.get('confirmations')")
[[ "$CORE_CONF" == "$EXP_CONFS" ]] || fail "Core confirmations != $EXP_CONFS (oracle anomaly): '$CORE_CONF'"
[[ "$LB_CONF" == "$CORE_CONF" ]] || { CONF_T="bad"; log "confirmations mismatch: impl='$LB_CONF' core='$CORE_CONF'"; }

CORE_VAL=$(jpy "$CORE_GTO" "format(float(d['value']),'.8f')")
LB_VAL=$(jpy "$LB_GTO"   "format(float(d.get('value',0)),'.8f')")
[[ "$LB_VAL" == "$CORE_VAL" ]] || { EXIST_T="bad"; log "value mismatch: impl='$LB_VAL' core='$CORE_VAL'"; }

for f in asm hex type; do
    CV=$(jpy "$CORE_GTO" "d['scriptPubKey'].get('$f','')")
    IV=$(jpy "$LB_GTO"   "d.get('scriptPubKey',{}).get('$f','')")
    [[ "$IV" == "$CV" ]] || { EXIST_T="bad"; log "scriptPubKey.$f mismatch: impl='$IV' core='$CV'"; }
done
CORE_HASADDR=$(jpy "$CORE_GTO" "'address' in d['scriptPubKey']")
if [[ "$CORE_HASADDR" == "true" ]]; then
    LB_HASADDR=$(jpy "$LB_GTO" "'address' in d.get('scriptPubKey',{})")
    [[ "$LB_HASADDR" == "true" ]] || { EXIST_T="bad"; log "lunarblock scriptPubKey missing 'address' (Core emits one)"; }
fi

CORE_CB=$(jpy "$CORE_GTO" "d['coinbase']")
LB_CB=$(jpy "$LB_GTO"   "d.get('coinbase')")
[[ "$CORE_CB" == "true" ]] || fail "Core coinbase flag not true for a coinbase coin (oracle anomaly): '$CORE_CB'"
[[ "$LB_CB" == "$CORE_CB" ]] || { CB_T="bad"; log "coinbase flag mismatch: impl='$LB_CB' core='$CORE_CB'"; }

# ════════════════════════════════════════════════════════════════════════
# CHECK 2 — spent/nonexistent output -> JSON null on BOTH nodes.
# ════════════════════════════════════════════════════════════════════════
CORE_NULL=$(core_gettxout "$COIN_TXID" 9)
LB_NULL=$(lb_gettxout "$COIN_TXID" 9)
case "$LB_NULL" in "<ERR>"*) fail "lunarblock gettxout(null-case) errored: ${LB_NULL#<ERR>}";; esac
[[ -z "$CORE_NULL" || "$CORE_NULL" == "null" ]] || fail "Core gettxout(absent vout) not null (oracle anomaly): '$CORE_NULL'"
[[ -z "$LB_NULL" || "$LB_NULL" == "null" ]] || { NULL_T="bad"; log "lunarblock gettxout(absent vout) not null: '$LB_NULL'"; }

ABSENT_TXID="0000000000000000000000000000000000000000000000000000000000000001"
CORE_NULL2=$(core_gettxout "$ABSENT_TXID" 0)
LB_NULL2=$(lb_gettxout "$ABSENT_TXID" 0)
case "$LB_NULL2" in "<ERR>"*) fail "lunarblock gettxout(absent txid) errored: ${LB_NULL2#<ERR>}";; esac
[[ -z "$CORE_NULL2" || "$CORE_NULL2" == "null" ]] || fail "Core gettxout(absent txid) not null (oracle anomaly): '$CORE_NULL2'"
[[ -z "$LB_NULL2" || "$LB_NULL2" == "null" ]] || { NULL_T="bad"; log "lunarblock gettxout(absent txid) not null: '$LB_NULL2'"; }

# ── Verdict. ──────────────────────────────────────────────────────────────
if [[ "$EXIST_T" == "ok" && "$NULL_T" == "ok" && "$BEST_T" == "ok" && "$CONF_T" == "ok" && "$CB_T" == "ok" ]]; then
    log "PASS: lunarblock gettxout matches Core on existing coin + bestblock + confs + coinbase + null"
    pass
fi

REASON=""
[[ "$EXIST_T" != "ok" ]] && REASON+="existing-UTXO shape diverges from Core; "
[[ "$BEST_T"  != "ok" ]] && REASON+="bestblock diverges from Core; "
[[ "$CONF_T"  != "ok" ]] && REASON+="confirmations diverges from Core; "
[[ "$CB_T"    != "ok" ]] && REASON+="coinbase flag diverges from Core; "
[[ "$NULL_T"  != "ok" ]] && REASON+="spent/nonexistent output not null; "
fail "${REASON% }"

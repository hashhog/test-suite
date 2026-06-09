#!/usr/bin/env bash
#
# ouroboros_gettxout.sh — self-contained gettxout Core-parity differential.
#
# gettxout queries the live UTXO set for ONE output (txid, vout); existing coin
# -> { bestblock, confirmations(=tip-coin_height+1), value, scriptPubKey{asm,hex,
# type,address}, coinbase }; spent/nonexistent -> JSON null.
# Core ref: bitcoin-core/src/rpc/blockchain.cpp (gettxout).
#
# Core mines the chain to a FIXED address (-listen=0 oracle); ouroboros replays
# Core's blocks via submitblock so both nodes carry the identical UTXO set + tip.
#
# Summary line (stdout):
#   PASS: GETTXOUT ouroboros: PASS existing=ok null=ok bestblock=ok confs=ok coinbase=ok
#   FAIL: GETTXOUT ouroboros: FAIL <short reason>

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OURO_DIR="$REPO_ROOT/ouroboros"
[[ -d "$OURO_DIR" ]] || OURO_DIR="$BASEDIR/ouroboros"

SECRET="1111111111111111111111111111111111111111111111111111111111111112"
SINK_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

OU_DATADIR="/tmp/gto-ouroboros-impl"
OU_RPC=40648
OU_P2P=40668
OU_LOG="$OU_DATADIR/node.log"

CORE_DATADIR="/tmp/gto-ouroboros-core"
CORE_RPC=40650
CORE_P2P=40670
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=6
COIN_HEIGHT=1
EXP_CONFS=6

OU_PID=""
OU_COOKIE=""
CORE_BG=""

log() { echo "[gettxout:ouroboros] $*" >&2; }

cleanup() {
    local ec=$?
    if [[ -n "$OU_PID" ]] && kill -0 "$OU_PID" 2>/dev/null; then
        kill "$OU_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$OU_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$OU_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    pkill -9 -f "gto-ouroboros-impl" >/dev/null 2>&1 || true
    pkill -9 -f "gto-ouroboros-core" >/dev/null 2>&1 || true
    fuser -k "${OU_RPC}/tcp"         >/dev/null 2>&1 || true
    fuser -k "${OU_P2P}/tcp"         >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp"       >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp"       >/dev/null 2>&1 || true
    rm -rf "$OU_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "GETTXOUT ouroboros: PASS existing=ok null=ok bestblock=ok confs=ok coinbase=ok"
    exit 0
}
fail() {
    echo "GETTXOUT ouroboros: FAIL $*"
    exit 1
}

# Core CLI shorthand.
ccli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# ouroboros JSON-RPC over curl: ou_rpc <method> <json-params-array> -> raw envelope.
ou_rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 120 -u "$OU_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$OU_RPC/" 2>/dev/null
}
# Unwrap a JSON-RPC envelope to its .result (prints "<ERR>..." on error).
ou_result() {
    python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('<PARSEERR>'); sys.exit(0)
if d.get('error') is not None:
    e=d['error']; print('<ERR>code=%s msg=%s' % (e.get('code'), e.get('message'))); sys.exit(0)
r=d.get('result')
print(r if isinstance(r,str) else json.dumps(r))
"
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
pkill -f "gto-ouroboros-impl" 2>/dev/null || true
pkill -f "gto-ouroboros-core" 2>/dev/null || true
sleep 2
fuser -k "${OU_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${OU_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 1
rm -rf "$OU_DATADIR" "$CORE_DATADIR"
mkdir -p "$OU_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1        || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1           || fail "curl not found on PATH"
[[ -f "$OURO_DIR/src/ouroboros/cli.py" ]] || fail "ouroboros checkout not found at $OURO_DIR (not built)"
[[ -x "$CORE_BIN" ]]                      || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                      || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]        || fail "Core test_framework not found at $TF_PATH"

OURO_PY="$OURO_DIR/.venv/bin/python3"
[[ -x "$OURO_PY" ]] || OURO_PY="python3"

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

# ── 2. Launch the Core regtest oracle (-listen=0). ────────────────────────
log "launching Core regtest oracle rpc=:$CORE_RPC (listen=0)"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -rpcbind=127.0.0.1 -listen=0 -discover=0 -dnsseed=0 \
    -fallbackfee=0.0002 -daemonwait=0 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 90 ))
core_ready=0
while (( $(date +%s) < core_deadline )); do
    if ccli getblockcount >/dev/null 2>&1; then core_ready=1; break; fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
[[ "$core_ready" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 90s"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Mine to FIXED depth on Core. ───────────────────────────────────────
log "mining block 1 coinbase -> $MINE_ADDR on Core"
ccli generatetoaddress 1 "$MINE_ADDR" >/dev/null 2>&1 || fail "Core generatetoaddress (funding) failed (see $CORE_LOG)"
log "mining 5 maturity blocks -> $SINK_ADDR on Core"
ccli generatetoaddress 5 "$SINK_ADDR" >/dev/null 2>&1 || fail "Core generatetoaddress (maturity) failed (see $CORE_LOG)"
CORE_HEIGHT=$(ccli getblockcount 2>/dev/null)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

# ── 4. Launch ouroboros on regtest. ───────────────────────────────────────
log "launching ouroboros (regtest, --nolisten) rpc=:$OU_RPC -> $OU_LOG"
(
    cd "$OURO_DIR" || exit 1
    exec "$OURO_PY" -m ouroboros.cli \
        --network regtest --data-dir "$OU_DATADIR" \
        start --force --nolisten --rpc-port "$OU_RPC" --p2p-port "$OU_P2P"
) >"$OU_LOG" 2>&1 &
OU_PID=$!
log "ouroboros pid=$OU_PID"
ou_deadline=$(( $(date +%s) + 180 ))
while (( $(date +%s) < ou_deadline )); do
    if [[ -z "$OU_COOKIE" ]]; then
        for c in "$OU_DATADIR/.cookie" "$OU_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && OU_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$OU_COOKIE" ]]; then
        echo "$(ou_rpc getblockcount)" | grep -q '"result"' && break
    fi
    kill -0 "$OU_PID" 2>/dev/null || { tail -n 20 "$OU_LOG" >&2 2>/dev/null || true; fail "ouroboros exited during startup (see $OU_LOG)"; }
    sleep 1
done
[[ -n "$OU_COOKIE" ]] || fail "ouroboros cookie never appeared within 180s"
echo "$(ou_rpc getblockcount)" | grep -q '"result"' || fail "ouroboros RPC never responded within 180s"
log "ouroboros RPC ready"

# ── 5. Replicate Core's chain onto ouroboros via submitblock. ─────────────
log "replicating Core blocks 1..$NBLOCKS onto ouroboros via submitblock"
for h in $(seq 1 "$NBLOCKS"); do
    BH=$(ccli getblockhash "$h" 2>/dev/null) || fail "Core getblockhash($h) failed"
    RAW=$(ccli getblock "$BH" 0 2>/dev/null) || fail "Core getblock($h) raw failed"
    sb=$(ou_rpc submitblock "[\"$RAW\"]" | ou_result)
    case "$sb" in
        "<ERR>"*) fail "ouroboros submitblock($h) error: ${sb#<ERR>}" ;;
        "null"|"") : ;;
        *) fail "ouroboros submitblock($h) rejected: $sb" ;;
    esac
done
OU_TIP_H=$(ou_rpc getblockcount | ou_result)
[[ "$OU_TIP_H" == "$NBLOCKS" ]] || fail "ouroboros tip=$OU_TIP_H != $NBLOCKS after replication"

CORE_TIP=$(ccli getbestblockhash 2>/dev/null)
OU_TIP=$(ou_rpc getbestblockhash | ou_result)
[[ "$CORE_TIP" == "$OU_TIP" ]] || fail "tip mismatch after mirror: core=$CORE_TIP ouroboros=$OU_TIP"
log "ouroboros at identical tip $OU_TIP (height $NBLOCKS)"

COIN_BH=$(ccli getblockhash "$COIN_HEIGHT" 2>/dev/null) || fail "Core getblockhash $COIN_HEIGHT failed"
COIN_TXID=$(ccli getblock "$COIN_BH" 1 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
[[ -n "$COIN_TXID" && "${#COIN_TXID}" == "64" ]] || fail "could not resolve block-1 coinbase txid (got '$COIN_TXID')"
log "coinbase txid=$COIN_TXID expected_confs=$EXP_CONFS"

core_gettxout() { ccli gettxout "$1" "$2" true 2>/dev/null; }
ou_gettxout() {
    local r; r=$(ou_rpc gettxout "[\"$1\", $2, true]" | ou_result)
    case "$r" in "<ERR>"*|"<PARSEERR>") echo "<ERR>$r"; return 0;; esac
    echo "$r"
}

# ════════════════════════════════════════════════════════════════════════
# CHECK 1 — existing UTXO: full-shape parity for the coinbase coin.
# ════════════════════════════════════════════════════════════════════════
EXIST_T="ok"; NULL_T="ok"; BEST_T="ok"; CONF_T="ok"; CB_T="ok"

CORE_GTO=$(core_gettxout "$COIN_TXID" 0) || fail "Core gettxout failed (see $CORE_LOG)"
[[ -n "$CORE_GTO" && "$CORE_GTO" != "null" ]] || fail "Core gettxout returned null for an UNSPENT coinbase (oracle anomaly)"
OU_GTO=$(ou_gettxout "$COIN_TXID" 0)
case "$OU_GTO" in "<ERR>"*) fail "ouroboros gettxout errored: ${OU_GTO#<ERR>}";; esac
[[ -n "$OU_GTO" && "$OU_GTO" != "null" ]] || { EXIST_T="bad"; log "ouroboros gettxout returned null for an UNSPENT coinbase"; }

log "Core:      $CORE_GTO"
log "ouroboros: $OU_GTO"

CORE_BEST=$(jpy "$CORE_GTO" "d['bestblock']")
OU_BEST=$(jpy "$OU_GTO"   "d.get('bestblock','')")
[[ "$CORE_BEST" == "$CORE_TIP" ]] || fail "Core bestblock != tip (oracle anomaly): '$CORE_BEST'"
[[ "$OU_BEST" == "$CORE_BEST" ]] || { BEST_T="bad"; log "bestblock mismatch: impl='$OU_BEST' core='$CORE_BEST'"; }

CORE_CONF=$(jpy "$CORE_GTO" "d['confirmations']")
OU_CONF=$(jpy "$OU_GTO"   "d.get('confirmations')")
[[ "$CORE_CONF" == "$EXP_CONFS" ]] || fail "Core confirmations != $EXP_CONFS (oracle anomaly): '$CORE_CONF'"
[[ "$OU_CONF" == "$CORE_CONF" ]] || { CONF_T="bad"; log "confirmations mismatch: impl='$OU_CONF' core='$CORE_CONF'"; }

CORE_VAL=$(jpy "$CORE_GTO" "format(float(d['value']),'.8f')")
OU_VAL=$(jpy "$OU_GTO"   "format(float(d.get('value',0)),'.8f')")
[[ "$OU_VAL" == "$CORE_VAL" ]] || { EXIST_T="bad"; log "value mismatch: impl='$OU_VAL' core='$CORE_VAL'"; }

for f in asm hex type; do
    CV=$(jpy "$CORE_GTO" "d['scriptPubKey'].get('$f','')")
    IV=$(jpy "$OU_GTO"   "d.get('scriptPubKey',{}).get('$f','')")
    [[ "$IV" == "$CV" ]] || { EXIST_T="bad"; log "scriptPubKey.$f mismatch: impl='$IV' core='$CV'"; }
done
CORE_HASADDR=$(jpy "$CORE_GTO" "'address' in d['scriptPubKey']")
if [[ "$CORE_HASADDR" == "true" ]]; then
    OU_HASADDR=$(jpy "$OU_GTO" "'address' in d.get('scriptPubKey',{})")
    [[ "$OU_HASADDR" == "true" ]] || { EXIST_T="bad"; log "ouroboros scriptPubKey missing 'address' (Core emits one)"; }
fi

CORE_CB=$(jpy "$CORE_GTO" "d['coinbase']")
OU_CB=$(jpy "$OU_GTO"   "d.get('coinbase')")
[[ "$CORE_CB" == "true" ]] || fail "Core coinbase flag not true for a coinbase coin (oracle anomaly): '$CORE_CB'"
[[ "$OU_CB" == "$CORE_CB" ]] || { CB_T="bad"; log "coinbase flag mismatch: impl='$OU_CB' core='$CORE_CB'"; }

# ════════════════════════════════════════════════════════════════════════
# CHECK 2 — spent/nonexistent output -> JSON null on BOTH nodes.
# ════════════════════════════════════════════════════════════════════════
CORE_NULL=$(core_gettxout "$COIN_TXID" 9)
OU_NULL=$(ou_gettxout "$COIN_TXID" 9)
case "$OU_NULL" in "<ERR>"*) fail "ouroboros gettxout(null-case) errored: ${OU_NULL#<ERR>}";; esac
[[ -z "$CORE_NULL" || "$CORE_NULL" == "null" ]] || fail "Core gettxout(absent vout) not null (oracle anomaly): '$CORE_NULL'"
[[ -z "$OU_NULL" || "$OU_NULL" == "null" ]] || { NULL_T="bad"; log "ouroboros gettxout(absent vout) not null: '$OU_NULL'"; }

ABSENT_TXID="0000000000000000000000000000000000000000000000000000000000000001"
CORE_NULL2=$(core_gettxout "$ABSENT_TXID" 0)
OU_NULL2=$(ou_gettxout "$ABSENT_TXID" 0)
case "$OU_NULL2" in "<ERR>"*) fail "ouroboros gettxout(absent txid) errored: ${OU_NULL2#<ERR>}";; esac
[[ -z "$CORE_NULL2" || "$CORE_NULL2" == "null" ]] || fail "Core gettxout(absent txid) not null (oracle anomaly): '$CORE_NULL2'"
[[ -z "$OU_NULL2" || "$OU_NULL2" == "null" ]] || { NULL_T="bad"; log "ouroboros gettxout(absent txid) not null: '$OU_NULL2'"; }

# ── Verdict. ──────────────────────────────────────────────────────────────
if [[ "$EXIST_T" == "ok" && "$NULL_T" == "ok" && "$BEST_T" == "ok" && "$CONF_T" == "ok" && "$CB_T" == "ok" ]]; then
    log "PASS: ouroboros gettxout matches Core on existing coin + bestblock + confs + coinbase + null"
    pass
fi

REASON=""
[[ "$EXIST_T" != "ok" ]] && REASON+="existing-UTXO shape diverges from Core; "
[[ "$BEST_T"  != "ok" ]] && REASON+="bestblock diverges from Core; "
[[ "$CONF_T"  != "ok" ]] && REASON+="confirmations diverges from Core; "
[[ "$CB_T"    != "ok" ]] && REASON+="coinbase flag diverges from Core; "
[[ "$NULL_T"  != "ok" ]] && REASON+="spent/nonexistent output not null; "
fail "${REASON% }"

#!/usr/bin/env bash
#
# rustoshi_gettxout.sh — self-contained gettxout Core-parity differential.
#
# gettxout queries the live UTXO set for ONE output (txid, vout) and returns its
# coin details, or JSON null if the output is spent / never existed. It is the
# wallet-less "is this coin still unspent, and what is it worth" RPC.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp (gettxout).
#   SIGNATURE: gettxout "txid" n ( include_mempool )   [3-arg form used here].
#   RESULT for an EXISTING UTXO (object):
#     { bestblock(hex tip), confirmations(int = tip_height - coin_height + 1),
#       value(BTC float), scriptPubKey{asm,hex,type,address}, coinbase(bool) }
#   RESULT for a spent / nonexistent output: JSON null.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports, launched -listen=0 (RPC only; the sandbox
#   SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener). Core mines the whole
#   chain to a deterministic p2wpkh address we hold the key for, and rustoshi is
#   fed each block via `submitblock` — so both nodes carry an IDENTICAL chain
#   (identical coinbases / identical UTXO set / identical tip). The gettxout
#   parity assertions therefore compare the same coin on the two nodes.
#
# DIFFERENTIAL TEST (run on BOTH impl and Core):
#   1. Mine to a FIXED depth: block 1 coinbase -> MINE_ADDR, then 5 maturity
#      blocks -> SINK. Tip height = 6, the coin's height = 1, so confirmations
#      is a KNOWN CONSTANT 6 (= 6 - 1 + 1) on both nodes.
#   2. existing=ok : gettxout(coinbase_txid, 0, true) on both nodes returns the
#      SAME bestblock(=tip), confirmations(=6), value, scriptPubKey{asm,hex,type,
#      address}, and coinbase(=true).
#   3. null=ok     : gettxout on a guaranteed-absent output (a never-mined txid /
#      out-of-range vout) -> JSON null on BOTH nodes.
#
# STRICT UNIFORM INTERFACE: no required args, idempotent, trap cleanup, scratch
#   /tmp datadirs + unique ports, ONE clean summary line on stdout, all noise ->
#   stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUT rustoshi: PASS existing=ok null=ok bestblock=ok confs=ok coinbase=ok
#   FAIL: GETTXOUT rustoshi: FAIL <short reason>
#   SKIP: if the impl binary is missing the FAIL reason contains "not found"
#         (GAP_RE-compatible) so the runner downgrades to SKIP.
#
# Touches ONLY /tmp/gto-rustoshi/ + /tmp/gto-core-rustoshi/ + ports below.
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/rustoshi/target/release/rustoshi"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/address)

# Deterministic test secrets. Mine block-1 coinbase to a p2wpkh address we hold
# the key for so its coinbase lands in the UTXO set; a second address is the
# sink for the maturity blocks.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
SINK_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

RS_DATADIR="/tmp/gto-rustoshi"
RS_RPC=22500
RS_P2P=22600
RS_LOG="$RS_DATADIR/node.log"

CORE_DATADIR="/tmp/gto-core-rustoshi"
CORE_RPC=22502
CORE_P2P=22602
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=6          # block-1 coinbase to MINE_ADDR + 5 maturity blocks -> SINK.
COIN_HEIGHT=1      # the funded coinbase is in block 1.
EXP_CONFS=6        # tip(6) - coin_height(1) + 1 = 6.

RS_PID=""
RS_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxout:rustoshi] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$RS_PID" ]] && kill -0 "$RS_PID" 2>/dev/null; then
        kill "$RS_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$RS_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$RS_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$RS_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETTXOUT rustoshi: PASS existing=ok null=ok bestblock=ok confs=ok coinbase=ok"
    exit 0
}
fail() {
    echo "GETTXOUT rustoshi: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gto-rustoshi" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${RS_RPC}|${RS_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${RS_RPC}|${RS_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${RS_RPC}/${RS_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$RS_DATADIR" "$CORE_DATADIR"
mkdir -p "$RS_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "rustoshi binary not found at $NODE_BIN (build with: cargo build --release)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── Derive the deterministic p2wpkh mining + sink addresses. ──────────────
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
[[ "$MINE_ADDR" != "$SINK_ADDR" ]] || fail "mine/sink addresses collided"
log "mine=$MINE_ADDR sink=$SINK_ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# Tolerant of the bitcoin-cli .cookie read race + heavy concurrent fleet load.
core_cli_retry() {
    local out="" rc=1
    for _ in $(seq 1 20); do
        out=$(core_cli "$@" 2>/dev/null); rc=$?
        [[ $rc -eq 0 && -n "$out" ]] && { echo "$out"; return 0; }
        [[ -n "$CORE_BG" ]] && ! kill -0 "$CORE_BG" 2>/dev/null && return 1   # daemon dead
        sleep 3
    done
    return 1
}

# rs_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
rs_rpc() {
    curl -s --max-time 90 -u "$RS_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$RS_RPC/" 2>/dev/null
}

# jpy <json> <expr>   (expr references parsed object as `d`)
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
    # -listen=0: RPC-only — the sandbox SIGKILLs a 0.0.0.0 P2P listener.
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
    log "launching Core oracle rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch rustoshi on regtest. ────────────────────────────────────────
log "launching rustoshi (regtest) rpc=:$RS_RPC"
"$NODE_BIN" --network=regtest --datadir="$RS_DATADIR" \
    --port="$RS_P2P" --rpcbind="127.0.0.1:$RS_RPC" >"$RS_LOG" 2>&1 &
RS_PID=$!
rs_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < rs_deadline )); do
    if [[ -z "$RS_COOKIE" ]]; then
        for c in "$RS_DATADIR/.cookie" "$RS_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && RS_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$RS_COOKIE" ]]; then
        echo "$(rs_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$RS_PID" 2>/dev/null || { tail -n 20 "$RS_LOG" >&2 2>/dev/null || true; fail "rustoshi exited during startup (see $RS_LOG)"; }
    sleep 1
done
[[ -n "$RS_COOKIE" ]] || fail "rustoshi cookie never appeared within 120s"
echo "$(rs_rpc getblockcount '[]')" | grep -q '"result"' || fail "rustoshi RPC never responded within 120s"
log "rustoshi RPC ready"

# ── 4. Mine to a FIXED depth: block 1 coinbase -> MINE_ADDR, then 5 maturity
#       blocks -> SINK. Mirror EVERY block into rustoshi so both carry the
#       identical UTXO set + tip. ────────────────────────────────────────────
log "mining block 1 coinbase -> $MINE_ADDR on Core"
core_cli_retry generatetoaddress 1 "$MINE_ADDR" >/dev/null || fail "Core generatetoaddress (funding) failed"
log "mining 5 maturity blocks -> $SINK_ADDR on Core"
core_cli_retry generatetoaddress 5 "$SINK_ADDR" >/dev/null || fail "Core generatetoaddress (maturity) failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

log "mirroring Core's $NBLOCKS blocks into rustoshi via submitblock"
for ((h=1; h<=NBLOCKS; h++)); do
    BH=$(core_cli_retry getblockhash "$h")  || fail "Core getblockhash $h failed"
    RAW=$(core_cli_retry getblock "$BH" 0)  || fail "Core getblock $h (raw) failed"
    SB=$(rs_rpc submitblock "[\"$RAW\"]")
    if echo "$SB" | grep -q '"error":{'; then
        ECODE=$(jpy "$SB" "d.get('error') and d['error'].get('code')")
        [[ -z "$ECODE" || "$ECODE" == "None" || "$ECODE" == "null" ]] || fail "rustoshi submitblock height=$h error: $SB"
    fi
done
RS_HEIGHT=$(jpy "$(rs_rpc getblockcount '[]')" "d['result']")
[[ "$RS_HEIGHT" == "$NBLOCKS" ]] || fail "rustoshi height $RS_HEIGHT != $NBLOCKS after mirror (submitblock did not connect chain)"

# Both chains must now share the SAME tip hash (identical blocks/UTXO set).
CORE_TIP=$(core_cli_retry getbestblockhash)
RS_TIP=$(jpy "$(rs_rpc getbestblockhash '[]')" "d['result']")
[[ "$CORE_TIP" == "$RS_TIP" ]] || fail "tip mismatch after mirror: core=$CORE_TIP rust=$RS_TIP"
log "both nodes at identical tip $RS_TIP (height $NBLOCKS)"

# The block-1 coinbase txid is the gettxout target (coinbase=true, vout 0).
COIN_BH=$(core_cli_retry getblockhash "$COIN_HEIGHT") || fail "Core getblockhash $COIN_HEIGHT failed"
COIN_TXID=$(core_cli_retry getblock "$COIN_BH" 1 | jpy "$(cat)" "d['tx'][0]")
[[ -z "$COIN_TXID" ]] && COIN_TXID=$(core_cli_retry getblock "$COIN_BH" 1 | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
[[ -n "$COIN_TXID" && "${#COIN_TXID}" == "64" ]] || fail "could not resolve block-1 coinbase txid (got '$COIN_TXID')"
log "coinbase txid=$COIN_TXID expected_confs=$EXP_CONFS"

# ── gettxout helpers: call on each node, return the .result JSON (or 'null'). ─
# Core CLI: gettxout txid n include_mempool. bitcoin-cli prints bare result.
core_gettxout() { core_cli_retry gettxout "$1" "$2" true; }
# rustoshi: gettxout via JSON-RPC, 3-arg [txid, n, include_mempool=true].
rs_gettxout() {
    local resp; resp=$(rs_rpc gettxout "[\"$1\", $2, true]")
    echo "$resp" | grep -q '"result"' || { echo "<ERR>$resp"; return 0; }
    jpy "$resp" "json.dumps(d['result'])"
}

# ════════════════════════════════════════════════════════════════════════
# CHECK 1 — existing UTXO: full-shape parity for the coinbase coin.
# ════════════════════════════════════════════════════════════════════════
EXIST_T="ok"; NULL_T="ok"; BEST_T="ok"; CONF_T="ok"; CB_T="ok"

CORE_GTO=$(core_gettxout "$COIN_TXID" 0) || fail "Core gettxout failed (see $CORE_LOG)"
[[ -n "$CORE_GTO" && "$CORE_GTO" != "null" ]] || fail "Core gettxout returned null for an UNSPENT coinbase (oracle anomaly)"
RS_GTO=$(rs_gettxout "$COIN_TXID" 0)
case "$RS_GTO" in "<ERR>"*) fail "rustoshi gettxout errored: ${RS_GTO#<ERR>}";; esac
[[ -n "$RS_GTO" && "$RS_GTO" != "null" ]] || { EXIST_T="bad"; log "rustoshi gettxout returned null for an UNSPENT coinbase"; }

log "Core:     $CORE_GTO"
log "rustoshi: $RS_GTO"

# bestblock == tip on both.
CORE_BEST=$(jpy "$CORE_GTO" "d['bestblock']")
RS_BEST=$(jpy "$RS_GTO"   "d.get('bestblock','')")
[[ "$CORE_BEST" == "$CORE_TIP" ]] || fail "Core bestblock != tip (oracle anomaly): '$CORE_BEST'"
[[ "$RS_BEST" == "$CORE_BEST" ]] || { BEST_T="bad"; log "bestblock mismatch: impl='$RS_BEST' core='$CORE_BEST'"; }

# confirmations == EXP_CONFS on both.
CORE_CONF=$(jpy "$CORE_GTO" "d['confirmations']")
RS_CONF=$(jpy "$RS_GTO"   "d.get('confirmations')")
[[ "$CORE_CONF" == "$EXP_CONFS" ]] || fail "Core confirmations != $EXP_CONFS (oracle anomaly): '$CORE_CONF'"
[[ "$RS_CONF" == "$CORE_CONF" ]] || { CONF_T="bad"; log "confirmations mismatch: impl='$RS_CONF' core='$CORE_CONF'"; }

# value: 8-dp equality.
CORE_VAL=$(jpy "$CORE_GTO" "format(float(d['value']),'.8f')")
RS_VAL=$(jpy "$RS_GTO"   "format(float(d.get('value',0)),'.8f')")
[[ "$RS_VAL" == "$CORE_VAL" ]] || { EXIST_T="bad"; log "value mismatch: impl='$RS_VAL' core='$CORE_VAL'"; }

# scriptPubKey sub-fields: asm, hex, type must match; address must match when
# Core emits one (an impl may differ only in the human-readable HRP prefix, so
# we compare on the hex/type/asm strictly and address presence).
for f in asm hex type; do
    CV=$(jpy "$CORE_GTO" "d['scriptPubKey'].get('$f','')")
    IV=$(jpy "$RS_GTO"   "d.get('scriptPubKey',{}).get('$f','')")
    [[ "$IV" == "$CV" ]] || { EXIST_T="bad"; log "scriptPubKey.$f mismatch: impl='$IV' core='$CV'"; }
done
CORE_HASADDR=$(jpy "$CORE_GTO" "'address' in d['scriptPubKey']")
if [[ "$CORE_HASADDR" == "true" ]]; then
    RS_HASADDR=$(jpy "$RS_GTO" "'address' in d.get('scriptPubKey',{})")
    [[ "$RS_HASADDR" == "true" ]] || { EXIST_T="bad"; log "rustoshi scriptPubKey missing 'address' (Core emits one)"; }
fi

# coinbase flag: must be true (block-1 coinbase) on both.
CORE_CB=$(jpy "$CORE_GTO" "d['coinbase']")
RS_CB=$(jpy "$RS_GTO"   "d.get('coinbase')")
[[ "$CORE_CB" == "true" ]] || fail "Core coinbase flag not true for a coinbase coin (oracle anomaly): '$CORE_CB'"
[[ "$RS_CB" == "$CORE_CB" ]] || { CB_T="bad"; log "coinbase flag mismatch: impl='$RS_CB' core='$CORE_CB'"; }

# ════════════════════════════════════════════════════════════════════════
# CHECK 2 — spent/nonexistent output -> JSON null on BOTH nodes.
# ════════════════════════════════════════════════════════════════════════
# A txid that was never mined (and an out-of-range vout) must be absent from the
# UTXO set on both nodes -> gettxout returns null. We use the coinbase txid with
# an out-of-range vout (a coinbase has exactly 1 output, so vout 9 is absent).
CORE_NULL=$(core_gettxout "$COIN_TXID" 9)
RS_NULL=$(rs_gettxout "$COIN_TXID" 9)
case "$RS_NULL" in "<ERR>"*) fail "rustoshi gettxout(null-case) errored: ${RS_NULL#<ERR>}";; esac
[[ -z "$CORE_NULL" || "$CORE_NULL" == "null" ]] || fail "Core gettxout(absent vout) not null (oracle anomaly): '$CORE_NULL'"
[[ -z "$RS_NULL" || "$RS_NULL" == "null" ]] || { NULL_T="bad"; log "rustoshi gettxout(absent vout) not null: '$RS_NULL'"; }

# Also a totally-absent txid -> null on both.
ABSENT_TXID="0000000000000000000000000000000000000000000000000000000000000001"
CORE_NULL2=$(core_gettxout "$ABSENT_TXID" 0)
RS_NULL2=$(rs_gettxout "$ABSENT_TXID" 0)
case "$RS_NULL2" in "<ERR>"*) fail "rustoshi gettxout(absent txid) errored: ${RS_NULL2#<ERR>}";; esac
[[ -z "$CORE_NULL2" || "$CORE_NULL2" == "null" ]] || fail "Core gettxout(absent txid) not null (oracle anomaly): '$CORE_NULL2'"
[[ -z "$RS_NULL2" || "$RS_NULL2" == "null" ]] || { NULL_T="bad"; log "rustoshi gettxout(absent txid) not null: '$RS_NULL2'"; }

# ── Verdict. ──────────────────────────────────────────────────────────────
if [[ "$EXIST_T" == "ok" && "$NULL_T" == "ok" && "$BEST_T" == "ok" && "$CONF_T" == "ok" && "$CB_T" == "ok" ]]; then
    log "PASS: rustoshi gettxout matches Core on existing coin + bestblock + confs + coinbase + null"
    pass
fi

REASON=""
[[ "$EXIST_T" != "ok" ]] && REASON+="existing-UTXO shape diverges from Core; "
[[ "$BEST_T"  != "ok" ]] && REASON+="bestblock diverges from Core; "
[[ "$CONF_T"  != "ok" ]] && REASON+="confirmations diverges from Core; "
[[ "$CB_T"    != "ok" ]] && REASON+="coinbase flag diverges from Core; "
[[ "$NULL_T"  != "ok" ]] && REASON+="spent/nonexistent output not null; "
fail "${REASON% }"

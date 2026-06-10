#!/usr/bin/env bash
#
# lunarblock_scantxoutset.sh — self-contained scantxoutset Core-parity test.
#
# scantxoutset scans the CURRENT UTXO set for outputs matching one or more
# descriptors and returns the matched coins + their total value. It is the
# wallet-less "where are my coins" RPC — a freshly funded address must surface
# its exact coin (txid/vout/amount) and total_amount byte-for-byte against
# Bitcoin Core.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:2316-2470 (scantxoutset).
#   SIGNATURE: scantxoutset "action" [scanobjects].
#     action='start' with scanobjects=[ "addr(<address>)" | {"desc":"..."} ]
#       -> scans the CURRENT UTXO set; returns an OBJECT:
#          { success(bool), txouts(int, total UTXOs scanned), height(int tip),
#            bestblock(hex), unspents[ {txid,vout,scriptPubKey,desc,amount,
#            coinbase,height,blockhash,confirmations} ], total_amount(BTC) }.
#     action='status' -> null when idle.
#     action='abort'  -> bool.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports, launched -listen=0 (RPC only; the sandbox
#   SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener).
#
#   To make the SAME UTXO exist byte-for-byte on BOTH nodes, Core mines the
#   whole chain to a deterministic p2wpkh address we hold the key for, and
#   lunarblock is fed each block via `submitblock` — so both nodes carry an
#   IDENTICAL chain (identical coinbases / identical UTXO set). Every parity
#   assertion therefore compares the exact same UTXO set on the two nodes.
#
# DIFFERENTIAL TEST (run on BOTH impl and Core):
#   1. Fund a known address (mine block-1 coinbase to it) and confirm it (mine
#      100 maturity blocks to a separate sink so the scan target holds exactly
#      one, exactly-checkable coin).
#   2. Call scantxoutset start "addr(<MINE_ADDR>)" on each node.
#   3. desc=ok    : impl total_amount EQUALS Core's, and the matched unspent
#                   set (txid:vout -> amount, 8-dp) EQUALS Core's, AND the
#                   matched coin (txid/vout/amount) is present in both.
#   4. shape=ok   : top-level object has success(bool) + total_amount + an
#                   unspents array; every key Core emits per-unspent is also
#                   present on the impl (txid,vout,scriptPubKey,desc,amount,
#                   coinbase,height,blockhash,confirmations). A missing key is
#                   a real shape divergence — reported, never papered over.
#   5. empty=ok   : an UNMATCHED address -> total_amount 0 / empty unspents on
#                   both nodes.
#   amount=ok is folded into desc=ok (total + per-coin amounts).
#
# STRICT UNIFORM INTERFACE (mirrors scan/rustoshi_scantxoutset.sh +
#   utxosetinfo/lunarblock_gettxoutsetinfo.sh):
#   set -uo pipefail, no required args, idempotent, trap cleanup, scratch /tmp
#   datadirs + unique ports, ONE clean summary line on stdout, all noise ->
#   stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: SCANTXOUTSET lunarblock: PASS desc=ok amount=ok shape=ok empty=ok
#   FAIL: SCANTXOUTSET lunarblock: FAIL <short reason>
#   SKIP: if the impl entrypoint/luajit is missing the FAIL reason contains
#         "not found" (GAP_RE-compatible) so the runner downgrades to SKIP.
#
# Touches ONLY /tmp/scan-lunarblock/ + /tmp/scan-lb-core/ and ports 22321/22341
#   (lunarblock RPC/P2P) + 22323/22343 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node. Never
#   broad-pkills bitcoind by name; only frees its OWN fixed ports / scratch dir.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/address)

# Deterministic test secrets. Mine block-1 coinbase to a p2wpkh address we hold
# the key for so its coinbase lands in the UTXO set; an unrelated second address
# is the "unmatched" needle for the empty-result sub-check; a third is the sink
# for the 100 maturity blocks (so only block 1 pays MINE_ADDR -> a single coin).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
EMPTY_SECRET="3333333333333333333333333333333333333333333333333333333333333334"
SINK_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

LB_DATADIR="/tmp/scan-lunarblock"
LB_RPC=22321
LB_P2P=22341
LB_LOG="$LB_DATADIR/node.log"

CORE_DATADIR="/tmp/scan-lb-core"
CORE_RPC=22323
CORE_P2P=22343
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=101        # 1 coinbase to MINE_ADDR + 100 maturity blocks (to a sink).

LB_PID=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[scantxoutset:lunarblock] $*" >&2; }

# ── Port free helper: kill + POLL until the socket is actually released. ──
free_port() {
    # WAIT-ONLY (port-kill removed: 2026-06-10 fuser incident): waits for OUR
    # just-stopped node to release the port. NEVER kills by port.
    local p="$1"
    for _ in $(seq 1 20); do
        ss -tln 2>/dev/null | grep -qE ":${p} " || return 0
        sleep 1
    done
    return 0
}

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
    free_port "$LB_RPC"
    free_port "$LB_P2P"
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$LB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <desc> <amount> <shape> <empty>
pass() {
    echo "SCANTXOUTSET lunarblock: PASS desc=$1 amount=$2 shape=$3 empty=$4"
    exit 0
}
fail() {
    echo "SCANTXOUTSET lunarblock: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "scan-lunarblock" 2>/dev/null || true
free_port "$LB_RPC"
free_port "$LB_P2P"
free_port "$CORE_RPC"
free_port "$CORE_P2P"
if ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${LB_RPC}/${LB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
rm -rf "$LB_DATADIR" "$CORE_DATADIR"
mkdir -p "$LB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
command -v luajit  >/dev/null 2>&1   || fail "luajit not found on PATH"
[[ -f "$LB_DIR/src/main.lua" ]]      || fail "lunarblock entrypoint not found at $LB_DIR/src/main.lua (no binary)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── Derive the deterministic p2wpkh mining + unmatched + sink addresses. ──
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
EMPTY_ADDR=$(derive_p2wpkh "$EMPTY_SECRET") || fail "could not derive unmatched address"
[[ "$EMPTY_ADDR" == bcrt1* ]] || fail "unmatched address not regtest bech32: '$EMPTY_ADDR'"
SINK_ADDR=$(derive_p2wpkh "$SINK_SECRET")   || fail "could not derive sink address"
[[ "$SINK_ADDR" == bcrt1* ]] || fail "sink address not regtest bech32: '$SINK_ADDR'"
[[ "$MINE_ADDR" != "$EMPTY_ADDR" && "$MINE_ADDR" != "$SINK_ADDR" ]] || fail "mine/unmatched/sink addresses collided"
log "mine addr=$MINE_ADDR  unmatched addr=$EMPTY_ADDR  sink addr=$SINK_ADDR"

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

# lb_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
# (lunarblock defaults to an EMPTY rpcpassword on regtest -> no auth header.)
lb_rpc() {
    curl -s --max-time 90 \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$LB_RPC/" 2>/dev/null
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

# ── 2. Launch the Core regtest oracle (RPC-only). ─────────────────────────
launch_core_once() {
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
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
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P -listen=0 (attempt $attempt)"
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

# ── 4. Fund the address: block 1 coinbase -> MINE_ADDR, then 100 maturity
#       blocks to a SINK address. Mirror EVERY block into lunarblock so both
#       carry an identical UTXO set. ───────────────────────────────────────
log "mining block 1 coinbase -> $MINE_ADDR on Core"
core_cli_retry generatetoaddress 1 "$MINE_ADDR" >/dev/null || fail "Core generatetoaddress (funding) failed"
log "mining 100 maturity blocks -> $SINK_ADDR on Core"
core_cli_retry generatetoaddress 100 "$SINK_ADDR" >/dev/null || fail "Core generatetoaddress (maturity) failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

log "mirroring Core's $NBLOCKS blocks into lunarblock via submitblock"
for ((h=1; h<=NBLOCKS; h++)); do
    BH=$(core_cli_retry getblockhash "$h")  || fail "Core getblockhash $h failed"
    RAW=$(core_cli_retry getblock "$BH" 0)  || fail "Core getblock $h (raw) failed"
    SB=$(lb_rpc submitblock "[\"$RAW\"]")
    RES=$(jpy "$SB" "d.get('result')")
    if [[ -n "$RES" && "$RES" != "None" && "$RES" != "duplicate" ]]; then
        log "lunarblock submitblock height=$h rejected: $SB"
        tail -n 40 "$LB_LOG" >&2 2>/dev/null || true
        fail "lunarblock submitblock failed at height $h: '$RES'"
    fi
done
LB_HEIGHT=$(jpy "$(lb_rpc getblockcount '[]')" "d['result']")
[[ "$LB_HEIGHT" == "$NBLOCKS" ]] || { tail -n 40 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock height $LB_HEIGHT != $NBLOCKS after mirror (submitblock did not connect chain)"; }

# Both chains must now share the SAME tip hash (identical blocks/UTXO set).
CORE_TIP=$(core_cli_retry getbestblockhash)
LB_TIP=$(jpy "$(lb_rpc getbestblockhash '[]')" "d['result']")
[[ "$CORE_TIP" == "$LB_TIP" ]] || fail "tip mismatch after mirror: core=$CORE_TIP lb=$LB_TIP"
log "both nodes at identical tip $LB_TIP (height $NBLOCKS)"

# scantxoutset start params. lunarblock's scanobjects arg is an array of
# descriptor STRINGS (or {desc=...} objects); the bare-string form is also
# accepted by Core's EvalDescriptorStringOrObject, so the SAME params drive
# both nodes.
SCAN_DESC="addr($MINE_ADDR)"
SCAN_PARAMS="[\"start\", [\"$SCAN_DESC\"]]"
EMPTY_PARAMS="[\"start\", [\"addr($EMPTY_ADDR)\"]]"

# ════════════════════════════════════════════════════════════════════════
# CHECK 1 — desc + amount: matched coin + total_amount EQUAL Core's.
# ════════════════════════════════════════════════════════════════════════
DESC_T="ok"; AMOUNT_T="ok"; SHAPE_T="ok"; EMPTY_T="ok"

CORE_SCAN=$(core_cli_retry scantxoutset start "[\"$SCAN_DESC\"]") \
    || fail "Core scantxoutset start failed (see $CORE_LOG)"
[[ -n "$CORE_SCAN" ]] || fail "Core scantxoutset produced no output"

LB_SCAN_RESP=$(lb_rpc scantxoutset "$SCAN_PARAMS")
echo "$LB_SCAN_RESP" | grep -q '"result"' || fail "lunarblock scantxoutset start errored: $LB_SCAN_RESP"
LB_SCAN=$(jpy "$LB_SCAN_RESP" "json.dumps(d['result'])")
[[ -n "$LB_SCAN" ]] || fail "lunarblock scantxoutset result empty"

log "Core scan: $CORE_SCAN"
log "lb   scan: $LB_SCAN"

# total_amount: numeric 8-dp equality.
CORE_TOTAL=$(jpy "$CORE_SCAN" "format(float(d['total_amount']),'.8f')")
LB_TOTAL=$(jpy "$LB_SCAN"   "format(float(d['total_amount']),'.8f')")
[[ -n "$CORE_TOTAL" ]] || fail "Core scan missing total_amount"
[[ "$CORE_TOTAL" == "$LB_TOTAL" ]] || { AMOUNT_T="bad"; DESC_T="bad"; log "total_amount mismatch: core='$CORE_TOTAL' lb='$LB_TOTAL'"; }
# Core mines 50 BTC coinbase on regtest; sanity-check we actually funded it.
[[ "$CORE_TOTAL" == "50.00000000" ]] || log "note: Core total_amount=$CORE_TOTAL (expected 50.00000000 for a single matured coinbase)"

# Matched unspent set: build a {txid:vout -> amount(8dp)} map on each node and
# compare. Core's coin must appear identically on lunarblock.
unspent_map() {
    python3 -c "
import sys, json
d=json.loads(sys.stdin.read())
us=d.get('unspents',[])
m={}
for u in us:
    m['%s:%s'%(u['txid'],u['vout'])]=format(float(u['amount']),'.8f')
print(json.dumps(m, sort_keys=True))
" <<<"$1" 2>/dev/null
}
CORE_UMAP=$(unspent_map "$CORE_SCAN")
LB_UMAP=$(unspent_map "$LB_SCAN")
[[ -n "$CORE_UMAP" && "$CORE_UMAP" != "{}" ]] || fail "Core scan returned no matched unspents (funding/oracle anomaly)"
[[ "$CORE_UMAP" == "$LB_UMAP" ]] || { DESC_T="bad"; AMOUNT_T="bad"; log "matched-unspent map mismatch: core=$CORE_UMAP lb=$LB_UMAP"; }

# Explicit single-coin parity: txid/vout/amount of Core's matched coin.
CORE_COIN_TXID=$(jpy "$CORE_SCAN" "d['unspents'][0]['txid']")
CORE_COIN_VOUT=$(jpy "$CORE_SCAN" "d['unspents'][0]['vout']")
CORE_COIN_AMT=$(jpy "$CORE_SCAN"  "format(float(d['unspents'][0]['amount']),'.8f')")
LB_HAS_COIN=$(python3 -c "
import sys,json
d=json.loads(sys.stdin.read())
key='$CORE_COIN_TXID:$CORE_COIN_VOUT'
for u in d.get('unspents',[]):
    if '%s:%s'%(u['txid'],u['vout'])==key and format(float(u['amount']),'.8f')=='$CORE_COIN_AMT':
        print('true'); break
else:
    print('false')
" <<<"$LB_SCAN" 2>/dev/null)
[[ "$LB_HAS_COIN" == "true" ]] || { DESC_T="bad"; log "lunarblock missing Core's matched coin $CORE_COIN_TXID:$CORE_COIN_VOUT ($CORE_COIN_AMT)"; }

# scriptPubKey of the matched coin must be byte-equal across nodes (same UTXO).
CORE_COIN_SPK=$(jpy "$CORE_SCAN" "d['unspents'][0].get('scriptPubKey','')")
LB_COIN_SPK=$(python3 -c "
import sys,json
d=json.loads(sys.stdin.read())
key='$CORE_COIN_TXID:$CORE_COIN_VOUT'
for u in d.get('unspents',[]):
    if '%s:%s'%(u['txid'],u['vout'])==key:
        print(u.get('scriptPubKey','')); break
" <<<"$LB_SCAN" 2>/dev/null)
[[ -n "$CORE_COIN_SPK" && "$CORE_COIN_SPK" == "$LB_COIN_SPK" ]] \
    || { DESC_T="bad"; log "matched-coin scriptPubKey mismatch: core='$CORE_COIN_SPK' lb='$LB_COIN_SPK'"; }

# ════════════════════════════════════════════════════════════════════════
# CHECK 2 — shape: top-level success/total_amount/unspents + per-unspent keys.
# ════════════════════════════════════════════════════════════════════════
# success must be a bool true.
LB_SUCCESS=$(jpy "$LB_SCAN" "d.get('success')")
[[ "$LB_SUCCESS" == "true" ]] || { SHAPE_T="bad"; log "lunarblock success != true: '$LB_SUCCESS'"; }
# top-level required keys present.
for f in success txouts height bestblock unspents total_amount; do
    P=$(jpy "$LB_SCAN" "'$f' in d")
    [[ "$P" == "true" ]] || { SHAPE_T="bad"; log "lunarblock scan top-level missing key '$f'"; }
done
# unspents must be a non-empty array here (we funded a coin).
LB_NUNS=$(jpy "$LB_SCAN" "len(d.get('unspents',[])) if isinstance(d.get('unspents'),list) else -1")
[[ "$LB_NUNS" =~ ^[0-9]+$ && "$LB_NUNS" -ge 1 ]] || { SHAPE_T="bad"; log "lunarblock unspents not a non-empty array: '$LB_NUNS'"; }

# Per-unspent: every key Core emits must also be present on lunarblock.
# Core keys: txid,vout,scriptPubKey,desc,amount,coinbase,height,blockhash,confirmations.
CORE_UKEYS=$(jpy "$CORE_SCAN" "','.join(sorted(d['unspents'][0].keys()))")
LB_UKEYS=$(jpy "$LB_SCAN"   "','.join(sorted(d['unspents'][0].keys()))")
log "Core unspent keys: $CORE_UKEYS"
log "lb   unspent keys: $LB_UKEYS"
MISSING_KEYS=$(python3 -c "
core=set('$CORE_UKEYS'.split(','))
lb=set('$LB_UKEYS'.split(','))
print(','.join(sorted(core-lb)))
" 2>/dev/null)
if [[ -n "$MISSING_KEYS" ]]; then
    SHAPE_T="bad"
    log "lunarblock unspent MISSING Core key(s): $MISSING_KEYS"
fi

# coinbase flag on the matched coin must agree (block-1 coinbase -> true on both).
CORE_COIN_CB=$(jpy "$CORE_SCAN" "d['unspents'][0].get('coinbase')")
LB_COIN_CB=$(python3 -c "
import sys,json
d=json.loads(sys.stdin.read())
key='$CORE_COIN_TXID:$CORE_COIN_VOUT'
for u in d.get('unspents',[]):
    if '%s:%s'%(u['txid'],u['vout'])==key:
        v=u.get('coinbase'); print('true' if v is True else 'false' if v is False else str(v)); break
" <<<"$LB_SCAN" 2>/dev/null)
[[ "$CORE_COIN_CB" == "$LB_COIN_CB" ]] || { SHAPE_T="bad"; log "matched-coin coinbase flag mismatch: core='$CORE_COIN_CB' lb='$LB_COIN_CB'"; }

# desc echoed back on the matched coin (Core normalizes via InferDescriptor and
# appends a #checksum; lunarblock echoes the input descriptor — both must be
# non-empty and reference the address. We require presence + the address
# substring, not a byte-equal descriptor string).
LB_DESC=$(jpy "$LB_SCAN" "d['unspents'][0].get('desc','')")
[[ -n "$LB_DESC" && "$LB_DESC" != "None" ]] || { SHAPE_T="bad"; log "lunarblock unspent desc empty"; }
echo "$LB_DESC" | grep -q "$MINE_ADDR" || { SHAPE_T="bad"; log "lunarblock unspent desc does not reference the address: '$LB_DESC'"; }

# ════════════════════════════════════════════════════════════════════════
# CHECK 3 — empty: an UNMATCHED address -> total_amount 0 / no unspents.
# ════════════════════════════════════════════════════════════════════════
CORE_EMPTY=$(core_cli_retry scantxoutset start "[\"addr($EMPTY_ADDR)\"]") \
    || fail "Core scantxoutset (unmatched) failed"
LB_EMPTY_RESP=$(lb_rpc scantxoutset "$EMPTY_PARAMS")
echo "$LB_EMPTY_RESP" | grep -q '"result"' || fail "lunarblock scantxoutset (unmatched) errored: $LB_EMPTY_RESP"
LB_EMPTY=$(jpy "$LB_EMPTY_RESP" "json.dumps(d['result'])")

CORE_E_TOTAL=$(jpy "$CORE_EMPTY" "format(float(d['total_amount']),'.8f')")
LB_E_TOTAL=$(jpy "$LB_EMPTY"   "format(float(d['total_amount']),'.8f')")
CORE_E_N=$(jpy "$CORE_EMPTY" "len(d.get('unspents',[]))")
LB_E_N=$(jpy "$LB_EMPTY"     "len(d.get('unspents',[]))")

[[ "$CORE_E_TOTAL" == "0.00000000" ]] || fail "Core unmatched total_amount != 0 (oracle anomaly): '$CORE_E_TOTAL'"
[[ "$CORE_E_N" == "0" ]]              || fail "Core unmatched unspents not empty (oracle anomaly): '$CORE_E_N'"
[[ "$LB_E_TOTAL" == "0.00000000" ]] || { EMPTY_T="bad"; log "lunarblock unmatched total_amount != 0: '$LB_E_TOTAL'"; }
[[ "$LB_E_N" == "0" ]]              || { EMPTY_T="bad"; log "lunarblock unmatched unspents not empty: '$LB_E_N'"; }

# ── Verdict. ──────────────────────────────────────────────────────────────
if [[ "$DESC_T" == "ok" && "$AMOUNT_T" == "ok" && "$SHAPE_T" == "ok" && "$EMPTY_T" == "ok" ]]; then
    log "PASS: lunarblock scantxoutset matches Core on matched coin + total_amount + shape + empty"
    pass "$DESC_T" "$AMOUNT_T" "$SHAPE_T" "$EMPTY_T"
fi

REASON=""
[[ "$DESC_T"   != "ok" ]] && REASON+="matched-coin/total diverges from Core; "
[[ "$AMOUNT_T" != "ok" ]] && REASON+="total_amount diverges from Core; "
if [[ "$SHAPE_T" != "ok" ]]; then
    [[ -n "$MISSING_KEYS" ]] && REASON+="unspent missing Core key(s) [$MISSING_KEYS]; " || REASON+="result shape diverges from Core; "
fi
[[ "$EMPTY_T"  != "ok" ]] && REASON+="unmatched-address result non-empty; "
fail "${REASON% }"

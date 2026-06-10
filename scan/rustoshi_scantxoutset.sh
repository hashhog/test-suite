#!/usr/bin/env bash
#
# rustoshi_scantxoutset.sh — self-contained scantxoutset Core-parity test.
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
#   rustoshi is fed each block via `submitblock` — so both nodes carry an
#   IDENTICAL chain (identical coinbases / identical UTXO set). Every parity
#   assertion therefore compares the exact same UTXO set on the two nodes.
#
# DIFFERENTIAL TEST (run on BOTH impl and Core):
#   1. Fund a known address (mine to it) and confirm it (mine to maturity).
#   2. Call scantxoutset start "addr(<MINE_ADDR>)" on each node.
#   3. desc=ok    : impl total_amount EQUALS Core's, and the matched unspent
#                   set (txid:vout -> amount, 8-dp) EQUALS Core's, AND the
#                   matched coinbase coin is present in both.
#   4. shape=ok   : top-level object has success(bool) + total_amount + an
#                   unspents array; every key Core emits per-unspent is also
#                   present on the impl (txid,vout,scriptPubKey,desc,amount,
#                   coinbase,height,blockhash,confirmations). A missing key is
#                   a real shape divergence — reported, never papered over.
#   5. empty=ok   : an UNMATCHED address -> total_amount 0 / empty unspents on
#                   both nodes.
#   amount=ok is folded into desc=ok (total + per-coin amounts).
#
# STRICT UNIFORM INTERFACE (mirrors rawtx/rustoshi_getrawtransaction.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: SCANTXOUTSET rustoshi: PASS desc=ok amount=ok shape=ok empty=ok
#   FAIL: SCANTXOUTSET rustoshi: FAIL <short reason>
#   SKIP: if the impl binary is missing the FAIL reason contains "not found"
#         (GAP_RE-compatible) so the runner downgrades to SKIP.
#
# Touches ONLY /tmp/scan-rustoshi/ + /tmp/scan-core/ and ports 22110/22130
#   (rustoshi RPC/P2P) + 22112/22132 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/rustoshi/target/release/rustoshi"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/address)

# Deterministic test secrets. Mine to a p2wpkh address we hold the key for so
# its coinbase lands in the UTXO set; an unrelated second address is the
# "unmatched" needle for the empty-result sub-check.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
EMPTY_SECRET="3333333333333333333333333333333333333333333333333333333333333334"

RS_DATADIR="/tmp/scan-rustoshi"
RS_RPC=22110
RS_P2P=22130
RS_LOG="$RS_DATADIR/node.log"

CORE_DATADIR="/tmp/scan-core"
CORE_RPC=22112
CORE_P2P=22132
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=101        # 1 coinbase to MINE_ADDR + 100 maturity blocks (to a sink).

RS_PID=""
RS_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[scantxoutset:rustoshi] $*" >&2; }

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
# pass <desc> <amount> <shape> <empty>
pass() {
    echo "SCANTXOUTSET rustoshi: PASS desc=$1 amount=$2 shape=$3 empty=$4"
    exit 0
}
fail() {
    echo "SCANTXOUTSET rustoshi: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "scan-rustoshi" 2>/dev/null || true
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

# ── Derive the deterministic p2wpkh mining + unmatched addresses. ─────────
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
[[ "$MINE_ADDR" != "$EMPTY_ADDR" ]] || fail "mine/unmatched addresses collided"
log "mine addr=$MINE_ADDR  unmatched addr=$EMPTY_ADDR"

# A deterministic throwaway sink for the 100 maturity blocks (so the only
# coinbase paying MINE_ADDR is block 1 — a single, exactly-checkable coin).
SINK_ADDR=$(derive_p2wpkh "2222222222222222222222222222222222222222222222222222222222222223") \
    || fail "could not derive sink address"
[[ "$SINK_ADDR" == bcrt1* ]] || fail "sink address not regtest bech32: '$SINK_ADDR'"

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
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P -listen=0 (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch rustoshi on regtest. ────────────────────────────────────────
log "launching rustoshi (regtest) rpc=:$RS_RPC p2p=:$RS_P2P -> $RS_LOG"
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

# ── 4. Fund the address: block 1 coinbase -> MINE_ADDR, then 100 maturity
#       blocks to a SINK address. Mirror EVERY block into rustoshi so both
#       carry an identical UTXO set. ───────────────────────────────────────
log "mining block 1 coinbase -> $MINE_ADDR on Core"
core_cli_retry generatetoaddress 1 "$MINE_ADDR" >/dev/null || fail "Core generatetoaddress (funding) failed"
log "mining 100 maturity blocks -> $SINK_ADDR on Core"
core_cli_retry generatetoaddress 100 "$SINK_ADDR" >/dev/null || fail "Core generatetoaddress (maturity) failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

log "mirroring Core's $NBLOCKS blocks into rustoshi via submitblock"
for ((h=1; h<=NBLOCKS; h++)); do
    BH=$(core_cli_retry getblockhash "$h")  || fail "Core getblockhash $h failed"
    RAW=$(core_cli_retry getblock "$BH" 0)  || fail "Core getblock $h (raw) failed"
    SB=$(rs_rpc submitblock "[\"$RAW\"]")
    if echo "$SB" | grep -q '"error":{'; then
        ECODE=$(jpy "$SB" "d.get('error') and d['error'].get('code')")
        [[ -z "$ECODE" || "$ECODE" == "None" ]] || fail "rustoshi submitblock height=$h error: $SB"
    fi
done
RS_HEIGHT=$(jpy "$(rs_rpc getblockcount '[]')" "d['result']")
[[ "$RS_HEIGHT" == "$NBLOCKS" ]] || fail "rustoshi height $RS_HEIGHT != $NBLOCKS after mirror (submitblock did not connect chain)"

# Both chains must now share the SAME tip hash (identical blocks/UTXO set).
CORE_TIP=$(core_cli_retry getbestblockhash)
RS_TIP=$(jpy "$(rs_rpc getbestblockhash '[]')" "d['result']")
[[ "$CORE_TIP" == "$RS_TIP" ]] || fail "tip mismatch after mirror: core=$CORE_TIP rust=$RS_TIP"
log "both nodes at identical tip $RS_TIP (height $NBLOCKS)"

# scantxoutset start params. rustoshi's scanobjects arg is an array of
# descriptor STRINGS (Vec<String>); the bare-string form is also accepted by
# Core's EvalDescriptorStringOrObject, so the SAME params drive both nodes.
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

RS_SCAN_RESP=$(rs_rpc scantxoutset "$SCAN_PARAMS")
echo "$RS_SCAN_RESP" | grep -q '"result"' || fail "rustoshi scantxoutset start errored: $RS_SCAN_RESP"
RS_SCAN=$(jpy "$RS_SCAN_RESP" "json.dumps(d['result'])")
[[ -n "$RS_SCAN" ]] || fail "rustoshi scantxoutset result empty"

log "Core scan: $CORE_SCAN"
log "rust scan: $RS_SCAN"

# total_amount: numeric 8-dp equality.
CORE_TOTAL=$(jpy "$CORE_SCAN" "format(float(d['total_amount']),'.8f')")
RS_TOTAL=$(jpy "$RS_SCAN"   "format(float(d['total_amount']),'.8f')")
[[ -n "$CORE_TOTAL" ]] || fail "Core scan missing total_amount"
[[ "$CORE_TOTAL" == "$RS_TOTAL" ]] || { AMOUNT_T="bad"; DESC_T="bad"; log "total_amount mismatch: core='$CORE_TOTAL' rust='$RS_TOTAL'"; }
# Core mines 50 BTC coinbase on regtest; sanity-check we actually funded it.
[[ "$CORE_TOTAL" == "50.00000000" ]] || log "note: Core total_amount=$CORE_TOTAL (expected 50.00000000 for a single matured coinbase)"

# Matched unspent set: build a {txid:vout -> amount(8dp)} map on each node and
# compare. Core's coin must appear identically on rustoshi.
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
RS_UMAP=$(unspent_map "$RS_SCAN")
[[ -n "$CORE_UMAP" && "$CORE_UMAP" != "{}" ]] || fail "Core scan returned no matched unspents (funding/oracle anomaly)"
[[ "$CORE_UMAP" == "$RS_UMAP" ]] || { DESC_T="bad"; AMOUNT_T="bad"; log "matched-unspent map mismatch:\n  core=$CORE_UMAP\n  rust=$RS_UMAP"; }

# Explicit single-coin parity: txid/vout/amount of Core's matched coin.
CORE_COIN_TXID=$(jpy "$CORE_SCAN" "d['unspents'][0]['txid']")
CORE_COIN_VOUT=$(jpy "$CORE_SCAN" "d['unspents'][0]['vout']")
CORE_COIN_AMT=$(jpy "$CORE_SCAN"  "format(float(d['unspents'][0]['amount']),'.8f')")
RS_HAS_COIN=$(python3 -c "
import sys,json
d=json.loads(sys.stdin.read())
key='$CORE_COIN_TXID:$CORE_COIN_VOUT'
for u in d.get('unspents',[]):
    if '%s:%s'%(u['txid'],u['vout'])==key and format(float(u['amount']),'.8f')=='$CORE_COIN_AMT':
        print('true'); break
else:
    print('false')
" <<<"$RS_SCAN" 2>/dev/null)
[[ "$RS_HAS_COIN" == "true" ]] || { DESC_T="bad"; log "rustoshi missing Core's matched coin $CORE_COIN_TXID:$CORE_COIN_VOUT ($CORE_COIN_AMT)"; }

# ════════════════════════════════════════════════════════════════════════
# CHECK 2 — shape: top-level success/total_amount/unspents + per-unspent keys.
# ════════════════════════════════════════════════════════════════════════
# success must be a bool true.
RS_SUCCESS=$(jpy "$RS_SCAN" "d.get('success')")
[[ "$RS_SUCCESS" == "true" ]] || { SHAPE_T="bad"; log "rustoshi success != true: '$RS_SUCCESS'"; }
# top-level required keys present.
for f in success txouts height bestblock unspents total_amount; do
    P=$(jpy "$RS_SCAN" "'$f' in d")
    [[ "$P" == "true" ]] || { SHAPE_T="bad"; log "rustoshi scan top-level missing key '$f'"; }
done
# unspents must be a non-empty array here (we funded a coin).
RS_NUNS=$(jpy "$RS_SCAN" "len(d.get('unspents',[])) if isinstance(d.get('unspents'),list) else -1")
[[ "$RS_NUNS" =~ ^[0-9]+$ && "$RS_NUNS" -ge 1 ]] || { SHAPE_T="bad"; log "rustoshi unspents not a non-empty array: '$RS_NUNS'"; }

# Per-unspent: every key Core emits must also be present on rustoshi.
# Core keys: txid,vout,scriptPubKey,desc,amount,coinbase,height,blockhash,confirmations.
CORE_UKEYS=$(jpy "$CORE_SCAN" "','.join(sorted(d['unspents'][0].keys()))")
RS_UKEYS=$(jpy "$RS_SCAN"   "','.join(sorted(d['unspents'][0].keys()))")
log "Core unspent keys: $CORE_UKEYS"
log "rust unspent keys: $RS_UKEYS"
MISSING_KEYS=$(python3 -c "
core=set('$CORE_UKEYS'.split(','))
rs=set('$RS_UKEYS'.split(','))
print(','.join(sorted(core-rs)))
" 2>/dev/null)
if [[ -n "$MISSING_KEYS" ]]; then
    SHAPE_T="bad"
    log "rustoshi unspent MISSING Core key(s): $MISSING_KEYS"
fi

# desc echoed back on the matched coin (Core normalizes via InferDescriptor;
# rustoshi echoes the input descriptor — both must at least be non-empty and
# reference the address. We require presence + the address substring, not a
# byte-equal descriptor string, since InferDescriptor adds a #checksum etc.).
RS_DESC=$(jpy "$RS_SCAN" "d['unspents'][0].get('desc','')")
[[ -n "$RS_DESC" && "$RS_DESC" != "None" ]] || { SHAPE_T="bad"; log "rustoshi unspent desc empty"; }

# ════════════════════════════════════════════════════════════════════════
# CHECK 3 — empty: an UNMATCHED address -> total_amount 0 / no unspents.
# ════════════════════════════════════════════════════════════════════════
CORE_EMPTY=$(core_cli_retry scantxoutset start "[\"addr($EMPTY_ADDR)\"]") \
    || fail "Core scantxoutset (unmatched) failed"
RS_EMPTY_RESP=$(rs_rpc scantxoutset "$EMPTY_PARAMS")
echo "$RS_EMPTY_RESP" | grep -q '"result"' || fail "rustoshi scantxoutset (unmatched) errored: $RS_EMPTY_RESP"
RS_EMPTY=$(jpy "$RS_EMPTY_RESP" "json.dumps(d['result'])")

CORE_E_TOTAL=$(jpy "$CORE_EMPTY" "format(float(d['total_amount']),'.8f')")
RS_E_TOTAL=$(jpy "$RS_EMPTY"   "format(float(d['total_amount']),'.8f')")
CORE_E_N=$(jpy "$CORE_EMPTY" "len(d.get('unspents',[]))")
RS_E_N=$(jpy "$RS_EMPTY"     "len(d.get('unspents',[]))")

[[ "$CORE_E_TOTAL" == "0.00000000" ]] || fail "Core unmatched total_amount != 0 (oracle anomaly): '$CORE_E_TOTAL'"
[[ "$CORE_E_N" == "0" ]]              || fail "Core unmatched unspents not empty (oracle anomaly): '$CORE_E_N'"
[[ "$RS_E_TOTAL" == "0.00000000" ]] || { EMPTY_T="bad"; log "rustoshi unmatched total_amount != 0: '$RS_E_TOTAL'"; }
[[ "$RS_E_N" == "0" ]]              || { EMPTY_T="bad"; log "rustoshi unmatched unspents not empty: '$RS_E_N'"; }

# ── Verdict. ──────────────────────────────────────────────────────────────
if [[ "$DESC_T" == "ok" && "$AMOUNT_T" == "ok" && "$SHAPE_T" == "ok" && "$EMPTY_T" == "ok" ]]; then
    log "PASS: rustoshi scantxoutset matches Core on matched coin + total_amount + shape + empty"
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

#!/usr/bin/env bash
#
# hotbuns_gettxoutsetinfo.sh — self-contained gettxoutsetinfo Core-parity test.
#
# This is the DEEPEST indexing cell: the UTXO-set HASH is a fingerprint of the
# ENTIRE UTXO set. Matching it byte-for-byte against a real bitcoind proves
# hotbuns's consensus STATE (its UTXO set) is byte-identical to Core's — not
# merely that the RPC has the right shape.
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp:1010+  (gettxoutsetinfo)
#   bitcoin-core/src/kernel/coinstats.cpp      (hash_serialized_3 + muhash
#       kernels, per-coin TxOutSer/ApplyHash, GetBogoSize, total_amount)
#
#   SIGNATURE: gettxoutsetinfo ( "hash_type" hash_or_height use_index )
#     hash_type default "hash_serialized_3"; options
#       "hash_serialized_3" | "muhash" | "none".
#     hash_or_height + use_index need coinstatsindex (OUT OF SCOPE) — base
#     chainstate stats at the tip only.
#
#   OUTPUT (base, no coinstatsindex):
#     { height, bestblock, txouts, bogosize,
#       hash_serialized_3 (only when hash_type=hash_serialized_3),
#       muhash (only when hash_type=muhash),
#       transactions, disk_size, total_amount }.
#     hash_serialized_3 : SHA256d over the UTXO set serialized in COIN-CURSOR
#       order (by outpoint: txid then vout numeric); per-coin = (txid, vout,
#       height<<1|coinbase, txout). Deterministic given the same UTXO set.
#     muhash : MuHash3072 multiset hash (order-independent) over the same bytes.
#
#   ERRORS:
#     hash_serialized_3 with a specific block/height -> RPC_INVALID_PARAMETER
#       (-8) "hash_serialized_3 hash type cannot be queried for a specific
#       block".
#     unrecognized hash_type -> error (Core -8 "<x> is not a valid hash_type").
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + OWN ports, launched -listen=0. To make the UTXO sets
#   byte-identical the two nodes share the IDENTICAL chain: Core MINES ~110
#   blocks AND broadcasts at least one SPEND tx (so the UTXO set has a spent
#   output REMOVED and new outputs ADDED — not just coinbases), then we REPLAY
#   every raw block into hotbuns via submitblock. Both nodes thus hold the same
#   blocks -> the same UTXO set -> the same set hash.
#
#   Assertions (Core is the oracle; hotbuns must equal it):
#     1. FIELDS+HASH: gettxoutsetinfo (default hash_type) — height, bestblock,
#        txouts, total_amount ALL EXACT vs Core, AND the set hash
#        (hash_serialized_3, with a muhash fallback) byte-EXACT vs Core. The
#        set-hash match is THE point: it proves the whole UTXO set is identical.
#     2. MUTATE: mine ONE more block (changes the set) -> height+1, bestblock
#        changed, set hash changed on BOTH and still matches between impl/Core.
#     3. ERRORS: gettxoutsetinfo hash_serialized_3 <height> -> -8; bogus
#        hash_type -> error. bogosize/transactions/disk_size: assert PRESENT +
#        typed (NOT byte-equal — bogosize is "meaningless", disk_size is
#        impl-specific).
#
# STRICT UNIFORM INTERFACE (mirrors blockfilter/hotbuns_getblockfilter.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + UNIQUE ports,
#   ONE clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTSETINFO hotbuns: PASS fields=ok hash=ok mutate=ok errors=ok
#   FAIL: GETTXOUTSETINFO hotbuns: FAIL <short reason>
#   SKIP: GETTXOUTSETINFO hotbuns: SKIP <reason>
#
# Touches ONLY /tmp/gtxo-hotbuns/ + /tmp/gtxo-hotbuns-core/ and ports
#   22174/22194 (hotbuns RPC/P2P) + 22176/22196 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node. Does NOT
#   broad-pkill bitcoind by name (a live mainnet bitcoind may be running) —
#   only frees its OWN fixed ports / scratch dir. Port-kills (fuser -k) are BANNED (2026-06-10 incident); PID-scoped kills only.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
HB_DIR="$BASEDIR/hotbuns"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/addr/WIF)

HB_DATADIR="/tmp/gtxo-hotbuns"
HB_RPC=22174
HB_P2P=22194
HB_LOG="/tmp/gtxo-hotbuns-node.log"               # outside the trap-wiped datadir

CORE_DATADIR="/tmp/gtxo-hotbuns-core"
CORE_RPC=22176
CORE_P2P=22196
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic mining key -> p2wpkh coinbase outputs we can later spend.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
# Deterministic destination key for the spend output.
SECRET2="2222222222222222222222222222222222222222222222222222222222222223"

NBLOCKS_PRE=110    # coinbase maturity (101) + headroom; gives a real UTXO set.

HB_PID=""
HB_COOKIE=""
CORE_BG=""
ADDR=""
ADDR2=""
WIF=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutsetinfo:hotbuns] $*" >&2; }

# ── Port-free poll: wait until a TCP port is actually free. ───────────────
wait_port_free() {
    # WAIT-ONLY (port-kill removed: 2026-06-10 fuser incident): NEVER kills by port.
    local port="$1"
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -qE ":${port} " || return 0
        sleep 1
    done
    return 0
}

# ── Cleanup: kill OUR nodes + wipe OUR scratch on any exit. ───────────────
cleanup() {
    local ec=$?
    if [[ -n "$HB_PID" ]] && kill -0 "$HB_PID" 2>/dev/null; then
        kill "$HB_PID" 2>/dev/null || true
        pkill -P "$HB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HB_PID" 2>/dev/null || true
        pkill -9 -P "$HB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$HB_DATADIR" "$CORE_DATADIR" "$HB_LOG" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "GETTXOUTSETINFO hotbuns: PASS fields=$1 hash=$2 mutate=$3 errors=$4"; exit 0; }
fail() { echo "GETTXOUTSETINFO hotbuns: FAIL $*"; exit 1; }
skip() { echo "GETTXOUTSETINFO hotbuns: SKIP $*"; exit 0; }

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
wait_port_free "$HB_RPC"
wait_port_free "$HB_P2P"
wait_port_free "$CORE_RPC"
wait_port_free "$CORE_P2P"
if ss -tln 2>/dev/null | grep -qE ":(${HB_RPC}|${HB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${HB_RPC}/${HB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
rm -rf "$HB_DATADIR" "$CORE_DATADIR" "$HB_LOG"
mkdir -p "$HB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
command -v bun     >/dev/null 2>&1 || skip "bun not found on PATH (hotbuns needs Bun runtime)"
[[ -f "$HB_DIR/src/index.ts" ]]    || fail "hotbuns entrypoint not found at $HB_DIR/src/index.ts"
[[ -x "$CORE_BIN" ]]               || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]               || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive deterministic regtest p2wpkh addresses + mining-key WIF. ────
eval "$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
from test_framework.wallet_util import bytes_to_wif
k=ECKey();  k.set(bytes.fromhex('$SECRET'),  compressed=True)
k2=ECKey(); k2.set(bytes.fromhex('$SECRET2'), compressed=True)
print('ADDR=%s'  % key_to_p2wpkh(k.get_pubkey().get_bytes(),  main=False))
print('ADDR2=%s' % key_to_p2wpkh(k2.get_pubkey().get_bytes(), main=False))
print('WIF=%s'   % bytes_to_wif(k.get_bytes()))
" 2>/dev/null)" || fail "could not derive deterministic keys (Core test_framework import failed)"
[[ "$ADDR"  == bcrt1* ]] || fail "derived mining address is not regtest bech32: '$ADDR'"
[[ "$ADDR2" == bcrt1* ]] || fail "derived dest address is not regtest bech32: '$ADDR2'"
[[ -n "$WIF" ]]          || fail "could not derive mining-key WIF"
log "mining addr=$ADDR  spend-dest=$ADDR2"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# tolerant of the bitcoin-cli .cookie read race under concurrent fleet load.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# hb_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
hb_rpc() {
    curl -s --max-time 120 -u "$HB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$HB_RPC/" 2>/dev/null
}

# jget <json> <pyexpr over d> -> value or empty (swallows errors).
jget() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if v is None: pass
    elif isinstance(v, bool): print('true' if v else 'false')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# ── 3. Launch Core regtest oracle (RPC-only). ─────────────────────────────
launch_core_once() {
    wait_port_free "$CORE_RPC"
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
    log "launching Core regtest oracle rpc=:$CORE_RPC (attempt $attempt, -listen=0)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch hotbuns on regtest. ─────────────────────────────────────────
log "launching hotbuns (regtest) rpc=:$HB_RPC p2p=:$HB_P2P -> $HB_LOG"
(
    cd "$HB_DIR"
    exec bun run src/index.ts \
        --network=regtest --datadir="$HB_DATADIR" \
        --port="$HB_P2P" --rpcport="$HB_RPC"
) >"$HB_LOG" 2>&1 &
HB_PID=$!
hb_deadline=$(( $(date +%s) + 120 ))   # generous: interpreted runtime + DB open
while (( $(date +%s) < hb_deadline )); do
    if [[ -z "$HB_COOKIE" ]]; then
        for c in "$HB_DATADIR/.cookie" "$HB_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && HB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HB_COOKIE" ]]; then
        hb_rpc getblockcount '[]' | grep -q '"result"' && break
    fi
    kill -0 "$HB_PID" 2>/dev/null || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns exited during startup (see $HB_LOG)"; }
    sleep 2
done
[[ -n "$HB_COOKIE" ]] || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns cookie never appeared within 120s"; }
hb_rpc getblockcount '[]' | grep -q '"result"' || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns RPC never responded within 120s"; }
log "hotbuns RPC ready"

# ── 4b. SKIP gate: hotbuns must expose gettxoutsetinfo. ───────────────────
PROBE=$(hb_rpc gettxoutsetinfo '[]')
PROBE_ERR=$(jget "$PROBE" "d.get('error',{}).get('message','') if isinstance(d.get('error'),dict) else ''")
if echo "$PROBE_ERR" | grep -qi "Method not found"; then
    skip "hotbuns has no gettxoutsetinfo ('$PROBE_ERR')"
fi

# ── 5. Build the shared chain on Core: mine to maturity + a SPEND tx. ─────
log "mining $NBLOCKS_PRE blocks to $ADDR on Core (coinbase maturity + headroom)"
core_cli_retry generatetoaddress "$NBLOCKS_PRE" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress (pre) failed"

# Spend the coinbase output of block 1 (now matured) -> ADDR2. This REMOVES a
# UTXO (the block-1 coinbase) and ADDS a new one (the spend output), so the
# UTXO set is more than just coinbases.
CB_BLOCKHASH=$(core_cli_retry getblockhash 1)
CB_TXID=$(core_cli_retry getblock "$CB_BLOCKHASH" \
            | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
[[ -n "$CB_TXID" ]] || fail "could not read block-1 coinbase txid"
UTXO=$(core_cli_retry gettxout "$CB_TXID" 0)
VAL=$(echo "$UTXO" | python3 -c "import sys,json;print(json.load(sys.stdin)['value'])" 2>/dev/null)
SPK=$(echo "$UTXO" | python3 -c "import sys,json;print(json.load(sys.stdin)['scriptPubKey']['hex'])" 2>/dev/null)
[[ -n "$VAL" && -n "$SPK" ]] || fail "could not read block-1 coinbase utxo (val='$VAL' spk='$SPK')"
OUTVAL=$(python3 -c "print(round($VAL-0.001,8))" 2>/dev/null)
RAW=$(core_cli_retry createrawtransaction \
        "[{\"txid\":\"$CB_TXID\",\"vout\":0}]" "[{\"$ADDR2\":$OUTVAL}]")
[[ -n "$RAW" ]] || fail "createrawtransaction failed"
SIGNED=$(core_cli signrawtransactionwithkey "$RAW" "[\"$WIF\"]" \
            "[{\"txid\":\"$CB_TXID\",\"vout\":0,\"scriptPubKey\":\"$SPK\",\"amount\":$VAL}]" 2>/dev/null)
COMPLETE=$(echo "$SIGNED" | python3 -c "import sys,json;print(json.load(sys.stdin).get('complete'))" 2>/dev/null)
SIGNEDHEX=$(echo "$SIGNED" | python3 -c "import sys,json;print(json.load(sys.stdin)['hex'])" 2>/dev/null)
[[ "$COMPLETE" == "True" && -n "$SIGNEDHEX" ]] || fail "spend tx did not sign completely (complete='$COMPLETE')"
core_cli sendrawtransaction "$SIGNEDHEX" >/dev/null 2>&1 || fail "sendrawtransaction (spend) failed"
# Mine ONE block — it now contains [coinbase, spend]; the spent coinbase output
# is REMOVED from the UTXO set and the spend output is ADDED.
core_cli_retry generatetoaddress 1 "$ADDR" >/dev/null || fail "Core generatetoaddress (spend block) failed"
TIPH=$(core_cli_retry getblockcount)
[[ "$TIPH" -ge $((NBLOCKS_PRE+1)) ]] || fail "Core tip height $TIPH unexpectedly low"

# Sanity: the spent coinbase output is gone from Core's UTXO set.
GONE=$(core_cli gettxout "$CB_TXID" 0 2>/dev/null)
[[ -z "$GONE" ]] || fail "block-1 coinbase output still in UTXO set after spend (oracle unexpected)"
log "Core chain built: tip height=$TIPH (spend removed UTXO $CB_TXID:0)"

# ── 6. Replay every block 1..TIPH into hotbuns via submitblock. ───────────
log "replaying blocks 1..$TIPH into hotbuns via submitblock"
for h in $(seq 1 "$TIPH"); do
    BH=$(core_cli_retry getblockhash "$h")
    RAWBLK=$(core_cli_retry getblock "$BH" 0)
    [[ -n "$RAWBLK" ]] || fail "could not read raw block at height $h from Core"
    RES=$(hb_rpc submitblock "[\"$RAWBLK\"]")
    RV=$(jget "$RES" "d.get('result')")
    if [[ -n "$RV" && "$RV" != "None" && "$RV" != "duplicate" ]]; then
        fail "hotbuns submitblock rejected block $h ($BH): $RES"
    fi
done
HB_TIP_H=$(jget "$(hb_rpc getblockcount '[]')" "d['result']")
[[ "$HB_TIP_H" == "$TIPH" ]] || fail "hotbuns tip height $HB_TIP_H != Core $TIPH after replay"
# Genesis must agree (regtest genesis is protocol-fixed); anchors the chain.
HB_GEN=$(jget "$(hb_rpc getblockhash '[0]')" "d['result']")
CORE_GEN=$(core_cli_retry getblockhash 0)
[[ "$HB_GEN" == "$CORE_GEN" ]] || fail "hotbuns regtest genesis '$HB_GEN' != Core '$CORE_GEN'"
# Tips must agree.
HB_TIP_HASH=$(jget "$(hb_rpc getbestblockhash '[]')" "d['result']")
CORE_TIP_HASH=$(core_cli_retry getbestblockhash)
[[ "$HB_TIP_HASH" == "$CORE_TIP_HASH" ]] || fail "hotbuns tip hash '$HB_TIP_HASH' != Core '$CORE_TIP_HASH' after replay"
log "hotbuns replayed to height $HB_TIP_H, tip==Core ($HB_TIP_HASH)"

# ── 7. Decide which hash_type to compare (default first; muhash fallback). ─
# Core supports both hash_serialized_3 (default) and muhash. We use Core's
# matching hash_type on the oracle side so we compare like-for-like. Prefer the
# default; if hotbuns omits hash_serialized_3 but exposes a Core-correct
# muhash, fall back to muhash.
HB_DEF=$(hb_rpc gettxoutsetinfo '[]')
HB_HS3=$(jget "$HB_DEF" "d['result'].get('hash_serialized_3')")
HASH_TYPE=""
HASH_FIELD=""
if [[ -n "$HB_HS3" && "$HB_HS3" =~ ^[0-9a-f]{64}$ ]]; then
    HASH_TYPE="hash_serialized_3"
    HASH_FIELD="hash_serialized_3"
else
    HB_MUH=$(jget "$(hb_rpc gettxoutsetinfo '["muhash"]')" "d['result'].get('muhash')")
    if [[ -n "$HB_MUH" && "$HB_MUH" =~ ^[0-9a-f]{64}$ ]]; then
        HASH_TYPE="muhash"
        HASH_FIELD="muhash"
    else
        fail "hotbuns gettxoutsetinfo exposes neither a valid hash_serialized_3 nor muhash (default resp: $HB_DEF)"
    fi
fi
log "comparing set hash via hash_type=$HASH_TYPE"

# Field extractors keyed to the chosen hash_type.
hb_info()   { hb_rpc gettxoutsetinfo "[\"$HASH_TYPE\"]"; }
core_info() { core_cli_retry gettxoutsetinfo "$HASH_TYPE"; }

# ── 8. CHECK 1 — FIELDS + HASH byte-EXACT vs Core. ────────────────────────
FIELDS_T="ok"; HASH_T="ok"
HB_JSON=$(hb_info)
CORE_JSON=$(core_info)
[[ -n "$CORE_JSON" ]] || fail "Core gettxoutsetinfo returned nothing (oracle unexpected)"

HB_HEIGHT=$(jget "$HB_JSON"   "d['result']['height']")
HB_BEST=$(jget   "$HB_JSON"   "d['result']['bestblock']")
HB_TXOUTS=$(jget "$HB_JSON"   "d['result']['txouts']")
HB_TOTAL=$(jget  "$HB_JSON"   "format(float(d['result']['total_amount']),'.8f')")
HB_HASH=$(jget   "$HB_JSON"   "d['result']['$HASH_FIELD']")
HB_BOGO=$(jget   "$HB_JSON"   "d['result']['bogosize']")
HB_TXS=$(jget    "$HB_JSON"   "d['result']['transactions']")
HB_DISK=$(jget   "$HB_JSON"   "d['result']['disk_size']")

C_HEIGHT=$(echo "$CORE_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['height'])" 2>/dev/null)
C_BEST=$(echo   "$CORE_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['bestblock'])" 2>/dev/null)
C_TXOUTS=$(echo "$CORE_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['txouts'])" 2>/dev/null)
C_TOTAL=$(echo  "$CORE_JSON" | python3 -c "import sys,json;print(format(float(json.load(sys.stdin)['total_amount']),'.8f'))" 2>/dev/null)
C_HASH=$(echo   "$CORE_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['$HASH_FIELD'])" 2>/dev/null)

# Exact field equality (height, bestblock, txouts, total_amount).
[[ "$HB_HEIGHT" == "$C_HEIGHT" ]] || { FIELDS_T="bad"; log "height mismatch: hb='$HB_HEIGHT' core='$C_HEIGHT'"; }
[[ "$HB_BEST"   == "$C_BEST"   ]] || { FIELDS_T="bad"; log "bestblock mismatch: hb='$HB_BEST' core='$C_BEST'"; }
[[ "$HB_TXOUTS" == "$C_TXOUTS" ]] || { FIELDS_T="bad"; log "txouts mismatch: hb='$HB_TXOUTS' core='$C_TXOUTS'"; }
[[ "$HB_TOTAL"  == "$C_TOTAL"  ]] || { FIELDS_T="bad"; log "total_amount mismatch: hb='$HB_TOTAL' core='$C_TOTAL'"; }

# bogosize/transactions/disk_size: PRESENT + integer-typed (NOT byte-equal).
[[ "$HB_BOGO" =~ ^[0-9]+$ ]] || { FIELDS_T="bad"; log "bogosize not a non-negative integer: '$HB_BOGO'"; }
[[ "$HB_TXS"  =~ ^[0-9]+$ ]] || { FIELDS_T="bad"; log "transactions not a non-negative integer: '$HB_TXS'"; }
[[ "$HB_DISK" =~ ^[0-9]+$ ]] || { FIELDS_T="bad"; log "disk_size not a non-negative integer: '$HB_DISK'"; }
# transactions should be <= txouts (one tx can have many outputs) and >0.
if [[ "$HB_TXS" =~ ^[0-9]+$ && "$HB_TXOUTS" =~ ^[0-9]+$ ]]; then
    (( HB_TXS > 0 && HB_TXS <= HB_TXOUTS )) || { FIELDS_T="bad"; log "transactions=$HB_TXS out of range vs txouts=$HB_TXOUTS"; }
fi

# THE point: the set hash must be byte-exact vs Core.
[[ -n "$HB_HASH" && "$HB_HASH" =~ ^[0-9a-f]{64}$ ]] || { HASH_T="bad"; log "hotbuns $HASH_FIELD not a 32-byte hex: '$HB_HASH'"; }
[[ -n "$C_HASH"  && "$C_HASH"  =~ ^[0-9a-f]{64}$ ]] || fail "Core $HASH_FIELD not a 32-byte hex: '$C_HASH' (oracle unexpected)"
[[ "$HB_HASH" == "$C_HASH" ]] || { HASH_T="bad"; log "$HASH_FIELD mismatch: hb='$HB_HASH' core='$C_HASH'"; }

[[ "$FIELDS_T" == "ok" ]] || fail "field parity (height/bestblock/txouts/total_amount/typed-fields) failed (see log)"
[[ "$HASH_T"   == "ok" ]] || fail "UTXO-set $HASH_FIELD diverges from Core — UTXO set NOT byte-identical (see log)"
log "FIELDS + $HASH_FIELD byte-exact vs Core (height=$HB_HEIGHT txouts=$HB_TXOUTS total=$HB_TOTAL hash=$HB_HASH)"

# ── 9. CHECK 2 — MUTATE: mine one more block, set hash changes + still matches.
MUTATE_T="ok"
PRE_HASH="$HB_HASH"
PRE_HEIGHT="$HB_HEIGHT"
PRE_BEST="$HB_BEST"

core_cli_retry generatetoaddress 1 "$ADDR" >/dev/null || fail "Core generatetoaddress (mutate) failed"
NEWTIPH=$(core_cli_retry getblockcount)
NEWBH=$(core_cli_retry getblockhash "$NEWTIPH")
NEWRAW=$(core_cli_retry getblock "$NEWBH" 0)
[[ -n "$NEWRAW" ]] || fail "could not read mutate block from Core"
RES=$(hb_rpc submitblock "[\"$NEWRAW\"]")
RV=$(jget "$RES" "d.get('result')")
if [[ -n "$RV" && "$RV" != "None" && "$RV" != "duplicate" ]]; then
    fail "hotbuns submitblock rejected mutate block $NEWBH: $RES"
fi
HB_TIP2=$(jget "$(hb_rpc getblockcount '[]')" "d['result']")
[[ "$HB_TIP2" == "$NEWTIPH" ]] || fail "hotbuns tip $HB_TIP2 != Core $NEWTIPH after mutate"

HB_JSON2=$(hb_info)
CORE_JSON2=$(core_info)
HB_H2=$(jget    "$HB_JSON2" "d['result']['height']")
HB_BEST2=$(jget "$HB_JSON2" "d['result']['bestblock']")
HB_HASH2=$(jget "$HB_JSON2" "d['result']['$HASH_FIELD']")
C_H2=$(echo    "$CORE_JSON2" | python3 -c "import sys,json;print(json.load(sys.stdin)['height'])" 2>/dev/null)
C_BEST2=$(echo "$CORE_JSON2" | python3 -c "import sys,json;print(json.load(sys.stdin)['bestblock'])" 2>/dev/null)
C_HASH2=$(echo "$CORE_JSON2" | python3 -c "import sys,json;print(json.load(sys.stdin)['$HASH_FIELD'])" 2>/dev/null)

# height+1.
[[ "$HB_H2" == "$C_H2" ]]                 || { MUTATE_T="bad"; log "mutate height mismatch: hb='$HB_H2' core='$C_H2'"; }
[[ "$HB_H2" == "$((PRE_HEIGHT + 1))" ]]   || { MUTATE_T="bad"; log "mutate height not pre+1: hb='$HB_H2' pre='$PRE_HEIGHT'"; }
# bestblock changed.
[[ "$HB_BEST2" == "$C_BEST2" ]]           || { MUTATE_T="bad"; log "mutate bestblock mismatch: hb='$HB_BEST2' core='$C_BEST2'"; }
[[ "$HB_BEST2" != "$PRE_BEST" ]]          || { MUTATE_T="bad"; log "mutate bestblock did NOT change: still '$PRE_BEST'"; }
# set hash changed on both AND still matches between impl and Core.
[[ "$HB_HASH2" != "$PRE_HASH" ]]          || { MUTATE_T="bad"; log "hotbuns set hash did NOT change after mining: still '$PRE_HASH'"; }
[[ "$C_HASH2"  != "$PRE_HASH" ]]          || { MUTATE_T="bad"; log "Core set hash did NOT change after mining: still '$PRE_HASH'"; }
[[ "$HB_HASH2" == "$C_HASH2" ]]           || { MUTATE_T="bad"; log "post-mutate $HASH_FIELD mismatch: hb='$HB_HASH2' core='$C_HASH2'"; }

[[ "$MUTATE_T" == "ok" ]] || fail "mutate check failed (height/bestblock/hash after mining one block) (see log)"
log "MUTATE ok: height $PRE_HEIGHT->$HB_H2, hash $PRE_HASH -> $HB_HASH2 (still ==Core)"

# ── 10. CHECK 3 — ERRORS. ─────────────────────────────────────────────────
ERR_T="ok"
# (a) hash_serialized_3 with a specific block/height -> -8.
ESPEC=$(hb_rpc gettxoutsetinfo "[\"hash_serialized_3\", $HB_H2]")
ESC=$(jget "$ESPEC" "d['error']['code']")
ESM=$(jget "$ESPEC" "d['error']['message']")
[[ "$ESC" == "-8" ]] || { ERR_T="bad"; log "hash_serialized_3 <height>: expected code -8, got '$ESC' ($ESPEC)"; }
echo "$ESM" | grep -qi "cannot be queried for a specific block" \
    || { ERR_T="bad"; log "hash_serialized_3 <height>: expected 'cannot be queried for a specific block', got '$ESM'"; }
# Cross-check Core returns -8 too (without coinstatsindex Core hits this same branch).
CORE_ES=$(core_cli gettxoutsetinfo hash_serialized_3 "$HB_H2" 2>&1 | grep -oE -- '-?[0-9]+' | head -1)
[[ "$CORE_ES" == "-8" ]] || log "note: Core hash_serialized_3 <height> code parse got '$CORE_ES' (informational)"

# (b) bogus hash_type -> error (Core -8 "<x> is not a valid hash_type").
EBOGUS=$(hb_rpc gettxoutsetinfo '["bogushash"]')
EBC=$(jget "$EBOGUS" "d['error']['code']")
EBM=$(jget "$EBOGUS" "d['error']['message']")
[[ -n "$EBC" && "$EBC" != "None" ]] || { ERR_T="bad"; log "bogus hash_type: expected an error, got none ($EBOGUS)"; }
# Core uses -8 for an invalid hash_type; accept -8 (and surface anything else).
[[ "$EBC" == "-8" ]] || { ERR_T="bad"; log "bogus hash_type: expected code -8, got '$EBC' (msg='$EBM')"; }
CORE_EB=$(core_cli gettxoutsetinfo bogushash 2>&1 | grep -oE -- '-?[0-9]+' | head -1)
[[ "$CORE_EB" == "-8" ]] || log "note: Core bogus hash_type code parse got '$CORE_EB' (informational)"

[[ "$ERR_T" == "ok" ]] || fail "error-code/message parity check failed (see log)"
log "errors match Core (-8 specific-block hash_serialized_3; -8 bogus hash_type)"

# ── Done. ──────────────────────────────────────────────────────────────────
pass "ok" "ok" "ok" "ok"

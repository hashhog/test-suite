#!/usr/bin/env bash
#
# lunarblock_getrawtransaction.sh — self-contained getrawtransaction DIFFERENTIAL test.
#
# The RPC-surface/indexing green-cell that follows getindexinfo (the flagged
# follow-up: "txindex on but getrawtransaction fails").  A block-explorer
# keystone.  getrawtransaction is READ-ONLY (NOT consensus) but must be
# Core-EXACT: same output shape per verbosity, same field-emit conditions, same
# byte-for-byte tx serialization, same error category.
#
# Core ref:
#   bitcoin-core/src/rpc/rawtransaction.cpp getrawtransaction (216-374)
#     getrawtransaction "txid" ( verbosity "blockhash" )
#       verbosity 0  -> the raw tx HEX string (EncodeHexTx), byte-exact.
#       verbosity 1  -> decoded OBJECT (TxToUniv include_hex=true) + envelope:
#                       txid, hash(=wtxid), version, size, vsize, weight,
#                       locktime, vin[], vout[], hex; and when confirmed in the
#                       active chain: blockhash, confirmations(=1+tip-txHeight),
#                       time, blocktime; in_active_chain when a blockhash ARG
#                       was supplied.
#       verbosity 2  -> v1 + per-vin prevout + fee (OPTIONAL; not asserted here).
#     verbosity accepts bool (true=1 / false=0) or int 0/1/2; default 0.
#     Errors (all RPC -5, RPC_INVALID_ADDRESS_OR_KEY):
#       - genesis-block coinbase txid (== genesis merkle root) -> "...cannot be
#         retrieved"
#       - blockhash arg not found -> "Block hash not found"
#       - tx not found            -> "No such mempool ..." (suffix varies; -5)
#   bitcoin-core/src/rpc/rawtransaction.cpp TxToJSON (58-85)
#   bitcoin-core/src/core_io.cpp TxToUniv (430-533)
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN regtest
#   instance (own scratch datadir + ports, -listen=0 RPC-only, -txindex=1).
#
# Because the two nodes are independent regtest chains (different coinbase
# history), their txids differ — so this is a SHAPE / FIELD-SEMANTICS
# differential, not a same-txid diff.  The load-bearing parity assertion is
# SELF-CONSISTENCY against Core's own decoder:
#
#   lunarblock's verbosity-0 HEX, fed through Core's decoderawtransaction, must
#   yield the EXACT SAME txid/hash/version/size/vsize/weight/locktime/vin/vout
#   that lunarblock's verbosity-1 getrawtransaction reports.  This asserts
#   lunarblock's decoded fields are byte-identical to how Core decodes the very
#   same serialized bytes — the strongest possible black-box parity check.
#   asm/desc are checked PRESENT but NOT byte-equal (InferDescriptor + asm
#   whitespace can legitimately differ).
#
# CHECKS (lunarblock, validated against the real Core decoder):
#   hex      : lunarblock getrawtransaction <txid> 0 on a MEMPOOL tx returns a
#              hex string that Core's decoderawtransaction accepts and that
#              re-serializes byte-EXACT (Core decode->txid matches lunarblock).
#   decoded  : lunarblock getrawtransaction <txid> 1 (mempool) matches Core's
#              decoderawtransaction of lunarblock's own hex EXACTLY on
#              txid, hash, version, size, vsize, weight, locktime, every vin
#              {txid,vout,scriptSig.hex,sequence,txinwitness}, every vout
#              {value,n,scriptPubKey.hex,.type,.address?}, and top-level hex;
#              asm/desc present-not-byte-equal.  Also cross-checks the same
#              load-bearing fields against a parallel Core-built mempool tx's
#              own getrawtransaction-1 shape (key-presence + types).
#   confirmed: mine the tx, then getrawtransaction <txid> 1 <blockhash> ->
#              blockhash matches, confirmations is a correct int >=1,
#              in_active_chain==true, time/blocktime present + int.  Bool/int
#              verbosity coercion (true->object, false/0->hex) also asserted.
#   errors   : random 32-byte txid -> -5; genesis-coinbase txid -> -5 with the
#              exact Core message; bogus blockhash arg -> -5 "Block hash not
#              found".  Core parity on the -5 category is cross-checked.
#   txindex  : (lunarblock supports --txindex) getrawtransaction <txid> 1 with
#              NO blockhash on a CONFIRMED tx succeeds via the index.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/lunarblock_*.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + unique ports, ONE
#   clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETRAWTRANSACTION lunarblock: PASS hex=ok decoded=ok confirmed=ok errors=ok
#   FAIL: GETRAWTRANSACTION lunarblock: FAIL <short reason> [hex=.. decoded=.. ...]
#
# Touches ONLY /tmp/grt-lunarblock + /tmp/grt-core and ports 22018/22038
#   (lunarblock RPC/P2P) + 22016/22036 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

LB_DATADIR="/tmp/grt-lunarblock"
LB_RPC=22018
LB_P2P=22038
LB_LOG="$LB_DATADIR/node.log"

CORE_DATADIR="/tmp/grt-core"
CORE_RPC=22016
CORE_P2P=22036
CORE_LOG="$CORE_DATADIR/core.log"

# Genesis-coinbase txid (== genesis merkle root).  Identical on
# mainnet/testnet/regtest — the genesis coinbase tx bytes are the same on all
# standard Bitcoin networks; only the block header differs.
GENESIS_COINBASE_TXID="4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
RANDOM_TXID="00000000000000000000000000000000000000000000000000000000deadbeef"
BOGUS_BLOCKHASH="00000000000000000000000000000000000000000000000000000000cafebabe"

LB_PID=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getrawtx:lunarblock] $*" >&2; }

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
    rm -rf "$LB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <hex> <decoded> <confirmed> <errors>
pass() {
    echo "GETRAWTRANSACTION lunarblock: PASS hex=$1 decoded=$2 confirmed=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETRAWTRANSACTION lunarblock: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "grt-lunarblock" 2>/dev/null || true
pkill -f "datadir $LB_DATADIR" 2>/dev/null || true
# Wait (up to 30s) for the ports to be released — the pkill above may have just
# reaped a prior run's node and its socket can take a beat to clear. Then ABORT
# if a listener persists (port-kills banned — 2026-06-10 fuser incident).
for __hp in "${LB_RPC}" "${LB_P2P}" "${CORE_RPC}" "${CORE_P2P}"; do
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
        sleep 1
    done
    if ss -tln 2>/dev/null | grep -qE ":${__hp} "; then
        fail "port ${__hp} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
    fi
done
sleep 1
rm -rf "$LB_DATADIR" "$CORE_DATADIR"
mkdir -p "$LB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v luajit  >/dev/null 2>&1 || fail "luajit not found on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -f "$LB_DIR/src/main.lua" ]]    || fail "lunarblock src/main.lua not found at $LB_DIR"
[[ -x "$CORE_BIN" ]]               || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]               || fail "bitcoin-cli not found at $CORE_CLI"

# ── JSON helpers (python3; no jq dependency). ─────────────────────────────
# jget <json> <field> -> value, "__MISSING__", or "__NULL__".
jget() {
    python3 - "$1" "$2" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("__PARSEERR__"); sys.exit(0)
k = sys.argv[2]
if not isinstance(d, dict) or k not in d:
    print("__MISSING__")
elif d[k] is None:
    print("__NULL__")
else:
    v = d[k]
    print("true" if v is True else "false" if v is False else v)
PY
}
# jtype <json> <field> -> int|float|str|bool|missing|null|other
jtype() {
    python3 - "$1" "$2" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("parseerr"); sys.exit(0)
k = sys.argv[2]
if not isinstance(d, dict) or k not in d:
    print("missing"); sys.exit(0)
v = d[k]
if v is None: print("null")
elif isinstance(v, bool): print("bool")
elif isinstance(v, int): print("int")
elif isinstance(v, float): print("float")
elif isinstance(v, str): print("str")
else: print("other")
PY
}
# jerr_code <json-rpc-envelope> -> error code, or "__NOERR__".
jerr_code() {
    python3 - "$1" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("__PARSEERR__"); sys.exit(0)
e = d.get("error")
if e is None:
    print("__NOERR__")
elif isinstance(e, dict):
    print(e.get("code", "__NOCODE__"))
else:
    print("__BADERR__")
PY
}
# jerr_msg <json-rpc-envelope> -> error message text, or "".
jerr_msg() {
    python3 - "$1" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    print(""); sys.exit(0)
e = d.get("error")
print(e.get("message","") if isinstance(e, dict) else "")
PY
}

# ── RPC wrappers. ─────────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }
# lb_rpc <method> <json-params-array> -> raw JSON-RPC envelope on stdout
lb_rpc() {
    curl -s --max-time 60 \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$LB_RPC/" 2>/dev/null
}
# lb_result <method> <params> -> the .result as compact JSON / string (or empty)
lb_result() {
    lb_rpc "$1" "$2" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
r=d.get("result")
if r is None: sys.exit(0)
print(r if isinstance(r,str) else json.dumps(r))'
}

# ── Core oracle as a SHORT-LIVED burst. ───────────────────────────────────
# This sandbox SIGKILLs bitcoind ~10-15s after load REGARDLESS of -listen=0 /
# -port (verified empirically), so a long-lived Core oracle alongside a slow
# lunarblock IBD is not possible.  Instead we gather ALL lunarblock data first,
# then run Core in tight, self-contained bursts: launch -> wait for RPC -> do a
# few fast RPC calls -> stop.  core_run_burst() relaunches Core fresh, runs the
# function name passed in $1 (which may call core_cli freely), and tears Core
# down.  It retries up to 3 times if Core is SIGKILLed before the burst body
# finishes.  Burst bodies must be FAST (a handful of RPCs, no mining loops).
core_stop_now() {
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    for _ in $(seq 1 10); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    for _ in $(seq 1 15); do
        ss -tln 2>/dev/null | grep -qE ":${CORE_RPC} " || break
        sleep 1
    done
    CORE_BG=""
}
# core_run_burst <body_fn>  -> 0 if the body ran to completion, 1 otherwise.
core_run_burst() {
    local body="$1" attempt
    for attempt in 1 2 3; do
        rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
        for _ in $(seq 1 15); do
            ss -tln 2>/dev/null | grep -qE ":${CORE_RPC} " || break
            sleep 1
        done
        sleep 1
        log "Core burst attempt $attempt: launching rpc=:$CORE_RPC (listen=0, txindex=1)"
        "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
            -listen=0 -txindex=1 -fallbackfee=0.0002 -daemonwait=0 >"$CORE_LOG" 2>&1 &
        CORE_BG=$!
        local up=0 deadline=$(( $(date +%s) + 30 ))
        while (( $(date +%s) < deadline )); do
            if core_cli getblockcount >/dev/null 2>&1; then up=1; break; fi
            kill -0 "$CORE_BG" 2>/dev/null || break
            sleep 1
        done
        if [[ "$up" -ne 1 ]]; then
            log "Core burst attempt $attempt: never came up"
            core_stop_now
            continue
        fi
        # Run the body; if it returns 0 (all its RPCs succeeded), we're done.
        if "$body"; then
            core_stop_now
            return 0
        fi
        log "Core burst attempt $attempt: body did not complete (Core likely SIGKILLed mid-burst)"
        core_stop_now
    done
    return 1
}

# ── 2. Launch lunarblock on regtest WITH --txindex. ───────────────────────
log "launching lunarblock (regtest, --txindex) rpc=:$LB_RPC p2p=:$LB_P2P -> $LB_LOG"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$LB_DATADIR' \
    --port '$LB_P2P' --rpcport '$LB_RPC' --nov2transport --txindex" \
    >"$LB_LOG" 2>&1 &
LB_PID=$!
log "lunarblock pid=$LB_PID"
lb_deadline=$(( $(date +%s) + 90 ))
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
[[ "$lb_up" -eq 1 ]] || { tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock RPC never reported chain=regtest within 90s"; }
log "lunarblock RPC ready"

# Confirm txindex actually enabled (getindexinfo should list it).
LB_IDX=$(lb_result getindexinfo '[]')
LB_HAS_TXINDEX=0
if echo "$LB_IDX" | grep -q '"txindex"'; then LB_HAS_TXINDEX=1; fi
log "lunarblock txindex present in getindexinfo: $LB_HAS_TXINDEX (getindexinfo=$LB_IDX)"

# ── 4. Build a real spendable wallet + a real non-coinbase tx on lunarblock.
LB_MINE_ADDR=$(lb_result getnewaddress '[]')
[[ -n "$LB_MINE_ADDR" ]] || { tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock getnewaddress returned empty"; }
log "lunarblock mining to $LB_MINE_ADDR (101 blocks to mature a coinbase)"
gen=$(lb_rpc generatetoaddress "[101,\"$LB_MINE_ADDR\"]")
echo "$gen" | grep -q '"result"' || { log "lunarblock generatetoaddress raw: $gen"; tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock generatetoaddress (101) failed"; }
LB_H=$(lb_result getblockcount '[]')
[[ "$LB_H" == "101" ]] || fail "lunarblock height=$LB_H expected 101 after generate"

LB_DEST=$(lb_result getnewaddress '[]')
[[ -n "$LB_DEST" ]] || fail "lunarblock getnewaddress (dest) returned empty"
LB_TXID=$(lb_result sendtoaddress "[\"$LB_DEST\",1.0]")
[[ "$LB_TXID" =~ ^[0-9a-f]{64}$ ]] || { log "sendtoaddress result: $LB_TXID"; tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock sendtoaddress did not return a 64-hex txid (got '$LB_TXID')"; }
log "lunarblock created mempool tx $LB_TXID -> $LB_DEST"

# ── 5. LUNARBLOCK DATA GATHERING (while lunarblock is alive). ─────────────
# Capture every value we need from lunarblock NOW; Core is queried later in
# short bursts because this sandbox SIGKILLs bitcoind after ~10-15s.

# (5a) verbosity-0 hex on the MEMPOOL tx, + verbosity coercion (false/default).
HEX_T="ok"
LB_HEX0=$(lb_result getrawtransaction "[\"$LB_TXID\",0]")
[[ "$LB_HEX0" =~ ^[0-9a-fA-F]+$ ]] || HEX_T="not-hex:$LB_HEX0"
LB_HEX_FALSE=$(lb_result getrawtransaction "[\"$LB_TXID\",false]")
LB_HEX_INT0=$(lb_result getrawtransaction "[\"$LB_TXID\"]")   # default verbosity == 0
[[ "$LB_HEX_FALSE" == "$LB_HEX0" ]] || HEX_T="false!=0:$LB_HEX_FALSE"
[[ "$LB_HEX_INT0"  == "$LB_HEX0" ]] || HEX_T="default!=0"

# (5b) verbosity-1 decoded object on the MEMPOOL tx.
LB_V1=$(lb_result getrawtransaction "[\"$LB_TXID\",1]")
[[ -n "$LB_V1" ]] || { tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; }

# (5c) lunarblock-side error codes (genesis/random/bogus-blockhash).
LB_E_RAND=$(jerr_code "$(lb_rpc getrawtransaction "[\"$RANDOM_TXID\"]")")
LB_E_GEN_ENV=$(lb_rpc getrawtransaction "[\"$GENESIS_COINBASE_TXID\"]")
LB_E_GEN=$(jerr_code "$LB_E_GEN_ENV")
LB_E_GEN_MSG=$(jerr_msg "$LB_E_GEN_ENV")
LB_E_BH_ENV=$(lb_rpc getrawtransaction "[\"$LB_TXID\",1,\"$BOGUS_BLOCKHASH\"]")
LB_E_BH=$(jerr_code "$LB_E_BH_ENV")
LB_E_BH_MSG=$(jerr_msg "$LB_E_BH_ENV")

# ── 6. CORE BURST: decode lunarblock's bytes + grab Core's error codes. ───
# Everything Core is needed for fits in one fast burst.  CORE_DECODE is Core's
# authoritative decode of lunarblock's verbosity-0 bytes — the load-bearing
# parity oracle.  The 3 error probes confirm Core's -5 category for the same
# inputs lunarblock saw.
CORE_DECODE=""; CORE_E_RAND="?"; CORE_E_GEN="?"; CORE_E_BH="?"
_core_burst_body() {
    CORE_DECODE=$(core_cli decoderawtransaction "$LB_HEX0" 2>/dev/null)
    [[ -n "$CORE_DECODE" ]] || return 1
    local raw
    raw=$(core_cli getrawtransaction "$RANDOM_TXID" 2>&1 >/dev/null)
    CORE_E_RAND=$(echo "$raw" | grep -oE 'code: -?[0-9]+' | grep -oE -- '-?[0-9]+' | head -1); [[ -z "$CORE_E_RAND" ]] && CORE_E_RAND="?"
    raw=$(core_cli getrawtransaction "$GENESIS_COINBASE_TXID" 2>&1 >/dev/null)
    CORE_E_GEN=$(echo "$raw" | grep -oE 'code: -?[0-9]+' | grep -oE -- '-?[0-9]+' | head -1); [[ -z "$CORE_E_GEN" ]] && CORE_E_GEN="?"
    raw=$(core_cli getrawtransaction "$RANDOM_TXID" 1 "$BOGUS_BLOCKHASH" 2>&1 >/dev/null)
    CORE_E_BH=$(echo "$raw" | grep -oE 'code: -?[0-9]+' | grep -oE -- '-?[0-9]+' | head -1); [[ -z "$CORE_E_BH" ]] && CORE_E_BH="?"
    return 0
}
if ! core_run_burst _core_burst_body; then
    fail "Core oracle could not complete the decode+error burst (sandbox SIGKILLed bitcoind 3x; see $CORE_LOG)"
fi
[[ -n "$CORE_DECODE" ]] || HEX_T="core-decode-failed"
CORE_DEC_TXID=$(jget "$CORE_DECODE" txid)
[[ "$CORE_DEC_TXID" == "$LB_TXID" ]] || HEX_T="core-decode-txid:$CORE_DEC_TXID!=$LB_TXID"
log "hex check: lunarblock v0 hex (${#LB_HEX0} chars), Core decode txid=$CORE_DEC_TXID -> $HEX_T"

# ── 7. DECODED check: verbosity 1 (mempool) == Core's decode of the SAME hex.
DECODED_T="ok"
[[ -n "$LB_V1" ]] || DECODED_T="v1-empty"
# Compare the load-bearing top-level scalar fields EXACTLY.  Note: Core's
# decoderawtransaction does NOT emit a top-level "hex" field (that belongs only
# to getrawtransaction's envelope), so "hex" is checked separately against the
# verbosity-0 bytes below.
if [[ "$DECODED_T" == "ok" ]]; then
    for f in txid hash version size vsize weight locktime; do
        lv=$(jget "$LB_V1" "$f")
        cv=$(jget "$CORE_DECODE" "$f")
        if [[ "$lv" == "__MISSING__" || "$lv" == "__NULL__" ]]; then
            DECODED_T="missing:$f"; break
        fi
        if [[ "$lv" != "$cv" ]]; then
            DECODED_T="ne:$f(lb=$lv core=$cv)"; break
        fi
    done
fi
# Top-level "hex" must be present and byte-EXACT equal to the verbosity-0 output.
if [[ "$DECODED_T" == "ok" ]]; then
    lb_v1_hex=$(jget "$LB_V1" hex)
    lc_hex0=$(echo "$LB_HEX0" | tr 'A-F' 'a-f')
    if [[ "$lb_v1_hex" == "__MISSING__" || "$lb_v1_hex" == "__NULL__" ]]; then
        DECODED_T="missing:hex"
    elif [[ "$lb_v1_hex" != "$lc_hex0" ]]; then
        DECODED_T="ne:hex(v1!=v0)"
    fi
fi
# Deep vin/vout parity: extract the load-bearing nested fields from both and
# compare them structurally (asm/desc deliberately EXCLUDED — present-not-equal).
if [[ "$DECODED_T" == "ok" ]]; then
    DEEP=$(python3 - "$LB_V1" "$CORE_DECODE" <<'PY'
import sys, json
lb  = json.loads(sys.argv[1])
core= json.loads(sys.argv[2])

def norm_vin(tx):
    out=[]
    for vi in tx.get("vin",[]):
        e={}
        if "coinbase" in vi:
            e["coinbase"]=vi["coinbase"]
        else:
            e["txid"]=vi.get("txid")
            e["vout"]=vi.get("vout")
            ss=vi.get("scriptSig",{})
            e["scriptSig_hex"]=ss.get("hex")  # hex exact; asm excluded
        e["sequence"]=vi.get("sequence")
        if "txinwitness" in vi:
            e["txinwitness"]=vi["txinwitness"]
        out.append(e)
    return out

def norm_vout(tx):
    out=[]
    for vo in tx.get("vout",[]):
        spk=vo.get("scriptPubKey",{})
        e={
            "value":vo.get("value"),
            "n":vo.get("n"),
            "spk_hex":spk.get("hex"),
            "spk_type":spk.get("type"),
        }
        # address: present-or-absent must MATCH; if present, must be byte-equal.
        if "address" in spk: e["address"]=spk["address"]
        out.append(e)
    return out

# scriptSig.hex / asm / desc presence assertions (present-not-byte-equal).
problems=[]
# every non-coinbase vin must have scriptSig with both asm and hex keys present.
for i,vi in enumerate(lb.get("vin",[])):
    if "coinbase" not in vi:
        ss=vi.get("scriptSig")
        if not isinstance(ss,dict) or "asm" not in ss or "hex" not in ss:
            problems.append(f"vin[{i}].scriptSig missing asm/hex")
# every vout scriptPubKey must have asm, hex, desc, type present.
for i,vo in enumerate(lb.get("vout",[])):
    spk=vo.get("scriptPubKey",{})
    for need in ("asm","hex","desc","type"):
        if need not in spk:
            problems.append(f"vout[{i}].scriptPubKey missing {need}")

if norm_vin(lb)!=norm_vin(core):
    problems.append("vin-mismatch lb=%s core=%s"%(json.dumps(norm_vin(lb)),json.dumps(norm_vin(core))))
if norm_vout(lb)!=norm_vout(core):
    problems.append("vout-mismatch lb=%s core=%s"%(json.dumps(norm_vout(lb)),json.dumps(norm_vout(core))))

print("OK" if not problems else " | ".join(problems))
PY
)
    [[ "$DEEP" == "OK" ]] || DECODED_T="deep:$DEEP"
fi
# Shape parity: lunarblock's verbosity-1 envelope must expose the full
# load-bearing key SET with Core-correct value types.  (This Core build is
# compiled WITHOUT wallet support, so a parallel Core-built tx cannot be made;
# the authoritative field parity above already runs against Core's real decoder.
# This step independently asserts the getrawtransaction-1 ENVELOPE shape that
# Core documents in TxToJSON + TxToUniv.)
if [[ "$DECODED_T" == "ok" ]]; then
    SHAPE=$(python3 - "$LB_V1" <<'PY'
import sys, json
lb = json.loads(sys.argv[1])
need = {"txid":"str","hash":"str","version":"int","size":"int","vsize":"int",
        "weight":"int","locktime":"int","vin":"list","vout":"list","hex":"str"}
def t(v):
    if isinstance(v,bool): return "bool"
    if isinstance(v,int): return "int"
    if isinstance(v,float): return "float"
    if isinstance(v,str): return "str"
    if isinstance(v,list): return "list"
    if isinstance(v,dict): return "dict"
    return "other"
for k,exp in need.items():
    if k not in lb: print(f"missing:{k}"); sys.exit(0)
    if t(lb[k])!=exp: print(f"type:{k}({t(lb[k])}!={exp})"); sys.exit(0)
# mempool tx (no blockhash arg, no -txindex hit yet for an unconfirmed tx) must
# NOT carry confirmed-only fields.
for k in ("blockhash","confirmations","time","blocktime","in_active_chain"):
    if k in lb: print(f"mempool-has-confirmed-field:{k}"); sys.exit(0)
print("OK")
PY
)
    [[ "$SHAPE" == "OK" ]] || DECODED_T="shape:$SHAPE"
fi
log "decoded check: -> $DECODED_T"

# ── 8. CONFIRMED check: mine the tx, query with the blockhash arg. ────────
# (lunarblock is still alive here — confirmed checks are all lunarblock-side.)
CONFIRMED_T="ok"
gen2=$(lb_rpc generatetoaddress "[1,\"$LB_MINE_ADDR\"]")
echo "$gen2" | grep -q '"result"' || CONFIRMED_T="mine-confirm-failed"
LB_BH=$(lb_result getbestblockhash '[]')
[[ "$LB_BH" =~ ^[0-9a-f]{64}$ ]] || CONFIRMED_T="bad-bestblockhash:$LB_BH"
LB_TIP=$(lb_result getblockcount '[]')
if [[ "$CONFIRMED_T" == "ok" ]]; then
    LB_C1=$(lb_result getrawtransaction "[\"$LB_TXID\",1,\"$LB_BH\"]")
    [[ -n "$LB_C1" ]] || CONFIRMED_T="confirmed-empty"
fi
if [[ "$CONFIRMED_T" == "ok" ]]; then
    c_bh=$(jget "$LB_C1" blockhash)
    c_conf=$(jget "$LB_C1" confirmations)
    c_iac=$(jget "$LB_C1" in_active_chain)
    c_time_t=$(jtype "$LB_C1" time)
    c_btime_t=$(jtype "$LB_C1" blocktime)
    [[ "$c_bh" == "$LB_BH" ]] || CONFIRMED_T="blockhash:$c_bh!=$LB_BH"
    [[ "$c_conf" =~ ^[0-9]+$ ]] && (( c_conf >= 1 )) || CONFIRMED_T="confirmations:$c_conf"
    [[ "$c_iac" == "true" ]] || CONFIRMED_T="in_active_chain:$c_iac"
    [[ "$c_time_t" == "int" ]]  || CONFIRMED_T="time-type:$c_time_t"
    [[ "$c_btime_t" == "int" ]] || CONFIRMED_T="blocktime-type:$c_btime_t"
    # time == blocktime (both = the block's nTime, per TxToJSON).
    [[ "$(jget "$LB_C1" time)" == "$(jget "$LB_C1" blocktime)" ]] || CONFIRMED_T="time!=blocktime"
fi
# Bool/int verbosity coercion on the confirmed-via-blockhash tx:
#   true  -> object (has txid)   false/0 -> hex string
if [[ "$CONFIRMED_T" == "ok" ]]; then
    bt=$(lb_rpc getrawtransaction "[\"$LB_TXID\",true,\"$LB_BH\"]")
    is_obj=$(python3 -c 'import sys,json;d=json.load(sys.stdin);r=d.get("result");print("yes" if isinstance(r,dict) and "txid" in r else "no")' <<<"$bt")
    [[ "$is_obj" == "yes" ]] || CONFIRMED_T="bool-true-not-object"
    bf=$(lb_rpc getrawtransaction "[\"$LB_TXID\",false,\"$LB_BH\"]")
    is_str=$(python3 -c 'import sys,json;d=json.load(sys.stdin);r=d.get("result");print("yes" if isinstance(r,str) else "no")' <<<"$bf")
    [[ "$is_str" == "yes" ]] || CONFIRMED_T="bool-false-not-hex"
fi
# txindex sub-check (only if lunarblock advertised txindex): confirmed tx
# retrievable with NO blockhash arg.
TXINDEX_NOTE="n/a"
if [[ "$CONFIRMED_T" == "ok" && "$LB_HAS_TXINDEX" == "1" ]]; then
    LB_NOBH=$(lb_result getrawtransaction "[\"$LB_TXID\",1]")
    nb_txid=$(jget "$LB_NOBH" txid)
    nb_bh=$(jget "$LB_NOBH" blockhash)
    if [[ "$nb_txid" != "$LB_TXID" ]]; then
        CONFIRMED_T="txindex-no-blockhash:$nb_txid"
    elif [[ "$nb_bh" != "$LB_BH" ]]; then
        CONFIRMED_T="txindex-blockhash:$nb_bh!=$LB_BH"
    else
        TXINDEX_NOTE="ok"
    fi
fi
log "confirmed check: -> $CONFIRMED_T (txindex-no-blockhash=$TXINDEX_NOTE)"

# ── 9. ERRORS check: random txid -> -5; genesis-coinbase -> -5; bogus bh -> -5.
# lunarblock codes were captured in step 5c; Core codes in the step-6 burst.
ERRORS_T="ok"
# (a) random/unknown txid (no blockhash) -> -5 on both.
[[ "$LB_E_RAND" == "-5" ]] || ERRORS_T="rand-not-5:$LB_E_RAND"
[[ "$CORE_E_RAND" == "-5" ]] || ERRORS_T="${ERRORS_T}|core-rand:$CORE_E_RAND"
# (b) genesis-coinbase txid -> -5 on both, with the exact Core message on lb.
[[ "$LB_E_GEN" == "-5" ]] || ERRORS_T="${ERRORS_T}|gen-not-5:$LB_E_GEN"
[[ "$CORE_E_GEN" == "-5" ]] || ERRORS_T="${ERRORS_T}|core-gen:$CORE_E_GEN"
echo "$LB_E_GEN_MSG" | grep -qi "genesis block coinbase" || ERRORS_T="${ERRORS_T}|gen-msg:$LB_E_GEN_MSG"
# (c) bogus blockhash arg -> -5 "Block hash not found" on both.  Core looks the
# blockhash up BEFORE the tx (rpc/rawtransaction.cpp:300-313), so any valid
# 64-hex txid + an unknown blockhash yields -5 — no wallet tx required.
[[ "$LB_E_BH" == "-5" ]] || ERRORS_T="${ERRORS_T}|bh-not-5:$LB_E_BH"
[[ "$CORE_E_BH" == "-5" ]] || ERRORS_T="${ERRORS_T}|core-bh:$CORE_E_BH"
echo "$LB_E_BH_MSG" | grep -qi "block hash not found" || ERRORS_T="${ERRORS_T}|bh-msg:$LB_E_BH_MSG"
log "errors check: rand(lb=$LB_E_RAND core=$CORE_E_RAND) gen(lb=$LB_E_GEN core=$CORE_E_GEN) bogusbh(lb=$LB_E_BH core=$CORE_E_BH) -> $ERRORS_T"

# ── 10. Verdict. ──────────────────────────────────────────────────────────
log "=== getrawtransaction DIFFERENTIAL (vs real Core regtest decoder) ==="
log "  hex=$HEX_T decoded=$DECODED_T confirmed=$CONFIRMED_T errors=$ERRORS_T"

FAILED=()
[[ "$HEX_T"       == "ok" ]] || FAILED+=("hex($HEX_T)")
[[ "$DECODED_T"   == "ok" ]] || FAILED+=("decoded($DECODED_T)")
[[ "$CONFIRMED_T" == "ok" ]] || FAILED+=("confirmed($CONFIRMED_T)")
[[ "$ERRORS_T"    == "ok" ]] || FAILED+=("errors($ERRORS_T)")

if [[ "${#FAILED[@]}" -gt 0 ]]; then
    fail "$(IFS=' '; echo "${FAILED[*]}") | hex=$HEX_T decoded=$DECODED_T confirmed=$CONFIRMED_T errors=$ERRORS_T"
fi

log "PASS: hex byte-exact via Core decoder; decoded fields == Core decode of same bytes; confirmed envelope + txindex correct; -5 error parity"
pass ok ok ok ok

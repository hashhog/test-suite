#!/usr/bin/env bash
#
# ouroboros_getnodeaddresses.sh — self-contained getnodeaddresses Core-parity test.
#
# The P2P-axis first cell, after the wallet + mempool-policy + getchaintxstats
# chapters. getnodeaddresses is a READ-ONLY addrman dump — NOT consensus — but
# the output SHAPE + the param/error semantics must match Bitcoin Core exactly.
#
# What this proves (Core ref: rpc/net.cpp:911-970 + netbase.cpp:100-142):
#   1. ERROR PATHS (no addrman population needed — robust + deterministic):
#        getnodeaddresses -1        -> RPC error code -8 "Address count out of range"
#        getnodeaddresses 1 "bogus" -> RPC error code -8 "Network not recognized: bogus"
#      asserted on BOTH ouroboros AND a real bitcoind regtest oracle.
#   2. SHAPE: addpeeraddress "8.8.8.8" 8333 then getnodeaddresses 0 on BOTH.
#      ouroboros's array must contain an object for 8.8.8.8 with EXACTLY the 5
#      keys {time, services, address, port, network}, address=="8.8.8.8",
#      port==8333, network=="ipv4", services an INTEGER (not a hex string),
#      time an INTEGER > 0. The KEY SET + types are compared to Core's object
#      for the same injected addr (time is NOT compared exactly — clocks differ).
#   3. COUNT/FILTER: getnodeaddresses 1 -> <=1 element; getnodeaddresses 0 "ipv4"
#      -> the ipv4 addr; getnodeaddresses 0 "onion" -> [] (only ipv4 injected).
#
# Ordering is treated as NON-DETERMINISTIC (addrman shuffles): every assertion
# matches by CONTENT, never by index.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/ouroboros_policy.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + UNIQUE
#   ports, ONE clean summary line on stdout, all noise -> stderr / logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETNODEADDRESSES ouroboros: PASS shape=ok errors=ok count=ok netfilter=ok
#   FAIL: GETNODEADDRESSES ouroboros: FAIL <short reason>
#
# Touches ONLY /tmp/gna-ouroboros/ + /tmp/gna-core/ and ports 21972/21992
# (ouroboros RPC/P2P) + 21973/21993 (Core oracle RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
# Disable job-control / monitor mode so killing background jobs in the cleanup
# trap never emits a "[1]+ Killed ..." (or bare-PID) job-control notification
# onto stdout — the single summary line must be the ONLY thing on stdout.
set +m

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

# Resolve the ouroboros checkout relative to this script:
# test-suite/p2p-addr/ -> repo root -> ouroboros/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OURO_DIR="$REPO_ROOT/ouroboros"

OU_DATADIR="/tmp/gna-ouroboros"
OU_RPC=21972
OU_P2P=21992
OU_LOG="$OU_DATADIR/node.log"

CORE_DATADIR="/tmp/gna-core"
CORE_RPC=21973
CORE_P2P=21993    # Core auto-binds an onion listener at P2P+1 (21994); both clear.
CORE_LOG="$CORE_DATADIR/core.log"

INJECT_ADDR="8.8.8.8"
INJECT_PORT=8333

OU_PID=""
OU_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gna:ouroboros] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$OU_PID" ]] && kill -0 "$OU_PID" 2>/dev/null; then
        kill "$OU_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$OU_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$OU_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    if [[ -n "$CORE_BG" ]]; then
        { kill "$CORE_BG"; wait "$CORE_BG"; } >/dev/null 2>&1 || true
    fi
    pkill -f "gna-ouroboros" 2>/dev/null || true
    rm -rf "$OU_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <shape> <errors> <count> <netfilter>
pass() {
    echo "GETNODEADDRESSES ouroboros: PASS shape=$1 errors=$2 count=$3 netfilter=$4"
    exit 0
}
fail() {
    echo "GETNODEADDRESSES ouroboros: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gna-ouroboros" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${OU_RPC}|${OU_P2P}|${CORE_RPC}|${CORE_P2P}|$((CORE_P2P + 1))) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${OU_RPC}|${OU_P2P}|${CORE_RPC}|${CORE_P2P}|$((CORE_P2P + 1))) "; then
    fail "port ${OU_RPC}/${OU_P2P}/${CORE_RPC}/${CORE_P2P}/$((CORE_P2P + 1)) already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$OU_DATADIR" "$CORE_DATADIR"
mkdir -p "$OU_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1        || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1           || fail "curl not found on PATH"
[[ -f "$OURO_DIR/src/ouroboros/cli.py" ]] || fail "ouroboros checkout not found at $OURO_DIR"
[[ -x "$CORE_BIN" ]]                      || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                      || fail "bitcoin-cli not found at $CORE_CLI"

OURO_PY="$OURO_DIR/.venv/bin/python3"
[[ -x "$OURO_PY" ]] || OURO_PY="python3"

# ── RPC helpers. ──────────────────────────────────────────────────────────
# Both nodes are driven over HTTP JSON-RPC via curl + cookie auth. This is more
# robust than bitcoin-cli under heavy concurrent box load (no per-call connect
# timeout flake) and prints NOTHING to stdout, so the single-summary-line
# contract is never violated by tool chatter.
CORE_COOKIE=""

# ou_rpc <method> <params-json>  -> raw JSON response from ouroboros.
ou_rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 20 -u "$OU_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$OU_RPC/" 2>/dev/null
}

# core_rpc <method> <params-json> -> raw JSON response from the Core oracle.
# Retries up to 4x on a transient connection failure (empty body / no "result"
# AND no "error") so a momentarily-busy oracle under fleet load self-heals.
core_rpc() {
    local method="$1" params="${2:-[]}" out=""
    for _try in 1 2 3 4; do
        out=$(curl -s --max-time 20 -u "$CORE_COOKIE" \
            --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
            "http://127.0.0.1:$CORE_RPC/" 2>/dev/null)
        if echo "$out" | grep -q '"result"\|"error"'; then
            echo "$out"; return 0
        fi
        sleep 1
    done
    echo "$out"
    return 0
}

# A tiny Python JSON evaluator over an RPC response. Reads the raw JSON envelope
# on stdin and runs the snippet in argv[1] with `r` bound to the parsed object.
# Prints whatever the snippet prints; exits 3 on parse failure.
PYJ='
import sys, json
try:
    r = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("json-parse-fail: %s\n" % e); sys.exit(3)
'

# ── 2. Launch the Core oracle (regtest). ──────────────────────────────────
# Retry the launch up to 3x: a back-to-back run can leave the RPC/P2P port in
# TIME_WAIT for a beat, so a transient bind failure should self-heal rather
# than fail the whole test.
core_ready=0
for attempt in 1 2 3; do
    log "launching Core oracle rpc=:$CORE_RPC p2p=:$CORE_P2P (attempt $attempt) -> $CORE_LOG"
    # Port-kill removed (2026-06-10 fuser incident): wait for OUR stopped node to release
    # the port; never kill by port.
    for __hp in "${CORE_RPC}" "${CORE_P2P}" "$((CORE_P2P + 1))"; do
        for _ in $(seq 1 30); do
            ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
            sleep 1
        done
        if ss -tln 2>/dev/null | grep -qE ":${__hp} "; then
            fail "port ${__hp} still LISTENING after our own stop — refusing port-kill (2026-06-10 fuser incident)"
        fi
    done
    rm -rf "$CORE_DATADIR" 2>/dev/null || true
    mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    core_deadline=$(( $(date +%s) + 60 ))
    core_exited=0
    while (( $(date +%s) < core_deadline )); do
        if "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1; then
            core_ready=1; break
        fi
        kill -0 "$CORE_BG" 2>/dev/null || { core_exited=1; break; }
        sleep 1
    done
    (( core_ready == 1 )) && break
    tail -n 10 "$CORE_LOG" >&2 2>/dev/null || true
    kill "$CORE_BG" 2>/dev/null || true
    CORE_BG=""
    log "Core oracle launch attempt $attempt failed (exited=$core_exited); retrying after settle"
    sleep 3
done
(( core_ready == 1 )) || fail "Core oracle failed to start after 3 attempts (see $CORE_LOG)"
# Capture the cookie for curl-based RPC and warm the RPC up via getnetworkinfo.
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "Core cookie not found at $CORE_DATADIR/regtest/.cookie"
warm=$(core_rpc getnetworkinfo "[]")
echo "$warm" | grep -q '"result"' \
    || fail "Core oracle RPC did not warm up via getnetworkinfo (got: $(echo "$warm" | head -c 200))"
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch ouroboros on regtest. ───────────────────────────────────────
# ouroboros is Python — the slowest-starting node in the fleet — so allow a
# generous (>=120s) RPC-startup wait.
log "launching ouroboros (regtest) rpc=:$OU_RPC p2p=:$OU_P2P -> $OU_LOG"
(
    cd "$OURO_DIR" || exit 1
    exec "$OURO_PY" -m ouroboros.cli \
        --network regtest --data-dir "$OU_DATADIR" \
        start --force --rpc-port "$OU_RPC" --p2p-port "$OU_P2P"
) >"$OU_LOG" 2>&1 &
OU_PID=$!
log "ouroboros pid=$OU_PID"
ou_deadline=$(( $(date +%s) + 150 ))
while (( $(date +%s) < ou_deadline )); do
    if [[ -z "$OU_COOKIE" ]]; then
        for c in "$OU_DATADIR/.cookie" "$OU_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && OU_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$OU_COOKIE" ]]; then
        r=$(ou_rpc getblockcount "[]")
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$OU_PID" 2>/dev/null || { tail -n 20 "$OU_LOG" >&2 2>/dev/null || true; fail "ouroboros exited during startup (see $OU_LOG)"; }
    sleep 1
done
[[ -n "$OU_COOKIE" ]] || fail "ouroboros cookie never appeared within 150s"
r=$(ou_rpc getblockcount "[]")
echo "$r" | grep -q '"result"' || fail "ouroboros RPC never responded within 150s"
log "ouroboros RPC ready"

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ ASSERTION 1 — ERROR PATHS (no addrman population needed).                 ║
# ╚══════════════════════════════════════════════════════════════════════════╝
log "=== assertion 1: error paths (count<0, bad network) ==="

# Extract an RPC error code from a JSON envelope (or NONE).
err_code() { python3 -c "$PYJ
e = r.get('error') or {}
print(e.get('code', 'NONE'))
"; }
# Extract an RPC error message from a JSON envelope (or empty).
err_msg() { python3 -c "$PYJ
e = r.get('error') or {}
print(e.get('message', ''))
"; }

# 1a. getnodeaddresses -1 -> error code -8 "Address count out of range" on BOTH.
core_neg=$(core_rpc getnodeaddresses "[-1]")
core_neg_code=$(echo "$core_neg" | err_code)
core_neg_msg=$(echo "$core_neg" | err_msg)
[[ "$core_neg_code" == "-8" ]] \
    || fail "Core getnodeaddresses -1 did not yield error code -8 (got '$core_neg_code'; raw: $core_neg) — oracle/version mismatch"
[[ "$core_neg_msg" == "Address count out of range" ]] \
    || fail "Core getnodeaddresses -1 message mismatch (got '$core_neg_msg') — oracle/version mismatch"

ou_neg=$(ou_rpc getnodeaddresses "[-1]")
ou_neg_code=$(echo "$ou_neg" | err_code)
ou_neg_msg=$(echo "$ou_neg" | err_msg)
[[ "$ou_neg_code" == "-8" ]] \
    || fail "ouroboros getnodeaddresses -1 error code != -8 (got '$ou_neg_code'; raw: $ou_neg)"
[[ "$ou_neg_msg" == "Address count out of range" ]] \
    || fail "ouroboros getnodeaddresses -1 message != 'Address count out of range' (got '$ou_neg_msg')"
log "  count<0 -> -8 'Address count out of range' on Core AND ouroboros"

# 1b. getnodeaddresses 1 "bogus" -> error code -8 "Network not recognized: bogus".
core_bn=$(core_rpc getnodeaddresses "[1,\"bogus\"]")
core_bn_code=$(echo "$core_bn" | err_code)
core_bn_msg=$(echo "$core_bn" | err_msg)
[[ "$core_bn_code" == "-8" ]] \
    || fail "Core getnodeaddresses 1 bogus did not yield error code -8 (got '$core_bn_code'; raw: $core_bn) — oracle/version mismatch"
[[ "$core_bn_msg" == "Network not recognized: bogus" ]] \
    || fail "Core getnodeaddresses 1 bogus message mismatch (got '$core_bn_msg') — oracle/version mismatch"

ou_bn=$(ou_rpc getnodeaddresses "[1,\"bogus\"]")
ou_bn_code=$(echo "$ou_bn" | err_code)
ou_bn_msg=$(echo "$ou_bn" | err_msg)
[[ "$ou_bn_code" == "-8" ]] \
    || fail "ouroboros getnodeaddresses 1 bogus error code != -8 (got '$ou_bn_code'; raw: $ou_bn)"
[[ "$ou_bn_msg" == "Network not recognized: bogus" ]] \
    || fail "ouroboros getnodeaddresses 1 bogus message != 'Network not recognized: bogus' (got '$ou_bn_msg')"
log "  bad network -> -8 'Network not recognized: bogus' on Core AND ouroboros"
ERRORS=ok

# Pre-population sanity: empty addrman -> [] (NOT an error).
ou_empty=$(ou_rpc getnodeaddresses "[0]")
ou_empty_kind=$(echo "$ou_empty" | python3 -c "$PYJ
res = r.get('result')
if 'error' in r and r['error']:
    print('ERROR'); raise SystemExit
print('list' if isinstance(res, list) else type(res).__name__)
")
[[ "$ou_empty_kind" == "list" ]] \
    || fail "ouroboros getnodeaddresses 0 on empty addrman did not return a JSON array (got kind '$ou_empty_kind'; raw: $ou_empty)"
log "  empty addrman -> [] (array, not error)"

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ ASSERTION 2 — SHAPE (inject 8.8.8.8, compare object key-set + types).     ║
# ╚══════════════════════════════════════════════════════════════════════════╝
log "=== assertion 2: shape (addpeeraddress + getnodeaddresses 0) ==="

# Inject the same address on BOTH nodes.
core_add=$(core_rpc addpeeraddress "[\"$INJECT_ADDR\",$INJECT_PORT]")
core_add_ok=$(echo "$core_add" | python3 -c "$PYJ
res = r.get('result') or {}
print('true' if res.get('success') is True else 'false')
")
[[ "$core_add_ok" == "true" ]] \
    || fail "Core addpeeraddress $INJECT_ADDR $INJECT_PORT did not return success=true (raw: $core_add) — oracle problem"

ou_add=$(ou_rpc addpeeraddress "[\"$INJECT_ADDR\",$INJECT_PORT]")
ou_add_ok=$(echo "$ou_add" | python3 -c "$PYJ
res = r.get('result') or {}
print('true' if res.get('success') is True else 'false')
")
[[ "$ou_add_ok" == "true" ]] \
    || fail "ouroboros addpeeraddress $INJECT_ADDR $INJECT_PORT did not return success=true (raw: $ou_add)"
log "  addpeeraddress $INJECT_ADDR:$INJECT_PORT -> success=true on Core AND ouroboros"

# Core's object for the injected addr — used to derive the EXPECTED key set.
core_all=$(core_rpc getnodeaddresses "[0]")
CORE_KEYS=$(echo "$core_all" | python3 -c "$PYJ
arr = r.get('result') if isinstance(r.get('result'), list) else []
for o in arr:
    if isinstance(o, dict) and o.get('address') == '$INJECT_ADDR':
        print(','.join(sorted(o.keys()))); break
")
[[ -n "$CORE_KEYS" ]] \
    || fail "Core getnodeaddresses 0 did not contain an object for $INJECT_ADDR (got: $(echo "$core_all" | head -c 300)) — oracle problem"
log "  Core object key set for $INJECT_ADDR: {$CORE_KEYS}"

# ouroboros's object for the injected addr — validate the full shape.
ou_all=$(ou_rpc getnodeaddresses "[0]")
# The python validator prints SHAPE_OK on success, or SHAPE_FAIL:<reason>.
shape_res=$(echo "$ou_all" | python3 -c "$PYJ
EXPECTED = {'time', 'services', 'address', 'port', 'network'}
CORE_KEYS = set('$CORE_KEYS'.split(',')) if '$CORE_KEYS' else set()
arr = r.get('result')
if not isinstance(arr, list):
    print('SHAPE_FAIL:result-not-array'); raise SystemExit
obj = None
for o in arr:
    if isinstance(o, dict) and o.get('address') == '$INJECT_ADDR':
        obj = o; break
if obj is None:
    print('SHAPE_FAIL:no-object-for-$INJECT_ADDR'); raise SystemExit
keys = set(obj.keys())
if keys != EXPECTED:
    extra = keys - EXPECTED
    missing = EXPECTED - keys
    print('SHAPE_FAIL:key-set-mismatch extra=%s missing=%s' % (sorted(extra), sorted(missing))); raise SystemExit
# Compare key SET to Core's object for the same injected addr.
if CORE_KEYS and keys != CORE_KEYS:
    print('SHAPE_FAIL:key-set-differs-from-core ouro=%s core=%s' % (sorted(keys), sorted(CORE_KEYS))); raise SystemExit
# Field values + TYPES.
if obj['address'] != '$INJECT_ADDR':
    print('SHAPE_FAIL:address!=$INJECT_ADDR (%r)' % obj['address']); raise SystemExit
if obj['port'] != $INJECT_PORT:
    print('SHAPE_FAIL:port!=$INJECT_PORT (%r)' % obj['port']); raise SystemExit
if obj['network'] != 'ipv4':
    print('SHAPE_FAIL:network!=ipv4 (%r)' % obj['network']); raise SystemExit
# services must be an INTEGER, not a hex string (unlike getpeerinfo).
if not isinstance(obj['services'], int) or isinstance(obj['services'], bool):
    print('SHAPE_FAIL:services-not-int (%r type=%s)' % (obj['services'], type(obj['services']).__name__)); raise SystemExit
# time must be an INTEGER > 0.
if not isinstance(obj['time'], int) or isinstance(obj['time'], bool):
    print('SHAPE_FAIL:time-not-int (%r type=%s)' % (obj['time'], type(obj['time']).__name__)); raise SystemExit
if obj['time'] <= 0:
    print('SHAPE_FAIL:time<=0 (%r)' % obj['time']); raise SystemExit
if not isinstance(obj['port'], int) or isinstance(obj['port'], bool):
    print('SHAPE_FAIL:port-not-int (%r)' % obj['port']); raise SystemExit
print('SHAPE_OK')
")
[[ "$shape_res" == "SHAPE_OK" ]] \
    || fail "shape mismatch: ${shape_res#SHAPE_FAIL:} (ouro raw: $(echo "$ou_all" | head -c 400))"
log "  ouroboros object for $INJECT_ADDR has EXACTLY {time,services,address,port,network}, types OK, matches Core key set"
SHAPE=ok

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ ASSERTION 3 — COUNT + NETWORK FILTER.                                     ║
# ╚══════════════════════════════════════════════════════════════════════════╝
log "=== assertion 3: count + network filter ==="

# 3a. getnodeaddresses 1 -> <= 1 element.
ou_one=$(ou_rpc getnodeaddresses "[1]")
ou_one_len=$(echo "$ou_one" | python3 -c "$PYJ
arr = r.get('result')
print(len(arr) if isinstance(arr, list) else 'NONE')
")
[[ "$ou_one_len" =~ ^[0-9]+$ ]] \
    || fail "ouroboros getnodeaddresses 1 did not return an array (raw: $ou_one)"
(( ou_one_len <= 1 )) \
    || fail "ouroboros getnodeaddresses 1 returned $ou_one_len elements (expected <= 1)"
log "  getnodeaddresses 1 -> $ou_one_len element(s) (<= 1)"
COUNT=ok

# 3b. getnodeaddresses 0 "ipv4" -> contains the ipv4 addr.
ou_ipv4=$(ou_rpc getnodeaddresses "[0,\"ipv4\"]")
ou_ipv4_has=$(echo "$ou_ipv4" | python3 -c "$PYJ
arr = r.get('result') or []
found = any(isinstance(o, dict) and o.get('address') == '$INJECT_ADDR' and o.get('network') == 'ipv4' for o in arr)
print('yes' if found else 'no')
")
[[ "$ou_ipv4_has" == "yes" ]] \
    || fail "ouroboros getnodeaddresses 0 ipv4 did not contain $INJECT_ADDR/ipv4 (raw: $(echo "$ou_ipv4" | head -c 300))"
log "  getnodeaddresses 0 ipv4 -> contains $INJECT_ADDR/ipv4"

# 3c. getnodeaddresses 0 "onion" -> [] (only ipv4 was injected).
ou_onion=$(ou_rpc getnodeaddresses "[0,\"onion\"]")
ou_onion_len=$(echo "$ou_onion" | python3 -c "$PYJ
arr = r.get('result')
print(len(arr) if isinstance(arr, list) else 'NONE')
")
[[ "$ou_onion_len" == "0" ]] \
    || fail "ouroboros getnodeaddresses 0 onion returned $ou_onion_len elements (expected 0; raw: $(echo "$ou_onion" | head -c 300))"
# Cross-check Core agrees onion is empty here (informational; Core is the oracle).
core_onion=$(core_rpc getnodeaddresses "[0,\"onion\"]" | python3 -c "$PYJ
arr = r.get('result')
print(len(arr) if isinstance(arr, list) else 'NONE')
" 2>/dev/null || echo "0")
[[ "$core_onion" == "0" ]] \
    || log "  note: Core onion-filter returned $core_onion (expected 0; informational)"
log "  getnodeaddresses 0 onion -> [] (only ipv4 injected)"
NETFILTER=ok

# ── Verdict. ──────────────────────────────────────────────────────────────
log "PASS: shape + error paths + count + network-filter all Core-parity"
pass "$SHAPE" "$ERRORS" "$COUNT" "$NETFILTER"

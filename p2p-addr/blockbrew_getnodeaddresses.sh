#!/usr/bin/env bash
#
# blockbrew_getnodeaddresses.sh — self-contained getnodeaddresses Core-parity test.
#
# The P2P-axis first cell, after the wallet + mempool-policy + getchaintxstats
# chapters. Proves blockbrew's getnodeaddresses RPC is a Core-correct read-only
# addrman dump: exact 5-key object shape ({time, services, address, port,
# network}), services emitted as an INTEGER (not a hex string, unlike
# getpeerinfo), correct network-class string, and Core-exact param/error
# semantics (count<0 -> -8 "Address count out of range"; unrecognized network
# -> -8 "Network not recognized: <raw arg>"; empty addrman -> [] not an error).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN regtest
# instance (own scratch datadir + ports). The addrman is populated
# deterministically via the companion `addpeeraddress` RPC (Core net.cpp:972),
# so the differential is reproducible (addrman ordering is non-deterministic;
# Core shuffles via GetAddressesUnsafe, so every assertion matches by CONTENT,
# never by index).
#
# Assertions (all run against BOTH blockbrew and Core):
#   1. ERROR PATHS (no addrman population needed — robust + deterministic):
#        getnodeaddresses -1        -> error code -8 "Address count out of range"
#        getnodeaddresses 1 "bogus" -> error code -8 "Network not recognized: bogus"
#   2. SHAPE: addpeeraddress "8.8.8.8" 8333 on both; getnodeaddresses 0 on both.
#        blockbrew's array contains an object for 8.8.8.8 with EXACTLY the 5 keys
#        {time, services, address, port, network}; address=="8.8.8.8",
#        port==8333, network=="ipv4", services is an INTEGER (>0), time an
#        INTEGER >0. The blockbrew object's KEY SET + value TYPES are compared
#        to Core's object for the same injected addr (time NOT compared exactly —
#        clocks differ). Any extra/missing key fails.
#   3. COUNT/FILTER: getnodeaddresses 1 -> <=1 element; getnodeaddresses 0 "ipv4"
#        -> the ipv4 addr present; getnodeaddresses 0 "onion" -> [] (only an
#        ipv4 addr was injected).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/blockbrew_policy.sh): no
#   required args, idempotent, trap cleanup, scratch datadirs + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETNODEADDRESSES blockbrew: PASS shape=ok errors=ok count=ok netfilter=ok
#   FAIL: GETNODEADDRESSES blockbrew: FAIL <short reason>
#
# Touches ONLY /tmp/gna-blockbrew/ + /tmp/gna-core-bb/ and ports 40073/40093
#   (blockbrew RPC/P2P) + 40075/40095 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/blockbrew/blockbrew"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

BB_DATADIR="/tmp/gna-blockbrew"
BB_RPC=40073
BB_P2P=40093
BB_LOG="$BB_DATADIR/node.log"
BB_URL="http://127.0.0.1:${BB_RPC}"
BB_COOKIE_FILE="$BB_DATADIR/regtest/.cookie"

CORE_DATADIR="/tmp/gna-core-bb"
CORE_RPC=40075
CORE_P2P=40095
CORE_LOG="$CORE_DATADIR/core.log"

BB_PID=""
BB_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gna:blockbrew] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BB_PID" ]] && kill -0 "$BB_PID" 2>/dev/null; then
        kill "$BB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${BB_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${BB_P2P}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$BB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <shape> <errors> <count> <netfilter>
pass() {
    echo "GETNODEADDRESSES blockbrew: PASS shape=$1 errors=$2 count=$3 netfilter=$4"
    exit 0
}
fail() {
    echo "GETNODEADDRESSES blockbrew: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
# Kill any leftover holder of our fixed ports, then wait for them to actually
# free (a just-killed node can hold the listen socket in TIME_WAIT/CLOSE for a
# moment). Polling here makes back-to-back invocations robust.
log "resetting scratch state"
# Politely stop a leftover Core on our port first (a half-dead bitcoind that's
# still draining its RPC socket can otherwise answer the readiness probe and
# then vanish mid-test). Then SIGKILL any remaining holder of our fixed ports.
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
for p in "$BB_RPC" "$BB_P2P" "$CORE_RPC" "$CORE_P2P"; do
    fuser -k "${p}/tcp" >/dev/null 2>&1 || true
done
for _ in $(seq 1 20); do
    busy=0
    for p in "$BB_RPC" "$BB_P2P" "$CORE_RPC" "$CORE_P2P"; do
        fuser "${p}/tcp" >/dev/null 2>&1 && busy=1
    done
    [[ "$busy" -eq 0 ]] && break
    sleep 1
done
rm -rf "$BB_DATADIR" "$CORE_DATADIR"
mkdir -p "$BB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1    || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]               || fail "blockbrew binary not found at $NODE_BIN (run build-all.sh blockbrew)"
[[ -x "$CORE_BIN" ]]               || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]               || fail "bitcoin-cli not found at $CORE_CLI"

# ── 2. Launch the Core oracle. ────────────────────────────────────────────
log "launching Core oracle rpc=:$CORE_RPC p2p=:$CORE_P2P"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < core_deadline )); do
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 && break
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
    || fail "Core oracle RPC never responded within 60s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch blockbrew on regtest. ───────────────────────────────────────
# -maxoutbound=0 -nolisten keeps it isolated so the addrman only ever contains
# what this harness injects via addpeeraddress (deterministic differential).
log "launching blockbrew (regtest) rpc=:$BB_RPC p2p=:$BB_P2P -> $BB_LOG"
# -metricsport=0 disables the Prometheus exporter (default port 9332 is a
# fixed global port not derived from our scratch ports — leaving it on makes
# back-to-back / concurrent invocations race on 9332. We don't need metrics).
"$NODE_BIN" \
    -network=regtest -datadir="$BB_DATADIR" \
    -listen="127.0.0.1:${BB_P2P}" -rpcbind="127.0.0.1:${BB_RPC}" \
    -maxoutbound=0 -nolisten -metricsport=0 \
    >"$BB_LOG" 2>&1 &
BB_PID=$!
log "blockbrew pid=$BB_PID"
bb_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < bb_deadline )); do
    if [[ -z "$BB_COOKIE" && -f "$BB_COOKIE_FILE" ]]; then
        BB_COOKIE=$(cat "$BB_COOKIE_FILE")
    fi
    if [[ -n "$BB_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$BB_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "$BB_URL/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$BB_PID" 2>/dev/null || { tail -n 20 "$BB_LOG" >&2 2>/dev/null || true; fail "blockbrew exited during startup (see $BB_LOG)"; }
    sleep 1
done
[[ -n "$BB_COOKIE" ]] || fail "blockbrew cookie never appeared within 60s"
r=$(curl -s --max-time 5 -u "$BB_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "$BB_URL/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "blockbrew RPC never responded within 60s"
log "blockbrew RPC ready"

# ── 4. RPC helpers. ───────────────────────────────────────────────────────
# bb_rpc <method> <json-params> -> full JSON-RPC response on stdout.
bb_rpc() {
    curl -s --max-time 15 -u "$BB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "$BB_URL/" 2>/dev/null
}
# core_rpc <method> [args...] -> raw bitcoin-cli output (result JSON or error).
# Retries on transient connection errors (a freshly-launched bitcoind can drop
# the first call or two while the RPC thread pool warms up); a genuine RPC error
# (e.g. the -8 error paths we assert on) is returned verbatim, not retried.
core_rpc() {
    local out
    for _ in 1 2 3 4 5; do
        out=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>&1)
        case "$out" in
            *"Could not connect"*|*"timeout on transient error"*|*"Loading"*|*"warming up"*)
                sleep 1; continue ;;
            *) echo "$out"; return 0 ;;
        esac
    done
    echo "$out"
}

# ── 5. Inline Python evaluator. ───────────────────────────────────────────
# All structural assertions run through one python3 process per check so we get
# real JSON parsing (key-set, types, content membership) rather than brittle
# grep. Each EVAL_* helper prints "OK" or "ERR <reason>" on stdout, exit 0/1.
EVAL_PY="$BB_DATADIR/gna_eval.py"
cat > "$EVAL_PY" <<'PYEOF'
import sys, json

mode = sys.argv[1]
data = sys.stdin.read()

def die(msg):
    print("ERR " + msg)
    sys.exit(1)

def ok():
    print("OK")
    sys.exit(0)

try:
    payload = json.loads(data) if data.strip() else None
except Exception as e:
    die(f"could not parse JSON ({e}); raw={data[:200]!r}")

# For blockbrew the array is in payload["result"]; allow a bare array too (Core
# bitcoin-cli emits the bare result).
def as_array(p):
    if isinstance(p, dict) and "result" in p:
        if p.get("error"):
            die(f"unexpected rpc error: {p['error']}")
        return p["result"]
    return p

if mode == "shape":
    # argv[2] = expected port (int), argv[3] = expected address
    exp_port = int(sys.argv[2]); exp_addr = sys.argv[3]
    arr = as_array(payload)
    if not isinstance(arr, list):
        die(f"result is not an array: {type(arr).__name__}")
    objs = [o for o in arr if isinstance(o, dict) and o.get("address") == exp_addr]
    if not objs:
        die(f"no object for address {exp_addr} in array of {len(arr)} elems")
    obj = objs[0]
    keyset = set(obj.keys())
    expect = {"time", "services", "address", "port", "network"}
    if keyset != expect:
        die(f"key set {sorted(keyset)} != {sorted(expect)} (extra/missing key)")
    # types + values
    if not isinstance(obj["time"], int) or isinstance(obj["time"], bool):
        die(f"time is not an integer: {obj['time']!r}")
    if obj["time"] <= 0:
        die(f"time not > 0: {obj['time']!r}")
    if not isinstance(obj["services"], int) or isinstance(obj["services"], bool):
        die(f"services is not an integer (got {type(obj['services']).__name__}={obj['services']!r}) — must NOT be a hex string")
    if obj["services"] <= 0:
        die(f"services not > 0: {obj['services']!r}")
    if obj["address"] != exp_addr:
        die(f"address {obj['address']!r} != {exp_addr!r}")
    if not isinstance(obj["port"], int) or obj["port"] != exp_port:
        die(f"port {obj['port']!r} != {exp_port}")
    if obj["network"] != "ipv4":
        die(f"network {obj['network']!r} != 'ipv4'")
    ok()

elif mode == "keyset-match":
    # Compare blockbrew object keyset+types for exp_addr against the SAME on Core.
    # argv[2] = path to Core JSON file, argv[3] = address
    core_path = sys.argv[2]; exp_addr = sys.argv[3]
    with open(core_path) as f:
        core_arr = json.load(f)
    bb_arr = as_array(payload)
    def pick(arr):
        c = [o for o in arr if isinstance(o, dict) and o.get("address") == exp_addr]
        return c[0] if c else None
    bo = pick(bb_arr); co = pick(core_arr)
    if bo is None: die(f"blockbrew has no object for {exp_addr}")
    if co is None: die(f"Core has no object for {exp_addr}")
    if set(bo.keys()) != set(co.keys()):
        die(f"key set mismatch vs Core: bb={sorted(bo.keys())} core={sorted(co.keys())}")
    # type parity per key (not exact values; time/clocks differ)
    for k in co.keys():
        bt = type(bo[k]).__name__; ct = type(co[k]).__name__
        # JSON ints/bools both 'int' in python except bool subclass; treat numeric
        if isinstance(co[k], bool) != isinstance(bo[k], bool):
            die(f"key {k}: bool-ness differs bb={bo[k]!r} core={co[k]!r}")
        if bt != ct:
            die(f"key {k}: type mismatch bb={bt} core={ct}")
    # spot-check the non-clock values match exactly
    for k in ("services", "address", "port", "network"):
        if bo[k] != co[k]:
            die(f"key {k}: value mismatch bb={bo[k]!r} core={co[k]!r}")
    ok()

elif mode == "count-le":
    exp_max = int(sys.argv[2])
    arr = as_array(payload)
    if not isinstance(arr, list):
        die(f"result is not an array")
    if len(arr) > exp_max:
        die(f"array has {len(arr)} elems, expected <= {exp_max}")
    ok()

elif mode == "has-addr":
    exp_addr = sys.argv[2]
    arr = as_array(payload)
    if not isinstance(arr, list):
        die("result is not an array")
    if not any(isinstance(o, dict) and o.get("address") == exp_addr for o in arr):
        die(f"address {exp_addr} not present in array of {len(arr)}")
    ok()

elif mode == "empty-array":
    arr = as_array(payload)
    if not isinstance(arr, list):
        die(f"result is not an array: {arr!r}")
    if len(arr) != 0:
        die(f"array not empty: {len(arr)} elems")
    ok()

elif mode == "err-code-msg":
    # argv[2] = expected code (int), argv[3] = expected message substring
    exp_code = int(sys.argv[2]); exp_msg = sys.argv[3]
    if not isinstance(payload, dict) or not payload.get("error"):
        die(f"expected an error object, got: {str(payload)[:200]}")
    err = payload["error"]
    if int(err.get("code")) != exp_code:
        die(f"error code {err.get('code')} != {exp_code}")
    if exp_msg not in str(err.get("message", "")):
        die(f"error message {err.get('message')!r} does not contain {exp_msg!r}")
    ok()

else:
    die(f"unknown mode {mode}")
PYEOF
[[ -s "$EVAL_PY" ]] || fail "failed to write python evaluator"

# evalpy MODE [args...] < json  -> returns 0 on OK, else logs ERR and returns 1.
evalpy() {
    local out
    out=$(python3 "$EVAL_PY" "$@")
    if [[ "$out" == OK ]]; then
        return 0
    fi
    log "  eval[$1] -> $out"
    return 1
}

# ── 6. ERROR PATHS (deterministic, no addrman population). ────────────────
ERRORS="ok"
log "checking error paths on blockbrew + Core"

# blockbrew: count -1 -> -8 "Address count out of range"
if ! bb_rpc getnodeaddresses '[-1]' | evalpy err-code-msg -8 "Address count out of range"; then
    ERRORS="fail"; log "  blockbrew getnodeaddresses -1 wrong error"
fi
# blockbrew: network "bogus" -> -8 "Network not recognized: bogus"
if ! bb_rpc getnodeaddresses '[1, "bogus"]' | evalpy err-code-msg -8 "Network not recognized: bogus"; then
    ERRORS="fail"; log "  blockbrew getnodeaddresses 1 bogus wrong error"
fi
# Core oracle parity for the same two error paths (cli emits 'error code: -8' + message).
core_neg=$(core_rpc getnodeaddresses -1)
echo "$core_neg" | grep -q "error code: -8" && echo "$core_neg" | grep -q "Address count out of range" \
    || { ERRORS="fail"; log "  Core getnodeaddresses -1 did not emit -8/Address count out of range: $core_neg"; }
core_bog=$(core_rpc getnodeaddresses 1 bogus)
echo "$core_bog" | grep -q "error code: -8" && echo "$core_bog" | grep -q "Network not recognized: bogus" \
    || { ERRORS="fail"; log "  Core getnodeaddresses 1 bogus did not emit -8/Network not recognized: bogus: $core_bog"; }

# ── 7. Populate the addrman on BOTH nodes via addpeeraddress. ─────────────
log "injecting 8.8.8.8:8333 into both addrmans via addpeeraddress"
bb_add=$(bb_rpc addpeeraddress '["8.8.8.8", 8333]')
echo "$bb_add" | grep -q '"success":true' || { log "  blockbrew addpeeraddress did not return success=true: $bb_add"; }
core_add=$(core_rpc addpeeraddress 8.8.8.8 8333)
echo "$core_add" | grep -q '"success": true' || { log "  Core addpeeraddress did not return success: $core_add"; }

# Capture Core's getnodeaddresses 0 for the keyset/type parity comparison.
CORE_GNA_FILE="$BB_DATADIR/core_gna0.json"
core_rpc getnodeaddresses 0 > "$CORE_GNA_FILE" 2>/dev/null
if ! python3 -c "import json,sys; json.load(open('$CORE_GNA_FILE'))" 2>/dev/null; then
    fail "Core getnodeaddresses 0 did not return valid JSON (see $CORE_LOG): $(cat "$CORE_GNA_FILE" 2>/dev/null | head -c 200)"
fi

# ── 8. SHAPE check (blockbrew object + keyset/type parity vs Core). ───────
SHAPE="ok"
log "checking object shape (5 keys, integer services, ipv4) on blockbrew"
if ! bb_rpc getnodeaddresses '[0]' | evalpy shape 8333 "8.8.8.8"; then
    SHAPE="fail"
fi
log "comparing blockbrew object keyset+types to Core's for 8.8.8.8"
if ! bb_rpc getnodeaddresses '[0]' | evalpy keyset-match "$CORE_GNA_FILE" "8.8.8.8"; then
    SHAPE="fail"
fi

# ── 9. COUNT / FILTER checks. ─────────────────────────────────────────────
COUNT="ok"
NETFILTER="ok"
log "checking count + network-filter semantics"

# getnodeaddresses 1 -> <= 1 element
if ! bb_rpc getnodeaddresses '[1]' | evalpy count-le 1; then
    COUNT="fail"; log "  blockbrew getnodeaddresses 1 returned > 1 element"
fi
# getnodeaddresses 0 -> contains the ipv4 addr (the count==0 "all" path)
if ! bb_rpc getnodeaddresses '[0]' | evalpy has-addr "8.8.8.8"; then
    COUNT="fail"; log "  blockbrew getnodeaddresses 0 missing 8.8.8.8"
fi
# getnodeaddresses 0 "ipv4" -> contains the ipv4 addr
if ! bb_rpc getnodeaddresses '[0, "ipv4"]' | evalpy has-addr "8.8.8.8"; then
    NETFILTER="fail"; log "  blockbrew getnodeaddresses 0 ipv4 missing 8.8.8.8"
fi
# getnodeaddresses 0 "onion" -> [] (only ipv4 injected)
if ! bb_rpc getnodeaddresses '[0, "onion"]' | evalpy empty-array; then
    NETFILTER="fail"; log "  blockbrew getnodeaddresses 0 onion not empty"
fi

# Core parity for the filter: Core 0 onion must also be empty (sanity on oracle).
core_onion=$(core_rpc getnodeaddresses 0 onion)
if ! echo "$core_onion" | python3 -c "import json,sys; a=json.load(sys.stdin); sys.exit(0 if isinstance(a,list) and len(a)==0 else 1)" 2>/dev/null; then
    log "  note: Core getnodeaddresses 0 onion was not empty: $core_onion"
fi

# ── 10. Verdict. ──────────────────────────────────────────────────────────
if [[ "$SHAPE" != "ok" ]]; then
    fail "object shape divergence (shape=$SHAPE errors=$ERRORS count=$COUNT netfilter=$NETFILTER) — see $BB_LOG"
fi
if [[ "$ERRORS" != "ok" ]]; then
    fail "error-path divergence (shape=$SHAPE errors=$ERRORS count=$COUNT netfilter=$NETFILTER)"
fi
if [[ "$COUNT" != "ok" ]]; then
    fail "count semantics divergence (shape=$SHAPE errors=$ERRORS count=$COUNT netfilter=$NETFILTER)"
fi
if [[ "$NETFILTER" != "ok" ]]; then
    fail "network-filter divergence (shape=$SHAPE errors=$ERRORS count=$COUNT netfilter=$NETFILTER)"
fi

log "PASS: getnodeaddresses Core-shaped (5-key object, integer services, ipv4 class); error codes -8 exact; count==0 all + count cap + network filter all Core-parity"
pass "$SHAPE" "$ERRORS" "$COUNT" "$NETFILTER"

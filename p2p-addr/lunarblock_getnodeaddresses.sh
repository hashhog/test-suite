#!/usr/bin/env bash
#
# lunarblock_getnodeaddresses.sh — self-contained P2P getnodeaddresses parity test.
#
# The first cell of the P2P axis (after the wallet + mempool-policy +
# getchaintxstats chapters). getnodeaddresses is a READ-ONLY addrman dump — NOT
# consensus — but the OUTPUT SHAPE and the param/error semantics must be EXACT.
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on its OWN regtest
#   scratch datadir + ports. The SAME probes (error paths + an injected
#   8.8.8.8:8333 addrman entry via addpeeraddress) are run against both Core and
#   lunarblock; lunarblock is compared against Core's behavior.
#
# Core ref: bitcoin-core/src/rpc/net.cpp:911-970 (getnodeaddresses),
#   :972-1030 (addpeeraddress), src/netbase.cpp:100-128
#   (ParseNetwork / GetNetworkName).
#
# EXACT CORE SEMANTICS:
#   getnodeaddresses ( count "network" ) -> JSON ARRAY of objects, each with
#   EXACTLY 5 keys {time, services, address, port, network}:
#     time     NUM_TIME  unix seconds as INTEGER
#     services NUM       raw services bitfield as INTEGER (NOT a hex string)
#     address  STR       ip literal / .onion / .b32.i2p (no port)
#     port     NUM       integer
#     network  STR       ipv4|ipv6|onion|i2p|cjdns|not_publicly_routable|internal
#   count default 1; count==0 -> ALL; count<0 -> error -8 "Address count out of
#   range". network (optional) accepts ONLY ipv4|ipv6|onion|i2p|cjdns; anything
#   else -> error -8 "Network not recognized: <raw arg>". The source addrman
#   list is SHUFFLED, so order is NON-DETERMINISTIC — match by content, never by
#   index. Fresh/empty addrman -> [] (empty array, NOT an error).
#
# ASSERTIONS (all run against BOTH lunarblock and the Core oracle):
#   1. ERROR PATHS (no addrman population needed — robust + deterministic):
#        getnodeaddresses -1        -> error code -8 ("Address count out of range")
#        getnodeaddresses 1 "bogus" -> error code -8 ("Network not recognized: bogus")
#   2. SHAPE: addpeeraddress "8.8.8.8" 8333 on both; getnodeaddresses 0 on both.
#        lunarblock's array contains an object for 8.8.8.8 with EXACTLY the 5
#        keys {time, services, address, port, network}; address=="8.8.8.8",
#        port==8333, network=="ipv4", services an INTEGER, time an INTEGER > 0.
#        Fail on any extra/missing key. The KEY SET is compared to Core's object
#        for the same injected addr (NOT time exactly — clocks differ).
#   3. COUNT/FILTER: getnodeaddresses 1 -> <=1 element; getnodeaddresses 0 "ipv4"
#        -> the ipv4 addr; getnodeaddresses 0 "onion" -> [] (only ipv4 injected).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/lunarblock_policy.sh): no
#   required args, idempotent, trap cleanup, scratch /tmp + unique ports, ONE
#   clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETNODEADDRESSES lunarblock: PASS shape=ok errors=ok count=ok netfilter=ok
#   FAIL: GETNODEADDRESSES lunarblock: FAIL <short reason>
#
# Touches ONLY /tmp/gna-lunarblock + /tmp/gna-core and ports 21978/21998
#   (lunarblock RPC/P2P), 21980/22000 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
set +m   # disable job-control monitor mode so backgrounded-process kills in
         # cleanup don't leak an async "Killed <pid>" notice onto stdout.

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

LB_DATADIR="/tmp/gna-lunarblock"
LB_RPC=21978
LB_P2P=21998
LB_LOG="$LB_DATADIR/node.log"

# Core oracle uses a lunarblock-SPECIFIC scratch datadir so it never shares a
# cookie with a concurrent getnodeaddresses fanout sibling that targets the bare
# /tmp/gna-core path (siblings offset only their ports, not the datadir, which
# otherwise produces "Authorization failed: Incorrect rpcuser or rpcpassword"
# when bitcoin-cli reads a sibling-rewritten .cookie).
CORE_DATADIR="/tmp/gna-core-lunarblock"
CORE_RPC=21980
CORE_P2P=22000
CORE_LOG="$CORE_DATADIR/core.log"

VDIR=""   # validator-scripts dir (under LB_DATADIR, set after mkdir)

LB_PID=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gna:lunarblock] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch, THEN emit the summary line LAST. ─
# The summary is deferred into the EXIT trap (via SUMMARY_LINE) so it is the
# very last write to stdout — AFTER every backgrounded job has been reaped.
# Otherwise bash's async "Killed <pid>" job-completion notice can land on
# stdout after the summary and corrupt `tail -n1`'s view for the regression
# runner.  All node-teardown noise stays on stderr; cleanup never writes the
# summary to anywhere but the final, post-teardown echo.
SUMMARY_LINE=""
cleanup() {
    local ec=$?
    {
        if [[ -n "$LB_PID" ]] && kill -0 "$LB_PID" 2>/dev/null; then
            kill -TERM "-${LB_PID}" 2>/dev/null || kill -TERM "$LB_PID" 2>/dev/null || true
            for _ in $(seq 1 15); do kill -0 "$LB_PID" 2>/dev/null || break; sleep 1; done
            kill -KILL "-${LB_PID}" 2>/dev/null || kill -KILL "$LB_PID" 2>/dev/null || true
        fi
        [[ -n "$LB_PID" ]] && wait "$LB_PID" 2>/dev/null || true
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
        for _ in $(seq 1 15); do
            "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
            sleep 1
        done
        [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
        [[ -n "$CORE_BG" ]] && wait "$CORE_BG" 2>/dev/null || true
        rm -rf "$LB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    } >&2
    # Emit the single summary line LAST, on stdout, after all reaping is done.
    [[ -n "$SUMMARY_LINE" ]] && echo "$SUMMARY_LINE"
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters (set SUMMARY_LINE, then exit -> cleanup prints it last). ─
# pass <shape> <errors> <count> <netfilter>
pass() {
    SUMMARY_LINE="GETNODEADDRESSES lunarblock: PASS shape=$1 errors=$2 count=$3 netfilter=$4"
    exit 0
}
fail() {
    SUMMARY_LINE="GETNODEADDRESSES lunarblock: FAIL $*"
    exit 1
}

# ── JSON probe helpers. ───────────────────────────────────────────────────
# lb_call <method> <params-json>  -> raw JSON-RPC response on stdout.
lb_call() {
    curl -s --max-time 15 \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$LB_RPC/" 2>/dev/null
}
# core_call <method-args...> via bitcoin-cli; stdout = result, exit reflects cli.
core_call() {
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>&1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
# Kill ONLY processes pinned to OUR exact scratch datadirs (anchor the match on
# the trailing space/flag boundary so a concurrent fanout sibling on e.g.
# /tmp/gna-core-bb is NOT collateral-killed).
log "resetting scratch state"
pkill -f -- "datadir $LB_DATADIR " 2>/dev/null || true
pkill -f -- "-datadir=$CORE_DATADIR " 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${LB_RPC}/${LB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$LB_DATADIR" "$CORE_DATADIR"
mkdir -p "$LB_DATADIR" "$CORE_DATADIR"
VDIR="$LB_DATADIR/validators"
mkdir -p "$VDIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v luajit  >/dev/null 2>&1   || fail "luajit not found on PATH"
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -f "$LB_DIR/src/main.lua" ]]      || fail "lunarblock src/main.lua not found at $LB_DIR"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"

# ── 2. Write the Python validators (avoids nested-quote shell hell). ──────
# Each reads a JSON-RPC response (or a bare CLI JSON value) on stdin, asserts,
# and exits 0/1. argv is used to parameterize.

# v_rpcerr.py <code> <message>: assert the response carries error.code/message.
cat > "$VDIR/v_rpcerr.py" <<'PYEOF'
import sys, json
want_code = int(sys.argv[1]); want_msg = sys.argv[2]
d = json.load(sys.stdin)
e = d.get("error")
if e is None:
    print("expected an error object, got result=%r" % d.get("result"), file=sys.stderr); sys.exit(1)
if int(e.get("code")) != want_code:
    print("expected code %d, got %r" % (want_code, e.get("code")), file=sys.stderr); sys.exit(1)
if e.get("message") != want_msg:
    print("expected message %r, got %r" % (want_msg, e.get("message")), file=sys.stderr); sys.exit(1)
PYEOF

# v_success.py: assert a JSON-RPC result of {"success": true}.
cat > "$VDIR/v_success.py" <<'PYEOF'
import sys, json
d = json.load(sys.stdin)
if d.get("error") is not None:
    print("addpeeraddress errored: %r" % d.get("error"), file=sys.stderr); sys.exit(1)
r = d.get("result")
if not (isinstance(r, dict) and r.get("success") is True):
    print("did not return success=true: %r" % r, file=sys.stderr); sys.exit(1)
PYEOF

# v_core_success.py: assert a bare CLI JSON value of {"success": true}.
cat > "$VDIR/v_core_success.py" <<'PYEOF'
import sys, json
r = json.load(sys.stdin)
if r.get("success") is not True:
    print("Core addpeeraddress not success: %r" % r, file=sys.stderr); sys.exit(1)
PYEOF

# v_core_keys.py: from a bare CLI getnodeaddresses array, print the sorted key
# set of the object whose address == 8.8.8.8.
cat > "$VDIR/v_core_keys.py" <<'PYEOF'
import sys, json
arr = json.load(sys.stdin)
m = [o for o in arr if o.get("address") == "8.8.8.8"]
if not m:
    print("Core dump missing 8.8.8.8: %r" % arr, file=sys.stderr); sys.exit(1)
print(",".join(sorted(m[0].keys())))
PYEOF

# v_shape.py <core_keys_csv>: from a JSON-RPC getnodeaddresses-0 response,
# assert the 8.8.8.8 object has EXACTLY {time,services,address,port,network}
# with correct value types, and the key set matches Core's.
cat > "$VDIR/v_shape.py" <<'PYEOF'
import sys, json
core_keys = set(sys.argv[1].split(","))
d = json.load(sys.stdin)
if d.get("error") is not None:
    print("getnodeaddresses 0 errored: %r" % d.get("error"), file=sys.stderr); sys.exit(1)
arr = d.get("result")
if not isinstance(arr, list):
    print("result not an array: %r" % type(arr), file=sys.stderr); sys.exit(1)
m = [o for o in arr if o.get("address") == "8.8.8.8"]
if not m:
    print("dump missing 8.8.8.8: %r" % arr, file=sys.stderr); sys.exit(1)
o = m[0]
expected = {"time", "services", "address", "port", "network"}
got = set(o.keys())
if got != expected:
    print("key set mismatch: expected %r, got %r" % (sorted(expected), sorted(got)), file=sys.stderr); sys.exit(1)
if got != core_keys:
    print("key set differs from Core: lunar=%r core=%r" % (sorted(got), sorted(core_keys)), file=sys.stderr); sys.exit(1)
if o["address"] != "8.8.8.8":
    print("address wrong: %r" % o["address"], file=sys.stderr); sys.exit(1)
if not (isinstance(o["port"], int) and not isinstance(o["port"], bool) and o["port"] == 8333):
    print("port wrong/not-int: %r" % o["port"], file=sys.stderr); sys.exit(1)
if o["network"] != "ipv4":
    print("network wrong: %r" % o["network"], file=sys.stderr); sys.exit(1)
if not (isinstance(o["services"], int) and not isinstance(o["services"], bool)):
    print("services not an int: %r (%s)" % (o["services"], type(o["services"]).__name__), file=sys.stderr); sys.exit(1)
if not (isinstance(o["time"], int) and not isinstance(o["time"], bool)):
    print("time not an int: %r (%s)" % (o["time"], type(o["time"]).__name__), file=sys.stderr); sys.exit(1)
if not (o["time"] > 0):
    print("time not > 0: %r" % o["time"], file=sys.stderr); sys.exit(1)
PYEOF

# v_le1.py: from a JSON-RPC getnodeaddresses response, assert result is a list
# with <= 1 element.
cat > "$VDIR/v_le1.py" <<'PYEOF'
import sys, json
d = json.load(sys.stdin)
if d.get("error") is not None:
    print("errored: %r" % d.get("error"), file=sys.stderr); sys.exit(1)
arr = d.get("result")
if not (isinstance(arr, list) and len(arr) <= 1):
    print("count=1 returned %r" % (len(arr) if isinstance(arr, list) else arr), file=sys.stderr); sys.exit(1)
PYEOF

# v_has_ipv4.py: from a JSON-RPC getnodeaddresses response, assert it contains
# the 8.8.8.8 ipv4 addr.
cat > "$VDIR/v_has_ipv4.py" <<'PYEOF'
import sys, json
d = json.load(sys.stdin)
if d.get("error") is not None:
    print("errored: %r" % d.get("error"), file=sys.stderr); sys.exit(1)
arr = d.get("result")
if not isinstance(arr, list):
    print("not a list: %r" % arr, file=sys.stderr); sys.exit(1)
m = [o for o in arr if o.get("address") == "8.8.8.8" and o.get("network") == "ipv4"]
if not m:
    print("ipv4 filter did not return 8.8.8.8: %r" % arr, file=sys.stderr); sys.exit(1)
PYEOF

# v_empty.py: from a JSON-RPC getnodeaddresses response, assert result == [].
cat > "$VDIR/v_empty.py" <<'PYEOF'
import sys, json
d = json.load(sys.stdin)
if d.get("error") is not None:
    print("errored: %r" % d.get("error"), file=sys.stderr); sys.exit(1)
arr = d.get("result")
if not (isinstance(arr, list) and len(arr) == 0):
    print("filter not empty: %r" % arr, file=sys.stderr); sys.exit(1)
PYEOF

# v_core_empty.py: from a bare CLI getnodeaddresses array, assert it == [].
cat > "$VDIR/v_core_empty.py" <<'PYEOF'
import sys, json
arr = json.load(sys.stdin)
if not (isinstance(arr, list) and len(arr) == 0):
    print("Core filter not empty: %r" % arr, file=sys.stderr); sys.exit(1)
PYEOF

# ── 3. Launch the Core regtest oracle. ────────────────────────────────────
log "launching Core oracle rpc=:$CORE_RPC p2p=:$CORE_P2P -> $CORE_LOG"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
disown "$CORE_BG" 2>/dev/null || true
core_deadline=$(( $(date +%s) + 60 ))
core_up=0
while (( $(date +%s) < core_deadline )); do
    if core_call getblockcount >/dev/null 2>&1; then core_up=1; break; fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
[[ "$core_up" -eq 1 ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle did not start within 60s (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch lunarblock on regtest (with one retry on a port-release race). ─
# --metricsport 0 disables the Prometheus server: its default port (9332) is
# fleet-shared and would collide with a concurrent fanout sibling or a prior
# run still releasing the port. We do not probe metrics here, so disable it.
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
lb_up=0
for attempt in 1 2; do
    log "launching lunarblock (regtest, attempt $attempt) rpc=:$LB_RPC p2p=:$LB_P2P -> $LB_LOG"
    # If a prior attempt left the RPC/P2P ports in TIME_WAIT or a half-dead
    # process, clear them before re-binding.
    # Port-kill removed (2026-06-10 fuser incident): wait for OUR stopped node to release
    # the port; never kill by port.
    for __hp in "${LB_RPC}" "${LB_P2P}"; do
        for _ in $(seq 1 30); do
            ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
            sleep 1
        done
        if ss -tln 2>/dev/null | grep -qE ":${__hp} "; then
            fail "port ${__hp} still LISTENING after our own stop — refusing port-kill (2026-06-10 fuser incident)"
        fi
    done
    sleep 1
    setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
        --network regtest --datadir '$LB_DATADIR' \
        --port '$LB_P2P' --rpcport '$LB_RPC' --metricsport 0 --nov2transport" \
        >"$LB_LOG" 2>&1 &
    LB_PID=$!
    disown "$LB_PID" 2>/dev/null || true
    log "lunarblock pid=$LB_PID"
    lb_deadline=$(( $(date +%s) + 90 ))
    lb_exited=0
    while (( $(date +%s) < lb_deadline )); do
        if ! kill -0 "$LB_PID" 2>/dev/null; then lb_exited=1; break; fi
        r=$(curl -s --max-time 5 \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockchaininfo","params":[]}' \
            "http://127.0.0.1:$LB_RPC/" 2>/dev/null)
        if echo "$r" | grep -q '"regtest"'; then lb_up=1; break; fi
        sleep 1
    done
    [[ "$lb_up" -eq 1 ]] && break
    log "attempt $attempt did not bring lunarblock RPC up (exited=$lb_exited); retrying"
    tail -n 10 "$LB_LOG" >&2 2>/dev/null || true
    # PID-scoped reap of the half-dead attempt (port-kill banned — 2026-06-10).
    if [[ -n "$LB_PID" ]]; then
        kill "$LB_PID" 2>/dev/null || true
        for _ in $(seq 1 10); do kill -0 "$LB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$LB_PID" 2>/dev/null || true
    fi
    LB_PID=""
done
[[ "$lb_up" -eq 1 ]] || { tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock RPC never reported chain=regtest within 90s (2 attempts)"; }
log "lunarblock RPC ready"

# ── 5. ERROR PATHS (deterministic; no addrman population needed). ─────────
log "asserting error paths"
# 5a. getnodeaddresses -1 -> error -8 "Address count out of range".
LB_NEG=$(lb_call getnodeaddresses '[-1]')
echo "$LB_NEG" | python3 "$VDIR/v_rpcerr.py" -8 "Address count out of range" 2>>"$LB_LOG" \
    || fail "lunarblock getnodeaddresses -1 did not return error -8 'Address count out of range' (got: $LB_NEG)"
CORE_NEG=$(core_call getnodeaddresses -1 || true)
echo "$CORE_NEG" | grep -q "error code: -8"             || fail "Core getnodeaddresses -1 did not yield code -8 (got: $CORE_NEG)"
echo "$CORE_NEG" | grep -q "Address count out of range" || fail "Core getnodeaddresses -1 message mismatch (got: $CORE_NEG)"

# 5b. getnodeaddresses 1 "bogus" -> error -8 "Network not recognized: bogus".
LB_BOGUS=$(lb_call getnodeaddresses '[1,"bogus"]')
echo "$LB_BOGUS" | python3 "$VDIR/v_rpcerr.py" -8 "Network not recognized: bogus" 2>>"$LB_LOG" \
    || fail "lunarblock getnodeaddresses 1 bogus did not return error -8 'Network not recognized: bogus' (got: $LB_BOGUS)"
CORE_BOGUS=$(core_call getnodeaddresses 1 bogus || true)
echo "$CORE_BOGUS" | grep -q "error code: -8"                || fail "Core getnodeaddresses 1 bogus did not yield code -8 (got: $CORE_BOGUS)"
echo "$CORE_BOGUS" | grep -q "Network not recognized: bogus" || fail "Core getnodeaddresses 1 bogus message mismatch (got: $CORE_BOGUS)"
ERRORS_T="ok"
log "error paths ok"

# ── 6. SHAPE: inject 8.8.8.8:8333 on both; assert the dumped object shape. ─
log "injecting 8.8.8.8:8333 via addpeeraddress on both nodes"
LB_ADD=$(lb_call addpeeraddress '["8.8.8.8",8333]')
echo "$LB_ADD" | python3 "$VDIR/v_success.py" 2>>"$LB_LOG" \
    || fail "lunarblock addpeeraddress 8.8.8.8 8333 did not return success=true (got: $LB_ADD)"
CORE_ADD=$(core_call addpeeraddress 8.8.8.8 8333 || true)
echo "$CORE_ADD" | python3 "$VDIR/v_core_success.py" 2>>"$CORE_LOG" \
    || fail "Core addpeeraddress 8.8.8.8 8333 did not return success=true (got: $CORE_ADD)"

# Capture Core's object key set for the injected addr (the parity reference).
CORE_DUMP=$(core_call getnodeaddresses 0)
CORE_KEYS=$(echo "$CORE_DUMP" | python3 "$VDIR/v_core_keys.py" 2>>"$CORE_LOG") \
    || fail "could not extract Core 8.8.8.8 object keys (got: $CORE_DUMP)"
log "Core object key set for 8.8.8.8 = {$CORE_KEYS}"

# lunarblock's dump: assert EXACTLY {time,services,address,port,network} + value
# types, and that the key set matches Core's (NOT time exactly — clocks differ).
LB_DUMP=$(lb_call getnodeaddresses '[0]')
echo "$LB_DUMP" | python3 "$VDIR/v_shape.py" "$CORE_KEYS" 2>>"$LB_LOG" \
    || fail "lunarblock getnodeaddresses 0 shape/type/keyset assertion failed (got: $LB_DUMP)"
SHAPE_T="ok"
log "shape ok"

# ── 7. COUNT/FILTER. ──────────────────────────────────────────────────────
log "asserting count + network filter"
# 7a. getnodeaddresses 1 -> <= 1 element.
LB_ONE=$(lb_call getnodeaddresses '[1]')
echo "$LB_ONE" | python3 "$VDIR/v_le1.py" 2>>"$LB_LOG" \
    || fail "lunarblock getnodeaddresses 1 returned >1 element (got: $LB_ONE)"

# 7b. getnodeaddresses 0 "ipv4" -> contains the ipv4 addr 8.8.8.8.
LB_IPV4=$(lb_call getnodeaddresses '[0,"ipv4"]')
echo "$LB_IPV4" | python3 "$VDIR/v_has_ipv4.py" 2>>"$LB_LOG" \
    || fail "lunarblock getnodeaddresses 0 ipv4 did not return the injected ipv4 addr (got: $LB_IPV4)"

# 7c. getnodeaddresses 0 "onion" -> [] (only an ipv4 addr was injected).
LB_ONION=$(lb_call getnodeaddresses '[0,"onion"]')
echo "$LB_ONION" | python3 "$VDIR/v_empty.py" 2>>"$LB_LOG" \
    || fail "lunarblock getnodeaddresses 0 onion was not [] (got: $LB_ONION)"

# Confirm Core also empties the onion filter (oracle parity on the filter path).
CORE_ONION=$(core_call getnodeaddresses 0 onion)
echo "$CORE_ONION" | python3 "$VDIR/v_core_empty.py" 2>>"$CORE_LOG" \
    || fail "Core getnodeaddresses 0 onion not [] (got: $CORE_ONION) — oracle disagreement"
COUNT_T="ok"
NETFILTER_T="ok"
log "count + netfilter ok"

# ── 8. Verdict. ───────────────────────────────────────────────────────────
log "PASS: error paths + shape + count + netfilter all match Core"
pass "$SHAPE_T" "$ERRORS_T" "$COUNT_T" "$NETFILTER_T"

#!/usr/bin/env bash
#
# beamchain_getnodeaddresses.sh — self-contained getnodeaddresses + addpeeraddress
# differential parity test (P2P axis, first cell after the wallet + policy +
# getchaintxstats chapters).
#
# WHAT IT PROVES: beamchain's `getnodeaddresses` RPC is a READ-ONLY addrman dump
# that matches Bitcoin Core's output SHAPE + param/error semantics EXACTLY
# (rpc/net.cpp:911-967, netbase.cpp:100-128). NOT consensus — but exactness on
# the 5-key object shape, the integer (not hex) services field, and the -8 error
# codes is the whole point. The companion `addpeeraddress` injector (rpc/net.cpp
# :972) is implemented too so the addrman can be populated deterministically.
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on its OWN regtest
# scratch + ports. Both nodes are driven over JSON-RPC; assertions compare
# beamchain's behaviour against Core's for the same operations.
#
# ASSERTIONS (per the cell brief):
#   1. ERROR PATHS (no addrman population needed — robust + deterministic):
#        getnodeaddresses -1       -> RPC error -8 "Address count out of range"
#        getnodeaddresses 1 bogus  -> RPC error -8 "Network not recognized: bogus"
#      asserted on BOTH beamchain AND Core (Core is the oracle for the codes).
#   2. SHAPE: addpeeraddress "8.8.8.8" 8333 on BOTH; getnodeaddresses 0 on BOTH.
#      beamchain's array must contain an object for 8.8.8.8 with EXACTLY the 5
#      keys {time, services, address, port, network}; address=="8.8.8.8",
#      port==8333, network=="ipv4", services an INTEGER (not a hex string),
#      time an INTEGER > 0. The KEY SET + types are compared to Core's object
#      for the same injected addr (time NOT compared exactly — clocks differ).
#   3. COUNT/FILTER: getnodeaddresses 1 -> <=1 element; getnodeaddresses 0 "ipv4"
#      -> the ipv4 addr present; getnodeaddresses 0 "onion" -> [] (only ipv4
#      injected). Ordering is non-deterministic (addrman shuffles) — match by
#      CONTENT, never by index.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/beamchain_policy.sh): no
#   required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout (all noise -> stderr / logfiles),
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETNODEADDRESSES beamchain: PASS shape=ok errors=ok count=ok netfilter=ok
#   FAIL: GETNODEADDRESSES beamchain: FAIL <short reason>
#
# Touches ONLY /tmp/gna-beamchain{,-core}/ and ports 21976/21996 (beamchain
#   RPC/P2P) + 21978/21998 (Core RPC/P2P). NEVER touches /data/nvme1/ or
#   testnet4-data/ or any live node (haskoin is mid-sync — left alone).

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

BC_DATADIR="/tmp/gna-beamchain"
BC_RPC=21976
BC_P2P=21996
BC_LOG="$BC_DATADIR/node.log"

CORE_DATADIR="/tmp/gna-beamchain-core"
CORE_RPC=21978
CORE_P2P=21998
CORE_LOG="$CORE_DATADIR/core.log"

BC_PID=""
BC_COOKIE=""
CORE_BG=""
CORE_COOKIE=""

# The injected test address.
INJ_ADDR="8.8.8.8"
INJ_PORT=8333

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gna:beamchain] $*" >&2; }

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETNODEADDRESSES beamchain: PASS shape=$1 errors=$2 count=$3 netfilter=$4"
    exit 0
}
fail() {
    echo "GETNODEADDRESSES beamchain: FAIL $*"
    exit 1
}

# ── Cleanup: kill both nodes + wipe scratch on any exit. ──────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BC_PID" ]] && kill -0 "$BC_PID" 2>/dev/null; then
        kill "$BC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BC_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$BC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gna-beamchain" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${BC_RPC}|${BC_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${BC_RPC}|${BC_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${BC_RPC}/${BC_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$BC_DATADIR" "$CORE_DATADIR"
mkdir -p "$BC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]] || fail "beamchain release binary not found at $NODE_BIN (run rebar3 as prod release)"
[[ -x "$CORE_BIN" ]] || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]] || fail "bitcoin-cli not found at $CORE_CLI"

# ── JSON-RPC helper (python). Prints, on stdout:
#     OK <json-result>            on success
#     ERR <code> <message>        on a JSON-RPC error object
#     FATAL <reason>              on transport failure
# Args: <url> <user:pass> <method> [json-params-array]
rpc_call() {
    local url="$1" cookie="$2" method="$3" params="${4:-[]}"
    python3 - "$url" "$cookie" "$method" "$params" <<'PYEOF'
import sys, json, base64, urllib.request
url, cookie, method, params = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    p = json.loads(params)
except Exception as e:
    print("FATAL bad-params:%s" % e); sys.exit(0)
body = json.dumps({"jsonrpc":"1.0","id":1,"method":method,"params":p}).encode()
auth = "Basic " + base64.b64encode(cookie.encode()).decode()
req = urllib.request.Request(url, data=body,
    headers={"Authorization":auth, "Content-Type":"application/json"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read())
except urllib.error.HTTPError as e:
    # bitcoind returns the JSON-RPC error body with a non-2xx status for
    # errors; read it back so we can surface the code/message.
    try:
        d = json.loads(e.read())
    except Exception:
        print("FATAL http:%s" % e); sys.exit(0)
except Exception as e:
    print("FATAL transport:%s" % e); sys.exit(0)
err = d.get("error")
if err:
    msg = (err.get("message") or "").replace("\n", " ")
    print("ERR %s %s" % (err.get("code"), msg))
else:
    print("OK " + json.dumps(d.get("result")))
PYEOF
}

# ── Readiness poll for the Core regtest oracle. ───────────────────────────
wait_core_ready() {
    local dd="$1" rpc="$2" pid="$3" lf="$4"
    local deadline=$(( $(date +%s) + 120 ))
    while (( $(date +%s) < deadline )); do
        if "$CORE_CLI" -regtest -datadir="$dd" -rpcport="$rpc" getblockcount >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || { tail -n 20 "$lf" >&2 2>/dev/null || true; return 1; }
        sleep 1
    done
    tail -n 20 "$lf" >&2 2>/dev/null || true
    return 1
}

# ── 2. Launch the Core oracle. ────────────────────────────────────────────
log "launching Core oracle rpc=:$CORE_RPC p2p=:$CORE_P2P"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -bind="127.0.0.1:$CORE_P2P" >"$CORE_LOG" 2>&1 &
CORE_BG=$!
wait_core_ready "$CORE_DATADIR" "$CORE_RPC" "$CORE_BG" "$CORE_LOG" \
    || fail "Core oracle failed to start within 120s (see $CORE_LOG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "Core cookie not found at $CORE_DATADIR/regtest/.cookie"
CORE_URL="http://127.0.0.1:$CORE_RPC/"
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch beamchain on regtest (release binary, foreground). ──────────
cat >"$BC_DATADIR/sys.config" <<ERLCFG
[
 {beamchain, [
   {network, regtest},
   {datadir, "$BC_DATADIR"},
   {p2pport, $BC_P2P},
   {rpcport, $BC_RPC}
 ]},
 {kernel, [{logger_level, info}]},
 {sasl,   [{sasl_error_logger, false}]}
].
ERLCFG
cat >"$BC_DATADIR/vm.args" <<ERLVM
-sname beamchain_gnaref_$$
-setcookie beamchain_gnaref
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest) rpc=:$BC_RPC p2p=:$BC_P2P -> $BC_LOG"
RELX_CONFIG_PATH="$BC_DATADIR/sys.config" VMARGS_PATH="$BC_DATADIR/vm.args" \
    "$NODE_BIN" foreground >"$BC_LOG" 2>&1 &
BC_PID=$!
log "beamchain pid=$BC_PID"
bc_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < bc_deadline )); do
    if [[ -z "$BC_COOKIE" ]]; then
        for c in "$BC_DATADIR/regtest/.cookie" "$BC_DATADIR/.cookie"; do
            [[ -f "$c" ]] && BC_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$BC_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$BC_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$BC_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$BC_PID" 2>/dev/null || { tail -n 20 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain exited during startup (see $BC_LOG)"; }
    sleep 1
done
[[ -n "$BC_COOKIE" ]] || fail "beamchain cookie never appeared within 60s"
r=$(curl -s --max-time 5 -u "$BC_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$BC_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "beamchain RPC never responded within 60s"
BC_URL="http://127.0.0.1:$BC_RPC/"
log "beamchain RPC ready"

# ══════════════════════════════════════════════════════════════════════════
# Assertion 1 — ERROR PATHS (no addrman population needed).
# ══════════════════════════════════════════════════════════════════════════
ERRORS_OK="ok"

check_error() {
    # check_error <label> <url> <cookie> <params-json> <expected-substr>
    local label="$1" url="$2" cookie="$3" params="$4" want="$5"
    local out code msg
    out=$(rpc_call "$url" "$cookie" getnodeaddresses "$params")
    case "$out" in
        ERR\ *)
            code=$(echo "$out" | awk '{print $2}')
            msg=${out#ERR $code }
            if [[ "$code" != "-8" ]]; then
                log "  $label: expected code -8, got $code (msg='$msg')"
                return 1
            fi
            if [[ "$msg" != *"$want"* ]]; then
                log "  $label: expected message to contain '$want', got '$msg'"
                return 1
            fi
            log "  $label: OK (code=-8 msg='$msg')"
            return 0
            ;;
        *)
            log "  $label: expected an error, got: $out"
            return 1
            ;;
    esac
}

log "=== assertion 1: error paths ==="
# count -1 -> -8 "Address count out of range"  (both nodes)
check_error "core  count=-1" "$CORE_URL" "$CORE_COOKIE" '[-1]' "Address count out of range" || ERRORS_OK="core-count-neg"
check_error "beam  count=-1" "$BC_URL"   "$BC_COOKIE"   '[-1]' "Address count out of range" || ERRORS_OK="beam-count-neg"
# network "bogus" -> -8 "Network not recognized: bogus"  (both nodes)
check_error "core  net=bogus" "$CORE_URL" "$CORE_COOKIE" '[1, "bogus"]' "Network not recognized: bogus" || ERRORS_OK="core-net-bogus"
check_error "beam  net=bogus" "$BC_URL"   "$BC_COOKIE"   '[1, "bogus"]' "Network not recognized: bogus" || ERRORS_OK="beam-net-bogus"

[[ "$ERRORS_OK" == "ok" ]] || fail "error-path mismatch ($ERRORS_OK): see log; errors=$ERRORS_OK"
log "error paths OK on both nodes"

# ══════════════════════════════════════════════════════════════════════════
# Assertion 2 — SHAPE (inject 8.8.8.8:8333 on both, compare object shape).
# ══════════════════════════════════════════════════════════════════════════
log "=== assertion 2: shape ==="

# Inject on Core (addpeeraddress "8.8.8.8" 8333) and on beamchain.
core_add=$(rpc_call "$CORE_URL" "$CORE_COOKIE" addpeeraddress "[\"$INJ_ADDR\", $INJ_PORT]")
log "  core addpeeraddress -> $core_add"
case "$core_add" in OK\ *) : ;; *) fail "core addpeeraddress failed: $core_add" ;; esac

beam_add=$(rpc_call "$BC_URL" "$BC_COOKIE" addpeeraddress "[\"$INJ_ADDR\", $INJ_PORT]")
log "  beam addpeeraddress -> $beam_add"
case "$beam_add" in
    OK\ *) : ;;
    *) fail "beamchain addpeeraddress failed: $beam_add" ;;
esac
# beamchain must report success=true (8.8.8.8 is routable).
echo "${beam_add#OK }" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get("success") is True else 1)' \
    || fail "beamchain addpeeraddress did not return {success:true}: $beam_add"

# Fetch the full dump from both (count 0 = all).
core_dump=$(rpc_call "$CORE_URL" "$CORE_COOKIE" getnodeaddresses '[0]')
beam_dump=$(rpc_call "$BC_URL"   "$BC_COOKIE"   getnodeaddresses '[0]')
log "  core getnodeaddresses 0 -> $core_dump"
log "  beam getnodeaddresses 0 -> $beam_dump"
case "$core_dump" in OK\ *) : ;; *) fail "core getnodeaddresses 0 failed: $core_dump" ;; esac
case "$beam_dump" in OK\ *) : ;; *) fail "beamchain getnodeaddresses 0 failed: $beam_dump" ;; esac

# Validate beamchain's object for 8.8.8.8 against the exact 5-key shape + types,
# and cross-check the KEY SET against Core's object for the same addr.
SHAPE_RES=$(python3 - "$INJ_ADDR" "$INJ_PORT" "${beam_dump#OK }" "${core_dump#OK }" <<'PYEOF'
import sys, json
inj_addr, inj_port = sys.argv[1], int(sys.argv[2])
beam = json.loads(sys.argv[3])
core = json.loads(sys.argv[4])

if not isinstance(beam, list):
    print("FAIL beam-not-array"); sys.exit(0)
if not isinstance(core, list):
    print("FAIL core-not-array"); sys.exit(0)

def find(arr):
    for o in arr:
        if isinstance(o, dict) and o.get("address") == inj_addr and o.get("port") == inj_port:
            return o
    return None

b = find(beam)
if b is None:
    print("FAIL beam-missing-injected-addr"); sys.exit(0)

# EXACTLY the 5 keys, no more, no less.
want_keys = {"time", "services", "address", "port", "network"}
got_keys = set(b.keys())
if got_keys != want_keys:
    missing = want_keys - got_keys
    extra = got_keys - want_keys
    print("FAIL beam-keys missing=%s extra=%s" % (sorted(missing), sorted(extra))); sys.exit(0)

# Field values + types.
if b["address"] != inj_addr:
    print("FAIL beam-address=%r" % b["address"]); sys.exit(0)
if b["port"] != inj_port or not isinstance(b["port"], int) or isinstance(b["port"], bool):
    print("FAIL beam-port=%r" % b["port"]); sys.exit(0)
if b["network"] != "ipv4":
    print("FAIL beam-network=%r" % b["network"]); sys.exit(0)
# services MUST be an INTEGER (not a hex string, unlike getpeerinfo).
if not isinstance(b["services"], int) or isinstance(b["services"], bool):
    print("FAIL beam-services-not-int=%r" % b["services"]); sys.exit(0)
# time MUST be an INTEGER > 0.
if not isinstance(b["time"], int) or isinstance(b["time"], bool) or b["time"] <= 0:
    print("FAIL beam-time=%r" % b["time"]); sys.exit(0)

# Cross-check the KEY SET against Core's object for the same injected addr.
c = find(core)
if c is None:
    print("FAIL core-missing-injected-addr"); sys.exit(0)
if set(c.keys()) != want_keys:
    print("FAIL core-keys=%s" % sorted(c.keys())); sys.exit(0)
# Same TYPES on the shared fields (do NOT compare time value — clocks differ).
if not isinstance(c["services"], int) or isinstance(c["services"], bool):
    print("FAIL core-services-not-int=%r" % c["services"]); sys.exit(0)
if c["network"] != "ipv4":
    print("FAIL core-network=%r" % c["network"]); sys.exit(0)
if c["address"] != inj_addr or c["port"] != inj_port:
    print("FAIL core-addr/port=%r:%r" % (c["address"], c["port"])); sys.exit(0)

print("OK")
PYEOF
)
log "  shape check -> $SHAPE_RES"
SHAPE_OK="ok"
case "$SHAPE_RES" in
    OK) : ;;
    *) SHAPE_OK="$SHAPE_RES" ;;
esac
[[ "$SHAPE_OK" == "ok" ]] || fail "shape mismatch: $SHAPE_RES (errors=ok)"
log "shape OK"

# ══════════════════════════════════════════════════════════════════════════
# Assertion 3 — COUNT / NETWORK FILTER (beamchain semantics).
# ══════════════════════════════════════════════════════════════════════════
log "=== assertion 3: count + netfilter ==="
COUNT_OK="ok"
NETFILTER_OK="ok"

# getnodeaddresses 1 -> at most 1 element.
g1=$(rpc_call "$BC_URL" "$BC_COOKIE" getnodeaddresses '[1]')
log "  beam getnodeaddresses 1 -> $g1"
case "$g1" in
    OK\ *)
        n=$(echo "${g1#OK }" | python3 -c 'import sys,json; a=json.load(sys.stdin); print(len(a) if isinstance(a,list) else -1)')
        if [[ "$n" -lt 0 || "$n" -gt 1 ]]; then COUNT_OK="count1-len=$n"; fi
        ;;
    *) COUNT_OK="count1-failed:$g1" ;;
esac

# getnodeaddresses 0 "ipv4" -> the injected ipv4 addr present.
gv4=$(rpc_call "$BC_URL" "$BC_COOKIE" getnodeaddresses '[0, "ipv4"]')
log "  beam getnodeaddresses 0 ipv4 -> $gv4"
case "$gv4" in
    OK\ *)
        echo "${gv4#OK }" | python3 -c "
import sys, json
a = json.load(sys.stdin)
if not isinstance(a, list): sys.exit(2)
ok = any(isinstance(o,dict) and o.get('address')=='$INJ_ADDR' and o.get('network')=='ipv4' for o in a)
sys.exit(0 if ok else 1)
" || NETFILTER_OK="ipv4-filter-missing-addr"
        ;;
    *) NETFILTER_OK="ipv4-filter-failed:$gv4" ;;
esac

# getnodeaddresses 0 "onion" -> [] (only an ipv4 addr was injected).
gon=$(rpc_call "$BC_URL" "$BC_COOKIE" getnodeaddresses '[0, "onion"]')
log "  beam getnodeaddresses 0 onion -> $gon"
case "$gon" in
    OK\ *)
        echo "${gon#OK }" | python3 -c 'import sys,json; a=json.load(sys.stdin); sys.exit(0 if isinstance(a,list) and len(a)==0 else 1)' \
            || NETFILTER_OK="onion-filter-not-empty"
        ;;
    *) NETFILTER_OK="onion-filter-failed:$gon" ;;
esac

[[ "$COUNT_OK" == "ok" ]]     || fail "count semantics broken: $COUNT_OK (shape=ok errors=ok)"
[[ "$NETFILTER_OK" == "ok" ]] || fail "network-filter broken: $NETFILTER_OK (shape=ok errors=ok count=ok)"
log "count + netfilter OK"

# ── Verdict. ──────────────────────────────────────────────────────────────
pass "$SHAPE_OK" "$ERRORS_OK" "$COUNT_OK" "$NETFILTER_OK"

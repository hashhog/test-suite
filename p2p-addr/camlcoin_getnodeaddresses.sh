#!/usr/bin/env bash
#
# camlcoin_getnodeaddresses.sh — self-contained DIFFERENTIAL test for the
# getnodeaddresses / addpeeraddress P2P RPCs against a REAL bitcoind oracle.
#
# This is the first cell of the P2P axis (after the wallet + mempool-policy +
# getchaintxstats chapters). getnodeaddresses is a read-only addrman dump — NOT
# consensus — so the bar is EXACT output shape + param/error semantics, mirrored
# against a real Bitcoin Core regtest node run side-by-side.
#
# ── WHAT IS ASSERTED (Core net.cpp:911-970 + netbase.cpp:100-142) ───────────
#   1. ERROR PATHS (no addrman population needed — robust + deterministic):
#        getnodeaddresses -1        -> RPC error -8 "Address count out of range"
#        getnodeaddresses 1 "bogus" -> RPC error -8 "Network not recognized: bogus"
#      asserted on BOTH camlcoin AND Core (the error text/code is copied from the
#      live Core run, so any future Core wording drift is caught automatically).
#   2. SHAPE PATH:
#        addpeeraddress "8.8.8.8" 8333 on BOTH; getnodeaddresses 0 on BOTH.
#        camlcoin's array MUST contain an object for 8.8.8.8 with EXACTLY the 5
#        keys {time, services, address, port, network} (no more, no fewer), with
#        address=="8.8.8.8", port==8333, network=="ipv4", services an INTEGER
#        (not a hex string, unlike getpeerinfo), time an INTEGER > 0. The KEY SET
#        + value TYPES are compared to Core's object for the same injected addr;
#        `time` is NOT compared by value (clocks differ).
#   3. COUNT/FILTER:
#        getnodeaddresses 1        -> <= 1 element
#        getnodeaddresses 0 "ipv4" -> the ipv4 addr present
#        getnodeaddresses 0 "onion"-> [] (only an ipv4 addr was injected)
#
#   Ordering is treated as NON-DETERMINISTIC (Core's addrman shuffles the dump):
#   every assertion matches by CONTENT, never by array index.
#
# ── UNIFORM INTERFACE (mirrors test-suite/policy/camlcoin_policy.sh) ─────────
#   set -uo pipefail, idempotent, trap cleanup, scratch /tmp + unique ports, ONE
#   clean summary line on stdout, all noise -> stderr/log, exit 0/1. No args.
#
#   Summary line (stdout):
#     GETNODEADDRESSES camlcoin: PASS shape=ok errors=ok count=ok netfilter=ok
#     GETNODEADDRESSES camlcoin: FAIL <short reason>
#
# Touches ONLY /tmp/gna-camlcoin/ + /tmp/gna-core/ and ports
#   21975/21995 (camlcoin RPC/P2P) + 21976/21996 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/camlcoin/_build/default/bin/main.exe"
BITCOIND="$BASEDIR/bitcoin-core/build/bin/bitcoind"
BITCOINCLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

CC_DATADIR="/tmp/gna-camlcoin"
CC_RPC=21975
CC_P2P=21995
CC_LOG="$CC_DATADIR/node.log"

# camlcoin-specific Core scratch dir (avoid colliding with sibling fan-out
# agents that also use /tmp/gna-core for their own oracle).
CORE_DATADIR="/tmp/gna-core-camlcoin"
CORE_RPC=21976
CORE_P2P=21996

CC_PID=""
CC_COOKIE=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gna:camlcoin] $*" >&2; }

# ── Cleanup: stop both nodes + wipe scratch on any exit. ──────────────────
cleanup() {
    local ec=$?
    # Stop Core (daemonized) gracefully, then force.
    "$BITCOINCLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    if [[ -n "$CC_PID" ]] && kill -0 "$CC_PID" 2>/dev/null; then
        kill "$CC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CC_PID" 2>/dev/null || true
    fi
    # Reap only OUR OWN leftovers (matched by scratch datadir) — never blanket
    # fuser -k a port (a sibling fan-out agent / live node may share the range).
    pkill -f "$CC_DATADIR"   2>/dev/null || true
    pkill -f "$CORE_DATADIR" 2>/dev/null || true
    sleep 1
    rm -rf "$CC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "GETNODEADDRESSES camlcoin: PASS shape=$1 errors=$2 count=$3 netfilter=$4"; exit 0; }
fail() { echo "GETNODEADDRESSES camlcoin: FAIL $*"; exit 1; }

# ── camlcoin RPC helper (cookie auth, JSON-RPC 1.0). ──────────────────────
# cc_rpc <method> <json-params-array>  -> raw JSON response on stdout.
cc_rpc() {
    curl -s --max-time 15 -u "$CC_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$CC_RPC/" 2>/dev/null
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
# Only reap OUR OWN prior leftovers (matched by this test's scratch datadirs);
# NEVER blanket-kill a port, so a sibling fan-out agent / live node on a nearby
# port is left untouched. If a FOREIGN process still holds one of our ports we
# fail loudly rather than killing it.
log "resetting scratch state (camlcoin $CC_DATADIR :$CC_RPC/$CC_P2P, core $CORE_DATADIR :$CORE_RPC/$CORE_P2P)"
pkill -f "$CC_DATADIR"   2>/dev/null || true   # our camlcoin regtest node
pkill -f "$CORE_DATADIR" 2>/dev/null || true   # our bitcoind oracle
"$BITCOINCLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
sleep 2
# Wait (briefly) for our mandated ports to be free. In the parallel fan-out a
# sibling agent may transiently squat a nearby port; we wait it out rather than
# kill a process we don't own. Fail only if it never frees within the window.
for p in "$CC_RPC" "$CC_P2P" "$CORE_RPC" "$CORE_P2P"; do
    free_deadline=$(( $(date +%s) + 45 ))
    while ss -ltn 2>/dev/null | grep -q ":${p} "; do
        # reap our own leftover once more in case it's us
        pkill -f "$CC_DATADIR"   2>/dev/null || true
        pkill -f "$CORE_DATADIR" 2>/dev/null || true
        (( $(date +%s) < free_deadline )) || \
            fail "port ${p} stayed in use by another process for 45s — refusing to kill it; rerun once it's free"
        sleep 2
    done
done
rm -rf "$CC_DATADIR" "$CORE_DATADIR"
mkdir -p "$CC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v curl   >/dev/null 2>&1 || fail "curl not found on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
[[ -x "$NODE_BIN" ]]    || fail "camlcoin binary not found at $NODE_BIN (run dune build)"
[[ -x "$BITCOIND" ]]    || fail "bitcoind oracle not found at $BITCOIND"
[[ -x "$BITCOINCLI" ]]  || fail "bitcoin-cli not found at $BITCOINCLI"

# ── 2. Launch the real Core oracle (daemonized so it detaches cleanly). ───
log "launching bitcoind oracle (regtest) rpc=:$CORE_RPC p2p=:$CORE_P2P"
"$BITCOIND" -regtest -datadir="$CORE_DATADIR" -port="$CORE_P2P" -rpcport="$CORE_RPC" \
    -rpcbind=127.0.0.1 -rpcallowip=127.0.0.1 -listen=1 -dnsseed=0 -daemon \
    -printtoconsole=0 >/dev/null 2>&1
core_deadline=$(( $(date +%s) + 60 ))
core_ready=0
while (( $(date +%s) < core_deadline )); do
    if "$BITCOINCLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1; then
        core_ready=1; break
    fi
    sleep 1
done
(( core_ready == 1 )) || fail "bitcoind oracle RPC never came up within 60s"
log "bitcoind oracle RPC ready"

# core_rpc <method> [args...] -> stdout (raw); returns CLI exit code.
core_rpc() { "$BITCOINCLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# ── 3. Launch camlcoin on regtest. ────────────────────────────────────────
log "launching camlcoin (regtest) rpc=:$CC_RPC p2p=:$CC_P2P -> $CC_LOG"
"$NODE_BIN" --network regtest --datadir "$CC_DATADIR" \
    --port "$CC_P2P" --rpcport "$CC_RPC" >"$CC_LOG" 2>&1 &
CC_PID=$!
log "camlcoin pid=$CC_PID"
cc_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < cc_deadline )); do
    if [[ -z "$CC_COOKIE" && -f "$CC_DATADIR/.cookie" ]]; then
        CC_COOKIE=$(cat "$CC_DATADIR/.cookie")
    fi
    if [[ -n "$CC_COOKIE" ]]; then
        r=$(cc_rpc getblockcount '[]')
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$CC_PID" 2>/dev/null || { tail -n 20 "$CC_LOG" >&2 2>/dev/null || true; fail "camlcoin exited during startup (see $CC_LOG)"; }
    sleep 1
done
[[ -n "$CC_COOKIE" ]] || fail "camlcoin cookie never appeared within 60s"
cc_rpc getblockcount '[]' | grep -q '"result"' || fail "camlcoin RPC never responded within 60s"
log "camlcoin RPC ready"

# ── 4. JSON probe helpers (python3 = robust JSON parsing, no jq dep). ──────
# Extract the JSON-RPC "result" from a camlcoin response, or report the error.
# cc_call <method> <params> -> prints either "OK\t<result-json>" or "ERR\t<code>\t<message>"
cc_call() {
    local resp; resp="$(cc_rpc "$1" "$2")"
    python3 - "$resp" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception as e:
    print("PARSEFAIL\t%s" % e); sys.exit(0)
err = d.get("error")
if err:
    print("ERR\t%s\t%s" % (err.get("code"), err.get("message")))
else:
    print("OK\t%s" % json.dumps(d.get("result")))
PY
}

# ── 5. ERROR PATHS — assert on BOTH camlcoin and Core. ────────────────────
log "=== error paths ==="

# Core's exact code+message for each error (the oracle of record).
core_err() {  # core_err <args...> -> "CODE\tMESSAGE" (single line)
    local out; out="$(core_rpc "$@" 2>&1 1>/dev/null)"
    # bitcoin-cli prints: "error code: -8\nerror message:\n<message>"
    local code msg
    code=$(echo "$out" | sed -n 's/^error code: //p' | head -1)
    msg=$(echo "$out" | sed -n '/^error message:/{n;p}' | head -1)
    echo "${code}	${msg}"
}

# -- negative count --
CORE_NEG="$(core_err getnodeaddresses -1)"
CORE_NEG_CODE="${CORE_NEG%%	*}"; CORE_NEG_MSG="${CORE_NEG#*	}"
log "core  getnodeaddresses -1 -> code=$CORE_NEG_CODE msg='$CORE_NEG_MSG'"
[[ "$CORE_NEG_CODE" == "-8" ]] || fail "core sanity: getnodeaddresses -1 expected code -8 got '$CORE_NEG_CODE'"
[[ "$CORE_NEG_MSG" == "Address count out of range" ]] || fail "core sanity: -1 msg '$CORE_NEG_MSG' != 'Address count out of range'"

CC_NEG="$(cc_call getnodeaddresses '[-1]')"
log "caml  getnodeaddresses -1 -> $CC_NEG"
IFS=$'\t' read -r cc_neg_tag cc_neg_code cc_neg_msg <<< "$CC_NEG"
[[ "$cc_neg_tag" == "ERR" ]]                              || fail "camlcoin getnodeaddresses -1 did not error (got: $CC_NEG)"
[[ "$cc_neg_code" == "-8" ]]                              || fail "camlcoin getnodeaddresses -1 code '$cc_neg_code' != -8 (Core: $CORE_NEG_CODE)"
[[ "$cc_neg_msg" == "Address count out of range" ]]      || fail "camlcoin getnodeaddresses -1 msg '$cc_neg_msg' != 'Address count out of range'"

# -- unrecognized network --
CORE_NET="$(core_err getnodeaddresses 1 bogus)"
CORE_NET_CODE="${CORE_NET%%	*}"; CORE_NET_MSG="${CORE_NET#*	}"
log "core  getnodeaddresses 1 bogus -> code=$CORE_NET_CODE msg='$CORE_NET_MSG'"
[[ "$CORE_NET_CODE" == "-8" ]] || fail "core sanity: getnodeaddresses 1 bogus expected code -8 got '$CORE_NET_CODE'"
[[ "$CORE_NET_MSG" == "Network not recognized: bogus" ]] || fail "core sanity: bogus msg '$CORE_NET_MSG' != 'Network not recognized: bogus'"

CC_NET="$(cc_call getnodeaddresses '[1,"bogus"]')"
log "caml  getnodeaddresses 1 bogus -> $CC_NET"
IFS=$'\t' read -r cc_net_tag cc_net_code cc_net_msg <<< "$CC_NET"
[[ "$cc_net_tag" == "ERR" ]]                              || fail "camlcoin getnodeaddresses 1 bogus did not error (got: $CC_NET)"
[[ "$cc_net_code" == "-8" ]]                              || fail "camlcoin getnodeaddresses 1 bogus code '$cc_net_code' != -8 (Core: $CORE_NET_CODE)"
[[ "$cc_net_msg" == "Network not recognized: bogus" ]]   || fail "camlcoin getnodeaddresses 1 bogus msg '$cc_net_msg' != 'Network not recognized: bogus'"

ERRORS_TOK=ok
log "error paths: ok (both impls: -8 + exact Core messages)"

# ── 6. Fresh-addrman empty case (BEFORE injecting): []. ───────────────────
CC_EMPTY="$(cc_call getnodeaddresses '[0]')"
IFS=$'\t' read -r cc_empty_tag cc_empty_res <<< "$CC_EMPTY"
[[ "$cc_empty_tag" == "OK" ]]    || fail "camlcoin getnodeaddresses 0 on empty addrman errored (got: $CC_EMPTY)"
[[ "$cc_empty_res" == "[]" ]]    || fail "camlcoin getnodeaddresses 0 on empty addrman != [] (got: '$cc_empty_res')"
log "empty addrman: camlcoin returns [] (not an error)"

# ── 7. SHAPE PATH — inject 8.8.8.8:8333 on BOTH, dump, compare. ───────────
log "=== shape path ==="
core_rpc addpeeraddress 8.8.8.8 8333 >/dev/null 2>&1 || fail "core addpeeraddress 8.8.8.8 8333 failed"
CC_ADD="$(cc_call addpeeraddress '["8.8.8.8",8333]')"
IFS=$'\t' read -r cc_add_tag cc_add_res <<< "$CC_ADD"
[[ "$cc_add_tag" == "OK" ]] || fail "camlcoin addpeeraddress 8.8.8.8 8333 errored (got: $CC_ADD)"
echo "$cc_add_res" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('success') is True else 1)" \
    || fail "camlcoin addpeeraddress did not return {success:true} (got: $cc_add_res)"

# Core's object for 8.8.8.8 -> reference KEY SET (ordered) + value types.
CORE_DUMP="$(core_rpc getnodeaddresses 0 2>/dev/null)"
CORE_SHAPE="$(python3 - "$CORE_DUMP" <<'PY'
import sys, json
arr = json.loads(sys.argv[1])
match = [o for o in arr if o.get("address") == "8.8.8.8"]
if not match:
    print("MISSING"); sys.exit(0)
o = match[0]
keys = list(o.keys())
print("KEYS\t%s" % ",".join(keys))
PY
)"
log "core 8.8.8.8 object: $CORE_SHAPE"
[[ "$CORE_SHAPE" == KEYS* ]] || fail "core sanity: getnodeaddresses 0 has no 8.8.8.8 object after addpeeraddress (got: $CORE_SHAPE)"
CORE_KEYS="${CORE_SHAPE#KEYS	}"
# Core's exact key set/order (independent assertion against the spec, too).
[[ "$CORE_KEYS" == "time,services,address,port,network" ]] \
    || fail "core sanity: 8.8.8.8 key order '$CORE_KEYS' != 'time,services,address,port,network'"

# camlcoin's dump -> assert the 8.8.8.8 object EXACTLY matches the 5-key set,
# correct value types, address/port/network values; time>0; services integer.
CC_DUMP="$(cc_rpc getnodeaddresses '[0]')"
SHAPE_VERDICT="$(python3 - "$CC_DUMP" "$CORE_KEYS" <<'PY'
import sys, json
resp = json.loads(sys.argv[1])
core_keys = sys.argv[2].split(",")
res = resp.get("result")
if not isinstance(res, list):
    print("FAIL\tcamlcoin getnodeaddresses 0 result is not a JSON array"); sys.exit(0)
match = [o for o in res if isinstance(o, dict) and o.get("address") == "8.8.8.8"]
if not match:
    print("FAIL\tcamlcoin dump has no object for 8.8.8.8 (got %s)" % json.dumps(res)); sys.exit(0)
o = match[0]
keys = list(o.keys())
# EXACT key set (no extra, no missing) AND same order as Core.
if keys != core_keys:
    print("FAIL\tcamlcoin 8.8.8.8 keys %s != Core keys %s" % (keys, core_keys)); sys.exit(0)
# value types + values
def is_int(x): return isinstance(x, int) and not isinstance(x, bool)
if not is_int(o["time"]):
    print("FAIL\tcamlcoin 'time' is not an integer (%r)" % o["time"]); sys.exit(0)
if o["time"] <= 0:
    print("FAIL\tcamlcoin 'time' not > 0 (%r)" % o["time"]); sys.exit(0)
if not is_int(o["services"]):
    print("FAIL\tcamlcoin 'services' is not an integer (got %r; must NOT be a hex string)" % o["services"]); sys.exit(0)
if not is_int(o["port"]):
    print("FAIL\tcamlcoin 'port' is not an integer (%r)" % o["port"]); sys.exit(0)
if o["address"] != "8.8.8.8":
    print("FAIL\tcamlcoin 'address' != 8.8.8.8 (%r)" % o["address"]); sys.exit(0)
if o["port"] != 8333:
    print("FAIL\tcamlcoin 'port' != 8333 (%r)" % o["port"]); sys.exit(0)
if o["network"] != "ipv4":
    print("FAIL\tcamlcoin 'network' != ipv4 (%r)" % o["network"]); sys.exit(0)
print("OK\tkeys=%s services=%r time=%r" % (",".join(keys), o["services"], o["time"]))
PY
)"
log "camlcoin 8.8.8.8 shape verdict: $SHAPE_VERDICT"
IFS=$'\t' read -r shape_tag shape_detail <<< "$SHAPE_VERDICT"
[[ "$shape_tag" == "OK" ]] || fail "$shape_detail"
SHAPE_TOK=ok

# ── 8. COUNT / FILTER. ────────────────────────────────────────────────────
log "=== count / filter ==="

# getnodeaddresses 1 -> <= 1 element.
CC_LIM="$(cc_rpc getnodeaddresses '[1]')"
LIM_VERDICT="$(python3 - "$CC_LIM" <<'PY'
import sys, json
res = json.loads(sys.argv[1]).get("result")
if not isinstance(res, list):
    print("FAIL\tgetnodeaddresses 1 result not a list"); sys.exit(0)
if len(res) > 1:
    print("FAIL\tgetnodeaddresses 1 returned %d elements (> 1)" % len(res)); sys.exit(0)
print("OK\tlen=%d" % len(res))
PY
)"
log "camlcoin getnodeaddresses 1 -> $LIM_VERDICT"
[[ "$LIM_VERDICT" == OK* ]] || fail "${LIM_VERDICT#FAIL	}"

# getnodeaddresses 0 ipv4 -> the ipv4 addr present.
CC_IPV4="$(cc_rpc getnodeaddresses '[0,"ipv4"]')"
IPV4_VERDICT="$(python3 - "$CC_IPV4" <<'PY'
import sys, json
res = json.loads(sys.argv[1]).get("result")
if not isinstance(res, list):
    print("FAIL\tgetnodeaddresses 0 ipv4 result not a list"); sys.exit(0)
addrs = [o.get("address") for o in res if isinstance(o, dict)]
if "8.8.8.8" not in addrs:
    print("FAIL\tgetnodeaddresses 0 ipv4 missing 8.8.8.8 (got %s)" % addrs); sys.exit(0)
# every returned element must be ipv4
bad = [o for o in res if o.get("network") != "ipv4"]
if bad:
    print("FAIL\tgetnodeaddresses 0 ipv4 returned non-ipv4 element(s): %s" % json.dumps(bad)); sys.exit(0)
print("OK\tipv4 addrs=%s" % addrs)
PY
)"
log "camlcoin getnodeaddresses 0 ipv4 -> $IPV4_VERDICT"
[[ "$IPV4_VERDICT" == OK* ]] || fail "${IPV4_VERDICT#FAIL	}"

# getnodeaddresses 0 onion -> [] (only ipv4 injected).
CC_ONION="$(cc_call getnodeaddresses '[0,"onion"]')"
IFS=$'\t' read -r cc_onion_tag cc_onion_res <<< "$CC_ONION"
[[ "$cc_onion_tag" == "OK" ]] || fail "camlcoin getnodeaddresses 0 onion errored (got: $CC_ONION)"
[[ "$cc_onion_res" == "[]" ]] || fail "camlcoin getnodeaddresses 0 onion != [] when only ipv4 injected (got: '$cc_onion_res')"
log "camlcoin getnodeaddresses 0 onion -> [] (ok)"

COUNT_TOK=ok
NETFILTER_TOK=ok

# ── 9. Verdict. ───────────────────────────────────────────────────────────
log "PASS: shape (5-key Core-exact object) + error codes/messages + count cap + network filter all parity-with-Core"
pass "$SHAPE_TOK" "$ERRORS_TOK" "$COUNT_TOK" "$NETFILTER_TOK"

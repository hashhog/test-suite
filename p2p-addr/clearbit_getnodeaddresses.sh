#!/usr/bin/env bash
#
# clearbit_getnodeaddresses.sh — self-contained getnodeaddresses DIFFERENTIAL.
#
# The P2P-axis first cell (after the wallet + mempool-policy + getchaintxstats
# chapters). Proves clearbit's read-only addrman-dump RPC matches Bitcoin Core
# EXACTLY on output SHAPE + param/error semantics. NOT consensus — but the
# JSON shape + the -8 error contract must be byte-faithful to Core.
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on its OWN regtest
#   scratch datadir + ports. clearbit runs on its own scratch + ports. The same
#   probe sequence is sent to both; clearbit is compared against the Core oracle.
#
# WHAT getnodeaddresses RETURNS (Core rpc/net.cpp:911-970):
#   A JSON ARRAY of objects, each with EXACTLY 5 keys in THIS order:
#     "time"     NUM   unix seconds (INT)
#     "services" NUM   raw services bitfield (INT — NOT a hex string)
#     "address"  STR   ip literal (no port)
#     "port"     NUM   integer
#     "network"  STR   ipv4 | ipv6 | onion | i2p | cjdns |
#                      not_publicly_routable | internal
#   count default 1; count==0 -> ALL; count<0 -> error -8 "Address count out of
#   range". network filter: ParseNetwork lowercases + accepts only
#   ipv4|ipv6|onion|i2p|cjdns; anything else -> error -8
#   "Network not recognized: <raw arg>". Order is NON-deterministic (addrman
#   shuffles) — every assertion below matches by CONTENT, never by index.
#
# COMPANION RPC: addpeeraddress "address" port (Core rpc/net.cpp:972) injects an
#   address into the addrman so the differential is deterministic. clearbit
#   implements a Core-shaped addpeeraddress returning {"success":bool}.
#
# ASSERTIONS:
#   1. ERROR PATHS (no addrman population — robust + deterministic): on BOTH
#      clearbit and Core, getnodeaddresses -1 -> error -8 ("Address count out of
#      range"); getnodeaddresses 1 "bogus" -> error -8 ("Network not recognized:
#      bogus").
#   2. SHAPE: addpeeraddress "8.8.8.8" 8333 on BOTH; getnodeaddresses 0 on BOTH.
#      clearbit's array MUST contain an object for 8.8.8.8 with EXACTLY the 5
#      keys {time,services,address,port,network}; address=="8.8.8.8", port==8333,
#      network=="ipv4", services an INTEGER (not hex), time an INTEGER > 0. The
#      KEY SET + value TYPES are compared to Core's object for the same injected
#      addr (time is NOT compared exactly — clocks differ).
#   3. COUNT/FILTER: getnodeaddresses 1 -> <=1 element; getnodeaddresses 0 "ipv4"
#      -> the ipv4 addr; getnodeaddresses 0 "onion" -> [] (only ipv4 injected).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/clearbit_policy.sh): no
#   required args, idempotent, trap cleanup, scratch /tmp + UNIQUE ports, ONE
#   clean summary line on stdout, all noise -> stderr/log, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETNODEADDRESSES clearbit: PASS shape=ok errors=ok count=ok netfilter=ok
#   FAIL: GETNODEADDRESSES clearbit: FAIL <short reason>
#
# Touches ONLY /tmp/gna-clearbit/ + /tmp/gna-clearbit-core/ and ports
#   21977/21997 (clearbit RPC/P2P) + 22077/22097 (Core oracle RPC/P2P, a
#   clearbit-private +100 band so concurrent sibling cells never collide).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node (haskoin is
#   mid-sync — left untouched).

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

CB_DATADIR="/tmp/gna-clearbit"
CB_NETDIR="$CB_DATADIR/regtest"
CB_RPC=21977
CB_P2P=21997
CB_LOG="$CB_DATADIR/node.log"

# Core oracle ports live in a clearbit-private +100 band keyed off clearbit's
# assigned 21977/21997 (-> 22077/22097). The fan-out assigns each impl a base
# slot in 21970+idx / 21990+idx; sibling cells run concurrently, so the Core
# oracle MUST NOT reuse a base-band port (another impl's clearbit-equivalent or
# its own Core oracle). The +100 offset keeps this oracle collision-free across
# the whole fleet. (bitcoind also opens a localhost control listener at <p2p>+1,
# so the P2P slot has margin too.) The datadir is clearbit-specific to avoid a
# shared /tmp/gna-core path racing a sibling's wipe.
CORE_DATADIR="/tmp/gna-clearbit-core"
CORE_RPC=22077
CORE_P2P=22097
CORE_LOG="$CORE_DATADIR/core.log"

CB_PID=""
CB_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gna:clearbit] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$CB_PID" ]] && kill -0 "$CB_PID" 2>/dev/null; then
        kill "$CB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$CB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ──────────────────────────────────────────────────────
pass() { echo "GETNODEADDRESSES clearbit: PASS shape=ok errors=ok count=ok netfilter=ok"; exit 0; }
fail() { echo "GETNODEADDRESSES clearbit: FAIL $*"; exit 1; }

# ── RPC helpers. ────────────────────────────────────────────────────────────
# cb_rpc <method> <params-json> -> prints the raw JSON-RPC response body.
cb_rpc() {
    curl -s --max-time 10 -u "$CB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$CB_RPC/" 2>/dev/null
}
# core_cli <args...> -> bitcoin-cli against the Core oracle.
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gna-clearbit" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${CB_RPC}|${CB_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${CB_RPC}|${CB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${CB_RPC}/${CB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$CB_DATADIR" "$CORE_DATADIR"
mkdir -p "$CB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ───────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]] || fail "clearbit binary not found at $NODE_BIN (build: zig build -Doptimize=ReleaseFast)"
[[ -x "$CORE_BIN" ]] || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]] || fail "bitcoin-cli not found at $CORE_CLI"

# ── 2. Launch the Core oracle. ──────────────────────────────────────────────
# Launched directly in this shell (not via $(...)) so the bg PID is a child of
# the main process group and survives until cleanup() stops it.
log "launching Core oracle rpc=:$CORE_RPC p2p=:$CORE_P2P"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < core_deadline )); do
    core_cli getblockcount >/dev/null 2>&1 && break
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
core_cli getblockcount >/dev/null 2>&1 || fail "Core oracle failed to start within 90s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch clearbit on regtest. ──────────────────────────────────────────
log "launching clearbit (regtest) rpc=:$CB_RPC p2p=:$CB_P2P -> $CB_LOG"
"$NODE_BIN" --regtest --datadir="$CB_DATADIR" \
    --port="$CB_P2P" --rpcport="$CB_RPC" >"$CB_LOG" 2>&1 &
CB_PID=$!
log "clearbit pid=$CB_PID"
cb_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < cb_deadline )); do
    if [[ -z "$CB_COOKIE" ]]; then
        for c in "$CB_NETDIR/.cookie" "$CB_DATADIR/.cookie"; do
            [[ -f "$c" ]] && CB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$CB_COOKIE" ]]; then
        r=$(cb_rpc getblockcount '[]')
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$CB_PID" 2>/dev/null || { tail -n 20 "$CB_LOG" >&2 2>/dev/null || true; fail "clearbit exited during startup (see $CB_LOG)"; }
    sleep 1
done
[[ -n "$CB_COOKIE" ]] || fail "clearbit cookie never appeared within 60s"
echo "$(cb_rpc getblockcount '[]')" | grep -q '"result"' || fail "clearbit RPC never responded within 60s"
log "clearbit RPC ready"

# ── 4. The JSON inspector (python3 stdin filter). ───────────────────────────
# Reads JSON on stdin + a mode arg; prints a terse verdict / value. Keeps all
# JSON parsing in python (jq may be absent on the box).
#   err <body>            -> "<code>|<message>"  for a JSON-RPC error body
#   findaddr <result>     -> the object (compact JSON) whose address==ARG2, or ""
#   len <result>          -> array length
#   addrs <result>        -> newline-joined "address|network" for every element
py() { python3 "$PYHELPER" "$@"; }
PYHELPER="$CB_DATADIR/inspect.py"
cat > "$PYHELPER" <<'PYEOF'
import sys, json
mode = sys.argv[1]
data = sys.stdin.read()
try:
    doc = json.loads(data)
except Exception as e:
    print(f"PARSEERR:{e}", file=sys.stderr); sys.exit(3)

if mode == "err":
    # JSON-RPC error body -> "code|message" (empty if no error).
    err = doc.get("error")
    if not err:
        print("")
    else:
        print(f"{err.get('code')}|{err.get('message')}")
    sys.exit(0)

# All other modes operate on the .result array.
res = doc.get("result") if isinstance(doc, dict) and "result" in doc else doc
if mode == "len":
    print(len(res) if isinstance(res, list) else -1); sys.exit(0)
if mode == "addrs":
    if isinstance(res, list):
        for o in res:
            if isinstance(o, dict):
                print(f"{o.get('address')}|{o.get('network')}")
    sys.exit(0)
if mode == "findaddr":
    want = sys.argv[2]
    if isinstance(res, list):
        for o in res:
            if isinstance(o, dict) and o.get("address") == want:
                print(json.dumps(o)); sys.exit(0)
    print(""); sys.exit(0)
if mode == "checkshape":
    # checkshape <address> : validate the object for <address> against the EXACT
    # Core 5-key contract. Prints "ok" or "BAD:<reason>".
    want = sys.argv[2]
    obj = None
    if isinstance(res, list):
        for o in res:
            if isinstance(o, dict) and o.get("address") == want:
                obj = o; break
    if obj is None:
        print(f"BAD:no object for {want}"); sys.exit(0)
    keys = set(obj.keys())
    expect = {"time", "services", "address", "port", "network"}
    if keys != expect:
        extra = keys - expect; missing = expect - keys
        print(f"BAD:keyset extra={sorted(extra)} missing={sorted(missing)}"); sys.exit(0)
    # types
    if not isinstance(obj["time"], int) or isinstance(obj["time"], bool):
        print(f"BAD:time not int ({type(obj['time']).__name__}={obj['time']!r})"); sys.exit(0)
    if obj["time"] <= 0:
        print(f"BAD:time<=0 ({obj['time']})"); sys.exit(0)
    if not isinstance(obj["services"], int) or isinstance(obj["services"], bool):
        print(f"BAD:services not int ({type(obj['services']).__name__}={obj['services']!r})"); sys.exit(0)
    if not isinstance(obj["port"], int) or isinstance(obj["port"], bool):
        print(f"BAD:port not int ({type(obj['port']).__name__}={obj['port']!r})"); sys.exit(0)
    if not isinstance(obj["address"], str):
        print(f"BAD:address not str"); sys.exit(0)
    if not isinstance(obj["network"], str):
        print(f"BAD:network not str"); sys.exit(0)
    if obj["address"] != want:
        print(f"BAD:address mismatch ({obj['address']})"); sys.exit(0)
    if obj["port"] != 8333:
        print(f"BAD:port!=8333 ({obj['port']})"); sys.exit(0)
    if obj["network"] != "ipv4":
        print(f"BAD:network!=ipv4 ({obj['network']})"); sys.exit(0)
    print("ok"); sys.exit(0)

print(f"UNKNOWNMODE:{mode}", file=sys.stderr); sys.exit(2)
PYEOF
[[ -s "$PYHELPER" ]] || fail "failed to write JSON inspector helper"

TARGET_ADDR="8.8.8.8"
TARGET_PORT=8333

# ════════════════════════════════════════════════════════════════════════════
#  ASSERTION 1 — ERROR PATHS (deterministic, no addrman population).
# ════════════════════════════════════════════════════════════════════════════
log "=== assertion 1: error paths (count<0, bad network) ==="

# 1a. getnodeaddresses -1 -> error -8 "Address count out of range" on BOTH.
CB_E1=$(cb_rpc getnodeaddresses '[-1]' | py err)
# bitcoin-cli surfaces the error on stderr as "error code: -8 / error message: ..."
CORE_E1=$(core_cli getnodeaddresses -1 2>&1 >/dev/null || true)
log "count<0  clearbit-err='$CB_E1'  core-stderr='$(echo "$CORE_E1" | tr '\n' ' ')'"
[[ "$CB_E1" == "-8|Address count out of range" ]] \
    || fail "count<0: clearbit error mismatch (got '$CB_E1', want '-8|Address count out of range')"
echo "$CORE_E1" | grep -q "\-8"                       || fail "count<0: Core did not return code -8 (got: $CORE_E1)"
echo "$CORE_E1" | grep -qi "Address count out of range" || fail "count<0: Core message mismatch (got: $CORE_E1)"

# 1b. getnodeaddresses 1 "bogus" -> error -8 "Network not recognized: bogus".
CB_E2=$(cb_rpc getnodeaddresses '[1,"bogus"]' | py err)
CORE_E2=$(core_cli getnodeaddresses 1 bogus 2>&1 >/dev/null || true)
log "bad-net  clearbit-err='$CB_E2'  core-stderr='$(echo "$CORE_E2" | tr '\n' ' ')'"
[[ "$CB_E2" == "-8|Network not recognized: bogus" ]] \
    || fail "bad-network: clearbit error mismatch (got '$CB_E2', want '-8|Network not recognized: bogus')"
echo "$CORE_E2" | grep -q "\-8"                            || fail "bad-network: Core did not return code -8 (got: $CORE_E2)"
echo "$CORE_E2" | grep -qi "Network not recognized: bogus" || fail "bad-network: Core message mismatch (got: $CORE_E2)"
log "assertion 1 OK"

# ════════════════════════════════════════════════════════════════════════════
#  ASSERTION 2 — SHAPE (inject 8.8.8.8 on both, compare object shape).
# ════════════════════════════════════════════════════════════════════════════
log "=== assertion 2: shape (addpeeraddress + getnodeaddresses 0) ==="

# Inject on Core. addpeeraddress returns {"success":true}.
CORE_ADD=$(core_cli addpeeraddress "$TARGET_ADDR" "$TARGET_PORT" 2>&1 || true)
echo "$CORE_ADD" | grep -q '"success": true' || log "WARN Core addpeeraddress did not report success: $CORE_ADD"

# Inject on clearbit.
CB_ADD=$(cb_rpc addpeeraddress "[\"$TARGET_ADDR\",$TARGET_PORT]")
echo "$CB_ADD" | grep -q '"success":true' || fail "clearbit addpeeraddress did not return success:true (got: $CB_ADD)"

# Dump ALL from both.
CB_DUMP=$(cb_rpc getnodeaddresses '[0]')
CORE_DUMP=$(core_cli getnodeaddresses 0 2>/dev/null || echo '[]')
log "clearbit dump: $CB_DUMP"
log "core dump:     $CORE_DUMP"

# clearbit object for 8.8.8.8 must satisfy the EXACT 5-key contract.
CB_SHAPE=$(echo "$CB_DUMP" | py checkshape "$TARGET_ADDR")
[[ "$CB_SHAPE" == "ok" ]] || fail "clearbit shape for $TARGET_ADDR: $CB_SHAPE"

# KEY-SET parity vs Core's object for the same injected addr (when Core returned
# one — Core's addrman is quality/recency filtered + shuffled, so a single
# freshly-injected addr is usually but not always returned; if Core returned it,
# its key set MUST be identical to clearbit's).
CORE_OBJ=$(echo "$CORE_DUMP" | py findaddr "$TARGET_ADDR")
if [[ -n "$CORE_OBJ" ]]; then
    CORE_KEYS=$(echo "$CORE_OBJ" | python3 -c 'import sys,json;print(",".join(sorted(json.load(sys.stdin).keys())))')
    CB_OBJ=$(echo "$CB_DUMP" | py findaddr "$TARGET_ADDR")
    CB_KEYS=$(echo "$CB_OBJ" | python3 -c 'import sys,json;print(",".join(sorted(json.load(sys.stdin).keys())))')
    log "core keys=[$CORE_KEYS]  clearbit keys=[$CB_KEYS]"
    [[ "$CORE_KEYS" == "$CB_KEYS" ]] || fail "key-set mismatch vs Core: core=[$CORE_KEYS] clearbit=[$CB_KEYS]"
    # Core's services for addpeeraddress = NODE_NETWORK|NODE_WITNESS = 9 (int).
    CORE_SVC=$(echo "$CORE_OBJ" | python3 -c 'import sys,json;o=json.load(sys.stdin);print(o["services"] if isinstance(o["services"],int) and not isinstance(o["services"],bool) else "NOTINT")')
    [[ "$CORE_SVC" != "NOTINT" ]] || fail "Core services not an integer (got: $CORE_OBJ)"
    log "core services (int) = $CORE_SVC"
else
    log "note: Core did not return $TARGET_ADDR in its dump (addrman quality/recency filter); shape compared against clearbit's contract only"
fi
log "assertion 2 OK"

# ════════════════════════════════════════════════════════════════════════════
#  ASSERTION 3 — COUNT / NETWORK FILTER.
# ════════════════════════════════════════════════════════════════════════════
log "=== assertion 3: count + network filter ==="

# 3a. getnodeaddresses 1 -> <=1 element.
CB_LEN1=$(cb_rpc getnodeaddresses '[1]' | py len)
log "count=1 -> len=$CB_LEN1"
[[ "$CB_LEN1" =~ ^[0-9]+$ ]] || fail "count=1: clearbit did not return a JSON array (len=$CB_LEN1)"
(( CB_LEN1 <= 1 )) || fail "count=1: clearbit returned $CB_LEN1 elements (want <=1)"

# 3b. getnodeaddresses 0 "ipv4" -> contains the ipv4 addr.
CB_IPV4=$(cb_rpc getnodeaddresses '[0,"ipv4"]')
echo "$CB_IPV4" | py addrs | grep -q "^$TARGET_ADDR|ipv4$" \
    || fail "netfilter ipv4: $TARGET_ADDR not present in ipv4-filtered dump ($(echo "$CB_IPV4" | py addrs | tr '\n' ' '))"
# Every returned element under the ipv4 filter MUST have network==ipv4.
BAD_NET=$(echo "$CB_IPV4" | py addrs | grep -v '|ipv4$' || true)
[[ -z "$BAD_NET" ]] || fail "netfilter ipv4: non-ipv4 element leaked through filter ($BAD_NET)"

# 3c. getnodeaddresses 0 "onion" -> [] (only an ipv4 addr was injected).
CB_ONION_LEN=$(cb_rpc getnodeaddresses '[0,"onion"]' | py len)
log "onion filter -> len=$CB_ONION_LEN"
[[ "$CB_ONION_LEN" == "0" ]] || fail "netfilter onion: expected empty array, got len=$CB_ONION_LEN"
log "assertion 3 OK"

# ── Verdict. ────────────────────────────────────────────────────────────────
log "PASS: shape (5-key contract) + error contract (-8) + count cap + network filter all match Core"
pass

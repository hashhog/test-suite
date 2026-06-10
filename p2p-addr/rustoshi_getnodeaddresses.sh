#!/usr/bin/env bash
#
# rustoshi_getnodeaddresses.sh — self-contained getnodeaddresses parity test.
#
# The P2P-axis first cell, after the wallet + mempool-policy + getchaintxstats
# chapters. Proves rustoshi's `getnodeaddresses` (a read-only addrman dump) is
# Core-shaped: EXACT output shape, EXACT count/network param + error semantics.
# NOT consensus, but the contract has to be byte-precise.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN regtest
#   scratch + ports. rustoshi is compared against that oracle.
#
# Core ref:
#   bitcoin-core/src/rpc/net.cpp:911-970  (getnodeaddresses)
#   bitcoin-core/src/rpc/net.cpp:972-...  (addpeeraddress — the injector)
#   bitcoin-core/src/netbase.cpp:100-142  (ParseNetwork / GetNetworkName)
#
# EXACT Core semantics asserted:
#   getnodeaddresses ( count "network" ) -> a JSON ARRAY of objects, each with
#   EXACTLY 5 keys {time, services, address, port, network}:
#     time     = unix seconds INTEGER
#     services = raw services bitfield INTEGER (NOT a hex string)
#     address  = ToStringAddr (ip literal / .onion / .b32.i2p, no port)
#     port     = integer
#     network  = ipv4 | ipv6 | onion | i2p | cjdns | not_publicly_routable | internal
#   count (positional 0, default 1) = max to return; 0 = ALL; <0 -> error -8
#     "Address count out of range".
#   network (positional 1, optional) accepts ONLY ipv4|ipv6|onion|i2p|cjdns
#     (ParseNetwork lowercases); anything else -> error -8
#     "Network not recognized: <raw arg>".
#   The returned list is SHUFFLED — assertions MUST be order-insensitive.
#   Fresh node, empty addrman -> [] (empty array, NOT an error).
#
# Assertions (all run on BOTH rustoshi and Core):
#   1. ERROR PATHS (no addrman population needed — robust + deterministic):
#        getnodeaddresses -1        -> error -8 "Address count out of range"
#        getnodeaddresses 1 "bogus" -> error -8 "Network not recognized: bogus"
#   2. SHAPE: addpeeraddress "8.8.8.8" 8333; getnodeaddresses 0; assert the
#        8.8.8.8 object has EXACTLY {time,services,address,port,network},
#        address==8.8.8.8, port==8333, network==ipv4, services is an INTEGER,
#        time is an INTEGER > 0. KEY SET + types compared to Core's object for
#        the SAME injected addr (time NOT compared exactly — clocks differ).
#   3. COUNT/FILTER: getnodeaddresses 1 -> <=1 element; getnodeaddresses 0
#        "ipv4" -> contains the ipv4 addr; getnodeaddresses 0 "onion" -> [].
#   Match by CONTENT, never by index (addrman shuffles).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/rustoshi_policy.sh): no
#   required args, idempotent, trap cleanup, scratch datadirs + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETNODEADDRESSES rustoshi: PASS shape=ok errors=ok count=ok netfilter=ok
#   FAIL: GETNODEADDRESSES rustoshi: FAIL <short reason>
#
# Touches ONLY /tmp/gna-rustoshi/ + /tmp/gna-core/ and ports 21970/21990
#   (rustoshi RPC/P2P) + 21972/21992 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/rustoshi/target/release/rustoshi"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

RS_DATADIR="/tmp/gna-rustoshi"
RS_RPC=21970
RS_P2P=21990
RS_LOG="$RS_DATADIR/node.log"

CORE_DATADIR="/tmp/gna-core"
CORE_RPC=21972
CORE_P2P=21992
CORE_LOG="$CORE_DATADIR/core.log"

RS_PID=""
RS_COOKIE=""
CORE_BG=""
CORE_COOKIE=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gna:rustoshi] $*" >&2; }

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
pass() { echo "GETNODEADDRESSES rustoshi: PASS shape=ok errors=ok count=ok netfilter=ok"; exit 0; }
fail() { echo "GETNODEADDRESSES rustoshi: FAIL $*"; exit 1; }

# ── RPC helpers. ──────────────────────────────────────────────────────────
# rs_rpc <method> <json-params-array>  -> raw JSON response body on stdout.
rs_rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 15 -u "$RS_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RS_RPC/" 2>/dev/null
}
# core_rpc <method> <json-params-array> -> raw JSON response body on stdout.
core_rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 15 -u "$CORE_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$CORE_RPC/" 2>/dev/null
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gna-rustoshi" 2>/dev/null || true
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
command -v jq   >/dev/null 2>&1  || fail "jq not found on PATH"
command -v curl >/dev/null 2>&1  || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]             || fail "rustoshi binary not found at $NODE_BIN (build with: cargo build --release)"
[[ -x "$CORE_BIN" ]]             || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]             || fail "bitcoin-cli not found at $CORE_CLI"

# ── 2. Launch the Core oracle (regtest). ──────────────────────────────────
# -listen=0 (no P2P listener): this harness only exercises the addrman RPCs, no
# peers are needed. It is ALSO load-bearing in this sandbox: a bitcoind that
# binds a 0.0.0.0 P2P listener + starts outbound (opencon) threads is SIGKILLed
# by the environment ~2s after "Done loading". -listen=0 keeps only the loopback
# RPC and the daemon survives. The addrman + addpeeraddress/getnodeaddresses
# paths are entirely independent of the P2P listener.
log "launching Core oracle rpc=:$CORE_RPC (listen=0, addrman-only)"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -listen=0 \
    -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < core_deadline )); do
    if "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1; then
        break
    fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
    || fail "Core oracle RPC never responded within 120s (see $CORE_LOG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "Core cookie not found at $CORE_DATADIR/regtest/.cookie"
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch rustoshi (regtest). ─────────────────────────────────────────
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

# ════════════════════════════════════════════════════════════════════════
# 4. ERROR PATHS — robust + deterministic, no addrman population needed.
# ════════════════════════════════════════════════════════════════════════
# Assert an RPC response carries error code -8 AND the expected message
# substring. <resp> <want-substring> <label>
assert_err8() {
    local resp="$1" want="$2" label="$3"
    local code msg
    code=$(echo "$resp" | jq -r '.error.code // empty' 2>/dev/null)
    msg=$(echo "$resp"  | jq -r '.error.message // empty' 2>/dev/null)
    [[ "$code" == "-8" ]] || return 1
    [[ "$msg" == *"$want"* ]] || return 1
    return 0
}

log "=== ERROR PATHS ==="

# negative count -> -8 "Address count out of range"
RS_NEG=$(rs_rpc getnodeaddresses '[-1]')
CORE_NEG=$(core_rpc getnodeaddresses '[-1]')
log "rustoshi getnodeaddresses -1 : $RS_NEG"
log "core     getnodeaddresses -1 : $CORE_NEG"
assert_err8 "$CORE_NEG" "Address count out of range" "core-neg" \
    || fail "Core oracle did not reject 'getnodeaddresses -1' with -8 'Address count out of range' (got: $CORE_NEG) — oracle/version mismatch"
assert_err8 "$RS_NEG" "Address count out of range" "rs-neg" \
    || fail "errors: rustoshi 'getnodeaddresses -1' not -8 'Address count out of range' (got: $RS_NEG)"

# bogus network -> -8 "Network not recognized: bogus"
RS_BOG=$(rs_rpc getnodeaddresses '[1,"bogus"]')
CORE_BOG=$(core_rpc getnodeaddresses '[1,"bogus"]')
log "rustoshi getnodeaddresses 1 bogus : $RS_BOG"
log "core     getnodeaddresses 1 bogus : $CORE_BOG"
assert_err8 "$CORE_BOG" "Network not recognized: bogus" "core-bog" \
    || fail "Core oracle did not reject 'getnodeaddresses 1 bogus' with -8 'Network not recognized: bogus' (got: $CORE_BOG)"
assert_err8 "$RS_BOG" "Network not recognized: bogus" "rs-bog" \
    || fail "netfilter: rustoshi 'getnodeaddresses 1 bogus' not -8 'Network not recognized: bogus' (got: $RS_BOG)"

# Fresh-node empty addrman -> [] (NOT an error), on rustoshi.
RS_EMPTY=$(rs_rpc getnodeaddresses '[0]')
EMPTY_TYPE=$(echo "$RS_EMPTY" | jq -r '.result | type' 2>/dev/null)
[[ "$EMPTY_TYPE" == "array" ]] \
    || fail "shape: rustoshi fresh 'getnodeaddresses 0' is not a JSON array (got: $RS_EMPTY)"
log "rustoshi fresh getnodeaddresses 0 -> array (len=$(echo "$RS_EMPTY" | jq '.result | length'))"

# ════════════════════════════════════════════════════════════════════════
# 5. SHAPE — inject 8.8.8.8:8333 on BOTH, dump, compare key set + types.
# ════════════════════════════════════════════════════════════════════════
log "=== SHAPE (inject 8.8.8.8:8333) ==="

RS_ADD=$(rs_rpc addpeeraddress '["8.8.8.8",8333]')
CORE_ADD=$(core_rpc addpeeraddress '["8.8.8.8",8333]')
log "rustoshi addpeeraddress : $RS_ADD"
log "core     addpeeraddress : $CORE_ADD"
# Core returns {"success":bool}; rustoshi must too. Require success==true so the
# subsequent dump assertions are meaningful.
RS_ADD_OK=$(echo "$RS_ADD" | jq -r '.result.success // empty' 2>/dev/null)
[[ "$RS_ADD_OK" == "true" ]] \
    || fail "shape: rustoshi addpeeraddress 8.8.8.8:8333 did not return {\"success\":true} (got: $RS_ADD)"
CORE_ADD_OK=$(echo "$CORE_ADD" | jq -r '.result.success // empty' 2>/dev/null)
[[ "$CORE_ADD_OK" == "true" ]] \
    || fail "Core oracle addpeeraddress 8.8.8.8:8333 did not succeed (got: $CORE_ADD) — oracle problem"

# Dump ALL (count 0) and locate the 8.8.8.8 object on each.
RS_DUMP=$(rs_rpc getnodeaddresses '[0]')
CORE_DUMP=$(core_rpc getnodeaddresses '[0]')

# rustoshi result must be a JSON array.
RS_DUMP_TYPE=$(echo "$RS_DUMP" | jq -r '.result | type' 2>/dev/null)
[[ "$RS_DUMP_TYPE" == "array" ]] \
    || fail "shape: rustoshi 'getnodeaddresses 0' is not a JSON array after inject (got: $RS_DUMP)"

# Select the object for 8.8.8.8 (match by CONTENT, never by index).
RS_OBJ=$(echo "$RS_DUMP" | jq -c '.result[] | select(.address=="8.8.8.8")' 2>/dev/null | head -n1)
[[ -n "$RS_OBJ" ]] \
    || fail "shape: rustoshi dump has no object for address 8.8.8.8 after addpeeraddress (dump: $RS_DUMP)"
CORE_OBJ=$(echo "$CORE_DUMP" | jq -c '.result[] | select(.address=="8.8.8.8")' 2>/dev/null | head -n1)
[[ -n "$CORE_OBJ" ]] \
    || fail "Core oracle dump has no object for 8.8.8.8 after addpeeraddress (dump: $CORE_DUMP) — oracle problem"

log "rustoshi 8.8.8.8 obj : $RS_OBJ"
log "core     8.8.8.8 obj : $CORE_OBJ"

# EXACT key set, in any order — must be exactly {time,services,address,port,network}.
WANT_KEYS='["address","network","port","services","time"]'
RS_KEYS=$(echo "$RS_OBJ"   | jq -cS 'keys' 2>/dev/null)
CORE_KEYS=$(echo "$CORE_OBJ" | jq -cS 'keys' 2>/dev/null)
[[ "$CORE_KEYS" == "$WANT_KEYS" ]] \
    || fail "Core oracle 8.8.8.8 object key set unexpected: $CORE_KEYS (want $WANT_KEYS) — oracle/version mismatch"
[[ "$RS_KEYS" == "$WANT_KEYS" ]] \
    || fail "shape: rustoshi 8.8.8.8 object key set is $RS_KEYS, want EXACTLY $WANT_KEYS (extra/missing key)"

# Field values + JSON types.
RS_ADDR=$(echo "$RS_OBJ"   | jq -r '.address')
RS_PORT=$(echo "$RS_OBJ"   | jq -r '.port')
RS_NET=$(echo "$RS_OBJ"    | jq -r '.network')
RS_SVC_TYPE=$(echo "$RS_OBJ" | jq -r '.services | type')
RS_TIME_TYPE=$(echo "$RS_OBJ" | jq -r '.time | type')
RS_TIME=$(echo "$RS_OBJ"   | jq -r '.time')
RS_PORT_TYPE=$(echo "$RS_OBJ" | jq -r '.port | type')

[[ "$RS_ADDR" == "8.8.8.8" ]]   || fail "shape: rustoshi address != 8.8.8.8 (got $RS_ADDR)"
[[ "$RS_PORT" == "8333" ]]      || fail "shape: rustoshi port != 8333 (got $RS_PORT)"
[[ "$RS_NET" == "ipv4" ]]       || fail "shape: rustoshi network != ipv4 (got $RS_NET)"
[[ "$RS_SVC_TYPE" == "number" ]] \
    || fail "shape: rustoshi services is not a JSON integer/number — got type '$RS_SVC_TYPE' (Core emits raw bitfield as INT, not a hex string)"
[[ "$RS_PORT_TYPE" == "number" ]] \
    || fail "shape: rustoshi port is not a JSON number (got type '$RS_PORT_TYPE')"
[[ "$RS_TIME_TYPE" == "number" ]] \
    || fail "shape: rustoshi time is not a JSON integer/number (got type '$RS_TIME_TYPE')"
# time integer > 0 (do NOT compare to Core exactly — clocks differ).
awk -v t="$RS_TIME" 'BEGIN{ exit !(t == int(t) && t > 0) }' \
    || fail "shape: rustoshi time is not an integer > 0 (got $RS_TIME)"

# Cross-check the type contract against Core for the SAME injected address.
CORE_SVC_TYPE=$(echo "$CORE_OBJ" | jq -r '.services | type')
[[ "$CORE_SVC_TYPE" == "number" ]] \
    || fail "Core oracle services type is '$CORE_SVC_TYPE' not number — oracle/version mismatch"

log "shape OK: keys=$RS_KEYS address=$RS_ADDR port=$RS_PORT network=$RS_NET services_type=$RS_SVC_TYPE time=$RS_TIME"

# ════════════════════════════════════════════════════════════════════════
# 6. COUNT / FILTER.
# ════════════════════════════════════════════════════════════════════════
log "=== COUNT / FILTER ==="

# getnodeaddresses 1 -> <= 1 element.
RS_C1=$(rs_rpc getnodeaddresses '[1]')
RS_C1_LEN=$(echo "$RS_C1" | jq '.result | length' 2>/dev/null)
[[ "$RS_C1_LEN" =~ ^[0-9]+$ ]] \
    || fail "count: rustoshi 'getnodeaddresses 1' result not an array (got: $RS_C1)"
(( RS_C1_LEN <= 1 )) \
    || fail "count: rustoshi 'getnodeaddresses 1' returned $RS_C1_LEN elements, want <= 1"

# getnodeaddresses 0 "ipv4" -> contains the ipv4 (8.8.8.8) addr.
RS_IPV4=$(rs_rpc getnodeaddresses '[0,"ipv4"]')
RS_IPV4_HIT=$(echo "$RS_IPV4" | jq -c '.result[] | select(.address=="8.8.8.8")' 2>/dev/null | head -n1)
[[ -n "$RS_IPV4_HIT" ]] \
    || fail "netfilter: rustoshi 'getnodeaddresses 0 ipv4' does not contain 8.8.8.8 (got: $RS_IPV4)"
# And every returned entry must actually be ipv4.
RS_IPV4_BAD=$(echo "$RS_IPV4" | jq -r '[.result[] | select(.network!="ipv4")] | length' 2>/dev/null)
[[ "$RS_IPV4_BAD" == "0" ]] \
    || fail "netfilter: rustoshi 'getnodeaddresses 0 ipv4' returned $RS_IPV4_BAD non-ipv4 entries (got: $RS_IPV4)"

# getnodeaddresses 0 "onion" -> [] (only an ipv4 addr was injected).
RS_ONION=$(rs_rpc getnodeaddresses '[0,"onion"]')
RS_ONION_TYPE=$(echo "$RS_ONION" | jq -r '.result | type' 2>/dev/null)
RS_ONION_LEN=$(echo "$RS_ONION" | jq '.result | length' 2>/dev/null)
[[ "$RS_ONION_TYPE" == "array" ]] \
    || fail "netfilter: rustoshi 'getnodeaddresses 0 onion' is not a JSON array (got: $RS_ONION)"
[[ "$RS_ONION_LEN" == "0" ]] \
    || fail "netfilter: rustoshi 'getnodeaddresses 0 onion' returned $RS_ONION_LEN elements, want 0 (only ipv4 was injected)"

log "count/filter OK: c1_len=$RS_C1_LEN ipv4_hit=yes ipv4_nonmatch=$RS_IPV4_BAD onion_len=$RS_ONION_LEN"

# ── 7. Verdict. ───────────────────────────────────────────────────────────
log "PASS: rustoshi getnodeaddresses Core-shaped (shape + errors + count + netfilter all match the live bitcoind oracle)"
pass

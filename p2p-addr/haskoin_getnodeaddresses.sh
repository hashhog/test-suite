#!/usr/bin/env bash
#
# haskoin_getnodeaddresses.sh — self-contained getnodeaddresses parity test.
#
# Mirrors test-suite/p2p-addr/rustoshi_getnodeaddresses.sh.  Proves haskoin's
# getnodeaddresses (a read-only addrman dump) is Core-shaped: EXACT output
# shape, EXACT count/network param + error semantics.  NOT consensus, but the
# contract has to be byte-precise.
#
# Core ref:
#   bitcoin-core/src/rpc/net.cpp:911-970  (getnodeaddresses)
#   bitcoin-core/src/rpc/net.cpp:972-...  (addpeeraddress — the injector)
#   bitcoin-core/src/netbase.cpp:100-142  (ParseNetwork / GetNetworkName)
#
# EXACT Core semantics asserted:
#   getnodeaddresses ( count "network" ) -> a JSON ARRAY of objects, each with
#   EXACTLY 5 keys {time, services, address, port, network}:
#     time=unix-secs INT, services=raw bitfield INT (NOT hex), address=ip literal
#     (no port), port=INT, network=ipv4|ipv6|onion|i2p|cjdns|not_publicly_routable.
#   count (default 1) = max; 0 = ALL; <0 -> error -8 "Address count out of range".
#   network accepts ONLY ipv4|ipv6|onion|i2p|cjdns; else -> error -8
#     "Network not recognized: <raw>".  The list is SHUFFLED — order-insensitive.
#   Fresh node, empty addrman -> [] (empty array, NOT an error).
#
# Assertions (all run on BOTH haskoin and Core):
#   1. ERROR PATHS: getnodeaddresses -1 -> -8 "Address count out of range";
#      getnodeaddresses 1 "bogus" -> -8 "Network not recognized: bogus".
#   2. SHAPE: addpeeraddress "8.8.8.8" 8333; getnodeaddresses 0; assert the
#      8.8.8.8 object has EXACTLY {time,services,address,port,network},
#      address==8.8.8.8, port==8333, network==ipv4, services INT, time INT>0.
#   3. COUNT/FILTER: getnodeaddresses 1 -> <=1; 0 "ipv4" -> contains 8.8.8.8;
#      0 "onion" -> [].  Match by CONTENT, never by index.
#
# Summary line (stdout):
#   PASS: GETNODEADDRESSES haskoin: PASS shape=ok errors=ok count=ok netfilter=ok
#   FAIL: GETNODEADDRESSES haskoin: FAIL <short reason>
#
# Touches ONLY /tmp/hk-getnodeaddresses/ + /tmp/hk-getnodeaddresses-core/ and
#   ports 41070/41090 (haskoin RPC/P2P) + 41072/41092 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

BASEDIR="/home/work/hashhog"
NODE_BIN="$(find "$BASEDIR/haskoin/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

export haskoin_datadir="$BASEDIR/haskoin"

HK_DATADIR="/tmp/hk-getnodeaddresses"
HK_RPC=41070
HK_P2P=41091
HK_LOG="$HK_DATADIR/node.log"
HK_COOKIE=""

CORE_DATADIR="/tmp/hk-getnodeaddresses-core"
CORE_RPC=41072
CORE_P2P=41092
CORE_LOG="$CORE_DATADIR/core.log"
CORE_COOKIE=""

HK_PID=""
CORE_BG=""

log() { echo "[gna:haskoin] $*" >&2; }

cleanup() {
    local ec=$?
    if [[ -n "$HK_PID" ]] && kill -0 "$HK_PID" 2>/dev/null; then
        kill "$HK_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HK_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HK_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${HK_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${HK_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$HK_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() { echo "GETNODEADDRESSES haskoin: PASS shape=ok errors=ok count=ok netfilter=ok"; exit 0; }
fail() { echo "GETNODEADDRESSES haskoin: FAIL $*"; exit 1; }

hk_rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 15 -u "$HK_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$HK_RPC/" 2>/dev/null
}
core_rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 15 -u "$CORE_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$CORE_RPC/" 2>/dev/null
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "hk-getnodeaddresses" 2>/dev/null || true
fuser -k "${HK_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${HK_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 3
rm -rf "$HK_DATADIR" "$CORE_DATADIR"
mkdir -p "$HK_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v jq   >/dev/null 2>&1  || fail "jq not found on PATH"
command -v curl >/dev/null 2>&1  || fail "curl not found on PATH"
[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || fail "haskoin binary not found (build with: cabal build exe:haskoin)"
[[ -x "$CORE_BIN" ]]             || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]             || fail "bitcoin-cli not found at $CORE_CLI"

# ── 2. Launch the Core oracle (regtest, listen=0). ────────────────────────
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

# ── 3. Launch haskoin (regtest, listen False). ────────────────────────────
log "launching haskoin (regtest) rpc=:$HK_RPC p2p=:$HK_P2P -> $HK_LOG"
"$NODE_BIN" --network Regtest --datadir "$HK_DATADIR" node \
    --rpcport "$HK_RPC" --port "$HK_P2P" --listen False --metricsport 0 \
    >"$HK_LOG" 2>&1 &
HK_PID=$!
hk_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < hk_deadline )); do
    if [[ -z "$HK_COOKIE" ]]; then
        for c in "$HK_DATADIR/regtest/.cookie" "$HK_DATADIR/.cookie"; do
            [[ -f "$c" ]] && HK_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HK_COOKIE" ]]; then
        echo "$(hk_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$HK_PID" 2>/dev/null || { tail -n 30 "$HK_LOG" >&2 2>/dev/null || true; fail "haskoin exited during startup (see $HK_LOG)"; }
    sleep 1
done
[[ -n "$HK_COOKIE" ]] || fail "haskoin cookie never appeared within 90s"
echo "$(hk_rpc getblockcount '[]')" | grep -q '"result"' || fail "haskoin RPC never responded within 90s"
log "haskoin RPC ready"

# ════════════════════════════════════════════════════════════════════════
# 4. ERROR PATHS.
# ════════════════════════════════════════════════════════════════════════
assert_err8() {
    local resp="$1" want="$2"
    local code msg
    code=$(echo "$resp" | jq -r '.error.code // empty' 2>/dev/null)
    msg=$(echo "$resp"  | jq -r '.error.message // empty' 2>/dev/null)
    [[ "$code" == "-8" ]] || return 1
    [[ "$msg" == *"$want"* ]] || return 1
    return 0
}

log "=== ERROR PATHS ==="
HK_NEG=$(hk_rpc getnodeaddresses '[-1]')
CORE_NEG=$(core_rpc getnodeaddresses '[-1]')
log "haskoin getnodeaddresses -1 : $HK_NEG"
log "core    getnodeaddresses -1 : $CORE_NEG"
assert_err8 "$CORE_NEG" "Address count out of range" \
    || fail "Core oracle did not reject 'getnodeaddresses -1' with -8 'Address count out of range' (got: $CORE_NEG) — oracle/version mismatch"
assert_err8 "$HK_NEG" "Address count out of range" \
    || fail "errors: haskoin 'getnodeaddresses -1' not -8 'Address count out of range' (got: $HK_NEG)"

HK_BOG=$(hk_rpc getnodeaddresses '[1,"bogus"]')
CORE_BOG=$(core_rpc getnodeaddresses '[1,"bogus"]')
log "haskoin getnodeaddresses 1 bogus : $HK_BOG"
log "core    getnodeaddresses 1 bogus : $CORE_BOG"
assert_err8 "$CORE_BOG" "Network not recognized: bogus" \
    || fail "Core oracle did not reject 'getnodeaddresses 1 bogus' with -8 'Network not recognized: bogus' (got: $CORE_BOG)"
assert_err8 "$HK_BOG" "Network not recognized: bogus" \
    || fail "netfilter: haskoin 'getnodeaddresses 1 bogus' not -8 'Network not recognized: bogus' (got: $HK_BOG)"

HK_EMPTY=$(hk_rpc getnodeaddresses '[0]')
EMPTY_TYPE=$(echo "$HK_EMPTY" | jq -r '.result | type' 2>/dev/null)
[[ "$EMPTY_TYPE" == "array" ]] \
    || fail "shape: haskoin fresh 'getnodeaddresses 0' is not a JSON array (got: $HK_EMPTY)"
log "haskoin fresh getnodeaddresses 0 -> array (len=$(echo "$HK_EMPTY" | jq '.result | length'))"

# ════════════════════════════════════════════════════════════════════════
# 5. SHAPE — inject 8.8.8.8:8333 on BOTH, dump, compare key set + types.
# ════════════════════════════════════════════════════════════════════════
log "=== SHAPE (inject 8.8.8.8:8333) ==="
HK_ADD=$(hk_rpc addpeeraddress '["8.8.8.8",8333]')
CORE_ADD=$(core_rpc addpeeraddress '["8.8.8.8",8333]')
log "haskoin addpeeraddress : $HK_ADD"
log "core    addpeeraddress : $CORE_ADD"
HK_ADD_OK=$(echo "$HK_ADD" | jq -r '.result.success // empty' 2>/dev/null)
[[ "$HK_ADD_OK" == "true" ]] \
    || fail "shape: haskoin addpeeraddress 8.8.8.8:8333 did not return {\"success\":true} (got: $HK_ADD)"
CORE_ADD_OK=$(echo "$CORE_ADD" | jq -r '.result.success // empty' 2>/dev/null)
[[ "$CORE_ADD_OK" == "true" ]] \
    || fail "Core oracle addpeeraddress 8.8.8.8:8333 did not succeed (got: $CORE_ADD) — oracle problem"

HK_DUMP=$(hk_rpc getnodeaddresses '[0]')
CORE_DUMP=$(core_rpc getnodeaddresses '[0]')

HK_DUMP_TYPE=$(echo "$HK_DUMP" | jq -r '.result | type' 2>/dev/null)
[[ "$HK_DUMP_TYPE" == "array" ]] \
    || fail "shape: haskoin 'getnodeaddresses 0' is not a JSON array after inject (got: $HK_DUMP)"

HK_OBJ=$(echo "$HK_DUMP" | jq -c '.result[] | select(.address=="8.8.8.8")' 2>/dev/null | head -n1)
[[ -n "$HK_OBJ" ]] \
    || fail "shape: haskoin dump has no object for address 8.8.8.8 after addpeeraddress (dump: $HK_DUMP)"
CORE_OBJ=$(echo "$CORE_DUMP" | jq -c '.result[] | select(.address=="8.8.8.8")' 2>/dev/null | head -n1)
[[ -n "$CORE_OBJ" ]] \
    || fail "Core oracle dump has no object for 8.8.8.8 after addpeeraddress (dump: $CORE_DUMP) — oracle problem"

log "haskoin 8.8.8.8 obj : $HK_OBJ"
log "core    8.8.8.8 obj : $CORE_OBJ"

WANT_KEYS='["address","network","port","services","time"]'
HK_KEYS=$(echo "$HK_OBJ"   | jq -cS 'keys' 2>/dev/null)
CORE_KEYS=$(echo "$CORE_OBJ" | jq -cS 'keys' 2>/dev/null)
[[ "$CORE_KEYS" == "$WANT_KEYS" ]] \
    || fail "Core oracle 8.8.8.8 object key set unexpected: $CORE_KEYS (want $WANT_KEYS) — oracle/version mismatch"
[[ "$HK_KEYS" == "$WANT_KEYS" ]] \
    || fail "shape: haskoin 8.8.8.8 object key set is $HK_KEYS, want EXACTLY $WANT_KEYS (extra/missing key)"

HK_ADDR=$(echo "$HK_OBJ"   | jq -r '.address')
HK_PORT=$(echo "$HK_OBJ"   | jq -r '.port')
HK_NET=$(echo "$HK_OBJ"    | jq -r '.network')
HK_SVC_TYPE=$(echo "$HK_OBJ" | jq -r '.services | type')
HK_TIME_TYPE=$(echo "$HK_OBJ" | jq -r '.time | type')
HK_TIME=$(echo "$HK_OBJ"   | jq -r '.time')
HK_PORT_TYPE=$(echo "$HK_OBJ" | jq -r '.port | type')

[[ "$HK_ADDR" == "8.8.8.8" ]]   || fail "shape: haskoin address != 8.8.8.8 (got $HK_ADDR)"
[[ "$HK_PORT" == "8333" ]]      || fail "shape: haskoin port != 8333 (got $HK_PORT)"
[[ "$HK_NET" == "ipv4" ]]       || fail "shape: haskoin network != ipv4 (got $HK_NET)"
[[ "$HK_SVC_TYPE" == "number" ]] \
    || fail "shape: haskoin services is not a JSON number — got type '$HK_SVC_TYPE' (Core emits raw bitfield as INT, not a hex string)"
[[ "$HK_PORT_TYPE" == "number" ]] \
    || fail "shape: haskoin port is not a JSON number (got type '$HK_PORT_TYPE')"
[[ "$HK_TIME_TYPE" == "number" ]] \
    || fail "shape: haskoin time is not a JSON number (got type '$HK_TIME_TYPE')"
awk -v t="$HK_TIME" 'BEGIN{ exit !(t == int(t) && t > 0) }' \
    || fail "shape: haskoin time is not an integer > 0 (got $HK_TIME)"

CORE_SVC_TYPE=$(echo "$CORE_OBJ" | jq -r '.services | type')
[[ "$CORE_SVC_TYPE" == "number" ]] \
    || fail "Core oracle services type is '$CORE_SVC_TYPE' not number — oracle/version mismatch"

log "shape OK: keys=$HK_KEYS address=$HK_ADDR port=$HK_PORT network=$HK_NET services_type=$HK_SVC_TYPE time=$HK_TIME"

# ════════════════════════════════════════════════════════════════════════
# 6. COUNT / FILTER.
# ════════════════════════════════════════════════════════════════════════
log "=== COUNT / FILTER ==="
HK_C1=$(hk_rpc getnodeaddresses '[1]')
HK_C1_LEN=$(echo "$HK_C1" | jq '.result | length' 2>/dev/null)
[[ "$HK_C1_LEN" =~ ^[0-9]+$ ]] \
    || fail "count: haskoin 'getnodeaddresses 1' result not an array (got: $HK_C1)"
(( HK_C1_LEN <= 1 )) \
    || fail "count: haskoin 'getnodeaddresses 1' returned $HK_C1_LEN elements, want <= 1"

HK_IPV4=$(hk_rpc getnodeaddresses '[0,"ipv4"]')
HK_IPV4_HIT=$(echo "$HK_IPV4" | jq -c '.result[] | select(.address=="8.8.8.8")' 2>/dev/null | head -n1)
[[ -n "$HK_IPV4_HIT" ]] \
    || fail "netfilter: haskoin 'getnodeaddresses 0 ipv4' does not contain 8.8.8.8 (got: $HK_IPV4)"
HK_IPV4_BAD=$(echo "$HK_IPV4" | jq -r '[.result[] | select(.network!="ipv4")] | length' 2>/dev/null)
[[ "$HK_IPV4_BAD" == "0" ]] \
    || fail "netfilter: haskoin 'getnodeaddresses 0 ipv4' returned $HK_IPV4_BAD non-ipv4 entries (got: $HK_IPV4)"

HK_ONION=$(hk_rpc getnodeaddresses '[0,"onion"]')
HK_ONION_TYPE=$(echo "$HK_ONION" | jq -r '.result | type' 2>/dev/null)
HK_ONION_LEN=$(echo "$HK_ONION" | jq '.result | length' 2>/dev/null)
[[ "$HK_ONION_TYPE" == "array" ]] \
    || fail "netfilter: haskoin 'getnodeaddresses 0 onion' is not a JSON array (got: $HK_ONION)"
[[ "$HK_ONION_LEN" == "0" ]] \
    || fail "netfilter: haskoin 'getnodeaddresses 0 onion' returned $HK_ONION_LEN elements, want 0 (only ipv4 was injected)"

log "count/filter OK: c1_len=$HK_C1_LEN ipv4_hit=yes ipv4_nonmatch=$HK_IPV4_BAD onion_len=$HK_ONION_LEN"

log "PASS: haskoin getnodeaddresses Core-shaped (shape + errors + count + netfilter all match the live bitcoind oracle)"
pass

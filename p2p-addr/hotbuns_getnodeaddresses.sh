#!/usr/bin/env bash
#
# hotbuns_getnodeaddresses.sh — self-contained getnodeaddresses DIFFERENTIAL
#                               (P2P-axis first cell; read-only addrman dump).
#
# The P2P-axis successor to the wallet (recovery/spend/history/import) +
# mempool-policy + getchaintxstats chapters. This proves a READ-ONLY addrman
# dump — NOT consensus — but with EXACT Core parity on the output shape and the
# param/error semantics:
#
#   getnodeaddresses ( count "network" )   (Core: rpc/net.cpp:911-970)
#     - returns a JSON ARRAY of objects, each with EXACTLY 5 keys in order:
#         time     NUM_TIME  unix seconds INTEGER
#         services NUM       raw services bitfield INTEGER (NOT a hex string)
#         address  STR       ip literal / .onion / .b32.i2p (no port)
#         port     NUM       integer
#         network  STR       ipv4|ipv6|onion|i2p|cjdns|not_publicly_routable|internal
#     - count (pos 0, default 1): MAX to return; 0 = ALL known; <0 -> error -8
#         "Address count out of range".
#     - network (pos 1, optional): ParseNetwork lowercases + accepts ONLY
#         ipv4|ipv6|onion|i2p|cjdns; anything else -> error -8
#         "Network not recognized: <raw arg>"; when set, filters the result.
#     - source = addrman (SHUFFLED — order NON-deterministic). Empty addrman
#         -> [] (empty array, NOT an error).
#
#   addpeeraddress "address" port ( tried )   (Core: rpc/net.cpp:972, test-only)
#     - inserts into the addrman; returns {"success": bool}. Used here to make
#       the differential DETERMINISTIC.
#
# DIFFERENTIAL ORACLE: a REAL bitcoind regtest oracle
# (${HASHHOG_ROOT}/bitcoin-core/build/bin/bitcoind + bitcoin-cli) on its OWN
# scratch + ports. Both hotbuns and Core are exercised; assertions compare the
# KEY SET + types (NOT time exactly — clocks differ) and the error/count/filter
# semantics.
#
# ASSERTIONS:
#   1. ERROR PATHS (no addrman population needed — robust + deterministic):
#        getnodeaddresses -1       -> RPC error -8 "Address count out of range"
#        getnodeaddresses 1 bogus  -> RPC error -8 "Network not recognized: bogus"
#      on BOTH hotbuns and Core.
#   2. SHAPE: addpeeraddress 8.8.8.8 8333 on BOTH; getnodeaddresses 0 on BOTH.
#      hotbuns array contains an object for 8.8.8.8 with EXACTLY the 5 keys
#      {time,services,address,port,network}; address==8.8.8.8, port==8333,
#      network==ipv4, services an INTEGER (not hex), time an INTEGER>0. Fail on
#      any extra/missing key. Compare the KEY SET + types to Core's object.
#   3. COUNT/FILTER: getnodeaddresses 1 -> <=1 element; getnodeaddresses 0 ipv4
#      -> the ipv4 addr; getnodeaddresses 0 onion -> [] (only an ipv4 injected).
#   Ordering is NON-deterministic (addrman shuffles) — match by content, never
#   by index.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/hotbuns_policy.sh): no
#   required args, idempotent, trap cleanup, scratch /tmp + unique ports, ONE
#   clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   GETNODEADDRESSES hotbuns: PASS shape=ok errors=ok count=ok netfilter=ok
#   GETNODEADDRESSES hotbuns: FAIL <short reason>
#
# Touches ONLY /tmp/gna-hotbuns/ and /tmp/gna-hotbuns-core/ and ports
#   21974 (hotbuns RPC) / 21994 (hotbuns P2P) / 21978 (Core RPC) /
#   21998 (Core P2P). NEVER touches /data/nvme1/ or testnet4-data/ or any live
#   node (haskoin is mid-sync — left untouched).

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_DIR="$BASEDIR/hotbuns"
BCD="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

HB_DATADIR="/tmp/gna-hotbuns"
HB_RPC=21974
HB_P2P=21994
HB_LOG="$HB_DATADIR/node.log"

CORE_DATADIR="/tmp/gna-hotbuns-core"
CORE_RPC=21978
CORE_P2P=21998
CORE_LOG="$CORE_DATADIR/core.log"

INJECT_ADDR="8.8.8.8"
INJECT_PORT=8333

HB_PID=""
HB_COOKIE=""
CORE_PID=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gna:hotbuns] $*" >&2; }

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "GETNODEADDRESSES hotbuns: PASS shape=ok errors=ok count=ok netfilter=ok"; exit 0; }
fail() { echo "GETNODEADDRESSES hotbuns: FAIL $*"; exit 1; }

# ── Cleanup: kill both nodes + wipe scratch on any exit. ──────────────────
cleanup() {
    local ec=$?
    if [[ -n "$CORE_PID" ]] && kill -0 "$CORE_PID" 2>/dev/null; then
        "$CLI" -regtest -datadir="$CORE_DATADIR" -rpcport=$CORE_RPC stop >/dev/null 2>&1 || true
        for _ in $(seq 1 15); do kill -0 "$CORE_PID" 2>/dev/null || break; sleep 1; done
        kill "$CORE_PID" 2>/dev/null || true
        kill -9 "$CORE_PID" 2>/dev/null || true
    fi
    if [[ -n "$HB_PID" ]] && kill -0 "$HB_PID" 2>/dev/null; then
        kill "$HB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HB_PID" 2>/dev/null || true
    fi
    rm -rf "$HB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── hotbuns RPC helper (raw): prints raw JSON-RPC response body. ──────────
hb_rpc_raw() {  # hb_rpc_raw <method> <params-json-array>
    curl -s --max-time 30 -u "$HB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$HB_RPC/" 2>/dev/null
}

# Tracks whether the test address has been injected, so a self-heal relaunch
# (which clears the in-memory addrman) can re-populate before the next read.
HB_INJECTED=0

# Forward declares (defined after the launcher). The self-healing wrapper
# detects an external SIGKILL of the regtest node (empty/refused response while
# the pid is gone), relaunches it, re-injects the test addr if it had been
# injected, and retries the call ONCE.
hb_rpc() {  # hb_rpc <method> <params-json-array>
    local out; out=$(hb_rpc_raw "$1" "$2")
    if [[ -z "$out" ]] && ! kill -0 "$HB_PID" 2>/dev/null; then
        log "hotbuns RPC empty + pid=$HB_PID gone (external SIGKILL?) — self-healing relaunch"
        launch_hotbuns
        if ensure_hotbuns_up; then
            if (( HB_INJECTED == 1 )); then
                log "re-injecting $INJECT_ADDR:$INJECT_PORT after relaunch"
                hb_rpc_raw addpeeraddress "[\"$INJECT_ADDR\",$INJECT_PORT]" >/dev/null
            fi
            out=$(hb_rpc_raw "$1" "$2")
        fi
    fi
    printf '%s' "$out"
}

# ── Core CLI helper (raw): JSON / error text on stdout+stderr. ────────────
core_cli_raw() { "$CLI" -regtest -datadir="$CORE_DATADIR" -rpcport=$CORE_RPC "$@"; }

# Tracks Core injection so a self-heal relaunch re-populates Core's addrman.
CORE_INJECTED=0

# Self-healing Core CLI: if the daemon is gone (external SIGKILL on this box),
# relaunch + re-inject the test addr, then retry the command ONCE. Note: this
# is used for READ/inject calls; the deliberate ERROR-path probes call
# core_cli_raw directly so a non-zero exit isn't mistaken for a dead daemon.
core_cli() {
    local out rc
    out=$(core_cli_raw "$@" 2>&1); rc=$?
    if (( rc != 0 )) && ! kill -0 "$CORE_PID" 2>/dev/null; then
        log "Core CLI failed + pid=$CORE_PID gone (external SIGKILL?) — self-healing relaunch"
        launch_core
        if ensure_core_up; then
            if (( CORE_INJECTED == 1 )); then
                log "re-injecting $INJECT_ADDR:$INJECT_PORT into Core after relaunch"
                core_cli_raw addpeeraddress "$INJECT_ADDR" "$INJECT_PORT" >/dev/null 2>&1
            fi
            out=$(core_cli_raw "$@" 2>&1); rc=$?
        fi
    fi
    printf '%s' "$out"
    return $rc
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
# NB: do NOT use `pkill -f <pattern>` for cleanup — the test harness wraps each
# command in an `eval '<command-text>'`, so a loose `-f` pattern (e.g. a scratch
# path substring) can match the harness's OWN wrapper command line and SIGKILL
# the whole invocation. We rely on tracked PIDs in cleanup() instead
# (port-kills banned — 2026-06-10 fuser incident).
log "resetting scratch state"
if ss -tln 2>/dev/null | grep -qE ":(${HB_RPC}|${HB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${HB_RPC}/${HB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$HB_DATADIR" "$CORE_DATADIR"
mkdir -p "$HB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v bun >/dev/null 2>&1    || fail "bun runtime not found on PATH"
command -v curl >/dev/null 2>&1   || fail "curl not found on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
[[ -x "$BCD" ]]                   || fail "bitcoind not found at $BCD"
[[ -x "$CLI" ]]                   || fail "bitcoin-cli not found at $CLI"
[[ -f "$NODE_DIR/src/index.ts" ]] || fail "hotbuns entrypoint not found at $NODE_DIR/src/index.ts"

# ── 2. Launch the Core regtest oracle (self-healing, same box hazard). ────
CORE_LAUNCH_TRIES=0
launch_core() {
    CORE_LAUNCH_TRIES=$(( CORE_LAUNCH_TRIES + 1 ))
    # PID-scoped stop of OUR previous attempt (port-kill removed: 2026-06-10 fuser incident).
    if [[ -n "${CORE_PID:-}" ]]; then
        kill "$CORE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CORE_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CORE_PID" 2>/dev/null || true
    fi
    for __hp in "${CORE_RPC}" "${CORE_P2P}"; do
        for _ in $(seq 1 15); do
            ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
            sleep 1
        done
    done
    sleep 1
    log "launching Core regtest oracle (attempt $CORE_LAUNCH_TRIES) rpc=:$CORE_RPC p2p=:$CORE_P2P -> $CORE_LOG"
    "$BCD" -regtest -datadir="$CORE_DATADIR" -port=$CORE_P2P -rpcport=$CORE_RPC \
        -rpcbind=127.0.0.1 -rpcallowip=127.0.0.1 -listen=0 -daemon=0 \
        >"$CORE_LOG" 2>&1 &
    CORE_PID=$!
    log "Core pid=$CORE_PID"
}
ensure_core_up() {
    local max_relaunch=4
    while (( CORE_LAUNCH_TRIES <= max_relaunch )); do
        local deadline=$(( $(date +%s) + 90 ))
        while (( $(date +%s) < deadline )); do
            "$CLI" -regtest -datadir="$CORE_DATADIR" -rpcport=$CORE_RPC getblockcount >/dev/null 2>&1 \
                && { log "Core oracle RPC ready"; return 0; }
            if ! kill -0 "$CORE_PID" 2>/dev/null; then
                log "Core pid=$CORE_PID died (external SIGKILL?) — relaunching"
                tail -n 8 "$CORE_LOG" >&2 2>/dev/null || true
                break
            fi
            sleep 1
        done
        "$CLI" -regtest -datadir="$CORE_DATADIR" -rpcport=$CORE_RPC getblockcount >/dev/null 2>&1 \
            && { log "Core oracle RPC ready"; return 0; }
        (( CORE_LAUNCH_TRIES > max_relaunch )) && break
        launch_core
    done
    return 1
}
launch_core
ensure_core_up || fail "Core oracle never reached a ready RPC within $CORE_LAUNCH_TRIES launch attempts (external SIGKILL of regtest helpers on this box; see $CORE_LOG)"

# ── 3. Launch hotbuns on regtest (self-healing). ──────────────────────────
# This box runs a live mainnet fleet + sandbox process management; we have
# observed NON-deterministic external SIGKILLs of detached regtest helper
# processes (both bun and bitcoind) even with ~86Gi free / PSI=0 (NOT OOM).
# So the launcher is wrapped in a relaunch loop: if the node dies during
# startup we respawn it (bounded). The addrman is in-memory and re-populated
# by addpeeraddress at assertion time, so a respawn loses nothing the test
# relies on (each assertion re-injects before reading).
HB_LAUNCH_TRIES=0
launch_hotbuns() {
    HB_LAUNCH_TRIES=$(( HB_LAUNCH_TRIES + 1 ))
    HB_COOKIE=""
    # PID-scoped stop of OUR previous attempt (port-kill removed: 2026-06-10 fuser incident).
    if [[ -n "${HB_PID:-}" ]]; then
        kill "$HB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HB_PID" 2>/dev/null || true
    fi
    for __hp in "${HB_RPC}" "${HB_P2P}"; do
        for _ in $(seq 1 15); do
            ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
            sleep 1
        done
    done
    sleep 1
    log "launching hotbuns (regtest, attempt $HB_LAUNCH_TRIES) rpc=:$HB_RPC p2p=:$HB_P2P -> $HB_LOG"
    (
        cd "$NODE_DIR" || exit 1
        exec bun run src/index.ts \
            --network=regtest --datadir="$HB_DATADIR" \
            --port="$HB_P2P" --rpcport="$HB_RPC"
    ) >"$HB_LOG" 2>&1 &
    HB_PID=$!
    log "hotbuns pid=$HB_PID"
}

# Bring hotbuns up + ready (cookie + getblockcount). Returns 0 on ready, 1 if
# we exhausted the relaunch budget. Respawns on observed death.
ensure_hotbuns_up() {
    local max_relaunch=4
    while (( HB_LAUNCH_TRIES <= max_relaunch )); do
        local deadline=$(( $(date +%s) + 90 ))
        while (( $(date +%s) < deadline )); do
            if [[ -z "$HB_COOKIE" ]]; then
                for c in "$HB_DATADIR/.cookie" "$HB_DATADIR/regtest/.cookie"; do
                    [[ -f "$c" ]] && HB_COOKIE=$(cat "$c") && break
                done
            fi
            if [[ -n "$HB_COOKIE" ]]; then
                # Non-healing raw call here — ensure_hotbuns_up IS the healer,
                # so it must not recurse through the self-healing hb_rpc wrapper.
                local r; r=$(hb_rpc_raw getblockcount '[]')
                echo "$r" | grep -q '"result"' && { log "hotbuns RPC ready"; return 0; }
            fi
            if ! kill -0 "$HB_PID" 2>/dev/null; then
                log "hotbuns pid=$HB_PID died during startup (external SIGKILL?) — relaunching"
                tail -n 8 "$HB_LOG" >&2 2>/dev/null || true
                break   # break inner -> outer relaunch
            fi
            sleep 1
        done
        # Either RPC came up (returned above) or the node died / timed out.
        if [[ -n "$HB_COOKIE" ]] && echo "$(hb_rpc_raw getblockcount '[]')" | grep -q '"result"'; then
            log "hotbuns RPC ready"; return 0
        fi
        (( HB_LAUNCH_TRIES > max_relaunch )) && break
        launch_hotbuns
    done
    return 1
}

launch_hotbuns
ensure_hotbuns_up || fail "hotbuns never reached a ready RPC within $HB_LAUNCH_TRIES launch attempts (external SIGKILL of regtest helpers on this box; see $HB_LOG)"

# ── Tiny JSON helpers (python3 — no jq dependency). ───────────────────────
# json_field <json> <jq-style python expr on variable d>  -> prints repr.
pyjson() {  # pyjson <json-string> <python-expr>   (d = parsed json)
    python3 -c '
import sys, json
d = json.loads(sys.argv[1])
print(eval(sys.argv[2]))
' "$1" "$2" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────
# ASSERTION 1 — ERROR PATHS (both hotbuns and Core).
# ──────────────────────────────────────────────────────────────────────────
log "=== ASSERTION 1: error paths (count<0, bogus network) ==="

# 1a. count == -1  -> error -8 "Address count out of range".
HB_NEG=$(hb_rpc getnodeaddresses '[-1]')
log "  hotbuns getnodeaddresses -1: $HB_NEG"
HB_NEG_CODE=$(pyjson "$HB_NEG" "d.get('error',{}).get('code') if d.get('error') else None")
HB_NEG_MSG=$(pyjson "$HB_NEG" "d.get('error',{}).get('message','') if d.get('error') else ''")
[[ "$HB_NEG_CODE" == "-8" ]] || fail "errors: hotbuns getnodeaddresses -1 expected error code -8, got '$HB_NEG_CODE' (msg='$HB_NEG_MSG')"
[[ "$HB_NEG_MSG" == "Address count out of range" ]] || fail "errors: hotbuns count<0 message != 'Address count out of range' (got '$HB_NEG_MSG')"

# Core parity for 1a.
CORE_NEG=$(core_cli_raw getnodeaddresses -1 2>&1)
echo "$CORE_NEG" | grep -q "error code: -8" || fail "errors: Core getnodeaddresses -1 did not return error code -8 (got: $CORE_NEG)"
echo "$CORE_NEG" | grep -q "Address count out of range" || fail "errors: Core count<0 message != 'Address count out of range' (got: $CORE_NEG)"

# 1b. network == "bogus"  -> error -8 "Network not recognized: bogus".
HB_BOG=$(hb_rpc getnodeaddresses '[1,"bogus"]')
log "  hotbuns getnodeaddresses 1 bogus: $HB_BOG"
HB_BOG_CODE=$(pyjson "$HB_BOG" "d.get('error',{}).get('code') if d.get('error') else None")
HB_BOG_MSG=$(pyjson "$HB_BOG" "d.get('error',{}).get('message','') if d.get('error') else ''")
[[ "$HB_BOG_CODE" == "-8" ]] || fail "errors: hotbuns getnodeaddresses 1 bogus expected error code -8, got '$HB_BOG_CODE' (msg='$HB_BOG_MSG')"
[[ "$HB_BOG_MSG" == "Network not recognized: bogus" ]] || fail "errors: hotbuns bogus-net message != 'Network not recognized: bogus' (got '$HB_BOG_MSG')"

# Core parity for 1b.
CORE_BOG=$(core_cli_raw getnodeaddresses 1 bogus 2>&1)
echo "$CORE_BOG" | grep -q "error code: -8" || fail "errors: Core getnodeaddresses 1 bogus did not return error code -8 (got: $CORE_BOG)"
echo "$CORE_BOG" | grep -q "Network not recognized: bogus" || fail "errors: Core bogus-net message != 'Network not recognized: bogus' (got: $CORE_BOG)"
log "  errors=ok"

# ──────────────────────────────────────────────────────────────────────────
# ASSERTION 2 — SHAPE (inject 8.8.8.8:8333, compare object shape vs Core).
# ──────────────────────────────────────────────────────────────────────────
log "=== ASSERTION 2: shape (addpeeraddress + getnodeaddresses 0) ==="

# Empty addrman sanity: getnodeaddresses 0 -> [] on hotbuns (NOT an error).
HB_EMPTY=$(hb_rpc getnodeaddresses '[0]')
HB_EMPTY_OK=$(pyjson "$HB_EMPTY" "isinstance(d.get('result'), list) and len(d['result'])==0 and d.get('error') is None")
[[ "$HB_EMPTY_OK" == "True" ]] || fail "shape: hotbuns empty addrman getnodeaddresses 0 != [] (got: $HB_EMPTY)"

# Inject on BOTH.
HB_ADD=$(hb_rpc addpeeraddress "[\"$INJECT_ADDR\",$INJECT_PORT]")
log "  hotbuns addpeeraddress $INJECT_ADDR $INJECT_PORT: $HB_ADD"
HB_ADD_OK=$(pyjson "$HB_ADD" "d.get('result',{}).get('success') is True")
[[ "$HB_ADD_OK" == "True" ]] || fail "shape: hotbuns addpeeraddress did not return {success:true} (got: $HB_ADD)"
HB_INJECTED=1   # so a self-heal relaunch re-injects before the next read

CORE_ADD=$(core_cli addpeeraddress "$INJECT_ADDR" "$INJECT_PORT" 2>&1)
echo "$CORE_ADD" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get("success") is True else 1)' 2>/dev/null \
    || fail "shape: Core addpeeraddress did not return {success:true} (got: $CORE_ADD)"
CORE_INJECTED=1   # so a self-heal relaunch re-injects into Core before reads

# getnodeaddresses 0 on BOTH.
HB_ALL=$(hb_rpc getnodeaddresses '[0]')
log "  hotbuns getnodeaddresses 0: $HB_ALL"
CORE_ALL=$(core_cli getnodeaddresses 0 2>&1)
log "  core getnodeaddresses 0: $(echo "$CORE_ALL" | tr -d '\n')"

# Validate hotbuns's object for 8.8.8.8: EXACTLY 5 keys, correct types/values,
# and the KEY SET matches Core's object for the same injected addr.
SHAPE_RES=$(python3 - "$HB_ALL" "$CORE_ALL" "$INJECT_ADDR" "$INJECT_PORT" <<'PYEOF'
import sys, json
hb_raw, core_raw, addr, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

hb = json.loads(hb_raw)
if hb.get("error") is not None:
    print("FAIL hotbuns getnodeaddresses 0 returned error: %s" % hb["error"]); sys.exit(0)
hb_list = hb.get("result")
if not isinstance(hb_list, list):
    print("FAIL hotbuns getnodeaddresses 0 result is not an array"); sys.exit(0)

# Core CLI prints bare JSON (array) on stdout.
try:
    core_list = json.loads(core_raw)
except Exception as e:
    print("FAIL could not parse Core getnodeaddresses 0 output: %s" % e); sys.exit(0)
if not isinstance(core_list, list):
    print("FAIL Core getnodeaddresses 0 output is not an array"); sys.exit(0)

EXPECT_KEYS = ["time", "services", "address", "port", "network"]

def find(lst):
    for o in lst:
        if isinstance(o, dict) and o.get("address") == addr and o.get("port") == port:
            return o
    return None

hbo = find(hb_list)
if hbo is None:
    print("FAIL hotbuns array has no object for %s:%d (got %d entries)" % (addr, port, len(hb_list))); sys.exit(0)
coreo = find(core_list)
if coreo is None:
    print("FAIL Core array has no object for %s:%d (oracle sanity)" % (addr, port)); sys.exit(0)

# EXACT 5-key set (no extra, no missing), in any order (we assert the set).
hb_keys = sorted(hbo.keys())
if hb_keys != sorted(EXPECT_KEYS):
    print("FAIL hotbuns object keys != {time,services,address,port,network}: got %s" % hb_keys); sys.exit(0)

# KEY SET parity with Core's object.
core_keys = sorted(coreo.keys())
if core_keys != sorted(EXPECT_KEYS):
    print("FAIL Core object keys != expected (oracle sanity): got %s" % core_keys); sys.exit(0)

# Types + values on hotbuns.
import numbers
def is_int(x):
    return isinstance(x, int) and not isinstance(x, bool)
if hbo["address"] != addr:
    print("FAIL hotbuns address != %s (got %r)" % (addr, hbo["address"])); sys.exit(0)
if hbo["port"] != port:
    print("FAIL hotbuns port != %d (got %r)" % (port, hbo["port"])); sys.exit(0)
if hbo["network"] != "ipv4":
    print("FAIL hotbuns network != ipv4 (got %r)" % hbo["network"]); sys.exit(0)
if not is_int(hbo["services"]):
    print("FAIL hotbuns services is not an INTEGER (got %r, type %s) — must NOT be a hex string" % (hbo["services"], type(hbo["services"]).__name__)); sys.exit(0)
if not is_int(hbo["time"]) or hbo["time"] <= 0:
    print("FAIL hotbuns time is not an INTEGER>0 (got %r, type %s)" % (hbo["time"], type(hbo["time"]).__name__)); sys.exit(0)

# Type parity with Core's object (NOT comparing time value — clocks differ).
if not is_int(coreo["services"]):
    print("FAIL Core services is not INTEGER (oracle sanity): %r" % coreo["services"]); sys.exit(0)
if not is_int(coreo["time"]):
    print("FAIL Core time is not INTEGER (oracle sanity): %r" % coreo["time"]); sys.exit(0)
if coreo["network"] != "ipv4":
    print("FAIL Core network != ipv4 (oracle sanity): %r" % coreo["network"]); sys.exit(0)

print("OK services=%r time=%r" % (hbo["services"], hbo["time"]))
PYEOF
)
log "  shape result: $SHAPE_RES"
[[ "$SHAPE_RES" == OK* ]] || fail "${SHAPE_RES#FAIL }"
log "  shape=ok"

# ──────────────────────────────────────────────────────────────────────────
# ASSERTION 3 — COUNT / FILTER.
# ──────────────────────────────────────────────────────────────────────────
log "=== ASSERTION 3: count + network filter ==="

# 3a. count == 1 -> <= 1 element.
HB_ONE=$(hb_rpc getnodeaddresses '[1]')
HB_ONE_LEN=$(pyjson "$HB_ONE" "len(d['result']) if isinstance(d.get('result'), list) else -1")
[[ "$HB_ONE_LEN" =~ ^[0-9]+$ ]] || fail "count: hotbuns getnodeaddresses 1 result not an array (got: $HB_ONE)"
(( HB_ONE_LEN <= 1 )) || fail "count: hotbuns getnodeaddresses 1 returned $HB_ONE_LEN elements (expected <=1)"

# 3b. network == ipv4 -> contains the ipv4 addr.
HB_V4=$(hb_rpc getnodeaddresses '[0,"ipv4"]')
HB_V4_HAS=$(pyjson "$HB_V4" "any(isinstance(o,dict) and o.get('address')=='$INJECT_ADDR' and o.get('port')==$INJECT_PORT for o in d.get('result',[]))")
[[ "$HB_V4_HAS" == "True" ]] || fail "netfilter: hotbuns getnodeaddresses 0 ipv4 missing $INJECT_ADDR:$INJECT_PORT (got: $HB_V4)"

# 3c. network == onion -> [] (only an ipv4 addr was injected).
HB_ONION=$(hb_rpc getnodeaddresses '[0,"onion"]')
HB_ONION_EMPTY=$(pyjson "$HB_ONION" "isinstance(d.get('result'), list) and len(d['result'])==0")
[[ "$HB_ONION_EMPTY" == "True" ]] || fail "netfilter: hotbuns getnodeaddresses 0 onion expected [] (got: $HB_ONION)"

# Core parity sanity on the filter (the oracle agrees).
CORE_ONION=$(core_cli getnodeaddresses 0 onion 2>&1)
echo "$CORE_ONION" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if isinstance(d,list) and len(d)==0 else 1)' 2>/dev/null \
    || fail "netfilter: Core getnodeaddresses 0 onion expected [] (oracle sanity; got: $CORE_ONION)"

CORE_V4=$(core_cli getnodeaddresses 0 ipv4 2>&1)
echo "$CORE_V4" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if any(isinstance(o,dict) and o.get('address')=='$INJECT_ADDR' for o in d) else 1)" 2>/dev/null \
    || fail "netfilter: Core getnodeaddresses 0 ipv4 missing $INJECT_ADDR (oracle sanity; got: $CORE_V4)"

log "  count=ok netfilter=ok"

# ── All assertions passed. ────────────────────────────────────────────────
log "PASS: getnodeaddresses Core-shaped (5-key objects, services INT, time INT) + error/count/filter parity with bitcoind v31.99"
pass

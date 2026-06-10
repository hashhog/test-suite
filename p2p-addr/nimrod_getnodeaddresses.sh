#!/usr/bin/env bash
#
# nimrod_getnodeaddresses.sh — self-contained getnodeaddresses P2P-axis
# differential test (read-only addrman dump).
#
# The first cell of the P2P axis, after the wallet + mempool-policy +
# getchaintxstats chapters. getnodeaddresses is NOT consensus — it is a
# read-only dump of the address manager — but the OUTPUT SHAPE and the
# param/error SEMANTICS must be EXACTLY Core's (rpc/net.cpp:911-967).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind on a SEPARATE regtest instance (own
#   scratch datadir + ports). Both nimrod and Core are driven with the same
#   calls and compared. Because addrman shuffles its output, every assertion is
#   ORDER-INSENSITIVE — addresses are matched by CONTENT, never by index.
#
# WHAT IS ASSERTED (per the buildable spec _next-cells-design-2026-06-04.md):
#   1. ERROR PATHS (no addrman population needed — robust + deterministic):
#        getnodeaddresses -1        -> RPC error code -8 "Address count out of range"
#        getnodeaddresses 1 "bogus" -> RPC error code -8 "Network not recognized: bogus"
#      asserted on BOTH nimrod AND Core.
#   2. SHAPE: addpeeraddress "8.8.8.8" 8333 on BOTH; getnodeaddresses 0 on BOTH.
#      nimrod's array must contain an object for 8.8.8.8 with EXACTLY the 5 keys
#      {time, services, address, port, network} (fail on any extra/missing key),
#      address=="8.8.8.8", port==8333, network=="ipv4", services an INTEGER (not
#      a hex string), time an INTEGER > 0. The KEY SET + value TYPES are also
#      compared to Core's object for the same injected addr (time is NOT compared
#      exactly — clocks differ).
#   3. COUNT/FILTER:
#        getnodeaddresses 1          -> <= 1 element
#        getnodeaddresses 0 "ipv4"   -> the ipv4 addr present
#        getnodeaddresses 0 "onion"  -> [] (only an ipv4 addr was injected)
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/nimrod_policy.sh): no
#   required args, set -uo pipefail, idempotent, trap cleanup, scratch /tmp +
#   UNIQUE ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETNODEADDRESSES nimrod: PASS shape=ok errors=ok count=ok netfilter=ok
#   FAIL: GETNODEADDRESSES nimrod: FAIL <short reason>
#
# Touches ONLY /tmp/gna-nimrod/ + /tmp/gna-core/ and ports 21971/21991 (nimrod
#   RPC/P2P), 21972/21992 (Core RPC/P2P). NEVER touches /data/nvme1/ or
#   testnet4-data/ or any live node (haskoin is mid-sync — left alone).

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASEDIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # meta-repo root
NODE_BIN="$BASEDIR/nimrod/bin/nimrod"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

NM_DATADIR="/tmp/gna-nimrod"
NM_RPC=21971
NM_P2P=21991
NM_LOG="$NM_DATADIR/node.log"
NM_COOKIE_FILE="$NM_DATADIR/regtest/.cookie"

# NOTE: the Core oracle ports live in a separate, collision-free range (2207x/2209x).
# The fanout's 2197x/2199x band is shared by sibling impls; rustoshi + ouroboros
# both happen to use 21972/21992 there, which would otherwise bind-collide with
# this test's Core oracle (and nimrod) mid-run under parallel fanout. (Sibling
# port-kills are gone — port-kills were banned after the 2026-06-10 fuser
# incident.) Keeping Core out of that band keeps this robust under parallelism. nimrod's own ports (RPC 21971 / P2P
# 21991) are unused by any sibling's kill set and stay as assigned.
CORE_DATADIR="/tmp/gna-nimrod-core"
CORE_RPC=22072
CORE_P2P=22092
CORE_LOG="$CORE_DATADIR/core.log"

INJ_ADDR="8.8.8.8"
INJ_PORT=8333

NM_PID=""
NM_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gna:nimrod] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$NM_PID" ]] && kill -0 "$NM_PID" 2>/dev/null; then
        kill "$NM_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NM_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NM_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$NM_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETNODEADDRESSES nimrod: PASS shape=ok errors=ok count=ok netfilter=ok"
    exit 0
}
fail() {
    echo "GETNODEADDRESSES nimrod: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gna-nimrod" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${NM_RPC}|${NM_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${NM_RPC}|${NM_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${NM_RPC}/${NM_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$NM_DATADIR" "$CORE_DATADIR"
mkdir -p "$NM_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]] || fail "nimrod binary not found at $NODE_BIN (run: cd nimrod && nimble build -d:release -y)"
[[ -x "$CORE_BIN" ]] || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]] || fail "bitcoin-cli not found at $CORE_CLI"

# ── 2. Launch the Core oracle. ────────────────────────────────────────────
log "launching Core oracle rpc=:$CORE_RPC p2p=:$CORE_P2P"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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

CC() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# ── 3. Launch nimrod on regtest. ──────────────────────────────────────────
# ouroboros-only note: generous (>=120s) RPC-startup wait. nimrod is a compiled
# binary that comes up fast; 60s is ample here.
log "launching nimrod (regtest) rpc=:$NM_RPC p2p=:$NM_P2P -> $NM_LOG"
"$NODE_BIN" --network=regtest --datadir="$NM_DATADIR" \
    --port="$NM_P2P" --rpcport="$NM_RPC" start >"$NM_LOG" 2>&1 &
NM_PID=$!
log "nimrod pid=$NM_PID"
nm_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < nm_deadline )); do
    if [[ -z "$NM_COOKIE" && -f "$NM_COOKIE_FILE" ]]; then
        NM_COOKIE=$(cat "$NM_COOKIE_FILE")
    fi
    if [[ -n "$NM_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$NM_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$NM_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$NM_PID" 2>/dev/null || { tail -n 20 "$NM_LOG" >&2 2>/dev/null || true; fail "nimrod exited during startup (see $NM_LOG)"; }
    sleep 1
done
[[ -n "$NM_COOKIE" ]] || fail "nimrod cookie never appeared within 60s"
r=$(curl -s --max-time 5 -u "$NM_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$NM_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "nimrod RPC never responded within 60s"
log "nimrod RPC ready"

# ── Raw nimrod JSON-RPC helper: prints the FULL response body. ────────────
nm_raw() {  # nm_raw <method> <json-params-array>
    curl -s --max-time 15 -u "$NM_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$NM_RPC/" 2>/dev/null
}

# ── 4. ERROR PATHS (no addrman population needed). ────────────────────────
log "=== error paths ==="

# 4a. getnodeaddresses -1 -> -8 "Address count out of range" on BOTH.
nm_neg=$(nm_raw getnodeaddresses '[-1]')
log "nimrod getnodeaddresses -1 -> $nm_neg"
echo "$nm_neg" | python3 -c '
import sys, json
d = json.load(sys.stdin)
e = d.get("error")
assert e is not None, "expected error, got result"
code = e.get("code"); msg = e.get("message")
assert code == -8, "expected code -8, got " + repr(code)
assert msg == "Address count out of range", "expected exact msg, got " + repr(msg)
' || fail "nimrod getnodeaddresses -1 did not throw -8 'Address count out of range' (got: $nm_neg)"

core_neg=$(CC getnodeaddresses -1 2>&1 || true)
log "Core getnodeaddresses -1 -> $core_neg"
echo "$core_neg" | grep -q "code: -8" || fail "Core getnodeaddresses -1 did not return code -8 (got: $core_neg)"
echo "$core_neg" | grep -qi "Address count out of range" || fail "Core getnodeaddresses -1 wrong message (got: $core_neg)"

# 4b. getnodeaddresses 1 "bogus" -> -8 "Network not recognized: bogus" on BOTH.
nm_bog=$(nm_raw getnodeaddresses '[1,"bogus"]')
log "nimrod getnodeaddresses 1 bogus -> $nm_bog"
echo "$nm_bog" | python3 -c '
import sys, json
d = json.load(sys.stdin)
e = d.get("error")
assert e is not None, "expected error, got result"
code = e.get("code"); msg = e.get("message")
assert code == -8, "expected code -8, got " + repr(code)
assert msg == "Network not recognized: bogus", "expected exact msg, got " + repr(msg)
' || fail "nimrod getnodeaddresses 1 bogus did not throw -8 'Network not recognized: bogus' (got: $nm_bog)"

core_bog=$(CC getnodeaddresses 1 "bogus" 2>&1 || true)
log "Core getnodeaddresses 1 bogus -> $core_bog"
echo "$core_bog" | grep -q "code: -8" || fail "Core getnodeaddresses 1 bogus did not return code -8 (got: $core_bog)"
echo "$core_bog" | grep -qi "Network not recognized: bogus" || fail "Core getnodeaddresses 1 bogus wrong message (got: $core_bog)"
log "error paths OK (both -8, exact messages)"

# ── 5. Populate the addrman on BOTH via addpeeraddress. ───────────────────
log "=== populate addrman: addpeeraddress $INJ_ADDR $INJ_PORT ==="
nm_add=$(nm_raw addpeeraddress "[\"$INJ_ADDR\",$INJ_PORT]")
log "nimrod addpeeraddress -> $nm_add"
echo "$nm_add" | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert d.get("error") is None, "unexpected error: " + repr(d.get("error"))
r = d.get("result")
assert isinstance(r, dict), "expected object result, got " + repr(r)
assert r.get("success") is True, "expected success:true, got " + repr(r)
' || fail "nimrod addpeeraddress did not return success:true (got: $nm_add)"

core_add=$(CC addpeeraddress "$INJ_ADDR" "$INJ_PORT" 2>&1 || true)
log "Core addpeeraddress -> $core_add"
echo "$core_add" | grep -q '"success": true' || fail "Core addpeeraddress did not return success:true (got: $core_add)"

# ── 6. SHAPE: getnodeaddresses 0 -> object for 8.8.8.8 with exactly 5 keys. ─
log "=== shape: getnodeaddresses 0 ==="
nm_all=$(nm_raw getnodeaddresses '[0]')
log "nimrod getnodeaddresses 0 -> $nm_all"
core_all=$(CC getnodeaddresses 0 2>/dev/null || true)
log "Core getnodeaddresses 0 -> $(echo "$core_all" | tr -d '\n')"

# Compare nimrod's row for 8.8.8.8 to Core's: exact 5-key set, value types,
# address/port/network exactly; time an INTEGER>0; services an INTEGER.
EXPECT_ADDR="$INJ_ADDR" EXPECT_PORT="$INJ_PORT" \
python3 - "$nm_all" "$core_all" <<'PYEOF' 2>/dev/null || fail "shape mismatch (see stderr / $NM_LOG)"
import sys, json, os
nm_body = sys.argv[1]
core_body = sys.argv[2]
want_addr = os.environ["EXPECT_ADDR"]
want_port = int(os.environ["EXPECT_PORT"])
EXPECT_KEYS = {"time", "services", "address", "port", "network"}

def err(m):
    print("SHAPE-ERR:", m, file=sys.stderr); sys.exit(1)

# nimrod result (JSON-RPC envelope).
d = json.loads(nm_body)
if d.get("error") is not None:
    err(f"nimrod returned error: {d['error']}")
nm = d.get("result")
if not isinstance(nm, list):
    err(f"nimrod result is not an array: {type(nm)}")

# Find nimrod's object for the injected address (order-insensitive).
nm_obj = None
for o in nm:
    if isinstance(o, dict) and o.get("address") == want_addr:
        nm_obj = o; break
if nm_obj is None:
    err(f"nimrod array has no object for address {want_addr}; got {nm}")

# EXACT 5-key set (no extra, no missing).
keys = set(nm_obj.keys())
if keys != EXPECT_KEYS:
    err(f"nimrod object keys {sorted(keys)} != expected {sorted(EXPECT_KEYS)}")

# Value checks.
if nm_obj["address"] != want_addr:
    err(f"address {nm_obj['address']!r} != {want_addr!r}")
if not isinstance(nm_obj["port"], int) or nm_obj["port"] != want_port:
    err(f"port {nm_obj['port']!r} != {want_port} (or not int)")
if nm_obj["network"] != "ipv4":
    err(f"network {nm_obj['network']!r} != 'ipv4'")
# services must be an INTEGER, not a hex string (unlike getpeerinfo).
if not isinstance(nm_obj["services"], int) or isinstance(nm_obj["services"], bool):
    err(f"services {nm_obj['services']!r} is not an integer")
# time must be an INTEGER > 0.
if not isinstance(nm_obj["time"], int) or isinstance(nm_obj["time"], bool):
    err(f"time {nm_obj['time']!r} is not an integer")
if nm_obj["time"] <= 0:
    err(f"time {nm_obj['time']} is not > 0")

# Compare KEY SET + value TYPES against Core's object for the same addr (NOT
# time exactly — clocks differ). Core CLI prints a bare JSON array.
core = json.loads(core_body)
if not isinstance(core, list):
    err(f"Core result is not an array: {type(core)}")
core_obj = None
for o in core:
    if isinstance(o, dict) and o.get("address") == want_addr:
        core_obj = o; break
if core_obj is None:
    err(f"Core array has no object for address {want_addr}; got {core}")
if set(core_obj.keys()) != keys:
    err(f"key set differs: nimrod {sorted(keys)} vs Core {sorted(core_obj.keys())}")
for k in EXPECT_KEYS:
    tn = type(nm_obj[k]); tc = type(core_obj[k])
    # int/bool distinction: both impls emit plain ints for these fields.
    if tn is not tc:
        err(f"type of '{k}' differs: nimrod {tn.__name__} vs Core {tc.__name__}")
# Sanity: Core agrees on address/port/network exactly.
if core_obj["address"] != want_addr or int(core_obj["port"]) != want_port or core_obj["network"] != "ipv4":
    err(f"Core object disagrees: {core_obj}")
print("SHAPE-OK", file=sys.stderr)
PYEOF
log "shape OK (exact 5-key set, types match Core, ipv4/8.8.8.8/8333, services+time integers)"

# ── 7. COUNT / FILTER. ────────────────────────────────────────────────────
log "=== count / network filter ==="

# 7a. getnodeaddresses 1 -> <= 1 element.
nm_one=$(nm_raw getnodeaddresses '[1]')
log "nimrod getnodeaddresses 1 -> $nm_one"
echo "$nm_one" | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert d.get("error") is None, "unexpected error: " + repr(d.get("error"))
r = d.get("result")
assert isinstance(r, list), "result not array: " + repr(r)
assert len(r) <= 1, "count=1 returned " + str(len(r)) + " elements"
' || fail "nimrod getnodeaddresses 1 returned >1 element (got: $nm_one)"

# 7b. getnodeaddresses 0 "ipv4" -> the ipv4 addr present.
nm_v4=$(nm_raw getnodeaddresses '[0,"ipv4"]')
log "nimrod getnodeaddresses 0 ipv4 -> $nm_v4"
EXPECT_ADDR="$INJ_ADDR" python3 -c '
import sys, json, os
want = os.environ["EXPECT_ADDR"]
d = json.load(sys.stdin)
assert d.get("error") is None, "unexpected error: " + repr(d.get("error"))
r = d.get("result")
assert isinstance(r, list), "result not array: " + repr(r)
assert any(isinstance(o, dict) and o.get("address") == want and o.get("network") == "ipv4" for o in r), \
    "ipv4 filter did not return " + want + ": " + repr(r)
' <<<"$nm_v4" || fail "nimrod getnodeaddresses 0 ipv4 missing the ipv4 addr (got: $nm_v4)"

# 7c. getnodeaddresses 0 "onion" -> [] (only an ipv4 addr was injected).
nm_onion=$(nm_raw getnodeaddresses '[0,"onion"]')
log "nimrod getnodeaddresses 0 onion -> $nm_onion"
echo "$nm_onion" | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert d.get("error") is None, "unexpected error: " + repr(d.get("error"))
r = d.get("result")
assert isinstance(r, list), "result not array: " + repr(r)
assert len(r) == 0, "onion filter returned non-empty " + repr(r)
' || fail "nimrod getnodeaddresses 0 onion was not [] (got: $nm_onion)"

# Cross-check Core agrees on the filters (robustness, not strictly required).
core_onion=$(CC getnodeaddresses 0 "onion" 2>/dev/null || true)
log "Core getnodeaddresses 0 onion -> $(echo "$core_onion" | tr -d '\n ')"
echo "$core_onion" | python3 -c '
import sys, json
r = json.load(sys.stdin)
assert isinstance(r, list) and len(r) == 0, "Core onion filter not []: " + repr(r)
' || fail "Core getnodeaddresses 0 onion was not [] (got: $core_onion)"

log "count/filter OK (count<=1, ipv4 returns the addr, onion empty)"

# ── 8. PASS. ──────────────────────────────────────────────────────────────
log "PASS: getnodeaddresses Core-shaped (shape + error codes/messages + count + network filter)"
pass

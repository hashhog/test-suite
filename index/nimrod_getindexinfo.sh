#!/usr/bin/env bash
#
# nimrod_getindexinfo.sh — self-contained getindexinfo INDEX-STATUS parity test.
#
# The indexing-axis keystone (first cell after the wallet + mempool-policy +
# getchaintxstats chapters). Where the policy harness proved the standardness
# gate, this proves the *index-status surface*: getindexinfo must return Core's
# EXACT shape for every index the node actually runs.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind on a SEPARATE regtest instance (own
#   scratch datadir + ports), started with -txindex=1 -blockfilterindex=basic
#   so Core reports BOTH a "txindex" and a "basic block filter index" entry.
#
# CORE SEMANTICS (bitcoin-core/src/rpc/node.cpp:351-410 SummaryToJSON +
#   getindexinfo; src/index/base.{h,cpp}):
#   * getindexinfo returns a dynamic JSON OBJECT keyed BY INDEX NAME. For each
#     *running* index Core pushes ONE entry whose value has EXACTLY two fields
#     in THIS ORDER: { "<index name>": { "synced": <bool>, "best_block_height":
#     <int> } }. Nothing else — no best_hash / best_block_hash / name-in-value.
#   * Index NAMES are the literal GetName() strings: "txindex",
#     "basic block filter index", "coinstatsindex", "txospenderindex". An index
#     appears ONLY if it is enabled/running.
#   * best_block_height = the height the index reached (0 if no best block yet);
#     synced = caught up to the chain tip. After syncing N empty blocks the
#     enabled index reports synced=true, best_block_height=N (== tip height).
#   * ARG index_name (optional, positional 0) filters to ONE index: the entry is
#     dropped when index_name is non-empty AND != the summary's name. So
#       getindexinfo "<name>"        -> only that key
#       getindexinfo "no-such-index" -> {} (empty object, NOT an error)
#     Empty/omitted arg = all running indexes.
#
# WHAT nimrod RUNS (the key design point): nimrod runs exactly ONE optional
#   index — the BIP-157 "basic block filter index" (wired when --blockfilterindex
#   is set). It does NOT run a txindex / coinstatsindex / txospenderindex. Per
#   Core semantics ("an index appears ONLY if running") nimrod must therefore
#   emit ONLY the "basic block filter index" key and must NOT fabricate a
#   "txindex" key. The differential validates nimrod's "basic block filter
#   index" entry against Core's same-named entry (Core runs it too), and asserts
#   nimrod correctly omits the txindex it doesn't run.
#
# ASSERTIONS (all on regtest, NOT live — deterministic at the same synced height):
#   1. shape  — for the "basic block filter index" entry Core reports, nimrod
#               reports the SAME key with synced==true, best_block_height==NBLOCKS,
#               and the value object has EXACTLY the keys {synced,best_block_height}
#               (FAIL on any extra key: best_hash / best_block_hash / name / etc).
#   2. height — best_block_height == NBLOCKS (the tip height) on nimrod.
#   3. filter — getindexinfo "basic block filter index" on nimrod returns ONLY
#               that key; getindexinfo "txindex" on nimrod returns {} (nimrod
#               does not run a txindex).
#   4. empty  — getindexinfo "no-such-index" on nimrod returns {} (empty object,
#               not an error).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/nimrod_policy.sh): no
#   required args, set -uo pipefail, idempotent, trap cleanup, scratch datadirs +
#   UNIQUE ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETINDEXINFO nimrod: PASS shape=ok height=ok filter=ok empty=ok
#   FAIL: GETINDEXINFO nimrod: FAIL <short reason>
#
# Touches ONLY /tmp/gii-nimrod/ + /tmp/gii-nimrod-core/ and ports 40031/40051
#   (nimrod RPC/P2P), 40231/40251 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASEDIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # meta-repo root
NODE_BIN="$BASEDIR/nimrod/bin/nimrod"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

NM_DATADIR="/tmp/gii-nimrod"
NM_RPC=40031
NM_P2P=40051
NM_LOG="$NM_DATADIR/node.log"
NM_COOKIE_FILE="$NM_DATADIR/regtest/.cookie"

CORE_DATADIR="/tmp/gii-nimrod-core"
CORE_RPC=40231
CORE_P2P=40251
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic regtest p2wpkh address (bcrt1...) for coinbase rewards — both
# nodes mine to the SAME address so the chains are byte-identical empty-block
# chains. No wallet dependency on the nimrod side.
ADDR="bcrt1q2vfxp232rx0z9rzn0hay9jptagk8c86ddphpjv"

NBLOCKS=120            # tip height after mining; the synced index must reach this.
INDEX_NAME="basic block filter index"

NM_PID=""
NM_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getindexinfo:nimrod] $*" >&2; }

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {  # pass <shape> <height> <filter> <empty>
    echo "GETINDEXINFO nimrod: PASS shape=$1 height=$2 filter=$3 empty=$4"
    exit 0
}
fail() {
    echo "GETINDEXINFO nimrod: FAIL $*"
    exit 1
}

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
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
    fuser -k "${NM_RPC}/tcp"   2>/dev/null || true
    fuser -k "${NM_P2P}/tcp"   2>/dev/null || true
    fuser -k "${CORE_RPC}/tcp" 2>/dev/null || true
    fuser -k "${CORE_P2P}/tcp" 2>/dev/null || true
    rm -rf "$NM_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── nimrod RPC helper (cookie auth, curl). ────────────────────────────────
# usage: nm_rpc <method> <json-params-array>   e.g.  nm_rpc getindexinfo '["txindex"]'
nm_rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 30 -u "$NM_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$NM_RPC/" 2>/dev/null
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "datadir=$NM_DATADIR"   2>/dev/null || true
pkill -f "datadir=$CORE_DATADIR" 2>/dev/null || true
fuser -k "${NM_RPC}/tcp"   2>/dev/null || true
fuser -k "${NM_P2P}/tcp"   2>/dev/null || true
fuser -k "${CORE_RPC}/tcp" 2>/dev/null || true
fuser -k "${CORE_P2P}/tcp" 2>/dev/null || true
sleep 1
rm -rf "$NM_DATADIR" "$CORE_DATADIR"
mkdir -p "$NM_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]] || fail "nimrod binary not found at $NODE_BIN (run: cd nimrod && nimble build -d:release -y)"
[[ -x "$CORE_BIN" ]] || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]] || fail "bitcoin-cli not found at $CORE_CLI"

# ── 2. Launch the Core oracle (-txindex=1 -blockfilterindex=basic). ───────
log "launching Core oracle rpc=:$CORE_RPC (-txindex=1 -blockfilterindex=basic)"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -txindex=1 -blockfilterindex=basic -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 60 ))
core_up=0
while (( $(date +%s) < core_deadline )); do
    if "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1; then
        core_up=1; break
    fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
(( core_up == 1 )) || fail "Core oracle failed to respond within 60s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch nimrod on regtest with --blockfilterindex. ──────────────────
log "launching nimrod (regtest) rpc=:$NM_RPC p2p=:$NM_P2P --blockfilterindex -> $NM_LOG"
"$NODE_BIN" --network=regtest --datadir="$NM_DATADIR" \
    --port="$NM_P2P" --rpcport="$NM_RPC" --blockfilterindex start >"$NM_LOG" 2>&1 &
NM_PID=$!
log "nimrod pid=$NM_PID"
# Generous RPC-startup wait (>=120s) to keep this harness uniform across the
# slowest impls in the fleet.
nm_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < nm_deadline )); do
    if [[ -z "$NM_COOKIE" && -f "$NM_COOKIE_FILE" ]]; then
        NM_COOKIE=$(cat "$NM_COOKIE_FILE")
    fi
    if [[ -n "$NM_COOKIE" ]]; then
        r=$(nm_rpc getblockcount '[]')
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$NM_PID" 2>/dev/null || { tail -n 20 "$NM_LOG" >&2 2>/dev/null || true; fail "nimrod exited during startup (see $NM_LOG)"; }
    sleep 1
done
[[ -n "$NM_COOKIE" ]] || fail "nimrod cookie never appeared within 120s"
r=$(nm_rpc getblockcount '[]')
echo "$r" | grep -q '"result"' || fail "nimrod RPC never responded within 120s"
log "nimrod RPC ready"

# ── 4. Mine the SAME number of empty blocks on BOTH nodes. ────────────────
log "mining $NBLOCKS empty blocks on Core"
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null 2>&1 \
    || fail "Core generatetoaddress failed (see $CORE_LOG)"

log "mining $NBLOCKS empty blocks on nimrod"
nm_gen=$(nm_rpc generatetoaddress "[$NBLOCKS,\"$ADDR\"]")
echo "$nm_gen" | grep -q '"result"' || { log "nimrod gen resp: $nm_gen"; fail "nimrod generatetoaddress failed"; }

# Confirm both reached the same tip.
core_h=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount 2>/dev/null)
nm_h=$(nm_rpc getblockcount '[]' | python3 -c 'import sys,json; print(json.load(sys.stdin).get("result"))' 2>/dev/null)
log "tip heights: core=$core_h nimrod=$nm_h (expected $NBLOCKS)"
[[ "$core_h" == "$NBLOCKS" ]] || fail "Core tip height $core_h != $NBLOCKS"
[[ "$nm_h"  == "$NBLOCKS" ]] || fail "nimrod tip height $nm_h != $NBLOCKS"

# ── 5. Poll getindexinfo until synced==true on BOTH (generous timeout). ───
# Core indexes sync on a background thread; nimrod populates the filter index
# inline on the mining path. Poll both to be robust either way.
poll_synced() {  # poll_synced <"core"|"nimrod"> <index-name>
    local who="$1" name="$2" deadline; deadline=$(( $(date +%s) + 120 ))
    local out
    while (( $(date +%s) < deadline )); do
        if [[ "$who" == "core" ]]; then
            out=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getindexinfo 2>/dev/null)
        else
            out=$(nm_rpc getindexinfo '[]')
        fi
        if echo "$out" | python3 -c "
import sys,json
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: sys.exit(1)
if 'result' in d: d=d['result']
e=d.get('''$name''')
sys.exit(0 if (e and e.get('synced') is True) else 1)
" 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

log "polling Core getindexinfo until '$INDEX_NAME' synced"
poll_synced core "$INDEX_NAME" || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core '$INDEX_NAME' never reported synced within 120s"; }
log "polling nimrod getindexinfo until '$INDEX_NAME' synced"
poll_synced nimrod "$INDEX_NAME" || { tail -n 20 "$NM_LOG" >&2 2>/dev/null || true; fail "nimrod '$INDEX_NAME' never reported synced within 120s"; }

# ── 6. Collect getindexinfo from both. ────────────────────────────────────
CORE_ALL=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getindexinfo 2>/dev/null)
NM_ALL=$(nm_rpc getindexinfo '[]')
NM_FILTER=$(nm_rpc getindexinfo "[\"$INDEX_NAME\"]")
NM_TXINDEX=$(nm_rpc getindexinfo '["txindex"]')
NM_NOSUCH=$(nm_rpc getindexinfo '["no-such-index"]')

log "core all     : $CORE_ALL"
log "nimrod all   : $NM_ALL"
log "nimrod filter: $NM_FILTER"
log "nimrod txidx : $NM_TXINDEX"
log "nimrod nosuch: $NM_NOSUCH"

# ── 7. Assertions, delegated to a Python checker (exact shape). ───────────
VERDICT=$(NBLOCKS="$NBLOCKS" INDEX_NAME="$INDEX_NAME" python3 - \
    "$CORE_ALL" "$NM_ALL" "$NM_FILTER" "$NM_TXINDEX" "$NM_NOSUCH" <<'PYEOF'
import sys, json, os

NBLOCKS    = int(os.environ["NBLOCKS"])
INDEX_NAME = os.environ["INDEX_NAME"]

def unwrap(raw):
    """Parse a JSON-RPC response or a bare CLI JSON object -> the result dict."""
    try:
        d = json.loads(raw)
    except Exception as e:
        return None, f"unparseable JSON: {e}"
    if isinstance(d, dict) and "result" in d and "jsonrpc" in d:
        if d.get("error"):
            return None, f"rpc error: {d['error']}"
        d = d["result"]
    if not isinstance(d, dict):
        return None, f"result not an object: {type(d).__name__}"
    return d, None

core_all_raw, nm_all_raw, nm_filter_raw, nm_txindex_raw, nm_nosuch_raw = sys.argv[1:6]

core_all, err = unwrap(core_all_raw)
if err: print(f"FAIL core getindexinfo: {err}"); sys.exit(0)
nm_all, err = unwrap(nm_all_raw)
if err: print(f"FAIL nimrod getindexinfo: {err}"); sys.exit(0)
nm_filter, err = unwrap(nm_filter_raw)
if err: print(f"FAIL nimrod getindexinfo filter: {err}"); sys.exit(0)
nm_txindex, err = unwrap(nm_txindex_raw)
if err: print(f"FAIL nimrod getindexinfo txindex: {err}"); sys.exit(0)
nm_nosuch, err = unwrap(nm_nosuch_raw)
if err: print(f"FAIL nimrod getindexinfo no-such-index: {err}"); sys.exit(0)

# Core MUST report the filter index (we started it with -blockfilterindex=basic).
if INDEX_NAME not in core_all:
    print(f"FAIL core did not report '{INDEX_NAME}' (got keys {sorted(core_all)})"); sys.exit(0)

# --- (1) shape: for the index Core reports that nimrod also runs, nimrod must
#         report the SAME key, with EXACTLY {synced, best_block_height}. ---
if INDEX_NAME not in nm_all:
    print(f"FAIL nimrod did not report '{INDEX_NAME}' (got keys {sorted(nm_all)})"); sys.exit(0)

nm_entry   = nm_all[INDEX_NAME]
core_entry = core_all[INDEX_NAME]
if not isinstance(nm_entry, dict):
    print(f"FAIL nimrod '{INDEX_NAME}' value is not an object"); sys.exit(0)

EXPECTED_KEYS = {"synced", "best_block_height"}
nm_keys = set(nm_entry.keys())
if nm_keys != EXPECTED_KEYS:
    extra = nm_keys - EXPECTED_KEYS
    missing = EXPECTED_KEYS - nm_keys
    msg = []
    if extra:   msg.append(f"extra keys {sorted(extra)}")
    if missing: msg.append(f"missing keys {sorted(missing)}")
    print(f"FAIL nimrod '{INDEX_NAME}' value keys != {{synced,best_block_height}}: " + "; ".join(msg)); sys.exit(0)
# Core's own entry must also be exactly the two keys (defensive parity check).
if set(core_entry.keys()) != EXPECTED_KEYS:
    print(f"FAIL core '{INDEX_NAME}' value keys != {{synced,best_block_height}} (got {sorted(core_entry)})"); sys.exit(0)

# Type checks: synced is a real bool, best_block_height a real int (not str).
if not isinstance(nm_entry["synced"], bool):
    print(f"FAIL nimrod synced is not a bool: {nm_entry['synced']!r}"); sys.exit(0)
if isinstance(nm_entry["best_block_height"], bool) or not isinstance(nm_entry["best_block_height"], int):
    print(f"FAIL nimrod best_block_height is not an int: {nm_entry['best_block_height']!r}"); sys.exit(0)

# synced must be True, matching Core.
if nm_entry["synced"] is not True:
    print(f"FAIL nimrod '{INDEX_NAME}' synced != true (got {nm_entry['synced']!r})"); sys.exit(0)
if core_entry["synced"] is not True:
    print(f"FAIL core '{INDEX_NAME}' synced != true (got {core_entry['synced']!r})"); sys.exit(0)
SHAPE = "ok"

# --- (2) height: best_block_height == NBLOCKS (the tip height), matching Core. ---
if nm_entry["best_block_height"] != NBLOCKS:
    print(f"FAIL nimrod best_block_height {nm_entry['best_block_height']} != {NBLOCKS}"); sys.exit(0)
if core_entry["best_block_height"] != NBLOCKS:
    print(f"FAIL core best_block_height {core_entry['best_block_height']} != {NBLOCKS}"); sys.exit(0)
HEIGHT = "ok"

# --- (3) filter: getindexinfo "<name>" returns ONLY that key; getindexinfo
#         "txindex" returns {} (nimrod does not run a txindex). ---
if set(nm_filter.keys()) != {INDEX_NAME}:
    print(f"FAIL nimrod getindexinfo '{INDEX_NAME}' returned keys {sorted(nm_filter)} (expected just ['{INDEX_NAME}'])"); sys.exit(0)
if nm_txindex != {}:
    print(f"FAIL nimrod getindexinfo 'txindex' returned {nm_txindex} (nimrod runs no txindex -> expected {{}})"); sys.exit(0)
FILTER = "ok"

# --- (4) empty: getindexinfo "no-such-index" returns {} (empty object). ---
if nm_nosuch != {}:
    print(f"FAIL nimrod getindexinfo 'no-such-index' returned {nm_nosuch} (expected {{}})"); sys.exit(0)
EMPTY = "ok"

print(f"PASS shape={SHAPE} height={HEIGHT} filter={FILTER} empty={EMPTY}")
PYEOF
)

log "verdict: $VERDICT"
case "$VERDICT" in
    PASS\ *)
        # VERDICT = "PASS shape=ok height=ok filter=ok empty=ok"
        # shellcheck disable=SC2086
        set -- $VERDICT
        shape=""; height=""; filter=""; empty=""
        for kv in "$@"; do
            case "$kv" in
                shape=*)  shape="${kv#shape=}" ;;
                height=*) height="${kv#height=}" ;;
                filter=*) filter="${kv#filter=}" ;;
                empty=*)  empty="${kv#empty=}" ;;
            esac
        done
        pass "$shape" "$height" "$filter" "$empty"
        ;;
    FAIL\ *)
        fail "${VERDICT#FAIL }"
        ;;
    *)
        fail "checker produced no verdict (output: ${VERDICT:-<empty>})"
        ;;
esac

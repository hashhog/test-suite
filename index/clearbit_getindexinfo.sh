#!/usr/bin/env bash
#
# clearbit_getindexinfo.sh — self-contained INDEX-STATUS parity test.
#
# The first cell of the indexing axis, after the wallet + mempool-policy +
# getchaintxstats chapters. Where the policy harness proved the mempool
# standardness gate, this proves clearbit's `getindexinfo` RPC reports the
# status of its running indices in the EXACT shape Bitcoin Core emits.
#
# getindexinfo is READ-ONLY index status — NOT consensus — but the output shape
# is load-bearing for any indexing client, so this asserts it byte-for-byte
# against a REAL bitcoind regtest oracle.
#
# CORE SEMANTICS (bitcoin-core/src/rpc/node.cpp:363-410 getindexinfo +
#   :351-361 SummaryToJSON, src/index/base.h:30-35 IndexSummary,
#   src/index/base.cpp:472-484 GetSummary):
#     getindexinfo returns a dynamic JSON OBJECT keyed BY INDEX NAME. For each
#     *running* index Core pushes one entry whose value carries EXACTLY two
#     fields in THIS ORDER: "synced" (bool) then "best_block_height" (int).
#     Nothing else — IndexSummary holds best_block_hash internally but
#     getindexinfo NEVER emits it. An index appears ONLY if it is enabled.
#     The index NAMES are the literal GetName() strings: "txindex" and
#     "basic block filter index". The optional positional arg filters to one
#     index; a non-matching name yields {} (empty object, NOT an error).
#     After a regtest node syncs N mined empty blocks, each enabled index
#     reports synced=true, best_block_height=N (== tip height).
#
# ORACLE = the box's REAL bitcoind (started -txindex=1 -blockfilterindex=basic)
#   on its own scratch datadir + ports. clearbit runs on its own scratch with
#   --txindex --blockfilterindex. The SAME number of empty blocks is mined on
#   both; we poll getindexinfo until synced==true on both (generous timeout);
#   then we assert clearbit matches Core key-for-key and shape-for-shape.
#
# ASSERTIONS:
#   1. shape   — for EACH index Core reports (txindex + basic block filter
#                index), clearbit reports the SAME key with synced==true,
#                best_block_height==N (the tip height), and the value object has
#                EXACTLY the keys {synced, best_block_height} (FAIL on any extra
#                key — best_hash / best_block_hash / name / etc.).
#   2. filter  — getindexinfo "txindex" on clearbit returns ONLY the txindex key.
#   3. empty   — getindexinfo "no-such-index" on clearbit returns {} (empty
#                object, not an error).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/clearbit_policy.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + UNIQUE
#   ports, ONE clean summary line on stdout, all noise -> stderr / logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   GETINDEXINFO clearbit: PASS shape=ok height=ok filter=ok empty=ok
#   GETINDEXINFO clearbit: FAIL <short reason>
#
# Touches ONLY /tmp/gii-clearbit/ + /tmp/gii-core/ and ports 40037/40057
#   (clearbit RPC/P2P) + 40038/40058 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

CB_DATADIR="/tmp/gii-clearbit"
CB_NETDIR="$CB_DATADIR/regtest"      # clearbit appends the network subdir
CB_RPC=40037
CB_P2P=40057
CB_LOG="$CB_DATADIR/node.log"

CORE_DATADIR="/tmp/gii-core"
CORE_RPC=40038
CORE_P2P=40058
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=120
# Deterministic regtest p2wpkh address (derived from secret 11..12 via Core's
# test_framework key_to_p2wpkh). Mining to a fixed address keeps the two nodes
# from needing a wallet.
MINE_ADDR="bcrt1qp53adya5a93nx8w82ymghjw8qpny0k328xzh6h"

# The two indices clearbit observably runs (chain_state.txindex_enabled /
# .blockfilterindex_enabled) — these are the GetName() strings Core emits.
IDX_TXINDEX="txindex"
IDX_FILTER="basic block filter index"

CB_PID=""
CB_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getindexinfo:clearbit] $*" >&2; }

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETINDEXINFO clearbit: PASS shape=ok height=ok filter=ok empty=ok"
    exit 0
}
fail() {
    echo "GETINDEXINFO clearbit: FAIL $*"
    exit 1
}

# ── Cleanup: kill node + oracle + wipe scratch on any exit. ───────────────
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
    fuser -k "${CB_RPC}/tcp"   2>/dev/null || true
    fuser -k "${CB_P2P}/tcp"   2>/dev/null || true
    fuser -k "${CORE_RPC}/tcp" 2>/dev/null || true
    fuser -k "${CORE_P2P}/tcp" 2>/dev/null || true
    rm -rf "$CB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gii-clearbit" 2>/dev/null || true
pkill -f "gii-core"     2>/dev/null || true
fuser -k "${CB_RPC}/tcp"   2>/dev/null || true
fuser -k "${CB_P2P}/tcp"   2>/dev/null || true
fuser -k "${CORE_RPC}/tcp" 2>/dev/null || true
fuser -k "${CORE_P2P}/tcp" 2>/dev/null || true
sleep 1
rm -rf "$CB_DATADIR" "$CORE_DATADIR"
mkdir -p "$CB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]] || fail "clearbit binary not found at $NODE_BIN (build: zig build -Doptimize=ReleaseFast)"
[[ -x "$CORE_BIN" ]] || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]] || fail "bitcoin-cli not found at $CORE_CLI"

# ── 2. JSON probe helper (python; reads stdin JSON, drills a path). ───────
# Usage: <json> | jget '<py-expr over var d>'  -> prints repr or empty on error.
jget() {
    python3 -c '
import sys, json
expr = sys.argv[1]
try:
    raw = sys.stdin.read()
    obj = json.loads(raw)
    d = obj.get("result") if isinstance(obj, dict) and "result" in obj else obj
    print(eval(expr))
except Exception as e:
    sys.stderr.write("jget error: %s\n" % e)
    print("")
' "$1"
}

# ── 3. Launch the Core oracle (txindex + basic block filter index). ───────
log "launching Core oracle rpc=:$CORE_RPC -txindex=1 -blockfilterindex=basic"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -txindex=1 -blockfilterindex=basic -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < core_deadline )); do
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 && break
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
    || fail "Core oracle failed to start within 90s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch clearbit on regtest with both indices enabled. ──────────────
log "launching clearbit (regtest) rpc=:$CB_RPC p2p=:$CB_P2P --txindex --blockfilterindex -> $CB_LOG"
"$NODE_BIN" --regtest --datadir="$CB_DATADIR" \
    --port="$CB_P2P" --rpcport="$CB_RPC" --txindex --blockfilterindex >"$CB_LOG" 2>&1 &
CB_PID=$!
log "clearbit pid=$CB_PID"
# ouroboros-style generous startup wait (>=120s) is the fleet standard; clearbit
# comes up far faster but we keep the floor generous for shared-runner contention.
cb_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < cb_deadline )); do
    if [[ -z "$CB_COOKIE" ]]; then
        for c in "$CB_NETDIR/.cookie" "$CB_DATADIR/.cookie"; do
            [[ -f "$c" ]] && CB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$CB_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$CB_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$CB_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$CB_PID" 2>/dev/null || { tail -n 20 "$CB_LOG" >&2 2>/dev/null || true; fail "clearbit exited during startup (see $CB_LOG)"; }
    sleep 1
done
[[ -n "$CB_COOKIE" ]] || fail "clearbit cookie never appeared within 120s"
r=$(curl -s --max-time 5 -u "$CB_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$CB_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "clearbit RPC never responded within 120s"
log "clearbit RPC ready"

# ── 5. RPC callers. ───────────────────────────────────────────────────────
cb_rpc() {  # cb_rpc <method> [params-json, default []]
    local method="$1"
    local params="${2:-[]}"
    curl -s --max-time 30 -u "$CB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$CB_RPC/" 2>/dev/null
}
core_rpc() {  # core_rpc <method> <args...>  (via bitcoin-cli)
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>/dev/null
}

# ── 6. Mine the SAME number of empty blocks on BOTH. ──────────────────────
log "mining $NBLOCKS empty blocks on Core -> $MINE_ADDR"
core_rpc generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null 2>&1 \
    || fail "Core generatetoaddress failed"
core_h=$(core_rpc getblockcount)
[[ "$core_h" == "$NBLOCKS" ]] || fail "Core height $core_h != $NBLOCKS after mining"

log "mining $NBLOCKS empty blocks on clearbit -> $MINE_ADDR"
cb_gen=$(cb_rpc generatetoaddress "[$NBLOCKS, \"$MINE_ADDR\"]")
echo "$cb_gen" | grep -q '"error":null\|"result"' || { log "clearbit generate resp: $cb_gen"; fail "clearbit generatetoaddress failed"; }
cb_h=$(cb_rpc getblockcount | jget 'int(d)')
[[ "$cb_h" == "$NBLOCKS" ]] || fail "clearbit height $cb_h != $NBLOCKS after mining"
log "both nodes at height $NBLOCKS"

# ── 7. Poll getindexinfo until synced==true on BOTH (generous timeout). ───
# Helper: returns 0 when EVERY index in the getindexinfo object reports
# synced==true (and there is at least one index), else non-zero.
all_synced_py='
import sys, json
raw = sys.stdin.read()
obj = json.loads(raw)
d = obj.get("result") if isinstance(obj, dict) and "result" in obj else obj
if not isinstance(d, dict) or len(d) == 0:
    sys.exit(1)
for k, v in d.items():
    if not (isinstance(v, dict) and v.get("synced") is True):
        sys.exit(1)
sys.exit(0)
'
log "polling for index sync on both nodes (>=120s budget)"
sync_deadline=$(( $(date +%s) + 120 ))
core_ok=""; cb_ok=""
while (( $(date +%s) < sync_deadline )); do
    if [[ -z "$core_ok" ]]; then
        core_gii=$(core_rpc getindexinfo)
        echo "$core_gii" | python3 -c "$all_synced_py" && core_ok="1"
    fi
    if [[ -z "$cb_ok" ]]; then
        cb_gii=$(cb_rpc getindexinfo '[]')
        echo "$cb_gii" | python3 -c "$all_synced_py" && cb_ok="1"
    fi
    [[ -n "$core_ok" && -n "$cb_ok" ]] && break
    sleep 2
done
[[ -n "$core_ok" ]] || { log "Core getindexinfo: $(core_rpc getindexinfo)"; fail "Core indices never reported synced=true within 120s"; }
[[ -n "$cb_ok"   ]] || { log "clearbit getindexinfo: $(cb_rpc getindexinfo '[]')"; fail "clearbit indices never reported synced=true within 120s"; }

# Capture the final synced snapshots.
CORE_GII=$(core_rpc getindexinfo)
CB_GII=$(cb_rpc getindexinfo '[]')
log "Core getindexinfo:     $CORE_GII"
log "clearbit getindexinfo: $CB_GII"

# ── 8. Assertion 1: shape + height — per index Core reports, clearbit must ─
#       report the SAME key, synced==true, best_block_height==NBLOCKS, and the
#       value object must have EXACTLY {synced, best_block_height}.
# Core's index names to require of clearbit (both enabled on both nodes).
for idx in "$IDX_TXINDEX" "$IDX_FILTER"; do
    # Core must report this index (sanity on the oracle).
    core_present=$(echo "$CORE_GII" | jget "1 if '${idx}' in d else 0")
    [[ "$core_present" == "1" ]] || fail "Core oracle did not report index '$idx' (oracle misconfigured?)"

    # clearbit must report the SAME key.
    cb_present=$(echo "$CB_GII" | jget "1 if '${idx}' in d else 0")
    [[ "$cb_present" == "1" ]] || fail "clearbit missing index key '$idx' (shape mismatch vs Core)"

    # EXACT value key set = {synced, best_block_height} — fail on any extra key.
    keys=$(echo "$CB_GII" | jget "sorted(d['${idx}'].keys())")
    [[ "$keys" == "['best_block_height', 'synced']" ]] \
        || fail "index '$idx' value keys = $keys (expected exactly {synced, best_block_height})"

    # synced must be the JSON literal true (bool), not a string/int.
    synced=$(echo "$CB_GII" | jget "d['${idx}']['synced'] is True")
    [[ "$synced" == "True" ]] || fail "index '$idx' synced is not boolean true (got $(echo "$CB_GII" | jget "repr(d['${idx}']['synced'])"))"

    # best_block_height must equal the tip height (== NBLOCKS on an empty chain),
    # and be an int (not a string).
    isint=$(echo "$CB_GII" | jget "isinstance(d['${idx}']['best_block_height'], int) and not isinstance(d['${idx}']['best_block_height'], bool)")
    [[ "$isint" == "True" ]] || fail "index '$idx' best_block_height is not an int"
    height=$(echo "$CB_GII" | jget "d['${idx}']['best_block_height']")
    [[ "$height" == "$NBLOCKS" ]] || fail "index '$idx' best_block_height=$height (expected $NBLOCKS == tip height)"
done

# clearbit must report exactly the two indices it runs and nothing else
# (no fabricated coinstatsindex / txospenderindex etc.).
cb_count=$(echo "$CB_GII" | jget "len(d)")
[[ "$cb_count" == "2" ]] || fail "clearbit getindexinfo reported $cb_count indices (expected exactly 2: txindex + basic block filter index)"

# ── 9. Assertion 2: filter — getindexinfo "txindex" returns ONLY txindex. ─
CB_FILT=$(cb_rpc getindexinfo "[\"$IDX_TXINDEX\"]")
filt_keys=$(echo "$CB_FILT" | jget "sorted(d.keys())")
[[ "$filt_keys" == "['txindex']" ]] \
    || fail "getindexinfo \"txindex\" returned keys $filt_keys (expected only the txindex key)"
# And its value is still the exact two-field shape.
filt_vkeys=$(echo "$CB_FILT" | jget "sorted(d['txindex'].keys())")
[[ "$filt_vkeys" == "['best_block_height', 'synced']" ]] \
    || fail "getindexinfo \"txindex\" value keys = $filt_vkeys (expected {synced, best_block_height})"

# Cross-check the filter arm against Core (Core also returns only txindex).
CORE_FILT=$(core_rpc getindexinfo "$IDX_TXINDEX")
core_filt_keys=$(echo "$CORE_FILT" | jget "sorted(d.keys())")
[[ "$core_filt_keys" == "['txindex']" ]] || log "NOTE: Core filter keys = $core_filt_keys (oracle)"

# ── 10. Assertion 3: empty — getindexinfo "no-such-index" returns {}. ─────
CB_EMPTY=$(cb_rpc getindexinfo '["no-such-index"]')
# Must be a result (NOT an error) and an empty object.
is_err=$(echo "$CB_EMPTY" | python3 -c '
import sys, json
o = json.loads(sys.stdin.read())
print(1 if isinstance(o, dict) and o.get("error") not in (None,) else 0)
' 2>/dev/null)
[[ "$is_err" == "0" ]] || fail "getindexinfo \"no-such-index\" returned an error (Core returns {} not an error)"
empty_len=$(echo "$CB_EMPTY" | jget "len(d)")
[[ "$empty_len" == "0" ]] || fail "getindexinfo \"no-such-index\" returned $empty_len keys (expected {} empty object)"
# And it is a dict/object, not e.g. an array.
empty_isobj=$(echo "$CB_EMPTY" | jget "isinstance(d, dict)")
[[ "$empty_isobj" == "True" ]] || fail "getindexinfo \"no-such-index\" result is not a JSON object"

log "all assertions passed"
pass

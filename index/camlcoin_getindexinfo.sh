#!/usr/bin/env bash
#
# camlcoin_getindexinfo.sh — self-contained getindexinfo index-status PARITY test.
#
# The first cell of the INDEXING axis (after the wallet + mempool-policy +
# getchaintxstats chapters). getindexinfo is READ-ONLY index status — NOT
# consensus — but the OUTPUT SHAPE must be byte-for-byte Core-correct.
#
# ── WHAT CORE DOES (the contract being verified) ───────────────────────────
#   getindexinfo ( "index_name" )   —   bitcoin-core/src/rpc/node.cpp:351-410
#   Returns a dynamic JSON OBJECT keyed BY INDEX NAME. For each *running*
#   index Core pushes ONE entry whose value has EXACTLY two fields, in THIS
#   order (SummaryToJSON, node.cpp:351-361):
#       { "<index name>": { "synced": <bool>, "best_block_height": <int> } }
#   NOTHING else — no best_hash, no best_block_hash, no name-inside-the-value.
#   Index names are the literal GetName() strings ("txindex",
#   "basic block filter index", ...). An index appears ONLY if it is running.
#   ARG index_name filters to one index: getindexinfo "txindex" returns only
#   {"txindex":{...}}; getindexinfo "no-such-index" returns {} (empty object,
#   NOT an error). best_block_height = the height the index reached;
#   synced = it has caught up to the chain tip.
#
# ── DIFFERENTIAL DESIGN (real bitcoind oracle, regtest, deterministic) ─────
#   A REAL bitcoind regtest oracle (the box's v31.99) is launched with
#   -txindex=1 on its OWN scratch + ports. camlcoin is launched on regtest on
#   its own scratch + ports; camlcoin's txindex is ALWAYS running (the
#   txid -> (block_hash, idx) mapping is written in lockstep at every
#   connect-block, with no enable/disable flag — see lib/sync.ml
#   tx_index_write_for_block), so it is the canonical always-synced index.
#
#   Both nodes mine the SAME NBLOCKS empty blocks to the SAME deterministic
#   regtest address (the box's bitcoind is built WITHOUT wallet support, so we
#   mine via generatetoaddress to a fixed p2wpkh bcrt1 address rather than
#   getnewaddress). Then both are polled until getindexinfo reports txindex
#   synced==true (generous timeout). Then we assert, against the LIVE Core
#   oracle for every index Core reports:
#     (1) shape  — camlcoin reports the SAME key with synced==true and
#                  best_block_height==NBLOCKS, and the value object has EXACTLY
#                  the keys {synced, best_block_height} (FAIL on any extra key
#                  such as best_hash / best_block_hash / name).
#     (2) filter — getindexinfo "txindex" on camlcoin returns ONLY the txindex
#                  key.
#     (3) empty  — getindexinfo "no-such-index" on camlcoin returns {} (an
#                  empty object, NOT an error).
#
#   NOTE on the basic block filter index: camlcoin HAS the BIP-157/158 filter
#   substrate (--blockfilterindex=basic) and getindexinfo correctly reports
#   its real status when enabled, but that index does NOT bootstrap on a
#   freshly-mined regtest chain (its backfill needs the genesis block BODY,
#   which camlcoin — like Core — never persists, so the filter index can't
#   seed height 0 and stays empty). That is a SEPARATE filter-index-bootstrap
#   defect, unrelated to getindexinfo's SHAPE correctness. So the differential
#   is run on txindex (the index camlcoin keeps in lockstep with the tip),
#   matching a Core oracle started with -txindex=1 only — both report exactly
#   {txindex}. getindexinfo itself remains a faithful Core-shaped status RPC.
#
# ── STRICT UNIFORM INTERFACE (mirrors test-suite/policy/camlcoin_policy.sh) ─
#   set -uo pipefail, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETINDEXINFO camlcoin: PASS shape=ok height=ok filter=ok empty=ok
#   FAIL: GETINDEXINFO camlcoin: FAIL <short reason>
#
# Touches ONLY /tmp/giifleet-camlcoin/ + /tmp/giifleet-core/ and the ports
#   below. NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/camlcoin/_build/default/bin/main.exe"
BITCOIND="$BASEDIR/bitcoin-core/build/bin/bitcoind"
BITCOINCLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address derivation)

# camlcoin scratch + ports (unique, per the cell spec).
CC_DATADIR="/tmp/giifleet-camlcoin"
CC_RPC=21935
CC_P2P=21955
CC_LOG="$CC_DATADIR/node.log"

# bitcoind oracle scratch + ports (own scratch + ports).
BC_DATADIR="/tmp/giifleet-core"
BC_RPC=21937
BC_P2P=21957

# Deterministic regtest p2wpkh address to mine to (bitcoind here is built
# WITHOUT wallet support, so we cannot getnewaddress). Derived from a fixed
# secret via the Core test_framework; recomputed at runtime so a different
# test_framework build can never desync the literal.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
MINE_ADDR=""

NBLOCKS=120            # mine the same N empty blocks on BOTH nodes

CC_PID=""
CC_COOKIE=""
BC_PID=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getindexinfo:camlcoin] $*" >&2; }

# ── Cleanup: stop both nodes + wipe scratch on any exit. ──────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BC_PID" ]]; then
        "$BITCOINCLI" -regtest -datadir="$BC_DATADIR" -rpcport="$BC_RPC" \
            -rpcconnect=127.0.0.1 stop >/dev/null 2>&1 || true
        for _ in $(seq 1 15); do kill -0 "$BC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BC_PID" 2>/dev/null || true
    fi
    if [[ -n "$CC_PID" ]] && kill -0 "$CC_PID" 2>/dev/null; then
        kill "$CC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CC_PID" 2>/dev/null || true
    fi
    rm -rf "$CC_DATADIR" "$BC_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "GETINDEXINFO camlcoin: PASS shape=$1 height=$2 filter=$3 empty=$4"; exit 0; }
fail() { echo "GETINDEXINFO camlcoin: FAIL $*"; exit 1; }

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state (camlcoin $CC_DATADIR :$CC_RPC/$CC_P2P, core $BC_DATADIR :$BC_RPC/$BC_P2P)"
pkill -f "giifleet-camlcoin" 2>/dev/null || true
pkill -f "giifleet-core"     2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${CC_RPC}|${CC_P2P}|${BC_RPC}|${BC_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${CC_RPC}|${CC_P2P}|${BC_RPC}|${BC_P2P}) "; then
    fail "port ${CC_RPC}/${CC_P2P}/${BC_RPC}/${BC_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$CC_DATADIR" "$BC_DATADIR"
mkdir -p "$CC_DATADIR" "$BC_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1    || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]               || fail "camlcoin binary not found at $NODE_BIN (run dune build)"
[[ -x "$BITCOIND" ]]               || fail "bitcoind oracle not found at $BITCOIND"
[[ -x "$BITCOINCLI" ]]             || fail "bitcoin-cli not found at $BITCOINCLI"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"

# Derive the deterministic mining address from the fixed secret.
MINE_ADDR=$(python3 - "$TF_PATH" "$SECRET" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
priv = ECKey(); priv.set(bytes.fromhex(sys.argv[2]), compressed=True)
print(key_to_p2wpkh(priv.get_pubkey().get_bytes(), main=False))
PYEOF
) || fail "could not derive deterministic mining address via test_framework"
[[ -n "$MINE_ADDR" ]] || fail "empty mining address derived"
log "deterministic mining address: $MINE_ADDR"

# ── 2. JSON helpers. ──────────────────────────────────────────────────────
# bitcoin-cli wrapper for the oracle.
bc() { "$BITCOINCLI" -regtest -datadir="$BC_DATADIR" -rpcport="$BC_RPC" -rpcconnect=127.0.0.1 "$@"; }

# camlcoin JSON-RPC over curl.
cc() {
    local method="$1"; local params="${2:-[]}"
    curl -s --max-time 60 -u "$CC_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$CC_RPC/" 2>/dev/null
}

# Extract the .result object from a camlcoin JSON-RPC envelope (raw JSON).
cc_result() { python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('result')))"; }

# ── 3. Launch the bitcoind oracle (regtest, txindex). ─────────────────────
log "launching bitcoind oracle (regtest -txindex=1)"
setsid "$BITCOIND" -regtest -datadir="$BC_DATADIR" -txindex=1 \
    -port="$BC_P2P" -rpcport="$BC_RPC" -rpcbind=127.0.0.1 -rpcallowip=127.0.0.1 \
    -listen=0 -fallbackfee=0.0001 >"$BC_DATADIR/stdout.log" 2>&1 < /dev/null &
BC_PID=$!
log "bitcoind pid=$BC_PID"
bc_ready=0
for _ in $(seq 1 60); do
    if bc getblockcount >/dev/null 2>&1; then bc_ready=1; break; fi
    kill -0 "$BC_PID" 2>/dev/null || { tail -n 20 "$BC_DATADIR/stdout.log" >&2 2>/dev/null || true; fail "bitcoind exited during startup"; }
    sleep 1
done
[[ "$bc_ready" -eq 1 ]] || fail "bitcoind RPC never responded within 60s"
log "bitcoind RPC ready"

# ── 4. Launch camlcoin (regtest; txindex is always on). ───────────────────
log "launching camlcoin (regtest) rpc=:$CC_RPC p2p=:$CC_P2P -> $CC_LOG"
"$NODE_BIN" --network regtest --datadir "$CC_DATADIR" \
    --port "$CC_P2P" --rpcport "$CC_RPC" >"$CC_LOG" 2>&1 &
CC_PID=$!
log "camlcoin pid=$CC_PID"
cc_ready=0
cc_deadline=$(( $(date +%s) + 120 ))   # generous startup wait
while (( $(date +%s) < cc_deadline )); do
    if [[ -z "$CC_COOKIE" && -f "$CC_DATADIR/.cookie" ]]; then
        CC_COOKIE=$(cat "$CC_DATADIR/.cookie")
    fi
    if [[ -n "$CC_COOKIE" ]]; then
        if cc getblockcount | grep -q '"result"'; then cc_ready=1; break; fi
    fi
    kill -0 "$CC_PID" 2>/dev/null || { tail -n 20 "$CC_LOG" >&2 2>/dev/null || true; fail "camlcoin exited during startup (see $CC_LOG)"; }
    sleep 1
done
[[ "$cc_ready" -eq 1 ]] || fail "camlcoin RPC never responded within 120s"
log "camlcoin RPC ready"

# ── 5. Mine the same N empty blocks on BOTH nodes. ────────────────────────
log "mining $NBLOCKS blocks on bitcoind oracle -> $MINE_ADDR"
bc generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null 2>&1 \
    || fail "bitcoind generatetoaddress failed"
bc_h=$(bc getblockcount 2>/dev/null)
[[ "$bc_h" == "$NBLOCKS" ]] || fail "bitcoind height $bc_h != $NBLOCKS after mining"

log "mining $NBLOCKS blocks on camlcoin -> $MINE_ADDR"
gen=$(cc generatetoaddress "[$NBLOCKS, \"$MINE_ADDR\"]")
echo "$gen" | grep -q '"result"' || { log "camlcoin generatetoaddress: $gen"; fail "camlcoin generatetoaddress failed"; }
cc_h=$(cc getblockcount | python3 -c "import sys,json;print(json.load(sys.stdin).get('result'))" 2>/dev/null)
[[ "$cc_h" == "$NBLOCKS" ]] || fail "camlcoin height $cc_h != $NBLOCKS after mining"

# ── 6. Poll getindexinfo until txindex synced on BOTH (generous timeout). ──
log "waiting for txindex sync on both nodes"
synced_deadline=$(( $(date +%s) + 120 ))
bc_synced=0; cc_synced=0
while (( $(date +%s) < synced_deadline )); do
    if [[ "$bc_synced" -ne 1 ]]; then
        s=$(bc getindexinfo 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('txindex',{}).get('synced'))" 2>/dev/null)
        [[ "$s" == "True" ]] && bc_synced=1
    fi
    if [[ "$cc_synced" -ne 1 ]]; then
        s=$(cc getindexinfo | cc_result 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin) or {};print(d.get('txindex',{}).get('synced'))" 2>/dev/null)
        [[ "$s" == "True" ]] && cc_synced=1
    fi
    [[ "$bc_synced" -eq 1 && "$cc_synced" -eq 1 ]] && break
    sleep 1
done
[[ "$bc_synced" -eq 1 ]] || fail "bitcoind txindex never reported synced within 120s"
[[ "$cc_synced" -eq 1 ]] || fail "camlcoin txindex never reported synced within 120s"
log "both nodes report txindex synced"

# ── 7. Pull getindexinfo from both + run the assertions in Python. ────────
CORE_GII=$(bc getindexinfo 2>/dev/null)
[[ -n "$CORE_GII" ]] || fail "bitcoind getindexinfo returned nothing"
CC_GII_ALL=$(cc getindexinfo | cc_result)
CC_GII_TXI=$(cc "getindexinfo" "[\"txindex\"]" | cc_result)
CC_GII_NONE=$(cc "getindexinfo" "[\"no-such-index\"]" | cc_result)

log "core  getindexinfo: $(echo "$CORE_GII" | tr -d '\n ' )"
log "caml  getindexinfo: $CC_GII_ALL"
log "caml  getindexinfo txindex: $CC_GII_TXI"
log "caml  getindexinfo no-such-index: $CC_GII_NONE"

RESULT=$(NBLOCKS="$NBLOCKS" python3 - "$CORE_GII" "$CC_GII_ALL" "$CC_GII_TXI" "$CC_GII_NONE" <<'PYEOF'
import sys, json, os

nblocks = int(os.environ["NBLOCKS"])
core = json.loads(sys.argv[1])
cc_all = json.loads(sys.argv[2])
cc_txi = json.loads(sys.argv[3])
cc_none = json.loads(sys.argv[4])

def die(reason):
    print("FAIL\t" + reason)
    sys.exit(0)

# Both must be JSON objects.
if not isinstance(core, dict):   die("core getindexinfo is not a JSON object")
if not isinstance(cc_all, dict): die("camlcoin getindexinfo is not a JSON object")

# (1) SHAPE + HEIGHT: for every index Core reports, camlcoin reports the same
#     key with synced==true, best_block_height==nblocks, and EXACTLY the keys
#     {synced, best_block_height}.
shape = "ok"; height = "ok"
for name, cval in core.items():
    if name not in cc_all:
        die(f"camlcoin missing index key Core reports: '{name}'")
    v = cc_all[name]
    if not isinstance(v, dict):
        die(f"camlcoin '{name}' value is not an object")
    keys = set(v.keys())
    if keys != {"synced", "best_block_height"}:
        extra = keys - {"synced", "best_block_height"}
        missing = {"synced", "best_block_height"} - keys
        die(f"camlcoin '{name}' has wrong key set {sorted(keys)} "
            f"(extra={sorted(extra)} missing={sorted(missing)}) "
            f"— must be exactly [best_block_height, synced]")
    if v["synced"] is not True:
        die(f"camlcoin '{name}'.synced != true (got {v['synced']!r})")
    if not isinstance(v["best_block_height"], int) or isinstance(v["best_block_height"], bool):
        die(f"camlcoin '{name}'.best_block_height is not an int (got {v['best_block_height']!r})")
    if v["best_block_height"] != nblocks:
        height = "bad"
        die(f"camlcoin '{name}'.best_block_height={v['best_block_height']} != tip height {nblocks}")
    # Core's own value must agree (sanity on the oracle).
    if core[name].get("synced") is not True or core[name].get("best_block_height") != nblocks:
        die(f"oracle '{name}' not synced at {nblocks} (got {core[name]!r}) — harness/oracle issue")

# txindex must be one of the indexes asserted (it is the always-on index here).
if "txindex" not in core:
    die("oracle did not report txindex (expected with -txindex=1)")
if "txindex" not in cc_all:
    die("camlcoin did not report txindex (expected: always-on)")

# (2) FILTER: getindexinfo "txindex" returns ONLY the txindex key.
flt = "ok"
if not isinstance(cc_txi, dict):
    die("camlcoin getindexinfo \"txindex\" is not a JSON object")
if set(cc_txi.keys()) != {"txindex"}:
    die(f"camlcoin getindexinfo \"txindex\" returned keys {sorted(cc_txi.keys())} "
        f"— must be exactly [txindex]")
# the filtered txindex value must also be the exact two-key shape
if set(cc_txi["txindex"].keys()) != {"synced", "best_block_height"}:
    die(f"camlcoin filtered txindex value has wrong key set {sorted(cc_txi['txindex'].keys())}")

# (3) EMPTY: getindexinfo "no-such-index" returns {} (empty object, not error).
emp = "ok"
if not isinstance(cc_none, dict):
    die("camlcoin getindexinfo \"no-such-index\" is not a JSON object")
if cc_none != {}:
    die(f"camlcoin getindexinfo \"no-such-index\" returned {cc_none!r} — must be {{}}")

print(f"PASS\t{shape}\t{height}\t{flt}\t{emp}")
PYEOF
)

verdict=$(printf '%s' "$RESULT" | cut -f1)
if [[ "$verdict" == "PASS" ]]; then
    shape=$(printf '%s' "$RESULT" | cut -f2)
    height=$(printf '%s' "$RESULT" | cut -f3)
    flt=$(printf '%s' "$RESULT" | cut -f4)
    emp=$(printf '%s' "$RESULT" | cut -f5)
    log "PASS: camlcoin getindexinfo matches Core shape on every index Core reports; filter + empty-object cases correct"
    pass "$shape" "$height" "$flt" "$emp"
else
    reason=$(printf '%s' "$RESULT" | cut -f2-)
    fail "$reason"
fi

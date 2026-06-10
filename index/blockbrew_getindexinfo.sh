#!/usr/bin/env bash
#
# blockbrew_getindexinfo.sh — self-contained getindexinfo Core-parity test.
#
# The indexing-axis keystone, after the wallet + mempool-policy + getchaintxstats
# chapters. getindexinfo is READ-ONLY index status — NOT consensus — but the
# OUTPUT SHAPE must be byte-faithful to Bitcoin Core.
#
# WHAT CORE EMITS (rpc/node.cpp:363-410, SummaryToJSON:351-361, base.{h,cpp}):
#   getindexinfo returns a dynamic JSON OBJECT keyed BY INDEX NAME. For each
#   *running* index Core pushes one entry whose value has EXACTLY two fields,
#   in THIS ORDER: { "<name>": { "synced": <bool>, "best_block_height": <int> } }.
#   NOTHING else — no best_hash, no best_block_hash, no name-inside-the-value.
#   INDEX NAMES are the literal GetName() strings: "txindex",
#   "basic block filter index" (= BlockFilterTypeName(BASIC)+" block filter index"),
#   "coinstatsindex", "txospenderindex". An index appears ONLY if it is running.
#   The optional positional arg filters to one index by name; a non-matching
#   name yields {} (an EMPTY OBJECT, not an error); empty/omitted = all running.
#   best_block_height = the height the index reached (0 if no best block yet);
#   synced = whether the index caught up to the chain tip.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN regtest
#   instance (own scratch datadir + ports), launched with -txindex=1 and
#   -blockfilterindex=basic so it runs the same two indexes blockbrew runs.
#   blockbrew is launched on regtest with -txindex -blockfilterindex=true.
#   Both mine 120 empty blocks; both are polled until every index reports
#   synced==true; then blockbrew's getindexinfo is asserted against Core's.
#
# blockbrew runs at most two of Core's index family (the others are not wired):
#   - "txindex"                   (driven off the chain connect/disconnect hooks)
#   - "basic block filter index"  (the registered BIP-157/158 basic filter index)
#
# ASSERTIONS:
#   1. shape  — for EACH index Core reports, blockbrew reports the SAME key with
#               synced==true, best_block_height==120 (the tip height), and the
#               value object has EXACTLY {synced, best_block_height}. FAIL if
#               best_hash / best_block_hash / name / any extra key is present.
#   2. filter — getindexinfo "txindex" on blockbrew returns ONLY the txindex key.
#   3. empty  — getindexinfo "no-such-index" on blockbrew returns {} (not error).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/blockbrew_policy.sh): no
#   required args, idempotent, trap cleanup, scratch datadirs + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETINDEXINFO blockbrew: PASS shape=ok height=ok filter=ok empty=ok
#   FAIL: GETINDEXINFO blockbrew: FAIL <short reason>
#
# Touches ONLY /tmp/giifleet-blockbrew/ + /tmp/giiref-core-bb/ and ports
#   21933/21953 (blockbrew RPC/P2P), 21934/21954 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/blockbrew/blockbrew"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

BB_DATADIR="/tmp/giifleet-blockbrew"
BB_RPC=21933
BB_P2P=21953
BB_LOG="$BB_DATADIR/node.log"
BB_URL="http://127.0.0.1:${BB_RPC}"
BB_COOKIE_FILE="$BB_DATADIR/regtest/.cookie"

CORE_DATADIR="/tmp/giiref-core-bb"
CORE_RPC=21934
CORE_P2P=21954
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=120            # mine 120 empty blocks; tip height == 120

BB_PID=""
BB_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getindexinfo:blockbrew] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BB_PID" ]] && kill -0 "$BB_PID" 2>/dev/null; then
        kill "$BB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$BB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {  # pass <shape> <height> <filter> <empty>
    echo "GETINDEXINFO blockbrew: PASS shape=$1 height=$2 filter=$3 empty=$4"
    exit 0
}
fail() {
    echo "GETINDEXINFO blockbrew: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
if ss -tln 2>/dev/null | grep -qE ":(${BB_RPC}|${BB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${BB_RPC}/${BB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$BB_DATADIR" "$CORE_DATADIR"
mkdir -p "$BB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "blockbrew binary not found at $NODE_BIN (run build-all.sh blockbrew)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"

# ── 2. Deterministic regtest bech32 (P2WPKH) mining address. ──────────────
# This box's bitcoind has no wallet support, so generatetoaddress needs an
# externally-supplied bech32 address. Derive a fixed bcrt1q… address from a
# constant 20-byte witness program (no wallet, no key material needed — the
# blocks are empty and the coinbase outputs are never spent).
MINE_ADDR=$(python3 - <<'PY'
def bech32_polymod(values):
    GEN=[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]
    chk=1
    for v in values:
        b=chk>>25; chk=(chk&0x1ffffff)<<5^v
        for i in range(5):
            chk^=GEN[i] if (b>>i)&1 else 0
    return chk
def hrp_expand(hrp): return [ord(x)>>5 for x in hrp]+[0]+[ord(x)&31 for x in hrp]
def create_checksum(hrp,data):
    values=hrp_expand(hrp)+data
    polymod=bech32_polymod(values+[0,0,0,0,0,0])^1   # bech32 const for v0
    return [(polymod>>5*(5-i))&31 for i in range(6)]
CHARSET="qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def convertbits(data,frombits,tobits,pad=True):
    acc=0;bits=0;ret=[];maxv=(1<<tobits)-1
    for value in data:
        acc=(acc<<frombits)|value;bits+=frombits
        while bits>=tobits:
            bits-=tobits;ret.append((acc>>bits)&maxv)
    if pad and bits: ret.append((acc<<(tobits-bits))&maxv)
    return ret
prog=bytes([0x11]*20)              # 20-byte witness-v0 program (P2WPKH)
data=[0]+convertbits(prog,8,5)
hrp="bcrt"
print(hrp+"1"+"".join(CHARSET[d] for d in data+create_checksum(hrp,data)))
PY
)
[[ -n "$MINE_ADDR" ]] || fail "could not derive a regtest mining address"
log "regtest mining address = $MINE_ADDR"

# ── 3. JSON helpers (curl over cookie auth, python field extraction). ──────
# bb_rpc <method> <params-json>  -> raw JSON-RPC response on stdout
bb_rpc() {
    curl -s --max-time 30 -u "$BB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "$BB_URL/" 2>/dev/null
}
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# jfield <json> <python-expr-on-`r`>  (r = parsed result of {"result":...})
jres() {  # extract .result as JSON text from a JSON-RPC response on stdin
    python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(3) if d.get('error') else print(json.dumps(d['result']))"
}

# ── 4. Launch the Core oracle (-txindex=1 -blockfilterindex=basic). ───────
log "launching Core oracle rpc=:$CORE_RPC -txindex=1 -blockfilterindex=basic"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -fallbackfee=0.0002 -txindex=1 -blockfilterindex=basic >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < core_deadline )); do
    core_cli getblockcount >/dev/null 2>&1 && break
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
core_cli getblockcount >/dev/null 2>&1 || fail "Core oracle RPC never responded within 60s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 5. Launch blockbrew on regtest (-txindex -blockfilterindex=true). ─────
# -maxoutbound=0 -nolisten keeps it isolated; the only blocks it sees are the
# ones this harness mines.
log "launching blockbrew (regtest) rpc=:$BB_RPC p2p=:$BB_P2P -> $BB_LOG"
"$NODE_BIN" \
    -network=regtest -datadir="$BB_DATADIR" \
    -listen="127.0.0.1:${BB_P2P}" -rpcbind="127.0.0.1:${BB_RPC}" \
    -txindex -blockfilterindex=true \
    -maxoutbound=0 -nolisten \
    >"$BB_LOG" 2>&1 &
BB_PID=$!
log "blockbrew pid=$BB_PID"
bb_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < bb_deadline )); do
    if [[ -z "$BB_COOKIE" && -f "$BB_COOKIE_FILE" ]]; then
        BB_COOKIE=$(cat "$BB_COOKIE_FILE")
    fi
    if [[ -n "$BB_COOKIE" ]]; then
        bb_rpc getblockcount "[]" | grep -q '"result"' && break
    fi
    kill -0 "$BB_PID" 2>/dev/null || { tail -n 20 "$BB_LOG" >&2 2>/dev/null || true; fail "blockbrew exited during startup (see $BB_LOG)"; }
    sleep 1
done
[[ -n "$BB_COOKIE" ]] || fail "blockbrew cookie never appeared within 60s"
bb_rpc getblockcount "[]" | grep -q '"result"' || fail "blockbrew RPC never responded within 60s"
log "blockbrew RPC ready"

# ── 6. Mine NBLOCKS empty blocks on both. ─────────────────────────────────
log "mining $NBLOCKS empty blocks on Core oracle"
core_cli generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null 2>&1 \
    || fail "Core generatetoaddress failed (see $CORE_LOG)"
CORE_HEIGHT=$(core_cli getblockcount 2>/dev/null)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height=$CORE_HEIGHT, expected $NBLOCKS"

log "mining $NBLOCKS empty blocks on blockbrew"
bb_rpc createwallet '["giiw"]' >/dev/null 2>&1 || true
# Prefer blockbrew's own wallet address (its wallet works); fall back to the
# deterministic derived address if getnewaddress is unavailable.
BB_ADDR=$(bb_rpc getnewaddress "[]" | python3 -c "import sys,json;d=json.load(sys.stdin);print('' if d.get('error') else d['result'])" 2>/dev/null)
[[ -z "$BB_ADDR" || "$BB_ADDR" == "None" ]] && BB_ADDR="$MINE_ADDR"
log "blockbrew mining address = $BB_ADDR"
bb_rpc generatetoaddress "[$NBLOCKS,\"$BB_ADDR\"]" >/dev/null 2>&1
BB_HEIGHT=$(bb_rpc getblockcount "[]" | jres) || fail "blockbrew getblockcount returned an error"
[[ "$BB_HEIGHT" == "$NBLOCKS" ]] || fail "blockbrew height=$BB_HEIGHT, expected $NBLOCKS (see $BB_LOG)"
log "both nodes at height $NBLOCKS"

# ── 7. Poll getindexinfo on both until every index reports synced==true. ──
# Generous timeout (filter-index catch-up after the last block can lag).
wait_synced() {  # wait_synced <label> <fetch-fn-name>
    local label="$1" fn="$2" deadline=$(( $(date +%s) + 120 )) j ok
    while (( $(date +%s) < deadline )); do
        j=$("$fn") || { sleep 1; continue; }
        ok=$(printf '%s' "$j" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print('0'); sys.exit()
if not isinstance(d,dict) or not d:
    print('0'); sys.exit()
print('1' if all(isinstance(v,dict) and v.get('synced') is True for v in d.values()) else '0')
" 2>/dev/null)
        [[ "$ok" == "1" ]] && return 0
        sleep 1
    done
    log "$label: indexes did not all report synced==true within 120s; last=$("$fn" 2>/dev/null)"
    return 1
}
fetch_core() { core_cli getindexinfo 2>/dev/null; }
fetch_bb()   { bb_rpc getindexinfo "[]" | jres 2>/dev/null; }

log "waiting for Core indexes to sync"
wait_synced "Core" fetch_core   || fail "Core indexes never reported synced (see $CORE_LOG)"
log "waiting for blockbrew indexes to sync"
wait_synced "blockbrew" fetch_bb || fail "blockbrew indexes never reported synced (see $BB_LOG)"

# ── 8. Assertion 1: SHAPE + HEIGHT, per index Core reports. ───────────────
CORE_JSON=$(fetch_core);            [[ -n "$CORE_JSON" ]] || fail "empty Core getindexinfo response"
BB_JSON=$(fetch_bb);                [[ -n "$BB_JSON"   ]] || fail "empty blockbrew getindexinfo response"
log "Core getindexinfo:      $CORE_JSON"
log "blockbrew getindexinfo: $BB_JSON"

# A single python comparator does the strict shape + height check and prints
# either "OK" or "FAIL <reason>". For EACH index name Core reports:
#   * blockbrew must report the same key,
#   * value object key SET must be EXACTLY {synced, best_block_height},
#   * synced must be true (bool),
#   * best_block_height must == NBLOCKS (int).
SHAPE_RESULT=$(python3 - "$CORE_JSON" "$BB_JSON" "$NBLOCKS" <<'PY'
import sys,json
core=json.loads(sys.argv[1]); bb=json.loads(sys.argv[2]); N=int(sys.argv[3])
EXPECT={"synced","best_block_height"}
if not isinstance(core,dict) or not core:
    print("FAIL Core reported no running indexes"); sys.exit()
if not isinstance(bb,dict):
    print("FAIL blockbrew getindexinfo is not a JSON object"); sys.exit()
for name,cv in core.items():
    if name not in bb:
        print(f"FAIL blockbrew missing index key '{name}' that Core reports"); sys.exit()
    v=bb[name]
    if not isinstance(v,dict):
        print(f"FAIL blockbrew['{name}'] value is not an object"); sys.exit()
    keys=set(v.keys())
    if keys!=EXPECT:
        extra=keys-EXPECT; missing=EXPECT-keys
        msg=[]
        if extra:   msg.append("extra="+",".join(sorted(extra)))
        if missing: msg.append("missing="+",".join(sorted(missing)))
        print(f"FAIL blockbrew['{name}'] value keys {sorted(keys)} != {{synced,best_block_height}} ({'; '.join(msg)})"); sys.exit()
    if v["synced"] is not True:
        print(f"FAIL blockbrew['{name}'].synced is {v['synced']!r}, expected true"); sys.exit()
    if not isinstance(v["best_block_height"],int) or isinstance(v["best_block_height"],bool):
        print(f"FAIL blockbrew['{name}'].best_block_height is not an integer: {v['best_block_height']!r}"); sys.exit()
    if v["best_block_height"]!=N:
        print(f"FAIL blockbrew['{name}'].best_block_height={v['best_block_height']}, expected {N}"); sys.exit()
print("OK")
PY
)
case "$SHAPE_RESULT" in
    OK) log "shape+height: OK (keys exactly {synced,best_block_height}, synced=true, height=$NBLOCKS for every Core-reported index)" ;;
    *)  fail "${SHAPE_RESULT#FAIL }" ;;
esac

# ── 9. Assertion 2: FILTER — getindexinfo "txindex" returns only txindex. ─
FILTER_JSON=$(bb_rpc getindexinfo '["txindex"]' | jres) || fail "blockbrew getindexinfo \"txindex\" returned an error"
log "blockbrew getindexinfo \"txindex\": $FILTER_JSON"
FILTER_RESULT=$(python3 - "$FILTER_JSON" <<'PY'
import sys,json
d=json.loads(sys.argv[1])
if not isinstance(d,dict):
    print("FAIL filtered result is not an object"); sys.exit()
if set(d.keys())!={"txindex"}:
    print(f"FAIL getindexinfo \"txindex\" returned keys {sorted(d.keys())}, expected only ['txindex']"); sys.exit()
print("OK")
PY
)
case "$FILTER_RESULT" in
    OK) log "filter: OK (getindexinfo \"txindex\" returns only the txindex key)" ;;
    *)  fail "${FILTER_RESULT#FAIL }" ;;
esac

# ── 10. Assertion 3: EMPTY — getindexinfo "no-such-index" returns {}. ─────
EMPTY_RESP=$(bb_rpc getindexinfo '["no-such-index"]')
# Must NOT be an RPC error, and the result must be an empty object.
echo "$EMPTY_RESP" | grep -q '"error":null' || fail "getindexinfo \"no-such-index\" returned an RPC error (expected empty object): $EMPTY_RESP"
EMPTY_JSON=$(printf '%s' "$EMPTY_RESP" | jres) || fail "getindexinfo \"no-such-index\" returned an error result"
log "blockbrew getindexinfo \"no-such-index\": $EMPTY_JSON"
EMPTY_RESULT=$(python3 - "$EMPTY_JSON" <<'PY'
import sys,json
d=json.loads(sys.argv[1])
if not isinstance(d,dict):
    print("FAIL no-such-index result is not an object"); sys.exit()
if d:
    print(f"FAIL getindexinfo \"no-such-index\" returned {d}, expected {{}}"); sys.exit()
print("OK")
PY
)
case "$EMPTY_RESULT" in
    OK) log "empty: OK (getindexinfo \"no-such-index\" returns {})" ;;
    *)  fail "${EMPTY_RESULT#FAIL }" ;;
esac

# ── 11. Verdict. ──────────────────────────────────────────────────────────
log "PASS: getindexinfo Core-shaped — shape+height match Core, txindex filter exact, unknown-name -> {}"
pass ok ok ok ok

#!/usr/bin/env bash
#
# hotbuns_getindexinfo.sh — self-contained getindexinfo Core-shape parity test.
#
# The first cell of the INDEXING axis, after the wallet + mempool-policy +
# getchaintxstats chapters. Read-only index status — NOT consensus, but the
# OUTPUT SHAPE must be EXACT.
#
# WHAT IT PROVES (Bitcoin Core src/rpc/node.cpp:363-410 + SummaryToJSON:351-361):
#   getindexinfo returns a dynamic JSON OBJECT keyed BY INDEX NAME. For each
#   *running* index Core pushes ONE entry whose value has EXACTLY two fields, in
#   THIS ORDER: "synced" (bool) then "best_block_height" (int) — and NOTHING
#   else (no best_hash, no best_block_hash, no name-inside-the-value). An index
#   appears ONLY if enabled/running. The optional positional "index_name" arg
#   filters to a single index; a non-matching name yields {} (empty object, NOT
#   an error).
#
# DIFFERENTIAL ORACLE: a REAL bitcoind regtest started with
#   -txindex=1 -blockfilterindex=basic.
#   hotbuns runs txindex UNCONDITIONALLY (it writes a (txid -> block) entry for
#   every tx of every connected block, ungated — sync/blocks.ts +
#   chain/state.ts), so the "txindex" key is ALWAYS present. hotbuns also ships
#   a BIP-157/158 "basic block filter index" enabled via --blockfilterindex=1
#   (cli.ts constructs the BlockFilterIndex, wires it into BlockSync AND
#   ChainStateManager; the connect-side indexBlock advances its height on the
#   regtest/generatetoaddress mining path too). We launch hotbuns with
#   --blockfilterindex=1 and Core with the matching pair, mine the SAME number
#   of empty blocks on BOTH, wait for index sync on BOTH, then compare the
#   getindexinfo OUTPUT SHAPE index-by-index.
#
# ASSERTIONS:
#   1. shape  — for EACH index Core reports, hotbuns reports the SAME key with
#               synced==true, best_block_height==NBLOCKS (tip height), and the
#               value object has EXACTLY the keys {synced, best_block_height}
#               (FAIL on best_hash / best_block_hash / name / any extra key).
#   2. filter — getindexinfo "txindex" on hotbuns returns ONLY the txindex key.
#   3. empty  — getindexinfo "no-such-index" on hotbuns returns {} (empty
#               object, not an error).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/hotbuns_policy.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + UNIQUE
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1. Run under: setsid -w bash hotbuns_getindexinfo.sh
#
# Summary line (stdout):
#   PASS: GETINDEXINFO hotbuns: PASS shape=ok height=ok filter=ok empty=ok
#   FAIL: GETINDEXINFO hotbuns: FAIL <short reason>
#
# Touches ONLY /tmp/giifleet-hotbuns/ + /tmp/giifleet-core-hb/ and ports
#   40034/40054 (hotbuns RPC/P2P), 40035/40055 (Core RPC/P2P), 40074 (hotbuns
#   metrics — pinned off the default 9332 so a co-running fleet node can't
#   clash). NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_DIR="$BASEDIR/hotbuns"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

HB_DATADIR="/tmp/giifleet-hotbuns"
HB_RPC=40034
HB_P2P=40054
HB_METRICS=40074
HB_LOG="$HB_DATADIR/node.log"

CORE_DATADIR="/tmp/giifleet-core-hb"
CORE_RPC=40035
CORE_P2P=40055
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=120            # mine this many empty blocks on both nodes
SECRET="6868686868686868686868686868686868686868686868686868686868686869"

HB_PID=""
HB_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gii:hotbuns] $*" >&2; }

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETINDEXINFO hotbuns: PASS shape=ok height=ok filter=ok empty=ok"
    exit 0
}
fail() {
    echo "GETINDEXINFO hotbuns: FAIL $*"
    exit 1
}

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$HB_PID" ]] && kill -0 "$HB_PID" 2>/dev/null; then
        kill "$HB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${HB_RPC}/tcp"         2>/dev/null || true
    fuser -k "${HB_P2P}/tcp"         2>/dev/null || true
    fuser -k "${HB_METRICS}/tcp"     2>/dev/null || true
    fuser -k "${CORE_RPC}/tcp"       2>/dev/null || true
    fuser -k "${CORE_P2P}/tcp"       2>/dev/null || true
    fuser -k "$((CORE_P2P + 1))/tcp" 2>/dev/null || true   # Core onion listener (P2P+1)
    rm -rf "$HB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "giifleet-hotbuns" 2>/dev/null || true
fuser -k "${HB_RPC}/tcp"         2>/dev/null || true
fuser -k "${HB_P2P}/tcp"         2>/dev/null || true
fuser -k "${HB_METRICS}/tcp"     2>/dev/null || true
fuser -k "${CORE_RPC}/tcp"       2>/dev/null || true
fuser -k "${CORE_P2P}/tcp"       2>/dev/null || true
fuser -k "$((CORE_P2P + 1))/tcp" 2>/dev/null || true
sleep 2
rm -rf "$HB_DATADIR" "$CORE_DATADIR"
mkdir -p "$HB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v bun     >/dev/null 2>&1   || fail "bun runtime not found on PATH"
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -f "$NODE_DIR/src/index.ts" ]]    || fail "hotbuns entrypoint not found at $NODE_DIR/src/index.ts"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive a deterministic regtest p2wpkh mining address. ──────────────
# Both nodes mine empty blocks to this address; the coinbase destination is
# irrelevant to getindexinfo (we only check index status), but a valid bcrt1
# address is required by generatetoaddress.
MINE_ADDR=$(python3 - "$TF_PATH" "$SECRET" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
priv = ECKey(); priv.set(bytes.fromhex(sys.argv[2]), compressed=True)
print(key_to_p2wpkh(priv.get_pubkey().get_bytes(), main=False))
PYEOF
) || fail "failed to derive regtest mining address (Core test_framework import?)"
[[ -n "$MINE_ADDR" ]] || fail "empty mining address"
log "mining address: $MINE_ADDR"

# ── hotbuns RPC helper (cookie auth, JSON-RPC over HTTP). ─────────────────
# hb_rpc <method> [json-params-array]  -> echoes the raw JSON-RPC response body
hb_rpc() {
    local method="$1"; local params="${2:-[]}"
    curl -s --max-time 90 -u "$HB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$HB_RPC/" 2>/dev/null
}
# Extract the JSON-encoded .result of an hb_rpc response, or "" on error/missing.
hb_result() {
    echo "$1" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get('error') is not None:
    sys.exit(0)
print(json.dumps(d.get('result')))" 2>/dev/null
}

# ── 3. Launch the Core regtest oracle with txindex + basic filter index. ──
log "launching Core oracle rpc=:$CORE_RPC -txindex=1 -blockfilterindex=basic"
# Fully detach (setsid + nohup + </dev/null) so the daemon survives the harness
# session/process-group teardown that otherwise SIGTERMs plain '&' background jobs.
setsid nohup "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -txindex=1 -blockfilterindex=basic -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 </dev/null &
CORE_BG=$!
disown "$CORE_BG" 2>/dev/null || true
core_deadline=$(( $(date +%s) + 90 ))
core_ready=0
while (( $(date +%s) < core_deadline )); do
    if "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1; then
        core_ready=1; break
    fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
[[ "$core_ready" -eq 1 ]] || fail "Core oracle failed to start within 90s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch hotbuns on regtest with the basic block filter index on. ────
# txindex is always on in hotbuns (no flag); --blockfilterindex=1 turns on the
# BIP-157/158 basic block filter index so getindexinfo reports both keys.
log "launching hotbuns (regtest) rpc=:$HB_RPC p2p=:$HB_P2P --blockfilterindex=1 -> $HB_LOG"
(
    cd "$NODE_DIR" || exit 1
    exec bun run src/index.ts \
        --network=regtest --datadir="$HB_DATADIR" \
        --port="$HB_P2P" --rpcport="$HB_RPC" --metrics-port="$HB_METRICS" \
        --blockfilterindex=1
) >"$HB_LOG" 2>&1 &
HB_PID=$!
log "hotbuns pid=$HB_PID"
hb_deadline=$(( $(date +%s) + 120 ))   # generous: ouroboros-style cold-start margin
while (( $(date +%s) < hb_deadline )); do
    if [[ -z "$HB_COOKIE" ]]; then
        for c in "$HB_DATADIR/.cookie" "$HB_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && HB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HB_COOKIE" ]]; then
        r=$(hb_rpc getblockcount)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$HB_PID" 2>/dev/null || { tail -n 20 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns exited during startup (see $HB_LOG)"; }
    sleep 1
done
[[ -n "$HB_COOKIE" ]] || fail "hotbuns cookie never appeared within 120s"
r=$(hb_rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "hotbuns RPC never responded within 120s"
log "hotbuns RPC ready"

# ── 5. Mine NBLOCKS empty blocks on BOTH nodes. ───────────────────────────
log "mining $NBLOCKS empty blocks on Core"
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null 2>>"$CORE_LOG" \
    || fail "Core generatetoaddress failed (see $CORE_LOG)"
CORE_HEIGHT=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount 2>/dev/null)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

log "mining $NBLOCKS empty blocks on hotbuns"
r=$(hb_rpc generatetoaddress "[$NBLOCKS, \"$MINE_ADDR\"]")
echo "$r" | grep -q '"result"' || { log "hotbuns generatetoaddress reply: $r"; fail "hotbuns generatetoaddress failed (see $HB_LOG)"; }
r=$(hb_rpc getblockcount)
HB_HEIGHT=$(echo "$r" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result'))" 2>/dev/null)
[[ "$HB_HEIGHT" == "$NBLOCKS" ]] || fail "hotbuns height $HB_HEIGHT != $NBLOCKS after mining"

# ── 6. Poll getindexinfo on BOTH until every reported index synced==true. ─
# Generous timeout: an index thread may lag block connection on a real node.
poll_synced() {  # poll_synced <getindexinfo-json>  -> 0 if all synced
    python3 - <<PYEOF
import sys, json
try:
    data = json.loads('''$1''')
except Exception:
    sys.exit(1)
if not data:
    sys.exit(1)
for name, v in data.items():
    if not isinstance(v, dict) or v.get("synced") is not True:
        sys.exit(1)
sys.exit(0)
PYEOF
}

log "waiting for Core index sync"
sync_deadline=$(( $(date +%s) + 120 ))
CORE_GII=""
while (( $(date +%s) < sync_deadline )); do
    CORE_GII=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getindexinfo 2>/dev/null)
    if [[ -n "$CORE_GII" ]] && poll_synced "$CORE_GII"; then break; fi
    sleep 2
done
[[ -n "$CORE_GII" ]] || fail "Core getindexinfo never returned"
poll_synced "$CORE_GII" || fail "Core indexes did not all reach synced=true within 120s ($CORE_GII)"
log "Core getindexinfo: $CORE_GII"

log "waiting for hotbuns index sync"
sync_deadline=$(( $(date +%s) + 120 ))
HB_GII=""
while (( $(date +%s) < sync_deadline )); do
    r=$(hb_rpc getindexinfo)
    HB_GII=$(hb_result "$r")
    if [[ -n "$HB_GII" && "$HB_GII" != "null" ]] && poll_synced "$HB_GII"; then break; fi
    sleep 2
done
[[ -n "$HB_GII" && "$HB_GII" != "null" ]] || fail "hotbuns getindexinfo never returned a usable object"
poll_synced "$HB_GII" || fail "hotbuns indexes did not all reach synced=true within 120s ($HB_GII)"
log "hotbuns getindexinfo: $HB_GII"

# Fetch hotbuns' filtered + empty-arg responses for the later assertions.
r=$(hb_rpc getindexinfo '["txindex"]')
echo "$r" | grep -q '"result"' || fail "hotbuns getindexinfo \"txindex\" did not return a result ($r)"
HB_GII_TXIDX=$(hb_result "$r")

r=$(hb_rpc getindexinfo '["no-such-index"]')
echo "$r" | grep -q '"result"' || fail "hotbuns getindexinfo \"no-such-index\" returned an ERROR (must be {}, not an error): $r"
HB_GII_NONE=$(hb_result "$r")

# ── 7. Compare in a single Python verdict pass. ───────────────────────────
VERDICT=$(python3 - "$NBLOCKS" "$CORE_GII" "$HB_GII" "$HB_GII_TXIDX" "$HB_GII_NONE" <<'PYEOF'
import sys, json
nblocks = int(sys.argv[1])
core   = json.loads(sys.argv[2])
hb     = json.loads(sys.argv[3])
hb_txi = json.loads(sys.argv[4])
hb_non = json.loads(sys.argv[5])

errs = []

# (1) shape + height: for EACH index Core reports, hotbuns must report the
#     SAME key with synced==true, best_block_height==nblocks, value object keys
#     EXACTLY {synced, best_block_height}.
if not core:
    errs.append("Core reported no indexes (oracle misconfigured)")
ALLOWED = {"synced", "best_block_height"}
for name, cval in core.items():
    if name not in hb:
        errs.append(f"missing-index:{name!r} (hotbuns did not report it)")
        continue
    ov = hb[name]
    if not isinstance(ov, dict):
        errs.append(f"index {name!r} value is not an object")
        continue
    keys = set(ov.keys())
    extra = keys - ALLOWED
    miss  = ALLOWED - keys
    if extra:
        errs.append(f"index {name!r} has EXTRA keys {sorted(extra)} (Core shape forbids best_hash/best_block_hash/name/etc)")
    if miss:
        errs.append(f"index {name!r} MISSING keys {sorted(miss)}")
    if ov.get("synced") is not True:
        errs.append(f"index {name!r} synced != true (got {ov.get('synced')!r})")
    if ov.get("best_block_height") != nblocks:
        errs.append(f"index {name!r} best_block_height={ov.get('best_block_height')!r} != {nblocks}")

# Sanity: hotbuns must at minimum report txindex.
if "txindex" not in hb:
    errs.append("hotbuns did not report a 'txindex' entry")

# (2) filter: getindexinfo "txindex" must return ONLY the txindex key.
if set(hb_txi.keys()) != {"txindex"}:
    errs.append(f"getindexinfo \"txindex\" returned keys {sorted(hb_txi.keys())} (expected just ['txindex'])")
else:
    tv = hb_txi["txindex"]
    if set(tv.keys()) != ALLOWED:
        errs.append(f"filtered txindex value keys {sorted(tv.keys())} != {sorted(ALLOWED)}")
    if tv.get("synced") is not True or tv.get("best_block_height") != nblocks:
        errs.append(f"filtered txindex value wrong: {tv}")

# (3) empty: getindexinfo "no-such-index" must be {} (empty object, not error).
if hb_non != {}:
    errs.append(f"getindexinfo \"no-such-index\" returned {hb_non!r} (expected {{}})")

if errs:
    print("FAIL: " + " | ".join(errs))
else:
    print("OK")
PYEOF
) || fail "verdict comparison crashed (see logs)"

if [[ "$VERDICT" != "OK" ]]; then
    log "Core getindexinfo:    $CORE_GII"
    log "hot  getindexinfo:    $HB_GII"
    log "hot  txindex-filter:  $HB_GII_TXIDX"
    log "hot  none-filter:     $HB_GII_NONE"
    fail "${VERDICT#FAIL: }"
fi

log "PASS: shape + height + filter + empty all match Core (NBLOCKS=$NBLOCKS)"
log "Core indexes: $(python3 -c "import sys,json; print(', '.join(json.loads(sys.argv[1]).keys()))" "$CORE_GII")"
log "hot  indexes: $(python3 -c "import sys,json; print(', '.join(json.loads(sys.argv[1]).keys()))" "$HB_GII")"
pass

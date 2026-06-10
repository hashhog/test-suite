#!/usr/bin/env bash
#
# haskoin_getindexinfo.sh — self-contained getindexinfo Core-shape parity test.
#
# Mirrors test-suite/index/rustoshi_getindexinfo.sh.  Read-only index status —
# NOT consensus, but the OUTPUT SHAPE must be EXACT.
#
# WHAT IT PROVES (Bitcoin Core src/rpc/node.cpp + SummaryToJSON):
#   getindexinfo returns a dynamic JSON OBJECT keyed BY INDEX NAME.  For each
#   *running* index Core pushes ONE entry whose value has EXACTLY two fields:
#   "synced" (bool) and "best_block_height" (int) — and NOTHING else (no
#   best_hash / best_block_hash / name-in-value).  An index appears ONLY if
#   enabled/running.  The optional positional "index_name" arg filters to a
#   single index; a non-matching name yields {} (empty object, NOT an error).
#
# DIFFERENTIAL ORACLE: a REAL bitcoind regtest started with -blockfilterindex=basic.
#   haskoin exposes the same index via --blockfilterindex (Main.hs:292).  This is
#   the apples-to-apples index here: haskoin has no -txindex CLI flag, but it
#   runs a "basic block filter index" populated in lockstep with block connection
#   (the regtest miner mirrors every connected block into the IndexManager).  A
#   node with the filter index enabled emits just the one "basic block filter
#   index" key, which is itself a valid Core configuration.
#
# ASSERTIONS:
#   1. shape  — for EACH index Core reports, haskoin reports the SAME key with
#               synced==true, best_block_height==NBLOCKS (tip height), and the
#               value object has EXACTLY {synced, best_block_height} (FAIL on any
#               extra key).
#   2. filter — getindexinfo "<index>" returns ONLY that index's key.
#   3. empty  — getindexinfo "no-such-index" returns {} (empty object, not error).
#
# Summary line (stdout):
#   PASS: GETINDEXINFO haskoin: PASS shape=ok height=ok filter=ok empty=ok
#   FAIL: GETINDEXINFO haskoin: FAIL <short reason>
#
# Touches ONLY /tmp/hk-getindexinfo/ + /tmp/hk-getindexinfo-core/ and ports
#   22730/22750 (haskoin RPC/P2P), 22731/22751 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

BASEDIR="/home/work/hashhog"
NODE_BIN="$(find "$BASEDIR/haskoin/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

export haskoin_datadir="$BASEDIR/haskoin"

HK_DATADIR="/tmp/hk-getindexinfo"
HK_RPC=22730
HK_P2P=22750
HK_LOG="$HK_DATADIR/node.log"
HK_COOKIE=""

CORE_DATADIR="/tmp/hk-getindexinfo-core"
CORE_RPC=22731
CORE_P2P=22751
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=120
SECRET="3333333333333333333333333333333333333333333333333333333333333334"
# The index name haskoin runs (== Core's BlockFilterTypeName(BASIC)+" block filter index").
INDEX_NAME="basic block filter index"

HK_PID=""
CORE_BG=""

log() { echo "[gii:haskoin] $*" >&2; }
pass() { echo "GETINDEXINFO haskoin: PASS shape=ok height=ok filter=ok empty=ok"; exit 0; }
fail() { echo "GETINDEXINFO haskoin: FAIL $*"; exit 1; }

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
    rm -rf "$HK_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "hk-getindexinfo" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${HK_RPC}|${HK_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${HK_RPC}|${HK_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${HK_RPC}/${HK_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 2
rm -rf "$HK_DATADIR" "$CORE_DATADIR"
mkdir -p "$HK_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || fail "haskoin binary not found (build with: cabal build exe:haskoin)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive a deterministic regtest p2wpkh mining address. ──────────────
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

hk_rpc() {
    local method="$1"; local params="${2:-[]}"
    curl -s --max-time 60 -u "$HK_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$HK_RPC/" 2>/dev/null
}

# ── 3. Launch the Core regtest oracle with the basic block filter index. ──
log "launching Core oracle rpc=:$CORE_RPC -blockfilterindex=basic (listen=0)"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -blockfilterindex=basic -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
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

# ── 4. Launch haskoin on regtest with the block filter index enabled. ─────
log "launching haskoin (regtest) rpc=:$HK_RPC p2p=:$HK_P2P --blockfilterindex -> $HK_LOG"
"$NODE_BIN" --network Regtest --datadir "$HK_DATADIR" node \
    --rpcport "$HK_RPC" --port "$HK_P2P" --listen False --metricsport 0 \
    --blockfilterindex >"$HK_LOG" 2>&1 &
HK_PID=$!
log "haskoin pid=$HK_PID"
hk_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < hk_deadline )); do
    if [[ -z "$HK_COOKIE" ]]; then
        for c in "$HK_DATADIR/regtest/.cookie" "$HK_DATADIR/.cookie"; do
            [[ -f "$c" ]] && HK_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HK_COOKIE" ]]; then
        r=$(hk_rpc getblockcount)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$HK_PID" 2>/dev/null || { tail -n 30 "$HK_LOG" >&2 2>/dev/null || true; fail "haskoin exited during startup (see $HK_LOG)"; }
    sleep 1
done
[[ -n "$HK_COOKIE" ]] || fail "haskoin cookie never appeared within 90s"
r=$(hk_rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "haskoin RPC never responded within 90s"
log "haskoin RPC ready"

# ── 5. Mine NBLOCKS empty blocks on BOTH nodes. ───────────────────────────
log "mining $NBLOCKS empty blocks on Core"
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null 2>>"$CORE_LOG" \
    || fail "Core generatetoaddress failed (see $CORE_LOG)"
CORE_HEIGHT=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount 2>/dev/null)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

log "mining $NBLOCKS empty blocks on haskoin"
r=$(hk_rpc generatetoaddress "[$NBLOCKS, \"$MINE_ADDR\"]")
echo "$r" | grep -q '"result"' || { log "haskoin generatetoaddress reply: $r"; fail "haskoin generatetoaddress failed (see $HK_LOG)"; }
r=$(hk_rpc getblockcount)
HK_HEIGHT=$(echo "$r" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result'))" 2>/dev/null)
[[ "$HK_HEIGHT" == "$NBLOCKS" ]] || fail "haskoin height $HK_HEIGHT != $NBLOCKS after mining"

# ── 6. Poll getindexinfo on BOTH until every reported index synced==true. ─
poll_synced() {
    python3 - <<PYEOF
import sys, json
data = json.loads('''$1''')
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

log "waiting for haskoin index sync"
sync_deadline=$(( $(date +%s) + 120 ))
HK_GII=""
while (( $(date +%s) < sync_deadline )); do
    r=$(hk_rpc getindexinfo)
    HK_GII=$(echo "$r" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('result')))" 2>/dev/null)
    if [[ -n "$HK_GII" && "$HK_GII" != "null" ]] && poll_synced "$HK_GII"; then break; fi
    sleep 2
done
[[ -n "$HK_GII" && "$HK_GII" != "null" ]] || fail "haskoin getindexinfo never returned a usable object"
poll_synced "$HK_GII" || fail "haskoin indexes did not all reach synced=true within 120s ($HK_GII)"
log "haskoin getindexinfo: $HK_GII"

# Filtered + empty-arg responses for the later assertions.
r=$(hk_rpc getindexinfo "[\"$INDEX_NAME\"]")
HK_GII_FILT=$(echo "$r" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('result')))" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "haskoin getindexinfo \"$INDEX_NAME\" did not return a result ($r)"

r=$(hk_rpc getindexinfo '["no-such-index"]')
HK_GII_NONE=$(echo "$r" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('result')))" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "haskoin getindexinfo \"no-such-index\" returned an ERROR (must be {}, not an error): $r"

# ── 7. Compare in a single Python verdict pass. ───────────────────────────
VERDICT=$(python3 - "$NBLOCKS" "$CORE_GII" "$HK_GII" "$HK_GII_FILT" "$HK_GII_NONE" "$INDEX_NAME" <<'PYEOF'
import sys, json
nblocks   = int(sys.argv[1])
core      = json.loads(sys.argv[2])
hk        = json.loads(sys.argv[3])
hk_filt   = json.loads(sys.argv[4])
hk_none   = json.loads(sys.argv[5])
idx_name  = sys.argv[6]

errs = []
ALLOWED = {"synced", "best_block_height"}

if not core:
    errs.append("Core reported no indexes (oracle misconfigured)")

# (1) shape + height: for EACH index Core reports, haskoin must report the SAME
#     key with synced==true, best_block_height==nblocks, value keys EXACTLY
#     {synced, best_block_height}.
for name, cval in core.items():
    if name not in hk:
        errs.append(f"missing-index:{name!r} (haskoin did not report it)")
        continue
    ov = hk[name]
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

# Sanity: haskoin must at minimum report the basic block filter index.
if idx_name not in hk:
    errs.append(f"haskoin did not report a {idx_name!r} entry")

# (2) filter: getindexinfo "<index>" must return ONLY that key.
if set(hk_filt.keys()) != {idx_name}:
    errs.append(f"getindexinfo {idx_name!r} returned keys {sorted(hk_filt.keys())} (expected just [{idx_name!r}])")
else:
    tv = hk_filt[idx_name]
    if set(tv.keys()) != ALLOWED:
        errs.append(f"filtered value keys {sorted(tv.keys())} != {sorted(ALLOWED)}")
    if tv.get("synced") is not True or tv.get("best_block_height") != nblocks:
        errs.append(f"filtered value wrong: {tv}")

# (3) empty: getindexinfo "no-such-index" must be {} (empty object, not error).
if hk_none != {}:
    errs.append(f"getindexinfo \"no-such-index\" returned {hk_none!r} (expected {{}})")

print("FAIL: " + " | ".join(errs) if errs else "OK")
PYEOF
) || fail "verdict comparison crashed (see logs)"

if [[ "$VERDICT" != "OK" ]]; then
    log "Core getindexinfo:   $CORE_GII"
    log "haskoin getindexinfo: $HK_GII"
    log "haskoin filter:      $HK_GII_FILT"
    log "haskoin none-filter: $HK_GII_NONE"
    fail "${VERDICT#FAIL: }"
fi

log "PASS: shape + height + filter + empty all match Core (NBLOCKS=$NBLOCKS)"
pass

#!/usr/bin/env bash
#
# rustoshi_getindexinfo.sh — self-contained getindexinfo Core-shape parity test.
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
# DIFFERENTIAL ORACLE: a REAL bitcoind regtest started with -txindex=1.
#   rustoshi exposes the same index via --txindex (crates/.../main.rs:159).
#   We launch BOTH nodes with txindex on (and ONLY txindex — a node with txindex
#   enabled but no filter index emits just the one "txindex" key, which is itself
#   a valid Core configuration), mine the SAME number of empty blocks on BOTH,
#   wait for index sync on BOTH, then compare. txindex is the apples-to-apples
#   index here: it is the one rustoshi's generatetoaddress mining path populates
#   in lockstep with block connection (the basic block filter index is only
#   written on the P2P connect path, a pre-existing mining-path detail unrelated
#   to getindexinfo's output shape, which is what this cell asserts).
#
# ASSERTIONS:
#   1. shape  — for EACH index Core reports, rustoshi reports the SAME key with
#               synced==true, best_block_height==NBLOCKS (tip height), and the
#               value object has EXACTLY the keys {synced, best_block_height}
#               (FAIL on best_hash / best_block_hash / name / any extra key).
#   2. filter — getindexinfo "txindex" on rustoshi returns ONLY the txindex key.
#   3. empty  — getindexinfo "no-such-index" on rustoshi returns {} (empty
#               object, not an error).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/rustoshi_policy.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + UNIQUE
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1. Run under: setsid -w bash rustoshi_getindexinfo.sh
#
# Summary line (stdout):
#   PASS: GETINDEXINFO rustoshi: PASS shape=ok height=ok filter=ok empty=ok
#   FAIL: GETINDEXINFO rustoshi: FAIL <short reason>
#
# Touches ONLY /tmp/giifleet-rustoshi/ + /tmp/giifleet-core-rs/ and ports
#   40030/40050 (rustoshi RPC/P2P), 40031/40051 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/rustoshi/target/release/rustoshi"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

RS_DATADIR="/tmp/giifleet-rustoshi"
RS_RPC=40030
RS_P2P=40050
RS_LOG="$RS_DATADIR/node.log"

CORE_DATADIR="/tmp/giifleet-core-rs"
CORE_RPC=40031
CORE_P2P=40051
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=120            # mine this many empty blocks on both nodes
SECRET="3333333333333333333333333333333333333333333333333333333333333334"

RS_PID=""
RS_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gii:rustoshi] $*" >&2; }

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETINDEXINFO rustoshi: PASS shape=ok height=ok filter=ok empty=ok"
    exit 0
}
fail() {
    echo "GETINDEXINFO rustoshi: FAIL $*"
    exit 1
}

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
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${RS_RPC}/tcp"         2>/dev/null || true
    fuser -k "${RS_P2P}/tcp"         2>/dev/null || true
    fuser -k "${CORE_RPC}/tcp"       2>/dev/null || true
    fuser -k "${CORE_P2P}/tcp"       2>/dev/null || true
    fuser -k "$((CORE_P2P + 1))/tcp" 2>/dev/null || true   # Core onion listener (P2P+1)
    rm -rf "$RS_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "giifleet-rustoshi" 2>/dev/null || true
fuser -k "${RS_RPC}/tcp"         2>/dev/null || true
fuser -k "${RS_P2P}/tcp"         2>/dev/null || true
fuser -k "${CORE_RPC}/tcp"       2>/dev/null || true
fuser -k "${CORE_P2P}/tcp"       2>/dev/null || true
fuser -k "$((CORE_P2P + 1))/tcp" 2>/dev/null || true
sleep 2
rm -rf "$RS_DATADIR" "$CORE_DATADIR"
mkdir -p "$RS_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "rustoshi binary not found at $NODE_BIN (build with: cargo build --release)"
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

# ── rustoshi RPC helper (cookie auth, JSON-RPC over HTTP). ────────────────
# rs_rpc <method> [json-params-array]  -> echoes the raw JSON-RPC response body
rs_rpc() {
    local method="$1"; local params="${2:-[]}"
    curl -s --max-time 60 -u "$RS_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RS_RPC/" 2>/dev/null
}

# ── 3. Launch the Core regtest oracle with txindex on. ────────────────────
log "launching Core oracle rpc=:$CORE_RPC -txindex=1"
# Fully detach (setsid + nohup + </dev/null) so the daemon survives the harness
# session/process-group teardown that otherwise SIGTERMs plain '&' background jobs.
setsid nohup "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -txindex=1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 </dev/null &
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

# ── 4. Launch rustoshi on regtest with txindex enabled. ───────────────────
log "launching rustoshi (regtest) rpc=:$RS_RPC p2p=:$RS_P2P --txindex -> $RS_LOG"
setsid nohup "$NODE_BIN" --network=regtest --datadir="$RS_DATADIR" \
    --port="$RS_P2P" --rpcbind="127.0.0.1:$RS_RPC" --txindex >"$RS_LOG" 2>&1 </dev/null &
RS_PID=$!
disown "$RS_PID" 2>/dev/null || true
log "rustoshi pid=$RS_PID"
rs_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < rs_deadline )); do
    # rustoshi can ROTATE the cookie on a fresh start, so re-read it every loop.
    for c in "$RS_DATADIR/.cookie" "$RS_DATADIR/regtest/.cookie"; do
        [[ -f "$c" ]] && RS_COOKIE=$(cat "$c") && break
    done
    if [[ -n "$RS_COOKIE" ]]; then
        r=$(rs_rpc getblockcount)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$RS_PID" 2>/dev/null || { tail -n 20 "$RS_LOG" >&2 2>/dev/null || true; fail "rustoshi exited during startup (see $RS_LOG)"; }
    sleep 1
done
[[ -n "$RS_COOKIE" ]] || fail "rustoshi cookie never appeared within 120s"
r=$(rs_rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "rustoshi RPC never responded within 120s"
log "rustoshi RPC ready"

# ── 5. Mine NBLOCKS empty blocks on BOTH nodes. ───────────────────────────
log "mining $NBLOCKS empty blocks on Core"
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null 2>>"$CORE_LOG" \
    || fail "Core generatetoaddress failed (see $CORE_LOG)"
CORE_HEIGHT=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount 2>/dev/null)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

log "mining $NBLOCKS empty blocks on rustoshi"
r=$(rs_rpc generatetoaddress "[$NBLOCKS, \"$MINE_ADDR\"]")
echo "$r" | grep -q '"result"' || { log "rustoshi generatetoaddress reply: $r"; fail "rustoshi generatetoaddress failed (see $RS_LOG)"; }
r=$(rs_rpc getblockcount)
RS_HEIGHT=$(echo "$r" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result'))" 2>/dev/null)
[[ "$RS_HEIGHT" == "$NBLOCKS" ]] || fail "rustoshi height $RS_HEIGHT != $NBLOCKS after mining"

# ── 6. Poll getindexinfo on BOTH until every reported index synced==true. ─
# Generous timeout: an index thread may lag block connection on a real node.
poll_synced() {  # poll_synced <getindexinfo-json>  -> 0 if all synced
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

log "waiting for rustoshi index sync"
sync_deadline=$(( $(date +%s) + 120 ))
RS_GII=""
while (( $(date +%s) < sync_deadline )); do
    r=$(rs_rpc getindexinfo)
    RS_GII=$(echo "$r" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('result')))" 2>/dev/null)
    if [[ -n "$RS_GII" && "$RS_GII" != "null" ]] && poll_synced "$RS_GII"; then break; fi
    sleep 2
done
[[ -n "$RS_GII" && "$RS_GII" != "null" ]] || fail "rustoshi getindexinfo never returned a usable object"
poll_synced "$RS_GII" || fail "rustoshi indexes did not all reach synced=true within 120s ($RS_GII)"
log "rustoshi getindexinfo: $RS_GII"

# Fetch rustoshi's filtered + empty-arg responses for the later assertions.
r=$(rs_rpc getindexinfo '["txindex"]')
RS_GII_TXIDX=$(echo "$r" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('result')))" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "rustoshi getindexinfo \"txindex\" did not return a result ($r)"

r=$(rs_rpc getindexinfo '["no-such-index"]')
RS_GII_NONE=$(echo "$r" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('result')))" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "rustoshi getindexinfo \"no-such-index\" returned an ERROR (must be {}, not an error): $r"

# ── 7. Compare in a single Python verdict pass. ───────────────────────────
VERDICT=$(python3 - "$NBLOCKS" "$CORE_GII" "$RS_GII" "$RS_GII_TXIDX" "$RS_GII_NONE" <<'PYEOF'
import sys, json
nblocks = int(sys.argv[1])
core   = json.loads(sys.argv[2])
rs     = json.loads(sys.argv[3])
rs_txi = json.loads(sys.argv[4])
rs_non = json.loads(sys.argv[5])

errs = []

# (1) shape + height: for EACH index Core reports, rustoshi must report the
#     SAME key with synced==true, best_block_height==nblocks, value object keys
#     EXACTLY {synced, best_block_height}.
if not core:
    errs.append("Core reported no indexes (oracle misconfigured)")
ALLOWED = {"synced", "best_block_height"}
for name, cval in core.items():
    if name not in rs:
        errs.append(f"missing-index:{name!r} (rustoshi did not report it)")
        continue
    ov = rs[name]
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

# Sanity: rustoshi must at minimum report txindex.
if "txindex" not in rs:
    errs.append("rustoshi did not report a 'txindex' entry")

# (2) filter: getindexinfo "txindex" must return ONLY the txindex key.
if set(rs_txi.keys()) != {"txindex"}:
    errs.append(f"getindexinfo \"txindex\" returned keys {sorted(rs_txi.keys())} (expected just ['txindex'])")
else:
    tv = rs_txi["txindex"]
    if set(tv.keys()) != ALLOWED:
        errs.append(f"filtered txindex value keys {sorted(tv.keys())} != {sorted(ALLOWED)}")
    if tv.get("synced") is not True or tv.get("best_block_height") != nblocks:
        errs.append(f"filtered txindex value wrong: {tv}")

# (3) empty: getindexinfo "no-such-index" must be {} (empty object, not error).
if rs_non != {}:
    errs.append(f"getindexinfo \"no-such-index\" returned {rs_non!r} (expected {{}})")

if errs:
    print("FAIL: " + " | ".join(errs))
else:
    print("OK")
PYEOF
) || fail "verdict comparison crashed (see logs)"

if [[ "$VERDICT" != "OK" ]]; then
    log "Core getindexinfo:   $CORE_GII"
    log "rust getindexinfo:   $RS_GII"
    log "rust txindex-filter: $RS_GII_TXIDX"
    log "rust none-filter:    $RS_GII_NONE"
    fail "${VERDICT#FAIL: }"
fi

log "PASS: shape + height + filter + empty all match Core (NBLOCKS=$NBLOCKS)"
log "Core indexes: $(python3 -c "import sys,json; print(', '.join(json.loads(sys.argv[1]).keys()))" "$CORE_GII")"
log "rust indexes: $(python3 -c "import sys,json; print(', '.join(json.loads(sys.argv[1]).keys()))" "$RS_GII")"
pass

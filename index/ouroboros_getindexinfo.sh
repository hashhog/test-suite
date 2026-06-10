#!/usr/bin/env bash
#
# ouroboros_getindexinfo.sh — self-contained getindexinfo Core-shape parity test.
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
# DIFFERENTIAL ORACLE: a REAL bitcoind regtest started with -txindex=1 (and
#   -blockfilterindex=basic). ouroboros runs txindex always-on (built inline
#   with block connection) + an optional basic block filter index enabled via
#   --blockfilterindex. We mine the SAME number of empty blocks on BOTH, wait
#   for index sync on BOTH, then compare.
#
# ASSERTIONS:
#   1. shape  — for EACH index Core reports, ouroboros reports the SAME key with
#               synced==true, best_block_height==NBLOCKS (tip height), and the
#               value object has EXACTLY the keys {synced, best_block_height}
#               (FAIL on best_hash / best_block_hash / name / any extra key).
#   2. filter — getindexinfo "txindex" on ouroboros returns ONLY the txindex key.
#   3. empty  — getindexinfo "no-such-index" on ouroboros returns {} (empty
#               object, not an error).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/ouroboros_policy.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + UNIQUE
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1. Run under: setsid -w bash ouroboros_getindexinfo.sh
#
# Summary line (stdout):
#   PASS: GETINDEXINFO ouroboros: PASS shape=ok height=ok filter=ok empty=ok
#   FAIL: GETINDEXINFO ouroboros: FAIL <short reason>
#
# Touches ONLY /tmp/giifleet-ouroboros/ + /tmp/giifleet-core/ and ports
#   21932/21952 (ouroboros RPC/P2P), 21933/21953 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

# Resolve the ouroboros checkout relative to this script:
# test-suite/index/ -> repo root -> ouroboros/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OURO_DIR="$REPO_ROOT/ouroboros"

OU_DATADIR="/tmp/giifleet-ouroboros"
OU_RPC=21932
OU_P2P=21952
OU_LOG="$OU_DATADIR/node.log"

CORE_DATADIR="/tmp/giifleet-core"
CORE_RPC=21933
CORE_P2P=21953
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=120            # mine this many empty blocks on both nodes
SECRET="2222222222222222222222222222222222222222222222222222222222222223"

OU_PID=""
OU_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gii:ouroboros] $*" >&2; }

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETINDEXINFO ouroboros: PASS shape=ok height=ok filter=ok empty=ok"
    exit 0
}
fail() {
    echo "GETINDEXINFO ouroboros: FAIL $*"
    exit 1
}

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$OU_PID" ]] && kill -0 "$OU_PID" 2>/dev/null; then
        kill "$OU_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$OU_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$OU_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$OU_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "giifleet-ouroboros" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${OU_RPC}|${OU_P2P}|${CORE_RPC}|${CORE_P2P}|$((CORE_P2P + 1))) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${OU_RPC}|${OU_P2P}|${CORE_RPC}|${CORE_P2P}|$((CORE_P2P + 1))) "; then
    fail "port ${OU_RPC}/${OU_P2P}/${CORE_RPC}/${CORE_P2P}/$((CORE_P2P + 1)) already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$OU_DATADIR" "$CORE_DATADIR"
mkdir -p "$OU_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1        || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1        || fail "curl not found on PATH"
[[ -f "$OURO_DIR/src/ouroboros/cli.py" ]] || fail "ouroboros checkout not found at $OURO_DIR"
[[ -x "$CORE_BIN" ]]                      || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                      || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]        || fail "Core test_framework not found at $TF_PATH"

OURO_PY="$OURO_DIR/.venv/bin/python3"
[[ -x "$OURO_PY" ]] || OURO_PY="python3"

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

# ── ouroboros RPC helper (cookie auth, JSON-RPC over HTTP). ───────────────
# ou_rpc <method> [json-params-array]  -> echoes the raw JSON-RPC response body
ou_rpc() {
    local method="$1"; local params="${2:-[]}"
    curl -s --max-time 60 -u "$OU_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$OU_RPC/" 2>/dev/null
}

# ── 3. Launch the Core regtest oracle with both indexes on. ───────────────
log "launching Core oracle rpc=:$CORE_RPC -txindex=1 -blockfilterindex=basic"
# Fully detach (setsid + nohup + </dev/null) so the daemon survives the harness
# session/process-group teardown that otherwise SIGTERMs plain '&' background jobs.
setsid nohup "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -txindex=1 -blockfilterindex=basic -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 </dev/null &
CORE_BG=$!
disown "$CORE_BG" 2>/dev/null || true
core_deadline=$(( $(date +%s) + 60 ))
core_ready=0
while (( $(date +%s) < core_deadline )); do
    if "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1; then
        core_ready=1; break
    fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
[[ "$core_ready" -eq 1 ]] || fail "Core oracle failed to start within 60s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch ouroboros on regtest with the block filter index enabled. ───
# txindex is always-on in ouroboros (built inline at block connect); the basic
# block filter index is gated on --blockfilterindex (Core -blockfilterindex=basic).
# ouroboros is Python — the slowest-starting node — so allow a generous wait.
log "launching ouroboros (regtest) rpc=:$OU_RPC p2p=:$OU_P2P --blockfilterindex -> $OU_LOG"
# Fully detach (setsid + nohup + </dev/null) so the node survives the harness
# session/process-group teardown that otherwise SIGTERMs plain '&' background jobs.
setsid nohup bash -c '
    cd "$1" || exit 1
    exec "$2" -m ouroboros.cli \
        --network regtest --data-dir "$3" \
        start --force --rpc-port "$4" --p2p-port "$5" --blockfilterindex
' _ "$OURO_DIR" "$OURO_PY" "$OU_DATADIR" "$OU_RPC" "$OU_P2P" >"$OU_LOG" 2>&1 </dev/null &
OU_PID=$!
disown "$OU_PID" 2>/dev/null || true
log "ouroboros pid=$OU_PID"
ou_deadline=$(( $(date +%s) + 150 ))
while (( $(date +%s) < ou_deadline )); do
    if [[ -z "$OU_COOKIE" ]]; then
        for c in "$OU_DATADIR/.cookie" "$OU_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && OU_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$OU_COOKIE" ]]; then
        r=$(ou_rpc getblockcount)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$OU_PID" 2>/dev/null || { tail -n 20 "$OU_LOG" >&2 2>/dev/null || true; fail "ouroboros exited during startup (see $OU_LOG)"; }
    sleep 1
done
[[ -n "$OU_COOKIE" ]] || fail "ouroboros cookie never appeared within 150s"
r=$(ou_rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "ouroboros RPC never responded within 150s"
log "ouroboros RPC ready"

# ── 5. Mine NBLOCKS empty blocks on BOTH nodes. ───────────────────────────
log "mining $NBLOCKS empty blocks on Core"
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null 2>>"$CORE_LOG" \
    || fail "Core generatetoaddress failed (see $CORE_LOG)"
CORE_HEIGHT=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount 2>/dev/null)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

log "mining $NBLOCKS empty blocks on ouroboros"
r=$(ou_rpc generatetoaddress "[$NBLOCKS, \"$MINE_ADDR\"]")
echo "$r" | grep -q '"result"' || { log "ouroboros generatetoaddress reply: $r"; fail "ouroboros generatetoaddress failed (see $OU_LOG)"; }
r=$(ou_rpc getblockcount)
OU_HEIGHT=$(echo "$r" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result'))" 2>/dev/null)
[[ "$OU_HEIGHT" == "$NBLOCKS" ]] || fail "ouroboros height $OU_HEIGHT != $NBLOCKS after mining"

# ── 6. Poll getindexinfo on BOTH until every reported index synced==true. ─
# Generous timeout: an index thread may lag block connection on a real node.
poll_synced() {  # poll_synced <who> <getindexinfo-json>  -> 0 if all synced
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

log "waiting for ouroboros index sync"
sync_deadline=$(( $(date +%s) + 120 ))
OU_GII=""
while (( $(date +%s) < sync_deadline )); do
    r=$(ou_rpc getindexinfo)
    OU_GII=$(echo "$r" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('result')))" 2>/dev/null)
    if [[ -n "$OU_GII" && "$OU_GII" != "null" ]] && poll_synced "$OU_GII"; then break; fi
    sleep 2
done
[[ -n "$OU_GII" && "$OU_GII" != "null" ]] || fail "ouroboros getindexinfo never returned a usable object"
poll_synced "$OU_GII" || fail "ouroboros indexes did not all reach synced=true within 120s ($OU_GII)"
log "ouroboros getindexinfo: $OU_GII"

# Fetch ouroboros's filtered + empty-arg responses for the later assertions.
r=$(ou_rpc getindexinfo '["txindex"]')
OU_GII_TXIDX=$(echo "$r" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('result')))" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "ouroboros getindexinfo \"txindex\" did not return a result ($r)"

r=$(ou_rpc getindexinfo '["no-such-index"]')
OU_GII_NONE=$(echo "$r" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('result')))" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "ouroboros getindexinfo \"no-such-index\" returned an ERROR (must be {}, not an error): $r"

# ── 7. Compare in a single Python verdict pass. ───────────────────────────
VERDICT=$(python3 - "$NBLOCKS" "$CORE_GII" "$OU_GII" "$OU_GII_TXIDX" "$OU_GII_NONE" <<'PYEOF'
import sys, json
nblocks = int(sys.argv[1])
core   = json.loads(sys.argv[2])
ou     = json.loads(sys.argv[3])
ou_txi = json.loads(sys.argv[4])
ou_non = json.loads(sys.argv[5])

errs = []

# (1) shape + height: for EACH index Core reports, ouroboros must report the
#     SAME key with synced==true, best_block_height==nblocks, value object keys
#     EXACTLY {synced, best_block_height}.
if not core:
    errs.append("Core reported no indexes (oracle misconfigured)")
ALLOWED = {"synced", "best_block_height"}
for name, cval in core.items():
    if name not in ou:
        errs.append(f"missing-index:{name!r} (ouroboros did not report it)")
        continue
    ov = ou[name]
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
    # field-order parity (Core pushes synced THEN best_block_height)
    klist = list(ov.keys())
    if klist[:2] != ["synced", "best_block_height"]:
        errs.append(f"index {name!r} field order {klist} != ['synced','best_block_height']")

# Sanity: ouroboros must at minimum report txindex.
if "txindex" not in ou:
    errs.append("ouroboros did not report a 'txindex' entry")

# (2) filter: getindexinfo "txindex" must return ONLY the txindex key.
if set(ou_txi.keys()) != {"txindex"}:
    errs.append(f"getindexinfo \"txindex\" returned keys {sorted(ou_txi.keys())} (expected just ['txindex'])")
else:
    tv = ou_txi["txindex"]
    if set(tv.keys()) != ALLOWED:
        errs.append(f"filtered txindex value keys {sorted(tv.keys())} != {sorted(ALLOWED)}")
    if tv.get("synced") is not True or tv.get("best_block_height") != nblocks:
        errs.append(f"filtered txindex value wrong: {tv}")

# (3) empty: getindexinfo "no-such-index" must be {} (empty object, not error).
if ou_non != {}:
    errs.append(f"getindexinfo \"no-such-index\" returned {ou_non!r} (expected {{}})")

if errs:
    print("FAIL: " + " | ".join(errs))
else:
    print("OK")
PYEOF
) || fail "verdict comparison crashed (see logs)"

if [[ "$VERDICT" != "OK" ]]; then
    log "Core getindexinfo:  $CORE_GII"
    log "ouro getindexinfo:  $OU_GII"
    log "ouro txindex-filter: $OU_GII_TXIDX"
    log "ouro none-filter:    $OU_GII_NONE"
    fail "${VERDICT#FAIL: }"
fi

log "PASS: shape + height + filter + empty all match Core (NBLOCKS=$NBLOCKS)"
log "Core indexes: $(python3 -c "import sys,json; print(', '.join(json.loads(sys.argv[1]).keys()))" "$CORE_GII")"
log "ouro indexes: $(python3 -c "import sys,json; print(', '.join(json.loads(sys.argv[1]).keys()))" "$OU_GII")"
pass

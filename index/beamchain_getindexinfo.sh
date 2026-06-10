#!/usr/bin/env bash
#
# beamchain_getindexinfo.sh — self-contained getindexinfo Core-shape parity test.
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
# DIFFERENTIAL ORACLE: a REAL bitcoind regtest started with -txindex=1 and
#   -blockfilterindex=basic. beamchain runs txindex always-on by default (written
#   atomically inside each block-connect WriteBatch) + an optional basic block
#   filter index enabled via BEAMCHAIN_BLOCKFILTERINDEX=1 (Core's
#   -blockfilterindex=basic). We mine the SAME number of empty blocks on BOTH,
#   wait for index sync on BOTH, then compare.
#
# ASSERTIONS:
#   1. shape  — for EACH index Core reports, beamchain reports the SAME key with
#               synced==true, best_block_height==NBLOCKS (tip height), and the
#               value object has EXACTLY the keys {synced, best_block_height}
#               (FAIL on best_hash / best_block_hash / name / any extra key),
#               with field order synced THEN best_block_height.
#   2. filter — getindexinfo "txindex" on beamchain returns ONLY the txindex key.
#   3. empty  — getindexinfo "no-such-index" on beamchain returns {} (empty
#               object, not an error).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/beamchain_policy.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + UNIQUE
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1. Run under: setsid -w bash beamchain_getindexinfo.sh
#
# Summary line (stdout):
#   PASS: GETINDEXINFO beamchain: PASS shape=ok height=ok filter=ok empty=ok
#   FAIL: GETINDEXINFO beamchain: FAIL <short reason>
#
# Touches ONLY /tmp/giifleet-beamchain/ + /tmp/giifleet-beamchain-core/ and ports
#   21936/21956 (beamchain RPC/P2P), 21937/21957 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

BC_DATADIR="/tmp/giifleet-beamchain"
BC_RPC=21936
BC_P2P=21956
BC_LOG="$BC_DATADIR/node.log"

# Core-oracle scratch dir is namespaced to THIS harness (…-beamchain-…) so a
# sibling getindexinfo run never shares a datadir.
CORE_DATADIR="/tmp/giifleet-beamchain-core"
CORE_RPC=21937
CORE_P2P=21957
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=120            # mine this many empty blocks on both nodes
SECRET="3333333333333333333333333333333333333333333333333333333333333334"

BC_PID=""
BC_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gii:beamchain] $*" >&2; }

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETINDEXINFO beamchain: PASS shape=ok height=ok filter=ok empty=ok"
    exit 0
}
fail() {
    echo "GETINDEXINFO beamchain: FAIL $*"
    exit 1
}

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BC_PID" ]] && kill -0 "$BC_PID" 2>/dev/null; then
        kill "$BC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BC_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    # beamchain runs under its own process group (setsid -w); reap stragglers.
    pkill -f "giifleet-beamchain" 2>/dev/null || true
    rm -rf "$BC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "giifleet-beamchain" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${BC_RPC}|${BC_P2P}|${CORE_RPC}|${CORE_P2P}|$((CORE_P2P + 1))) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${BC_RPC}|${BC_P2P}|${CORE_RPC}|${CORE_P2P}|$((CORE_P2P + 1))) "; then
    fail "port ${BC_RPC}/${BC_P2P}/${CORE_RPC}/${CORE_P2P}/$((CORE_P2P + 1)) already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$BC_DATADIR" "$CORE_DATADIR"
mkdir -p "$BC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "beamchain release binary not found at $NODE_BIN (run rebar3 as prod release)"
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

# ── beamchain RPC helper (cookie auth, JSON-RPC over HTTP). ───────────────
# bc_rpc <method> [json-params-array]  -> echoes the raw JSON-RPC response body
bc_rpc() {
    local method="$1"; local params="${2:-[]}"
    curl -s --max-time 60 -u "$BC_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$BC_RPC/" 2>/dev/null
}
# Extract the JSON-RPC "result" (as compact JSON) from a response body.
jq_result() { python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('result')))" 2>/dev/null; }

# ── 3. Launch the Core regtest oracle with both indexes on. ───────────────
log "launching Core oracle rpc=:$CORE_RPC -txindex=1 -blockfilterindex=basic"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -bind="127.0.0.1:$CORE_P2P" -txindex=1 -blockfilterindex=basic -fallbackfee=0.0002 \
    >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 120 ))
core_ready=0
while (( $(date +%s) < core_deadline )); do
    if "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1; then
        core_ready=1; break
    fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
[[ "$core_ready" -eq 1 ]] || fail "Core oracle failed to start within 120s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch beamchain on regtest with BOTH indexes enabled. ─────────────
# txindex is default-on (written atomically at block connect); the basic block
# filter index is opt-in via BEAMCHAIN_BLOCKFILTERINDEX=1 (mirrors Core's
# -blockfilterindex=basic). Release binary, foreground, sys.config + vm.args —
# mirrors test-suite/policy/beamchain_spend launching convention.
cat >"$BC_DATADIR/sys.config" <<ERLCFG
[
 {beamchain, [
   {network, regtest},
   {datadir, "$BC_DATADIR"},
   {p2pport, $BC_P2P},
   {rpcport, $BC_RPC}
 ]},
 {kernel, [{logger_level, info}]},
 {sasl,   [{sasl_error_logger, false}]}
].
ERLCFG
cat >"$BC_DATADIR/vm.args" <<ERLVM
-sname beamchain_giiref_$$
-setcookie beamchain_giiref
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest) rpc=:$BC_RPC p2p=:$BC_P2P txindex=1 blockfilterindex=1 -> $BC_LOG"
BEAMCHAIN_TXINDEX=1 BEAMCHAIN_BLOCKFILTERINDEX=1 \
    RELX_CONFIG_PATH="$BC_DATADIR/sys.config" VMARGS_PATH="$BC_DATADIR/vm.args" \
    "$NODE_BIN" foreground >"$BC_LOG" 2>&1 &
BC_PID=$!
log "beamchain pid=$BC_PID"
bc_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < bc_deadline )); do
    if [[ -z "$BC_COOKIE" ]]; then
        for c in "$BC_DATADIR/regtest/.cookie" "$BC_DATADIR/.cookie"; do
            [[ -f "$c" ]] && BC_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$BC_COOKIE" ]]; then
        r=$(bc_rpc getblockcount)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$BC_PID" 2>/dev/null || { tail -n 20 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain exited during startup (see $BC_LOG)"; }
    sleep 1
done
[[ -n "$BC_COOKIE" ]] || fail "beamchain cookie never appeared within 90s"
r=$(bc_rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "beamchain RPC never responded within 90s"
log "beamchain RPC ready"

# ── 4b. Wait for beamchain's optional filter index to register. ───────────
# beamchain starts beamchain_rpc (RPC server) BEFORE beamchain_blockfilter_index
# in its supervision tree, and is_enabled/0 is a 5s gen_server:call that can
# transiently fail (-> the filter index is omitted) while the node is busy
# opening RocksDB CFs and spinning up sync threads. So for the first ~15-30s
# after RPC is ready the filter index may not yet appear in getindexinfo. Mine
# ONLY after BOTH indexes appear so the filter index indexes every block from
# height 1 (there is NO backfill — the index advances purely at block-connect).
# txindex is written in the connect WriteBatch so it is always present once RPC
# answers. Generous 180s deadline (the box may be running a live mainnet IBD +
# this harness's own Core oracle concurrently).
# has_filter <raw-rpc-response> -> exit 0 iff result is an object containing the
# 'basic block filter index' key.
has_filter() {
    echo "$1" | python3 -c "import sys,json
try:
    d = json.load(sys.stdin).get('result')
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and 'basic block filter index' in d else 1)" 2>/dev/null
}
log "waiting (up to 180s) for beamchain filter index to register in getindexinfo"
fidx_deadline=$(( $(date +%s) + 180 ))
pre_resp=""
while (( $(date +%s) < fidx_deadline )); do
    pre_resp=$(bc_rpc getindexinfo)
    if has_filter "$pre_resp"; then break; fi
    kill -0 "$BC_PID" 2>/dev/null || { tail -n 20 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain exited while waiting for filter index (see $BC_LOG)"; }
    sleep 2
done
has_filter "$pre_resp" \
    || fail "beamchain 'basic block filter index' never registered within 180s (BEAMCHAIN_BLOCKFILTERINDEX not honored?): $pre_resp"
log "beamchain indexes registered: $(echo "$pre_resp" | jq_result)"

# ── 5. Mine NBLOCKS empty blocks on BOTH nodes. ───────────────────────────
log "mining $NBLOCKS empty blocks on Core"
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null 2>>"$CORE_LOG" \
    || fail "Core generatetoaddress failed (see $CORE_LOG)"
CORE_HEIGHT=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount 2>/dev/null)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

log "mining $NBLOCKS empty blocks on beamchain"
r=$(bc_rpc generatetoaddress "[$NBLOCKS, \"$MINE_ADDR\"]")
echo "$r" | grep -q '"result"' || { log "beamchain generatetoaddress reply: $r"; fail "beamchain generatetoaddress failed (see $BC_LOG)"; }
r=$(bc_rpc getblockcount)
BC_HEIGHT=$(echo "$r" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result'))" 2>/dev/null)
[[ "$BC_HEIGHT" == "$NBLOCKS" ]] || fail "beamchain height $BC_HEIGHT != $NBLOCKS after mining (got $r)"

# ── 6. Poll getindexinfo on BOTH until every reported index synced==true. ─
# Generous timeout: an index may lag block connection on a real node.
poll_synced() {  # poll_synced <getindexinfo-json>  -> 0 if non-empty AND all synced
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

log "waiting for beamchain index sync"
sync_deadline=$(( $(date +%s) + 120 ))
BC_GII=""
while (( $(date +%s) < sync_deadline )); do
    r=$(bc_rpc getindexinfo)
    BC_GII=$(echo "$r" | jq_result)
    if [[ -n "$BC_GII" && "$BC_GII" != "null" ]] && poll_synced "$BC_GII"; then break; fi
    sleep 2
done
[[ -n "$BC_GII" && "$BC_GII" != "null" ]] || fail "beamchain getindexinfo never returned a usable object"
poll_synced "$BC_GII" || fail "beamchain indexes did not all reach synced=true within 120s ($BC_GII)"
log "beamchain getindexinfo: $BC_GII"

# Fetch beamchain's filtered + empty-arg responses for the later assertions.
r=$(bc_rpc getindexinfo '["txindex"]')
BC_GII_TXIDX=$(echo "$r" | jq_result)
echo "$r" | grep -q '"result"' || fail "beamchain getindexinfo \"txindex\" did not return a result ($r)"

r=$(bc_rpc getindexinfo '["no-such-index"]')
BC_GII_NONE=$(echo "$r" | jq_result)
echo "$r" | grep -q '"result"' || fail "beamchain getindexinfo \"no-such-index\" returned an ERROR (must be {}, not an error): $r"

# ── 7. Compare in a single Python verdict pass. ───────────────────────────
VERDICT=$(python3 - "$NBLOCKS" "$CORE_GII" "$BC_GII" "$BC_GII_TXIDX" "$BC_GII_NONE" <<'PYEOF'
import sys, json
nblocks = int(sys.argv[1])
core   = json.loads(sys.argv[2])
bc     = json.loads(sys.argv[3])
bc_txi = json.loads(sys.argv[4])
bc_non = json.loads(sys.argv[5])

errs = []

# (1) shape + height: for EACH index Core reports, beamchain must report the
#     SAME key with synced==true, best_block_height==nblocks, value object keys
#     EXACTLY {synced, best_block_height} in that order.
if not core:
    errs.append("Core reported no indexes (oracle misconfigured)")
ALLOWED = {"synced", "best_block_height"}
for name, cval in core.items():
    if name not in bc:
        errs.append(f"missing-index:{name!r} (beamchain did not report it)")
        continue
    bv = bc[name]
    if not isinstance(bv, dict):
        errs.append(f"index {name!r} value is not an object")
        continue
    keys = set(bv.keys())
    extra = keys - ALLOWED
    miss  = ALLOWED - keys
    if extra:
        errs.append(f"index {name!r} has EXTRA keys {sorted(extra)} (Core shape forbids best_hash/best_block_hash/name/etc)")
    if miss:
        errs.append(f"index {name!r} MISSING keys {sorted(miss)}")
    if bv.get("synced") is not True:
        errs.append(f"index {name!r} synced != true (got {bv.get('synced')!r})")
    if bv.get("best_block_height") != nblocks:
        errs.append(f"index {name!r} best_block_height={bv.get('best_block_height')!r} != {nblocks}")
    # field-order parity (Core pushes synced THEN best_block_height)
    klist = list(bv.keys())
    if klist[:2] != ["synced", "best_block_height"]:
        errs.append(f"index {name!r} field order {klist} != ['synced','best_block_height']")

# Sanity: beamchain must at minimum report txindex.
if "txindex" not in bc:
    errs.append("beamchain did not report a 'txindex' entry")

# (2) filter: getindexinfo "txindex" must return ONLY the txindex key.
if set(bc_txi.keys()) != {"txindex"}:
    errs.append(f"getindexinfo \"txindex\" returned keys {sorted(bc_txi.keys())} (expected just ['txindex'])")
else:
    tv = bc_txi["txindex"]
    if set(tv.keys()) != ALLOWED:
        errs.append(f"filtered txindex value keys {sorted(tv.keys())} != {sorted(ALLOWED)}")
    if tv.get("synced") is not True or tv.get("best_block_height") != nblocks:
        errs.append(f"filtered txindex value wrong: {tv}")

# (3) empty: getindexinfo "no-such-index" must be {} (empty object, not error).
if bc_non != {}:
    errs.append(f"getindexinfo \"no-such-index\" returned {bc_non!r} (expected {{}})")

if errs:
    print("FAIL: " + " | ".join(errs))
else:
    print("OK")
PYEOF
) || fail "verdict comparison crashed (see logs)"

if [[ "$VERDICT" != "OK" ]]; then
    log "Core getindexinfo:   $CORE_GII"
    log "beam getindexinfo:   $BC_GII"
    log "beam txindex-filter: $BC_GII_TXIDX"
    log "beam none-filter:    $BC_GII_NONE"
    fail "${VERDICT#FAIL: }"
fi

log "PASS: shape + height + filter + empty all match Core (NBLOCKS=$NBLOCKS)"
log "Core indexes: $(python3 -c "import sys,json; print(', '.join(json.loads(sys.argv[1]).keys()))" "$CORE_GII")"
log "beam indexes: $(python3 -c "import sys,json; print(', '.join(json.loads(sys.argv[1]).keys()))" "$BC_GII")"
pass

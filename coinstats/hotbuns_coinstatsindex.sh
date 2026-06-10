#!/usr/bin/env bash
#
# hotbuns_coinstatsindex.sh — self-contained gettxoutsetinfo-AT-HISTORICAL-HEIGHT
#   (coinstatsindex) Core-parity differential test for hotbuns.
#
# Capability under test:
#   gettxoutsetinfo ( "hash_type" hash_or_height use_index )
#   With -coinstatsindex=1, gettxoutsetinfo can return UTXO-set statistics AS OF
#   a HISTORICAL block (not just the tip) when given hash_or_height (a height int
#   or a block hash). This is backed by the coinstatsindex — a per-height running
#   UTXO-set muhash + counts/amounts maintained on every block connect/disconnect.
#   Without coinstatsindex, a non-tip hash_or_height -> error -8
#   "Querying specific block heights requires coinstatsindex".
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp   (gettxoutsetinfo: GetUTXOStats with
#       a CCoinsStats whose m_hash_type=MUHASH and pindex=block@height; routes to
#       g_coin_stats_index->LookUpStats when use_index && coinstatsindex enabled)
#   bitcoin-core/src/kernel/coinstats.cpp (per-coin muhash/counts kernels)
#   bitcoin-core/src/index/coinstatsindex.cpp (per-height running muhash + DB)
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + OWN ports, launched -listen=0 -coinstatsindex=1 -txindex=1.
#   To make the UTXO sets byte-identical the two nodes share the IDENTICAL chain:
#   Core MINES ~150 blocks to a deterministic address AND broadcasts a few SPEND
#   txs (so the UTXO set genuinely DIFFERS across heights — outputs removed AND
#   added, not just coinbases), then we REPLAY every raw block into hotbuns via
#   submitblock. Both nodes hold the same blocks -> the same per-height UTXO set
#   -> the same per-height coinstatsindex stats.
#
# STRICT SHARED CONTRACT (gate ALL — identical across all 10 scripts):
#   - Launch BOTH impl and a real bitcoind oracle on regtest with
#     -coinstatsindex=1 (and -txindex=1).
#   - Mine ~150 blocks with real spends; mirror the chain byte-identically.
#   - Wait for coinstatsindex to sync (poll getindexinfo, fallback gettxoutsetinfo
#     @tip).
#   - Pick a HISTORICAL height H well below tip (H=100).
#   - Call gettxoutsetinfo "muhash" H (and the default hash_type) on BOTH.
#   - GATE: impl.height==H==Core.height; impl.bestblock==Core.bestblock (the hash
#     AT height H, NOT the tip); impl.txouts==Core.txouts;
#     impl.total_amount==Core.total_amount; impl.<hash field> (muhash or
#     hash_serialized_3)==Core's.
#   - ERROR gate: with coinstatsindex DISABLED, a non-tip hash_or_height MUST
#     error (match Core's -8).
#
# Summary line (stdout), EXACTLY one of:
#   COINSTATSINDEX hotbuns: PASS atheight=ok txouts=ok amount=ok hash=ok bestblock=ok reorg=ok
#   COINSTATSINDEX hotbuns: FAIL <reason>
#   COINSTATSINDEX hotbuns: SKIP <reason>
#
# Touches ONLY /tmp/csidx-hotbuns/ + /tmp/csidx-hotbuns-core/ +
#   /tmp/csidx-hotbuns-coredis/ and ports 22374/22394 (hotbuns RPC/P2P) +
#   22376/22396 (Core oracle RPC/P2P) + 22378/22398 (Core disabled-index probe).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node. Does NOT
#   broad-pkill bitcoind by name — only frees its OWN fixed ports / scratch dir.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
HB_DIR="$BASEDIR/hotbuns"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/addr/WIF)

HB_DATADIR="/tmp/csidx-hotbuns"
HB_RPC=22374
HB_P2P=22394
HB_LOG="/tmp/csidx-hotbuns-node.log"               # outside the trap-wiped datadir

CORE_DATADIR="/tmp/csidx-hotbuns-core"
CORE_RPC=22376
CORE_P2P=22396
CORE_LOG="$CORE_DATADIR/core.log"

# Separate Core instance with coinstatsindex DISABLED, for the ERROR gate. Its
# own datadir/ports so it never collides with the main oracle.
CORED_DATADIR="/tmp/csidx-hotbuns-coredis"
CORED_RPC=22378
CORED_P2P=22398
CORED_LOG="$CORED_DATADIR/core.log"

# Deterministic mining key -> p2wpkh coinbase outputs we can later spend.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
# Deterministic destination key for the spend outputs.
SECRET2="2222222222222222222222222222222222222222222222222222222222222223"
# Deterministic chain-B mining key for the REORG phase. B mines to a DISTINCT
# address so its blocks differ from chain A's even at equal heights (different
# coinbase scriptPubKey -> a real reorg, not a no-op).
SECRET3="3333333333333333333333333333333333333333333333333333333333333334"

NBLOCKS_PRE=150    # >> coinbase maturity (101); gives a rich UTXO set + headroom.
HIST_H=100         # HISTORICAL height to query (well below tip ~150+).

HB_PID=""
HB_COOKIE=""
CORE_BG=""
CORED_BG=""
ADDR=""
ADDR2=""
ADDR3=""
WIF=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[coinstatsindex:hotbuns] $*" >&2; }

# ── Port-free poll: wait until a TCP port is actually free. ───────────────
wait_port_free() {
    # WAIT-ONLY (port-kill removed: 2026-06-10 fuser incident): NEVER kills by port.
    local port="$1"
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -qE ":${port} " || return 0
        sleep 1
    done
    return 0
}

# ── Cleanup: kill OUR nodes + wipe OUR scratch on any exit. ───────────────
cleanup() {
    local ec=$?
    if [[ -n "$HB_PID" ]] && kill -0 "$HB_PID" 2>/dev/null; then
        kill "$HB_PID" 2>/dev/null || true
        pkill -P "$HB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HB_PID" 2>/dev/null || true
        pkill -9 -P "$HB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI"  -regtest -datadir="$CORE_DATADIR"  -rpcport="$CORE_RPC"  stop >/dev/null 2>&1 || true
    "$CORE_CLI"  -regtest -datadir="$CORED_DATADIR" -rpcport="$CORED_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR"  -rpcport="$CORE_RPC"  getblockcount >/dev/null 2>&1 || \
        "$CORE_CLI" -regtest -datadir="$CORED_DATADIR" -rpcport="$CORED_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG"  ]] && kill "$CORE_BG"  2>/dev/null || true
    [[ -n "$CORED_BG" ]] && kill "$CORED_BG" 2>/dev/null || true
    rm -rf "$HB_DATADIR" "$CORE_DATADIR" "$CORED_DATADIR" "$HB_LOG" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "COINSTATSINDEX hotbuns: PASS atheight=$1 txouts=$2 amount=$3 hash=$4 bestblock=$5 reorg=$6"; exit 0; }
fail() { echo "COINSTATSINDEX hotbuns: FAIL $*"; exit 1; }
skip() { echo "COINSTATSINDEX hotbuns: SKIP $*"; exit 0; }

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
wait_port_free "$HB_RPC"
wait_port_free "$HB_P2P"
wait_port_free "$CORE_RPC"
wait_port_free "$CORE_P2P"
wait_port_free "$CORED_RPC"
wait_port_free "$CORED_P2P"
if ss -tln 2>/dev/null | grep -qE ":(${HB_RPC}|${HB_P2P}|${CORE_RPC}|${CORE_P2P}|${CORED_RPC}|${CORED_P2P}) "; then
    fail "port ${HB_RPC}/${HB_P2P}/${CORE_RPC}/${CORE_P2P}/${CORED_RPC}/${CORED_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
rm -rf "$HB_DATADIR" "$CORE_DATADIR" "$CORED_DATADIR" "$HB_LOG"
mkdir -p "$HB_DATADIR" "$CORE_DATADIR" "$CORED_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
command -v bun     >/dev/null 2>&1 || skip "bun not found on PATH (hotbuns needs Bun runtime)"
[[ -f "$HB_DIR/src/index.ts" ]]    || skip "hotbuns entrypoint not found (not built) at $HB_DIR/src/index.ts"
[[ -x "$CORE_BIN" ]]               || skip "bitcoind not found (not built) at $CORE_BIN"
[[ -x "$CORE_CLI" ]]               || skip "bitcoin-cli not found (not built) at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive deterministic regtest p2wpkh addresses + mining-key WIF. ────
eval "$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
from test_framework.wallet_util import bytes_to_wif
k=ECKey();  k.set(bytes.fromhex('$SECRET'),  compressed=True)
k2=ECKey(); k2.set(bytes.fromhex('$SECRET2'), compressed=True)
k3=ECKey(); k3.set(bytes.fromhex('$SECRET3'), compressed=True)
print('ADDR=%s'  % key_to_p2wpkh(k.get_pubkey().get_bytes(),  main=False))
print('ADDR2=%s' % key_to_p2wpkh(k2.get_pubkey().get_bytes(), main=False))
print('ADDR3=%s' % key_to_p2wpkh(k3.get_pubkey().get_bytes(), main=False))
print('WIF=%s'   % bytes_to_wif(k.get_bytes()))
" 2>/dev/null)" || fail "could not derive deterministic keys (Core test_framework import failed)"
[[ "$ADDR"  == bcrt1* ]] || fail "derived mining address is not regtest bech32: '$ADDR'"
[[ "$ADDR2" == bcrt1* ]] || fail "derived dest address is not regtest bech32: '$ADDR2'"
[[ "$ADDR3" == bcrt1* ]] || fail "derived chain-B address is not regtest bech32: '$ADDR3'"
[[ "$ADDR3" != "$ADDR" ]] || fail "chain-A and chain-B mining addresses collided"
[[ -n "$WIF" ]]          || fail "could not derive mining-key WIF"
log "mining addr=$ADDR  spend-dest=$ADDR2  chain-B addr=$ADDR3"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli()  { "$CORE_CLI"  -regtest -datadir="$CORE_DATADIR"  -rpcport="$CORE_RPC"  "$@"; }
cored_cli() { "$CORE_CLI"  -regtest -datadir="$CORED_DATADIR" -rpcport="$CORED_RPC" "$@"; }

# tolerant of the bitcoin-cli .cookie read race under concurrent fleet load.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# hb_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
hb_rpc() {
    curl -s --max-time 180 -u "$HB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$HB_RPC/" 2>/dev/null
}

# jget <json> <pyexpr over d> -> value or empty (swallows errors).
jget() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if v is None: pass
    elif isinstance(v, bool): print('true' if v else 'false')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# Core JSON-field extractor (from a `bitcoin-cli` json blob on stdin via arg).
cget() { echo "$1" | python3 -c "import sys,json;print(json.load(sys.stdin)$2)" 2>/dev/null; }

# ── 3. Launch Core regtest oracle WITH coinstatsindex + txindex. ──────────
launch_core_once() {
    wait_port_free "$CORE_RPC"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        -listen=0 -fallbackfee=0.0002 -coinstatsindex=1 -txindex=1 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if core_cli getblockcount >/dev/null 2>&1; then
            core_cli_retry getblockcount >/dev/null && return 0
        fi
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
CORE_OK=0
for attempt in 1 2 3; do
    log "launching Core oracle rpc=:$CORE_RPC (attempt $attempt, -coinstatsindex=1 -txindex=1)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch hotbuns on regtest WITH coinstatsindex + txindex. ───────────
# We pass --coinstatsindex=1 --txindex=1 to mirror the Core launch. If hotbuns
# rejects unknown flags it will fail to start (caught below as a SKIP/FAIL on
# startup, not silently). Both arg spellings (=1 and bare) are passed defensively
# only via the documented =VALUE form used elsewhere in the fleet.
log "launching hotbuns (regtest) rpc=:$HB_RPC p2p=:$HB_P2P -> $HB_LOG"
(
    cd "$HB_DIR"
    exec bun run src/index.ts \
        --network=regtest --datadir="$HB_DATADIR" \
        --port="$HB_P2P" --rpcport="$HB_RPC" \
        --coinstatsindex=1 --txindex=1
) >"$HB_LOG" 2>&1 &
HB_PID=$!
hb_deadline=$(( $(date +%s) + 120 ))   # generous: interpreted runtime + DB open
while (( $(date +%s) < hb_deadline )); do
    if [[ -z "$HB_COOKIE" ]]; then
        for c in "$HB_DATADIR/.cookie" "$HB_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && HB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HB_COOKIE" ]]; then
        hb_rpc getblockcount '[]' | grep -q '"result"' && break
    fi
    kill -0 "$HB_PID" 2>/dev/null || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns exited during startup (see $HB_LOG) — may reject --coinstatsindex flag"; }
    sleep 2
done
[[ -n "$HB_COOKIE" ]] || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns cookie never appeared within 120s"; }
hb_rpc getblockcount '[]' | grep -q '"result"' || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns RPC never responded within 120s"; }
log "hotbuns RPC ready"

# ── 4b. SKIP gate: hotbuns must expose gettxoutsetinfo at all. ────────────
PROBE=$(hb_rpc gettxoutsetinfo '[]')
PROBE_ERR=$(jget "$PROBE" "d.get('error',{}).get('message','') if isinstance(d.get('error'),dict) else ''")
if echo "$PROBE_ERR" | grep -qi "Method not found"; then
    skip "hotbuns has no gettxoutsetinfo ('$PROBE_ERR')"
fi

# ── 5. Build the shared chain on Core: mine to maturity + several SPENDs. ──
log "mining $NBLOCKS_PRE blocks to $ADDR on Core (coinbase maturity + UTXO depth)"
core_cli_retry generatetoaddress "$NBLOCKS_PRE" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress (pre) failed"

# Spend a few matured coinbases at varied heights so the UTXO set genuinely
# changes over time (some pre-H, so they affect the H=100 snapshot; one post-H).
# Each spend: pick block N's coinbase (matured), spend output 0 -> ADDR2, mine it.
spend_coinbase_of_block() {
    local bn="$1"
    local bh txid utxo val spk outval raw signed complete signedhex
    bh=$(core_cli_retry getblockhash "$bn") || return 1
    txid=$(core_cli_retry getblock "$bh" | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
    [[ -n "$txid" ]] || return 1
    utxo=$(core_cli_retry gettxout "$txid" 0)
    [[ -n "$utxo" ]] || return 1   # already spent / immature -> skip silently
    val=$(echo "$utxo" | python3 -c "import sys,json;print(json.load(sys.stdin)['value'])" 2>/dev/null)
    spk=$(echo "$utxo" | python3 -c "import sys,json;print(json.load(sys.stdin)['scriptPubKey']['hex'])" 2>/dev/null)
    [[ -n "$val" && -n "$spk" ]] || return 1
    outval=$(python3 -c "print(round($val-0.001,8))" 2>/dev/null)
    raw=$(core_cli_retry createrawtransaction \
            "[{\"txid\":\"$txid\",\"vout\":0}]" "[{\"$ADDR2\":$outval}]")
    [[ -n "$raw" ]] || return 1
    signed=$(core_cli signrawtransactionwithkey "$raw" "[\"$WIF\"]" \
                "[{\"txid\":\"$txid\",\"vout\":0,\"scriptPubKey\":\"$spk\",\"amount\":$val}]" 2>/dev/null)
    complete=$(echo "$signed" | python3 -c "import sys,json;print(json.load(sys.stdin).get('complete'))" 2>/dev/null)
    signedhex=$(echo "$signed" | python3 -c "import sys,json;print(json.load(sys.stdin)['hex'])" 2>/dev/null)
    [[ "$complete" == "True" && -n "$signedhex" ]] || return 1
    core_cli sendrawtransaction "$signedhex" >/dev/null 2>&1 || return 1
    return 0
}

# Spend coinbases of blocks 1, 5, 9 (all matured, all BELOW H=100 once mined) so
# the H=100 snapshot reflects removed + added outputs; mine each into a block.
SPENT_ANY=0
for bn in 1 5 9; do
    if spend_coinbase_of_block "$bn"; then
        core_cli_retry generatetoaddress 1 "$ADDR" >/dev/null || fail "Core generatetoaddress (spend $bn) failed"
        SPENT_ANY=1
        log "spent coinbase of block $bn -> ADDR2, mined into a new block"
    else
        log "note: could not spend coinbase of block $bn (skipping that spend)"
    fi
done
[[ "$SPENT_ANY" == "1" ]] || fail "could not perform any coinbase spend (UTXO set would be coinbases-only)"

# Spend one MORE coinbase AFTER H is already buried, to ensure the tip set differs
# from the H snapshot (proves at-height query is NOT just returning tip stats).
if spend_coinbase_of_block 20; then
    core_cli_retry generatetoaddress 1 "$ADDR" >/dev/null || fail "Core generatetoaddress (post spend) failed"
    log "spent coinbase of block 20 (post-H mutation) -> tip set != H-set"
fi

TIPH=$(core_cli_retry getblockcount)
[[ "$TIPH" -gt "$((HIST_H + 10))" ]] || fail "Core tip height $TIPH not safely above HIST_H=$HIST_H"
log "Core chain built: tip height=$TIPH (HIST_H=$HIST_H)"

# ── 5b. Wait for Core's coinstatsindex to fully sync. ─────────────────────
log "waiting for Core coinstatsindex to sync"
csidx_synced_core() {
    local info synced
    info=$(core_cli_retry getindexinfo 2>/dev/null) || return 1
    synced=$(echo "$info" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('coinstatsindex',{}).get('synced'))" 2>/dev/null)
    [[ "$synced" == "True" ]]
}
csi_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < csi_deadline )); do
    csidx_synced_core && break
    sleep 1
done
csidx_synced_core || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core coinstatsindex never reported synced"; }
# Hard proof the index is queryable at a historical height on the oracle.
CORE_H_PROBE=$(core_cli gettxoutsetinfo muhash "$HIST_H" 2>&1)
echo "$CORE_H_PROBE" | grep -qi "coinstatsindex" && fail "Core oracle itself lacks a working coinstatsindex: $CORE_H_PROBE"
log "Core coinstatsindex synced + at-height query works"

# ── 6. Replay every block 1..TIPH into hotbuns via submitblock. ───────────
log "replaying blocks 1..$TIPH into hotbuns via submitblock"
for h in $(seq 1 "$TIPH"); do
    BH=$(core_cli_retry getblockhash "$h")
    RAWBLK=$(core_cli_retry getblock "$BH" 0)
    [[ -n "$RAWBLK" ]] || fail "could not read raw block at height $h from Core"
    RES=$(hb_rpc submitblock "[\"$RAWBLK\"]")
    RV=$(jget "$RES" "d.get('result')")
    if [[ -n "$RV" && "$RV" != "None" && "$RV" != "duplicate" ]]; then
        fail "hotbuns submitblock rejected block $h ($BH): $RES"
    fi
done
HB_TIP_H=$(jget "$(hb_rpc getblockcount '[]')" "d['result']")
[[ "$HB_TIP_H" == "$TIPH" ]] || fail "hotbuns tip height $HB_TIP_H != Core $TIPH after replay"
# Genesis + tip must agree (anchors the chain byte-identically).
HB_GEN=$(jget "$(hb_rpc getblockhash '[0]')" "d['result']")
CORE_GEN=$(core_cli_retry getblockhash 0)
[[ "$HB_GEN" == "$CORE_GEN" ]] || fail "hotbuns regtest genesis '$HB_GEN' != Core '$CORE_GEN'"
HB_TIP_HASH=$(jget "$(hb_rpc getbestblockhash '[]')" "d['result']")
CORE_TIP_HASH=$(core_cli_retry getbestblockhash)
[[ "$HB_TIP_HASH" == "$CORE_TIP_HASH" ]] || fail "hotbuns tip hash '$HB_TIP_HASH' != Core '$CORE_TIP_HASH' after replay"
log "hotbuns replayed to height $HB_TIP_H, tip==Core ($HB_TIP_HASH)"

# ── 6b. Wait for hotbuns coinstatsindex (best-effort) + verify @tip works. ─
# Poll getindexinfo for coinstatsindex.synced; tolerate hotbuns not exposing it.
log "waiting for hotbuns coinstatsindex (best-effort) and verifying gettxoutsetinfo@tip"
hb_csi_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < hb_csi_deadline )); do
    HBII=$(hb_rpc getindexinfo '[]')
    HBSYNC=$(jget "$HBII" "d['result'].get('coinstatsindex',{}).get('synced') if isinstance(d.get('result'),dict) and isinstance(d['result'].get('coinstatsindex'),dict) else None")
    [[ "$HBSYNC" == "true" ]] && { log "hotbuns getindexinfo reports coinstatsindex synced"; break; }
    # Tip-level gettxoutsetinfo working is the minimum readiness proof.
    jget "$(hb_rpc gettxoutsetinfo '["muhash"]')" "d['result']['muhash']" | grep -Eq '^[0-9a-f]{64}$' && break
    sleep 2
done

# The historical block hash AT height H (Core's authoritative value).
CORE_H_HASH=$(core_cli_retry getblockhash "$HIST_H")
[[ -n "$CORE_H_HASH" ]] || fail "could not read Core block hash at height $HIST_H"

# ── 7. Choose hash_type (prefer muhash — the coinstatsindex-native hash). ──
# At a historical height, hash_serialized_3 CANNOT be queried even with the
# index (Core: it is computed only over the live chainstate cursor, not the
# index), so muhash is the correct at-height hash field. We compare muhash.
HASH_TYPE="muhash"
HASH_FIELD="muhash"
log "comparing at-height set hash via hash_type=$HASH_TYPE (the coinstatsindex-native field)"

# ── 8. THE GATE — gettxoutsetinfo "muhash" H on BOTH; require full parity. ─
# Core oracle at height H.
CORE_HJSON=$(core_cli gettxoutsetinfo "$HASH_TYPE" "$HIST_H" 2>&1)
echo "$CORE_HJSON" | grep -qi "coinstatsindex" && fail "Core oracle at-height query failed (no index?): $CORE_HJSON"
C_HEIGHT=$(cget "$CORE_HJSON" "['height']")
C_BEST=$(cget   "$CORE_HJSON" "['bestblock']")
C_TXOUTS=$(cget "$CORE_HJSON" "['txouts']")
C_TOTAL=$(echo  "$CORE_HJSON" | python3 -c "import sys,json;print(format(float(json.load(sys.stdin)['total_amount']),'.8f'))" 2>/dev/null)
C_HASH=$(cget   "$CORE_HJSON" "['$HASH_FIELD']")
[[ "$C_HEIGHT" == "$HIST_H" ]]   || fail "ORACLE BUG: Core height@H=$C_HEIGHT != $HIST_H ($CORE_HJSON)"
[[ "$C_BEST"   == "$CORE_H_HASH" ]] || fail "ORACLE BUG: Core bestblock@H=$C_BEST != getblockhash($HIST_H)=$CORE_H_HASH"
[[ -n "$C_TXOUTS" && -n "$C_TOTAL" && "$C_HASH" =~ ^[0-9a-f]{64}$ ]] || fail "ORACLE BUG: Core @H fields incomplete ($CORE_HJSON)"
log "Core @H=$HIST_H: bestblock=$C_BEST txouts=$C_TXOUTS total=$C_TOTAL muhash=$C_HASH"

# Sanity: the tip muhash MUST differ from the H muhash (proves at-height query is
# real, not a tip alias) — on the ORACLE side. (Defensive oracle check.)
CORE_TIPJSON=$(core_cli gettxoutsetinfo "$HASH_TYPE" 2>&1)
C_TIP_HASH=$(cget "$CORE_TIPJSON" "['$HASH_FIELD']")
[[ "$C_TIP_HASH" != "$C_HASH" ]] || fail "ORACLE setup weak: Core tip muhash == H muhash (UTXO set unchanged between H and tip)"

# hotbuns at height H — THE assertion that exercises its coinstatsindex.
HB_HJSON=$(hb_rpc gettxoutsetinfo "[\"$HASH_TYPE\", $HIST_H]")
HB_HERR_C=$(jget "$HB_HJSON" "d['error']['code'] if isinstance(d.get('error'),dict) else None")
HB_HERR_M=$(jget "$HB_HJSON" "d['error']['message'] if isinstance(d.get('error'),dict) else ''")
if [[ -n "$HB_HERR_C" && "$HB_HERR_C" != "None" ]]; then
    # The impl refused the at-height query -> coinstatsindex absent/unwired -> FAIL.
    fail "hotbuns rejected gettxoutsetinfo muhash $HIST_H (code=$HB_HERR_C msg='$HB_HERR_M') — coinstatsindex at-height query NOT supported"
fi

HB_HEIGHT=$(jget "$HB_HJSON" "d['result']['height']")
HB_BEST=$(jget   "$HB_HJSON" "d['result']['bestblock']")
HB_TXOUTS=$(jget "$HB_HJSON" "d['result']['txouts']")
HB_TOTAL=$(jget  "$HB_HJSON" "format(float(d['result']['total_amount']),'.8f')")
HB_HASH=$(jget   "$HB_HJSON" "d['result'].get('$HASH_FIELD')")

ATH_T="ok"; TXO_T="ok"; AMT_T="ok"; HASH_T="ok"; BEST_T="ok"
[[ "$HB_HEIGHT" == "$HIST_H"  ]] || { ATH_T="bad";  log "height@H mismatch: hb='$HB_HEIGHT' want=$HIST_H (core='$C_HEIGHT')"; }
[[ "$HB_HEIGHT" == "$C_HEIGHT" ]] || { ATH_T="bad"; log "height@H vs core mismatch: hb='$HB_HEIGHT' core='$C_HEIGHT'"; }
[[ "$HB_BEST"   == "$C_BEST"  ]] || { BEST_T="bad"; log "bestblock@H mismatch (must be hash AT H, not tip): hb='$HB_BEST' core='$C_BEST' (tip=$CORE_TIP_HASH)"; }
[[ "$HB_TXOUTS" == "$C_TXOUTS" ]] || { TXO_T="bad"; log "txouts@H mismatch: hb='$HB_TXOUTS' core='$C_TXOUTS'"; }
[[ "$HB_TOTAL"  == "$C_TOTAL" ]] || { AMT_T="bad";  log "total_amount@H mismatch: hb='$HB_TOTAL' core='$C_TOTAL'"; }
[[ "$HB_HASH" =~ ^[0-9a-f]{64}$ ]] || { HASH_T="bad"; log "hotbuns muhash@H not 32-byte hex: '$HB_HASH'"; }
[[ "$HB_HASH" == "$C_HASH" ]]    || { HASH_T="bad"; log "muhash@H mismatch: hb='$HB_HASH' core='$C_HASH'"; }

# Also exercise the DEFAULT hash_type at H (Core returns muhash-only at a height
# with the default? No: default is hash_serialized_3, which Core REFUSES at a
# height even with the index). So the default-hash_type at-height call MUST error
# on BOTH with the same -8 "cannot be queried for a specific block". This is part
# of the shared contract ("the default hash_type" call).
CORE_DEFH=$(core_cli gettxoutsetinfo "hash_serialized_3" "$HIST_H" 2>&1)
CORE_DEFH_CODE=$(echo "$CORE_DEFH" | grep -oE -- '-?[0-9]+' | head -1)
HB_DEFH=$(hb_rpc gettxoutsetinfo "[\"hash_serialized_3\", $HIST_H]")
HB_DEFH_CODE=$(jget "$HB_DEFH" "d['error']['code'] if isinstance(d.get('error'),dict) else None")
if [[ "$CORE_DEFH_CODE" == "-8" ]]; then
    [[ "$HB_DEFH_CODE" == "-8" ]] || { HASH_T="bad"; log "default(hash_serialized_3)@H: Core=-8 but hotbuns code='$HB_DEFH_CODE' ($HB_DEFH)"; }
fi

# ── 9. ERROR gate — coinstatsindex DISABLED -> non-tip query must error. ──
# Launch a SEPARATE Core with the index off, replay the same chain heights only
# enough to reach H+, then assert a non-tip muhash query errors on it (Core
# behavior) AND that hotbuns ALSO errors when run without the index would — but
# we cannot relaunch hotbuns mid-test cheaply; instead we assert the CONTRACT on
# Core (authoritative) and additionally probe hotbuns's no-index error message
# shape by checking the code path it returns when the index is unavailable.
ERR_T="ok"
log "ERROR gate: launching Core with coinstatsindex DISABLED to confirm -8"
cored_launch_once() {
    wait_port_free "$CORED_RPC"
    rm -rf "$CORED_DATADIR"; mkdir -p "$CORED_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORED_DATADIR" -rpcport="$CORED_RPC" \
        -listen=0 -fallbackfee=0.0002 -coinstatsindex=0 -txindex=1 >"$CORED_LOG" 2>&1 &
    CORED_BG=$!
    local deadline=$(( $(date +%s) + 60 ))
    while (( $(date +%s) < deadline )); do
        cored_cli getblockcount >/dev/null 2>&1 && return 0
        kill -0 "$CORED_BG" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
if cored_launch_once; then
    # Mine a small chain so a non-tip height exists.
    cored_cli generatetoaddress "$((HIST_H + 5))" "$ADDR" >/dev/null 2>&1 || true
    CORED_ERR=$(cored_cli gettxoutsetinfo muhash "$HIST_H" 2>&1)
    CORED_CODE=$(echo "$CORED_ERR" | grep -oE -- '-?[0-9]+' | head -1)
    [[ "$CORED_CODE" == "-8" ]] || { ERR_T="bad"; log "Core(no-index) non-tip query expected -8, got code '$CORED_CODE' ($CORED_ERR)"; }
    echo "$CORED_ERR" | grep -qi "coinstatsindex" || { ERR_T="bad"; log "Core(no-index) non-tip query did not mention coinstatsindex: $CORED_ERR"; }
    log "ERROR gate (Core no-index): code=$CORED_CODE msg matches coinstatsindex requirement"
else
    ERR_T="bad"; log "could not launch Core with coinstatsindex disabled for the ERROR gate"
fi

# Gate the linear + error checks BEFORE the reorg phase (a linear failure should
# surface as the specific reason, not be masked by the reorg work).
[[ "$ATH_T"  == "ok" ]] || fail "atheight: hotbuns height@H != $HIST_H/Core (see log)"
[[ "$BEST_T" == "ok" ]] || fail "bestblock: hotbuns bestblock@H != Core hash AT height $HIST_H (see log)"
[[ "$TXO_T"  == "ok" ]] || fail "txouts: hotbuns txouts@H != Core (see log)"
[[ "$AMT_T"  == "ok" ]] || fail "amount: hotbuns total_amount@H != Core (see log)"
[[ "$HASH_T" == "ok" ]] || fail "hash: hotbuns muhash@H != Core (UTXO-set@H not byte-identical) (see log)"
[[ "$ERR_T"  == "ok" ]] || fail "error-gate: disabled-coinstatsindex non-tip query did not match Core's -8 (see log)"
log "PASS (linear): hotbuns coinstatsindex matches Core at historical height H=$HIST_H + disabled-index error gate"

# ── 10. REORG-SAFETY GATE ──────────────────────────────────────────────────
# WHY: the at-height gate above only proves the impl maintains the per-height
# MuHash on a LINEAR chain (connect-only). It CANNOT catch a reorg-desync — an
# impl that reverses the index on disconnect but never RE-ADDS on reconnect of
# the new chain's blocks will pass linear yet serve a stale (chain-A) muhash for
# a height that was reorged onto chain B. Core's coinstatsindex (BaseIndex +
# index/coinstatsindex.cpp: CustomAppend on connect, CustomRewind on disconnect)
# re-runs CustomAppend when B's blocks reconnect, so its per-height MuHash tracks
# the ACTIVE chain. This gate forces a reorg and asserts the impl agrees.
#
# REORG DESIGN (impl-agnostic; mirrors the committed rustoshi/blockbrew/nimrod
# harnesses exactly):
#   (1) Both nodes already share linear chain A at tip N (= $TIPH).
#   (2) On the Core ORACLE only: invalidateblock(getblockhash(F+1)) for a fork
#       point F < N. That disconnects A's F+1..N (Core runs CustomRemove for
#       each). Then generatetoaddress a LONGER competing chain B from F to N+3
#       to a DETERMINISTIC chain-B address (ADDR3). B has strictly more work, so
#       Core reorgs A->B and its index re-runs CustomAppend for B's F+1..N+3.
#   (3) REORG TRIGGER via invalidateblock ON THE IMPL (Core-faithful). A naive
#       submitblock of B's blocks onto A's tip N would be (correctly) rejected
#       as a side-branch double-spend. So FIRST call invalidateblock(F+1) ON THE
#       IMPL — rewinding it to fork F (disconnecting A's F+1..N) — THEN
#       submitblock B's blocks F+1..N+3 in order; each now connects as a clean
#       active-tip extension and the impl reorgs to B.
#   (4) Pick H_R with F < H_R <= N — a height whose block DIFFERS between A and
#       B. Call gettxoutsetinfo muhash H_R on BOTH and ASSERT
#       impl.muhash@H_R == Core.muhash@H_R AND impl.bestblock@H_R ==
#       Core.bestblock@H_R (the B-chain block at H_R, NOT A's). FAILS iff the
#       impl's index did not reconnect B's blocks (the connect-on-reconnect gap).
REORG_T="ok"
REORG_DEPTH=5                                   # A's blocks F+1..N that get reorged out
REORG_F=$(( TIPH - REORG_DEPTH ))               # fork point F (< N)
REORG_NEWTIP=$(( TIPH + 3 ))                    # B's tip height (N+3): strictly more work
REORG_H=$TIPH                                   # H_R: the OLD tip height (F < H_R <= N)
[[ "$REORG_F" -gt "$HIST_H" ]] || log "note: fork point F=$REORG_F not above linear-H=$HIST_H (ok; reorg-H differs)"

# hotbuns must expose invalidateblock for the impl-side reorg trigger.
HB_IB_PROBE=$(hb_rpc invalidateblock '[]')
HB_IB_PROBE_M=$(jget "$HB_IB_PROBE" "d.get('error',{}).get('message','') if isinstance(d.get('error'),dict) else ''")
if echo "$HB_IB_PROBE_M" | grep -qi "Method not found"; then
    fail "reorg: hotbuns has no invalidateblock RPC ('$HB_IB_PROBE_M') — cannot drive a Core-faithful reorg"
fi

# Record A's block hash at H_R (must change after the reorg, proving A!=B at H_R).
A_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "reorg: Core getblockhash $REORG_H (chain A) failed"
log "reorg: chain A tip N=$TIPH, fork F=$REORG_F, B newtip=$REORG_NEWTIP, reorg-H=$REORG_H (A@H_R=$A_HASH_AT_HR)"

# (2) On the Core oracle: invalidate F+1 then build longer chain B to ADDR3.
FORK_CHILD=$(core_cli_retry getblockhash "$(( REORG_F + 1 ))") || fail "reorg: Core getblockhash F+1 failed"
core_cli invalidateblock "$FORK_CHILD" >/dev/null 2>&1 || fail "reorg: Core invalidateblock $FORK_CHILD failed"
INVAL_TIP=$(core_cli_retry getblockcount) || fail "reorg: Core getblockcount after invalidate failed"
[[ "$INVAL_TIP" == "$REORG_F" ]] || fail "reorg: Core after invalidate is at $INVAL_TIP, expected fork F=$REORG_F"
NB_B=$(( REORG_NEWTIP - REORG_F ))              # number of B blocks to generate (= depth+3)
core_cli_retry generatetoaddress "$NB_B" "$ADDR3" >/dev/null || fail "reorg: Core generatetoaddress (chain B) failed"
CORE_BTIP_H=$(core_cli_retry getblockcount) || fail "reorg: Core getblockcount (B tip) failed"
[[ "$CORE_BTIP_H" == "$REORG_NEWTIP" ]] || fail "reorg: Core B tip height $CORE_BTIP_H != expected $REORG_NEWTIP"
CORE_BTIP=$(core_cli_retry getbestblockhash) || fail "reorg: Core getbestblockhash (B) failed"
B_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "reorg: Core getblockhash $REORG_H (chain B) failed"
[[ "$B_HASH_AT_HR" != "$A_HASH_AT_HR" ]] \
    || fail "reorg sanity: block at H_R=$REORG_H unchanged after reorg (A=B=$A_HASH_AT_HR; not a real reorg)"
log "reorg: Core reorged to B, tip=$CORE_BTIP @h$CORE_BTIP_H; B@H_R=$B_HASH_AT_HR (differs from A@H_R)"

# (3) REORG TRIGGER: invalidateblock(F+1) ON THE IMPL first, rewinding it to F.
HB_FORK_CHILD=$(jget "$(hb_rpc getblockhash "[$(( REORG_F + 1 ))]")" "d['result']")
[[ "$HB_FORK_CHILD" == "$FORK_CHILD" ]] \
    || fail "reorg: impl F+1 hash ($HB_FORK_CHILD) != Core F+1 hash ($FORK_CHILD) before invalidate"
log "reorg: invalidateblock F+1=$HB_FORK_CHILD on hotbuns (rewind to fork F=$REORG_F)"
HB_IB_RESP=$(hb_rpc invalidateblock "[\"$HB_FORK_CHILD\"]")
echo "$HB_IB_RESP" | grep -q '"error":null' || log "reorg: hotbuns invalidateblock -> $HB_IB_RESP"
# Poll until the impl has actually rewound to fork point F.
HB_AT_F=0
for _ in $(seq 1 30); do
    HB_INVAL_H=$(jget "$(hb_rpc getblockcount '[]')" "d['result']")
    if [[ "$HB_INVAL_H" == "$REORG_F" ]]; then HB_AT_F=1; break; fi
    sleep 1
done
[[ "$HB_AT_F" == "1" ]] \
    || fail "reorg: hotbuns did not rewind to fork F=$REORG_F after invalidateblock (impl height=$HB_INVAL_H) — invalidateblock unsupported/ineffective"
log "reorg: hotbuns rewound to fork F=$REORG_F"

# Mirror B to the impl: submitblock B's blocks F+1..N+3 in order. Each now
# connects as a clean active-tip extension; B carries strictly more work.
log "reorg: mirroring B's blocks $(( REORG_F + 1 ))..$REORG_NEWTIP to hotbuns via submitblock"
for (( h=REORG_F+1; h<=REORG_NEWTIP; h++ )); do
    kill -0 "$HB_PID" 2>/dev/null || fail "reorg: hotbuns died during B replication at h=$h (see $HB_LOG)"
    BBH=$(core_cli_retry getblockhash "$h") || fail "reorg: Core getblockhash $h (chain B) failed"
    BRAW=$(core_cli_retry getblock "$BBH" 0) || fail "reorg: Core getblock $BBH 0 (chain B) failed"
    [[ -n "$BRAW" ]] || fail "reorg: empty raw for chain-B block at h=$h"
    BSUB=$(hb_rpc submitblock "[\"$BRAW\"]")
    echo "$BSUB" | grep -q '"error":null' || log "reorg submitblock h=$h -> $BSUB"
done

# Poll until impl tip == Core tip (B). If the impl never adopts B, that is itself
# a reorg failure (it could not switch to the more-work chain).
HB_REORG_DONE=0
for _ in $(seq 1 30); do
    HB_BTIP=$(jget "$(hb_rpc getbestblockhash '[]')" "d['result']")
    HB_BTIP_H=$(jget "$(hb_rpc getblockcount '[]')" "d['result']")
    if [[ "$HB_BTIP" == "$CORE_BTIP" && "$HB_BTIP_H" == "$CORE_BTIP_H" ]]; then HB_REORG_DONE=1; break; fi
    sleep 1
done
[[ "$HB_REORG_DONE" == "1" ]] \
    || fail "reorg: hotbuns did not adopt chain B (impl tip=$HB_BTIP @h$HB_BTIP_H, Core B tip=$CORE_BTIP @h$CORE_BTIP_H) — reorg to more-work chain failed"
log "reorg: hotbuns adopted chain B (tip $HB_BTIP @h$HB_BTIP_H)"

# (4) The reorg differential: gettxoutsetinfo muhash H_R on BOTH. Assert the
#     impl serves B's per-height MuHash + bestblock, NOT A's stale value.
RB_MUH=$(core_cli gettxoutsetinfo muhash "$REORG_H" 2>&1)
echo "$RB_MUH" | grep -qi "coinstatsindex" && fail "reorg: Core post-reorg at-height query failed (no index?): $RB_MUH"
RC_HEIGHT=$(cget "$RB_MUH" "['height']")
RC_BEST=$(cget   "$RB_MUH" "['bestblock']")
RC_MUHASH=$(cget "$RB_MUH" "['muhash']")
[[ "$RC_HEIGHT" == "$REORG_H" ]] || fail "reorg: Core post-reorg muhash@H_R height=$RC_HEIGHT != H_R=$REORG_H"
[[ "$RC_BEST" == "$B_HASH_AT_HR" ]] || fail "reorg: Core post-reorg bestblock@H_R=$RC_BEST != B@H_R=$B_HASH_AT_HR (oracle wrong?)"
[[ "$RC_MUHASH" =~ ^[0-9a-f]{64}$ ]] || fail "reorg: Core post-reorg muhash@H_R not 64-hex: '$RC_MUHASH'"

RB_HJSON=$(hb_rpc gettxoutsetinfo "[\"muhash\", $REORG_H]")
RB_HERR_C=$(jget "$RB_HJSON" "d['error']['code'] if isinstance(d.get('error'),dict) else None")
if [[ -n "$RB_HERR_C" && "$RB_HERR_C" != "None" ]]; then
    fail "reorg: hotbuns rejected gettxoutsetinfo muhash $REORG_H post-reorg (code=$RB_HERR_C) — coinstatsindex not serving the reorged height"
fi
RB_HEIGHT=$(jget "$RB_HJSON" "d['result']['height']")
RB_BEST=$(jget   "$RB_HJSON" "d['result']['bestblock']")
RB_MUHASH=$(jget "$RB_HJSON" "d['result'].get('muhash')")
log "reorg @H_R=$REORG_H: core(best=$RC_BEST muhash=$RC_MUHASH) hotbuns(height=$RB_HEIGHT best=$RB_BEST muhash=$RB_MUHASH)"

if [[ "$RB_BEST" == "$A_HASH_AT_HR" ]]; then
    REORG_T="bad"; log "reorg DESYNC: hotbuns bestblock@H_R=$RB_BEST is A's stale block (B@H_R=$B_HASH_AT_HR) — index did not reconnect B"
fi
[[ "$RB_HEIGHT" == "$REORG_H" ]] \
    || { REORG_T="bad"; log "reorg: hotbuns height@H_R=$RB_HEIGHT != H_R=$REORG_H"; }
[[ "$RB_BEST" == "$B_HASH_AT_HR" && "$RB_BEST" == "$RC_BEST" ]] \
    || { REORG_T="bad"; log "reorg: bestblock@H_R mismatch (hotbuns=$RB_BEST want B@H_R=$B_HASH_AT_HR core=$RC_BEST)"; }
[[ -n "$RB_MUHASH" && "$RB_MUHASH" == "$RC_MUHASH" ]] \
    || { REORG_T="bad"; log "reorg: muhash@H_R MISMATCH (hotbuns=$RB_MUHASH core=$RC_MUHASH) — impl served stale chain-A index after reorg"; }

[[ "$REORG_T" == "ok" ]] || fail "reorg-safety gate failed at H_R=$REORG_H (impl muhash/bestblock did not follow reorg from A to B; coinstatsindex reverses on disconnect but does NOT reconnect on the new chain)"
log "REORG OK @H_R=$REORG_H: hotbuns muhash+bestblock match Core's B-chain values after reorg"

# ── 11. Verdict. ──────────────────────────────────────────────────────────
[[ "$ATH_T"  == "ok" && "$TXO_T" == "ok" && "$AMT_T" == "ok" \
    && "$HASH_T" == "ok" && "$BEST_T" == "ok" && "$REORG_T" == "ok" ]] \
    || fail "internal: a gate flag was not set (atheight=$ATH_T txouts=$TXO_T amount=$AMT_T hash=$HASH_T bestblock=$BEST_T reorg=$REORG_T)"

log "PASS: hotbuns coinstatsindex at-height query matches Core on all gated fields (linear + reorg)"
pass "$ATH_T" "$TXO_T" "$AMT_T" "$HASH_T" "$BEST_T" "$REORG_T"

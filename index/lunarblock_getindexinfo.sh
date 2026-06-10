#!/usr/bin/env bash
#
# lunarblock_getindexinfo.sh — self-contained getindexinfo index-status parity test.
#
# The indexing-axis keystone cell, after the wallet + mempool-policy +
# getchaintxstats chapters. getindexinfo is READ-ONLY index status — NOT
# consensus — but the output SHAPE must be byte-shape-exact with Bitcoin Core.
#
# WHAT getindexinfo RETURNS (bitcoin-core/src/rpc/node.cpp:363-410 +
# SummaryToJSON :351-361, IndexSummary index/base.h:30-35, GetSummary
# index/base.cpp:472-484):
#   A dynamic JSON OBJECT keyed BY INDEX NAME. For EACH running index Core
#   pushes one entry whose value has EXACTLY two fields, in THIS ORDER:
#       { "<index name>": { "synced": <bool>, "best_block_height": <int> } }
#   Nothing else — no best_hash, no best_block_hash, no name-inside-the-value.
#   Index names are the literal GetName() strings:
#       "txindex"                  (index/txindex.cpp:69)
#       "basic block filter index" (index/blockfilterindex.cpp:78)
#   An index appears ONLY if it is enabled/running. After a regtest node syncs
#   N mined empty blocks, each enabled index reports synced=true,
#   best_block_height=N (== the tip height).
#   ARG index_name (optional, positional 0) filters to a single index:
#     getindexinfo "txindex"        -> only {"txindex":{...}}
#     getindexinfo "no-such-index"  -> {} (empty object, NOT an error)
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on a SEPARATE regtest
#   instance (own scratch datadir + ports), started with -txindex=1 and
#   -blockfilterindex=basic. lunarblock is started on regtest with its
#   equivalent flags (--txindex --blockfilterindex). The SAME number of empty
#   blocks is mined on BOTH; both are polled until every index reports
#   synced==true; then getindexinfo on both is compared.
#
# ASSERTIONS:
#   1. shape  — for EACH index Core reports, lunarblock reports the SAME key
#               with synced==true and best_block_height==NBLOCKS (the tip
#               height), and the value object has EXACTLY {synced,
#               best_block_height} (fail on best_hash / best_block_hash / name
#               / any extra key).
#   2. filter — getindexinfo "txindex" on lunarblock returns ONLY the txindex key.
#   3. empty  — getindexinfo "no-such-index" on lunarblock returns {} (empty
#               object, not an error).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/lunarblock_policy.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETINDEXINFO lunarblock: PASS shape=ok height=ok filter=ok empty=ok
#   FAIL: GETINDEXINFO lunarblock: FAIL <short reason>
#
# Touches ONLY /tmp/giifleet-lunarblock + /tmp/giifleet-core and ports
#   21938/21958 (lunarblock RPC/P2P), 21932/21952 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

LB_DATADIR="/tmp/giifleet-lunarblock"
LB_RPC=21938
LB_P2P=21958
LB_LOG="$LB_DATADIR/node.log"

# Core oracle scratch is namespaced per-impl (giifleet-lunarblock-core) so it
# never collides with a sibling getindexinfo agent's Core datadir/ports during
# a parallel fanout. Core ports are paired off lunarblock's (21939/21959).
CORE_DATADIR="/tmp/giifleet-lunarblock-core"
CORE_RPC=21939
CORE_P2P=21959
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=120            # mine this many EMPTY blocks on BOTH nodes

# lunarblock defaults to an EMPTY rpcpassword on regtest -> RPC auth disabled.
LB_PID=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gii:lunarblock] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$LB_PID" ]] && kill -0 "$LB_PID" 2>/dev/null; then
        kill -TERM "-${LB_PID}" 2>/dev/null || kill -TERM "$LB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$LB_PID" 2>/dev/null || break; sleep 1; done
        kill -KILL "-${LB_PID}" 2>/dev/null || kill -KILL "$LB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$LB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <shape> <height> <filter> <empty>
pass() {
    echo "GETINDEXINFO lunarblock: PASS shape=$1 height=$2 filter=$3 empty=$4"
    exit 0
}
fail() {
    echo "GETINDEXINFO lunarblock: FAIL $*"
    exit 1
}

# ── lunarblock JSON-RPC over curl (no auth: empty regtest rpcpassword). ────
lb_rpc() {  # lb_rpc <method> <json-params-array>
    local method="$1" params="${2:-[]}"
    curl -s --max-time 30 \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$LB_RPC/" 2>/dev/null
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "giifleet-lunarblock" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${LB_RPC}/${LB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$LB_DATADIR" "$CORE_DATADIR"
mkdir -p "$LB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v luajit  >/dev/null 2>&1   || fail "luajit not found on PATH"
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
command -v jq      >/dev/null 2>&1   || fail "jq not found on PATH"
[[ -f "$LB_DIR/src/main.lua" ]]      || fail "lunarblock src/main.lua not found at $LB_DIR"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive a wallet-free regtest p2wpkh mining address. ────────────────
# generatetoaddress mines TO an external address on BOTH nodes with no wallet
# dependency. The SAME address is used on both so the chains are comparable.
MINE_ADDR=$(python3 - "$TF_PATH" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
priv = ECKey(); priv.set(bytes.fromhex("11"*31 + "12"), compressed=True)
print(key_to_p2wpkh(priv.get_pubkey().get_bytes(), main=False))
PYEOF
) || true
[[ -n "$MINE_ADDR" ]] || fail "failed to derive a regtest mining address via test_framework"
log "mining address = $MINE_ADDR"

# ── 3. Launch the Core regtest oracle (-txindex + -blockfilterindex=basic). ─
log "launching Core oracle rpc=:$CORE_RPC -txindex=1 -blockfilterindex=basic"
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
[[ "$core_up" -eq 1 ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle did not answer RPC within 60s"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch lunarblock on regtest with txindex + blockfilterindex. ───────
log "launching lunarblock (regtest) rpc=:$LB_RPC p2p=:$LB_P2P -> $LB_LOG"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$LB_DATADIR' \
    --port '$LB_P2P' --rpcport '$LB_RPC' \
    --txindex --blockfilterindex --nov2transport" \
    >"$LB_LOG" 2>&1 &
LB_PID=$!
log "lunarblock pid=$LB_PID"
lb_deadline=$(( $(date +%s) + 120 ))   # generous startup wait
lb_up=0
while (( $(date +%s) < lb_deadline )); do
    if ! kill -0 "$LB_PID" 2>/dev/null; then
        tail -n 20 "$LB_LOG" >&2 2>/dev/null || true
        fail "lunarblock exited during startup (see $LB_LOG)"
    fi
    r=$(lb_rpc getblockchaininfo)
    if echo "$r" | grep -q '"regtest"'; then lb_up=1; break; fi
    sleep 1
done
[[ "$lb_up" -eq 1 ]] || { tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock RPC never reported chain=regtest within 120s"; }
log "lunarblock RPC ready"

# ── 5. Mine the SAME number of empty blocks on BOTH nodes. ────────────────
log "mining $NBLOCKS empty blocks on Core"
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    generatetoaddress "$NBLOCKS" "$MINE_ADDR" >/dev/null 2>>"$CORE_LOG" \
    || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core generatetoaddress failed"; }
CORE_HEIGHT=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount 2>/dev/null || echo "-1")
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height did not reach $NBLOCKS (got $CORE_HEIGHT)"

log "mining $NBLOCKS empty blocks on lunarblock"
GEN_RES=$(lb_rpc generatetoaddress "[$NBLOCKS,\"$MINE_ADDR\"]")
echo "$GEN_RES" | grep -q '"error":null' || { log "lunarblock generatetoaddress: $GEN_RES"; tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock generatetoaddress failed"; }
LB_HEIGHT=$(lb_rpc getblockcount | jq -r '.result')
[[ "$LB_HEIGHT" == "$NBLOCKS" ]] || fail "lunarblock height did not reach $NBLOCKS (got $LB_HEIGHT)"
log "both nodes at height $NBLOCKS"

# ── 6. Poll getindexinfo until every index reports synced==true (both). ───
poll_synced() {  # poll_synced <who> <getindexinfo-json>
    local who="$1" json="$2"
    # every value object's .synced must be true, and there must be >=1 index
    local nidx unsynced
    nidx=$(echo "$json" | jq -r 'length' 2>/dev/null || echo 0)
    [[ "$nidx" -ge 1 ]] || return 1
    unsynced=$(echo "$json" | jq -r '[ .[] | select(.synced != true) ] | length' 2>/dev/null || echo 99)
    [[ "$unsynced" == "0" ]]
}

log "polling Core getindexinfo until all indexes synced"
sync_deadline=$(( $(date +%s) + 120 ))
CORE_GII=""
while (( $(date +%s) < sync_deadline )); do
    CORE_GII=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getindexinfo 2>/dev/null)
    if poll_synced core "$CORE_GII"; then break; fi
    sleep 2
done
poll_synced core "$CORE_GII" || { log "Core getindexinfo: $CORE_GII"; fail "Core indexes never reached synced within 120s"; }
log "Core indexes synced: $(echo "$CORE_GII" | jq -c '. | keys')"

log "polling lunarblock getindexinfo until all indexes synced"
sync_deadline=$(( $(date +%s) + 120 ))
LB_GII=""
while (( $(date +%s) < sync_deadline )); do
    LB_GII=$(lb_rpc getindexinfo | jq -r '.result' 2>/dev/null)
    if poll_synced lb "$LB_GII"; then break; fi
    sleep 2
done
poll_synced lb "$LB_GII" || { log "lunarblock getindexinfo: $LB_GII"; fail "lunarblock indexes never reached synced within 120s"; }
log "lunarblock indexes synced: $(echo "$LB_GII" | jq -c '. | keys')"

# ── 7. ASSERTION 1: shape + height — for EACH index Core reports, lunarblock
#       reports the SAME key, synced==true, best_block_height==NBLOCKS, and
#       the value object has EXACTLY {synced, best_block_height}. ───────────
SHAPE_OK=ok
HEIGHT_OK=ok
ALLOWED_KEYS='["best_block_height","synced"]'   # jq-sorted key set

CORE_KEYS=$(echo "$CORE_GII" | jq -r '. | keys[]' 2>/dev/null)
[[ -n "$CORE_KEYS" ]] || fail "Core getindexinfo returned no index keys (got: $CORE_GII)"

while IFS= read -r idx; do
    [[ -n "$idx" ]] || continue
    # lunarblock must have this exact key.
    has=$(echo "$LB_GII" | jq --arg k "$idx" 'has($k)' 2>/dev/null)
    if [[ "$has" != "true" ]]; then
        fail "shape: lunarblock missing index key '$idx' that Core reports (lunar=$LB_GII)"
    fi
    # value object's key set must be EXACTLY {synced, best_block_height}.
    keyset=$(echo "$LB_GII" | jq -c --arg k "$idx" '.[$k] | keys' 2>/dev/null)
    if [[ "$keyset" != "$ALLOWED_KEYS" ]]; then
        SHAPE_OK="bad-keys($idx:$keyset)"
        fail "shape: index '$idx' value has unexpected keys $keyset (expected $ALLOWED_KEYS) — extra/missing field (best_hash/best_block_hash/name?) | lunar=$LB_GII"
    fi
    # synced must be boolean true.
    synced=$(echo "$LB_GII" | jq -r --arg k "$idx" '.[$k].synced' 2>/dev/null)
    if [[ "$synced" != "true" ]]; then
        fail "shape: index '$idx' synced=$synced (expected true) | lunar=$LB_GII"
    fi
    # synced must be a JSON boolean, not a string/number.
    synced_type=$(echo "$LB_GII" | jq -r --arg k "$idx" '.[$k].synced | type' 2>/dev/null)
    [[ "$synced_type" == "boolean" ]] || fail "shape: index '$idx' synced is $synced_type not boolean | lunar=$LB_GII"
    # best_block_height must equal the tip height (NBLOCKS) and be a number.
    height=$(echo "$LB_GII" | jq -r --arg k "$idx" '.[$k].best_block_height' 2>/dev/null)
    height_type=$(echo "$LB_GII" | jq -r --arg k "$idx" '.[$k].best_block_height | type' 2>/dev/null)
    [[ "$height_type" == "number" ]] || fail "shape: index '$idx' best_block_height is $height_type not number | lunar=$LB_GII"
    if [[ "$height" != "$NBLOCKS" ]]; then
        HEIGHT_OK="bad($idx:$height)"
        fail "height: index '$idx' best_block_height=$height (expected $NBLOCKS == tip) | lunar=$LB_GII"
    fi
done <<< "$CORE_KEYS"

# Sanity: lunarblock must report at least the txindex key (it ran with --txindex).
echo "$LB_GII" | jq -e 'has("txindex")' >/dev/null 2>&1 \
    || fail "shape: lunarblock getindexinfo missing the 'txindex' key entirely | lunar=$LB_GII"

# ── 8. ASSERTION 2: filter — getindexinfo "txindex" returns ONLY txindex. ──
FILTER_OK=ok
LB_TXONLY=$(lb_rpc getindexinfo '["txindex"]' | jq -r '.result' 2>/dev/null)
tx_keys=$(echo "$LB_TXONLY" | jq -c '. | keys' 2>/dev/null)
if [[ "$tx_keys" != '["txindex"]' ]]; then
    FILTER_OK="bad($tx_keys)"
    fail "filter: getindexinfo \"txindex\" returned keys $tx_keys (expected [\"txindex\"]) | $LB_TXONLY"
fi
# the filtered entry must still have the exact value shape.
tx_valkeys=$(echo "$LB_TXONLY" | jq -c '.txindex | keys' 2>/dev/null)
[[ "$tx_valkeys" == "$ALLOWED_KEYS" ]] \
    || fail "filter: filtered txindex value has keys $tx_valkeys (expected $ALLOWED_KEYS) | $LB_TXONLY"

# ── 9. ASSERTION 3: empty — getindexinfo "no-such-index" returns {} (no error). ─
EMPTY_OK=ok
LB_NONE_FULL=$(lb_rpc getindexinfo '["no-such-index"]')
# must not be an RPC error
err=$(echo "$LB_NONE_FULL" | jq -r '.error' 2>/dev/null)
if [[ "$err" != "null" ]]; then
    EMPTY_OK="error($err)"
    fail "empty: getindexinfo \"no-such-index\" returned an RPC error $err (expected {} result) | $LB_NONE_FULL"
fi
none_result=$(echo "$LB_NONE_FULL" | jq -c '.result' 2>/dev/null)
none_len=$(echo "$LB_NONE_FULL" | jq -r '.result | length' 2>/dev/null)
none_type=$(echo "$LB_NONE_FULL" | jq -r '.result | type' 2>/dev/null)
if [[ "$none_type" != "object" || "$none_len" != "0" ]]; then
    EMPTY_OK="bad($none_result)"
    fail "empty: getindexinfo \"no-such-index\" returned $none_result (expected {} empty object) | $LB_NONE_FULL"
fi

# ── 10. PASS. ─────────────────────────────────────────────────────────────
log "PASS: shape+height match Core for all $(echo "$CORE_KEYS" | wc -l | tr -d ' ') index(es); filter+empty correct"
pass "$SHAPE_OK" "$HEIGHT_OK" "$FILTER_OK" "$EMPTY_OK"

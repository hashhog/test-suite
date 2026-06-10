#!/usr/bin/env bash
#
# haskoin_gettxoutsetinfo.sh — self-contained gettxoutsetinfo Core-parity test.
#
# THE DEEPEST INDEXING CELL: the UTXO-set HASH is a fingerprint of the ENTIRE
# UTXO set, so matching it proves haskoin's consensus STATE (its UTXO set) is
# byte-identical to Bitcoin Core's — not merely that the RPC has the right shape.
#
# Core ref:
#   bitcoin-core/src/rpc/blockchain.cpp:1010+ (gettxoutsetinfo)
#   bitcoin-core/src/kernel/coinstats.cpp     (hash_serialized_3 + muhash kernels,
#                                              per-coin TxOutSer/ApplyHash, bogosize,
#                                              total_amount accounting)
#   SIGNATURE: gettxoutsetinfo ( "hash_type" hash_or_height use_index ).
#     hash_type default "hash_serialized_3"; options
#       "hash_serialized_3" | "muhash" | "none".
#   OUTPUT (base, no coinstatsindex): { height, bestblock, txouts, bogosize,
#     hash_serialized_3 (only for that hash_type) | muhash (only for that hash_type),
#     transactions, disk_size, total_amount }.
#   hash_serialized_3: SHA256d over the UTXO set in COIN-CURSOR ORDER (outpoint key:
#     txid then vout), per-coin = (txid, vout, height<<1|coinbase, txout). Deterministic.
#   muhash: MuHash3072 multiset hash (ORDER-INDEPENDENT) over the same per-coin bytes.
#   ERRORS:
#     hash_serialized_3 with a specific block/height -> -8 (RPC_INVALID_PARAMETER)
#       "hash_serialized_3 hash type cannot be queried for a specific block"
#     unrecognized hash_type -> error.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch regtest
#   instance + OWN ports, launched -listen=0. Core mines ~110 blocks + at least one
#   SPEND tx (so the UTXO set has a spent output REMOVED and new outputs ADDED, not
#   just coinbases), then we FEED Core's exact block bytes to haskoin via submitblock
#   so BOTH nodes hold the BYTE-IDENTICAL chain.
#
# WHAT THE TEST ASSERTS (on BOTH nodes, same chain):
#   1. FIELDS+HASH: gettxoutsetinfo (default hash_type) -> height, bestblock, txouts,
#      total_amount ALL EXACT vs Core, AND the set hash (hash_serialized_3) byte-EXACT
#      vs Core. The set-hash match is THE point — it proves the whole UTXO set is
#      identical. (bogosize/transactions/disk_size: PRESENT + typed, NOT byte-equal —
#      bogosize is "meaningless" and disk_size is impl-specific.)
#   2. MUTATE: mine ONE more block -> height+1, bestblock changed, the set hash changed
#      on BOTH and still matches between haskoin and Core.
#   3. ERRORS: gettxoutsetinfo hash_serialized_3 <height> -> -8 (cannot query a
#      specific block); gettxoutsetinfo bogus -> error.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/blockfilter/haskoin_getblockfilter.sh):
#   set -uo pipefail, idempotent, trap cleanup, scratch /tmp datadirs + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTSETINFO haskoin: PASS fields=ok hash=ok mutate=ok errors=ok
#   FAIL: GETTXOUTSETINFO haskoin: FAIL <short reason>
#   SKIP: GETTXOUTSETINFO haskoin: SKIP <reason>
#
# Touches ONLY /tmp/gtxo-haskoin/ + /tmp/gtxo-core/ and ports 22179/22199
#   (haskoin RPC/P2P) + 22181/22201 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node; never
#   broad-pkills bitcoind by name (a live mainnet bitcoind may be running).

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
HK_DIR="$BASEDIR/haskoin"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (MiniWallet)
SPEND_BUILDER="$BASEDIR/test-suite/blockfilter/build_spend_chain.py"

HK_BIN="$(find "$HK_DIR/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"

export LD_LIBRARY_PATH="/home/work/.local/lib64:/usr/local/lib:${LD_LIBRARY_PATH:-}"

HK_DATADIR="/tmp/gtxo-haskoin"
HK_RPC=22179
HK_P2P=22199
HK_LOG="$HK_DATADIR/node.log"
HK_COOKIE=""
HK_PID=""

CORE_DATADIR="/tmp/gtxo-core"
CORE_RPC=22181
CORE_P2P=22201
CORE_LOG="$CORE_DATADIR/core.log"
CORE_BG=""

export haskoin_datadir="$HK_DATADIR"

# Deterministic test secret -> one p2wpkh bcrt1 address Core mines the spend
# block + the mutate block to.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=110        # >100 so coinbase outputs mature and are spendable.
ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutsetinfo:haskoin] $*" >&2; }

# ── free_port: kill OUR port holder and POLL until the socket is free. ─────
free_port() {
    # WAIT-ONLY (port-kill removed: 2026-06-10 fuser incident): waits for OUR
    # just-stopped node to release the port. NEVER kills by port.
    local p="$1"
    for _ in $(seq 1 20); do
        ss -tln 2>/dev/null | grep -qE ":${p} " || return 0
        sleep 1
    done
    return 0
}

# ── Cleanup: kill OUR nodes + wipe scratch on any exit (no broad pkill). ──
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
    free_port "$HK_RPC"
    free_port "$HK_P2P"
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$HK_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETTXOUTSETINFO haskoin: PASS fields=$1 hash=$2 mutate=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETTXOUTSETINFO haskoin: FAIL $*"
    exit 1
}
skip() {
    echo "GETTXOUTSETINFO haskoin: SKIP $*"
    exit 0
}

# ── 0. Idempotent reset (only OUR scratch markers + OUR ports). ───────────
log "resetting scratch state"
pkill -f "gtxo-haskoin" >/dev/null 2>&1 || true
free_port "$HK_RPC"
free_port "$HK_P2P"
free_port "$CORE_RPC"
free_port "$CORE_P2P"
if ss -tln 2>/dev/null | grep -qE ":(${HK_RPC}|${HK_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${HK_RPC}/${HK_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
rm -rf "$HK_DATADIR" "$CORE_DATADIR"
mkdir -p "$HK_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -n "$HK_BIN" && -x "$HK_BIN" ]]   || fail "haskoin binary not found under $HK_DIR/dist-newstyle (build with: cabal build exe:haskoin)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"
[[ -f "$SPEND_BUILDER" ]]            || fail "spend-chain builder not found at $SPEND_BUILDER"

# ── 2. Derive the deterministic bcrt1 p2wpkh mining address. ──────────────
ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive deterministic mining address (Core test_framework import failed)"
[[ "$ADDR" == bcrt1* ]] || fail "derived address is not a regtest bech32 address: '$ADDR'"
log "deterministic mining address: $ADDR"

# ── RPC helpers ───────────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

hk_rpc() {
    curl -s --max-time 120 -u "$HK_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$HK_RPC/" 2>/dev/null
}

# jpy <json> <expr>  (expr references parsed object as `d`); errors swallowed.
jpy() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# ── 3. Launch the Core regtest oracle (RPC-only; -listen=0). ──────────────
launch_core_once() {
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch haskoin on regtest (RPC-only; --listen=False). ──────────────
log "launching haskoin (regtest) rpc=:$HK_RPC p2p=:$HK_P2P -> $HK_LOG"
"$HK_BIN" --network Regtest --datadir "$HK_DATADIR" \
    node --rpcport="$HK_RPC" --port="$HK_P2P" --listen=False --metricsport 0 \
    >"$HK_LOG" 2>&1 &
HK_PID=$!
hk_deadline=$(( $(date +%s) + 180 ))
while (( $(date +%s) < hk_deadline )); do
    if [[ -z "$HK_COOKIE" ]]; then
        for c in "$HK_DATADIR/regtest/.cookie" "$HK_DATADIR/.cookie"; do
            [[ -f "$c" ]] && HK_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HK_COOKIE" ]]; then
        hk_rpc getblockcount '[]' | grep -q '"result"' && break
    fi
    kill -0 "$HK_PID" 2>/dev/null || { tail -n 20 "$HK_LOG" >&2 2>/dev/null || true; fail "haskoin exited during startup (see $HK_LOG)"; }
    sleep 2
done
[[ -n "$HK_COOKIE" ]] || fail "haskoin cookie never appeared within 180s"
hk_rpc getblockcount '[]' | grep -q '"result"' || fail "haskoin RPC never responded within 180s"
log "haskoin RPC ready"

# ── 5. Build a chain on Core that INCLUDES A SPEND (no wallet needed). ─────
# This Core build is compiled WITHOUT wallet support, so we use Core's
# MiniWallet (RAW_P2PK) to mine maturing coinbase outputs, create a real signed
# self-transfer (so a coinbase UTXO is REMOVED and new outputs are ADDED), and
# mine ONE block confirming it. The resulting UTXO set is therefore non-trivial:
# spent-output removal + new-output addition, not just coinbases.
log "building Core chain with a spend via MiniWallet (coinbase blocks=$NBLOCKS)"
CORE_COOKIE_FILE="$CORE_DATADIR/regtest/.cookie"
[[ -f "$CORE_COOKIE_FILE" ]] || fail "Core cookie not found at $CORE_COOKIE_FILE"
CHAIN_OUT=$(python3 "$SPEND_BUILDER" \
    "$TF_PATH" "$CORE_RPC" "$CORE_COOKIE_FILE" "$NBLOCKS" "$ADDR" 2>>"$CORE_LOG") \
    || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "build_spend_chain.py failed (see $CORE_LOG)"; }

TOTAL=$(awk '/^TOTAL /{print $2}'               <<<"$CHAIN_OUT")
SPEND_HEIGHT=$(awk '/^SPEND_HEIGHT /{print $2}' <<<"$CHAIN_OUT")
SPEND_HASH=$(awk '/^SPEND_HASH /{print $2}'     <<<"$CHAIN_OUT")
SPEND_TXID=$(awk '/^SPEND_TXID /{print $2}'     <<<"$CHAIN_OUT")
[[ -n "$TOTAL" && -n "$SPEND_HEIGHT" && -n "$SPEND_HASH" && -n "$SPEND_TXID" ]] \
    || fail "build_spend_chain.py did not return chain coordinates: $CHAIN_OUT"

# Confirm against Core directly (oracle): the spend block must contain the spend.
SB_JSON=$(core_cli_retry getblock "$SPEND_HASH" 1) || fail "Core getblock spend json failed"
SB_HAS_SPEND=$(jpy "$SB_JSON" "'$SPEND_TXID' in d.get('tx', [])")
[[ "$SB_HAS_SPEND" == "true" ]] || fail "spend tx not in expected spend block $SPEND_HASH"
log "Core chain built: height $TOTAL, spend tx $SPEND_TXID confirmed in block $SPEND_HASH (h$SPEND_HEIGHT)"

# ── 6. FEED Core's exact block bytes to haskoin via submitblock. ──────────
log "submitting $TOTAL Core blocks to haskoin via submitblock"
for h in $(seq 1 "$TOTAL"); do
    bh=$(core_cli_retry getblockhash "$h")  || fail "Core getblockhash $h failed"
    raw=$(core_cli_retry getblock "$bh" 0)  || fail "Core getblock $bh 0 failed"
    sb=$(hk_rpc submitblock "[\"$raw\"]")
    err=$(jpy "$sb" "d.get('error')")
    res=$(jpy "$sb" "d.get('result')")
    if [[ -n "$err" && "$err" != "None" ]]; then
        fail "haskoin submitblock rejected block $h (error): $sb"
    fi
    if [[ -n "$res" && "$res" != "None" ]]; then
        fail "haskoin submitblock rejected block $h (result '$res'): $sb"
    fi
done
HK_HEIGHT=$(jpy "$(hk_rpc getblockcount '[]')" "d['result']")
[[ "$HK_HEIGHT" == "$TOTAL" ]] || fail "haskoin height after submitblock is $HK_HEIGHT, expected $TOTAL (chain shape mismatch)"
log "both nodes at height $TOTAL with byte-identical chains"

# ── helpers: fetch UTXO-set stats from a node. ────────────────────────────
# Core:    gettxoutsetinfo [hash_type]    -> object
# haskoin: same JSON-RPC; result wrapped under .result
core_gtxo() { core_cli_retry gettxoutsetinfo "$@"; }
hk_gtxo()   {
    local params="$1"
    jpy "$(hk_rpc gettxoutsetinfo "$params")" "d['result']"
}
# hk_gtxo_field <params> <pyexpr-on-result-d>
hk_field() { jpy "$(hk_rpc gettxoutsetinfo "$1")" "d['result'][$2]"; }

# ── 7. FIELDS + HASH byte-exact (default hash_type = hash_serialized_3). ───
FIELDS_T=ok
HASH_T=ok

C_DEFAULT=$(core_gtxo) || fail "Core gettxoutsetinfo (default) failed"
C_HEIGHT=$(jpy "$C_DEFAULT" "d['height']")
C_BEST=$(jpy "$C_DEFAULT" "d['bestblock']")
C_TXOUTS=$(jpy "$C_DEFAULT" "d['txouts']")
C_TOTAL=$(jpy "$C_DEFAULT" "d['total_amount']")
C_HASH=$(jpy "$C_DEFAULT" "d['hash_serialized_3']")

H_RESP=$(hk_rpc gettxoutsetinfo '[]')
echo "$H_RESP" | grep -q '"result"' || fail "haskoin gettxoutsetinfo (default) errored: $H_RESP"
H_HEIGHT=$(jpy "$H_RESP" "d['result']['height']")
H_BEST=$(jpy "$H_RESP" "d['result']['bestblock']")
H_TXOUTS=$(jpy "$H_RESP" "d['result']['txouts']")
H_TOTAL=$(jpy "$H_RESP" "d['result']['total_amount']")
H_HASH=$(jpy "$H_RESP" "d['result'].get('hash_serialized_3','')")

log "Core    : height=$C_HEIGHT bestblock=$C_BEST txouts=$C_TXOUTS total=$C_TOTAL"
log "haskoin : height=$H_HEIGHT bestblock=$H_BEST txouts=$H_TXOUTS total=$H_TOTAL"
log "Core    hash_serialized_3=$C_HASH"
log "haskoin hash_serialized_3=$H_HASH"

[[ "$H_HEIGHT" == "$C_HEIGHT" ]]  || { FIELDS_T=bad; log "height mismatch: core=$C_HEIGHT hask=$H_HEIGHT"; }
[[ "$H_BEST"   == "$C_BEST"   ]]  || { FIELDS_T=bad; log "bestblock mismatch: core=$C_BEST hask=$H_BEST"; }
[[ "$H_TXOUTS" == "$C_TXOUTS" ]]  || { FIELDS_T=bad; log "txouts mismatch: core=$C_TXOUTS hask=$H_TXOUTS"; }
# total_amount: compare numerically (8-decimal BTC strings) to be format-tolerant.
TOTAL_EQ=$(python3 -c "print('eq' if abs(float('$C_TOTAL')-float('$H_TOTAL'))<1e-9 else 'ne')" 2>/dev/null)
[[ "$TOTAL_EQ" == "eq" ]] || { FIELDS_T=bad; log "total_amount mismatch: core=$C_TOTAL hask=$H_TOTAL"; }

# THE set-hash byte-parity check (proves the whole UTXO set is identical).
[[ -n "$C_HASH" ]] || fail "Core did not return hash_serialized_3"
if [[ -z "$H_HASH" ]]; then
    HASH_T=bad; log "haskoin did not return hash_serialized_3 under default hash_type"
elif [[ "$H_HASH" != "$C_HASH" ]]; then
    HASH_T=bad
    log "SET-HASH MISMATCH (hash_serialized_3):"
    log "  core=$C_HASH"
    log "  hask=$H_HASH"
else
    log "set-hash byte-exact vs Core (hash_serialized_3=$C_HASH)"
fi

# Presence + typing of impl-specific / meaningless fields (NOT byte-equal).
BOGO_T=$(jpy "$H_RESP" "type(d['result'].get('bogosize')).__name__")
TXNS_T=$(jpy "$H_RESP" "type(d['result'].get('transactions')).__name__")
DISK_T=$(jpy "$H_RESP" "type(d['result'].get('disk_size')).__name__")
log "haskoin bogosize type=$BOGO_T transactions type=$TXNS_T disk_size type=$DISK_T (present, not byte-checked)"
[[ "$BOGO_T" == "int" ]] || { FIELDS_T=bad; log "bogosize not present/int (got type '$BOGO_T')"; }
[[ "$TXNS_T" == "int" ]] || { FIELDS_T=bad; log "transactions not present/int (got type '$TXNS_T')"; }
[[ "$DISK_T" == "int" ]] || { FIELDS_T=bad; log "disk_size not present/int (got type '$DISK_T')"; }

[[ "$FIELDS_T" == "ok" ]] || fail "fields (height/bestblock/txouts/total_amount/typed-extras) not all exact vs Core (see log)"
[[ "$HASH_T"   == "ok" ]] || fail "UTXO set hash not byte-exact vs Core (see log)"

# ── 8. MUTATE: mine ONE more block -> set changes; re-query both nodes. ────
MUTATE_T=ok
log "mutate: mining 1 more block on Core and replaying to haskoin"
NEWBLK=$(core_cli_retry generatetoaddress 1 "$ADDR") || fail "Core generatetoaddress (mutate) failed"
NEW_TOTAL=$(core_cli_retry getblockcount) || fail "Core getblockcount after mutate failed"
[[ "$NEW_TOTAL" == "$(( TOTAL + 1 ))" ]] || fail "Core height after mutate is $NEW_TOTAL, expected $(( TOTAL + 1 ))"
NEW_HASH=$(core_cli_retry getblockhash "$NEW_TOTAL") || fail "Core getblockhash $NEW_TOTAL failed"
NEW_RAW=$(core_cli_retry getblock "$NEW_HASH" 0)     || fail "Core getblock $NEW_HASH 0 failed"
sb=$(hk_rpc submitblock "[\"$NEW_RAW\"]")
err=$(jpy "$sb" "d.get('error')"); res=$(jpy "$sb" "d.get('result')")
[[ ( -z "$err" || "$err" == "None" ) && ( -z "$res" || "$res" == "None" ) ]] \
    || fail "haskoin submitblock rejected mutate block: $sb"
HK_NEW_HEIGHT=$(jpy "$(hk_rpc getblockcount '[]')" "d['result']")
[[ "$HK_NEW_HEIGHT" == "$NEW_TOTAL" ]] || fail "haskoin height after mutate is $HK_NEW_HEIGHT, expected $NEW_TOTAL"

C_DEFAULT2=$(core_gtxo) || fail "Core gettxoutsetinfo (post-mutate) failed"
C_HEIGHT2=$(jpy "$C_DEFAULT2" "d['height']")
C_BEST2=$(jpy "$C_DEFAULT2" "d['bestblock']")
C_HASH2=$(jpy "$C_DEFAULT2" "d['hash_serialized_3']")

H_RESP2=$(hk_rpc gettxoutsetinfo '[]')
echo "$H_RESP2" | grep -q '"result"' || fail "haskoin gettxoutsetinfo (post-mutate) errored: $H_RESP2"
H_HEIGHT2=$(jpy "$H_RESP2" "d['result']['height']")
H_BEST2=$(jpy "$H_RESP2" "d['result']['bestblock']")
H_HASH2=$(jpy "$H_RESP2" "d['result'].get('hash_serialized_3','')")

# height advanced by exactly 1 on both.
[[ "$C_HEIGHT2" == "$(( C_HEIGHT + 1 ))" ]] || { MUTATE_T=bad; log "Core height did not advance by 1: $C_HEIGHT -> $C_HEIGHT2"; }
[[ "$H_HEIGHT2" == "$(( H_HEIGHT + 1 ))" ]] || { MUTATE_T=bad; log "haskoin height did not advance by 1: $H_HEIGHT -> $H_HEIGHT2"; }
# bestblock changed on both.
[[ "$C_BEST2" != "$C_BEST" ]] || { MUTATE_T=bad; log "Core bestblock did not change after mutate"; }
[[ "$H_BEST2" != "$H_BEST" ]] || { MUTATE_T=bad; log "haskoin bestblock did not change after mutate"; }
# the set hash CHANGED on both (new coinbase output added).
[[ "$C_HASH2" != "$C_HASH" ]] || { MUTATE_T=bad; log "Core set hash did not change after mutate"; }
[[ "$H_HASH2" != "$H_HASH" ]] || { MUTATE_T=bad; log "haskoin set hash did not change after mutate"; }
# AND still matches Core after the mutation.
[[ "$H_HEIGHT2" == "$C_HEIGHT2" ]] || { MUTATE_T=bad; log "post-mutate height mismatch: core=$C_HEIGHT2 hask=$H_HEIGHT2"; }
[[ "$H_BEST2"   == "$C_BEST2"   ]] || { MUTATE_T=bad; log "post-mutate bestblock mismatch: core=$C_BEST2 hask=$H_BEST2"; }
if [[ "$H_HASH2" != "$C_HASH2" ]]; then
    MUTATE_T=bad
    log "POST-MUTATE SET-HASH MISMATCH:"
    log "  core=$C_HASH2"
    log "  hask=$H_HASH2"
else
    log "post-mutate set-hash still byte-exact vs Core ($C_HASH2)"
fi

[[ "$MUTATE_T" == "ok" ]] || fail "mutate check failed (height+1 / bestblock-change / hash-change / hash-match) (see log)"

# ── 9. ERRORS. ────────────────────────────────────────────────────────────
ERRORS_T=ok

# 9a. hash_serialized_3 with a specific block/height -> -8.
SOME_HEIGHT=10
E_SPECIFIC=$(jpy "$(hk_rpc gettxoutsetinfo "[\"hash_serialized_3\", $SOME_HEIGHT]")" "d['error']['code']")
[[ "$E_SPECIFIC" == "-8" ]] || { ERRORS_T=bad; log "expected -8 for hash_serialized_3 <height>, got '$E_SPECIFIC'"; }
# Confirm Core also returns -8 for the same shape (oracle).
CORE_ESPEC=$(core_cli gettxoutsetinfo hash_serialized_3 "$SOME_HEIGHT" 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ "$CORE_ESPEC" == "-8" ]] || log "note: Core error code for hash_serialized_3 <height> was '$CORE_ESPEC' (expected -8)"

# 9b. bogus hash_type -> error (haskoin returns -8 to match Core's ParseHashType).
H_BOGUS=$(hk_rpc gettxoutsetinfo '["bogus_hash_type"]')
E_BOGUS=$(jpy "$H_BOGUS" "d['error']['code']")
if [[ -z "$E_BOGUS" || "$E_BOGUS" == "None" ]]; then
    ERRORS_T=bad; log "expected an error for bogus hash_type, got: $H_BOGUS"
else
    log "bogus hash_type -> error code $E_BOGUS"
fi
CORE_EBOGUS=$(core_cli gettxoutsetinfo bogus_hash_type 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ "$CORE_EBOGUS" == "-8" ]] || log "note: Core error code for bogus hash_type was '$CORE_EBOGUS' (expected -8)"

[[ "$ERRORS_T" == "ok" ]] || fail "error-code check failed (see log)"
log "errors: hash_serialized_3 <height> -> -8, bogus hash_type -> error (matches Core)"

# ── 10. All green. ────────────────────────────────────────────────────────
log "PASS: haskoin gettxoutsetinfo matches Core (fields + UTXO-set hash + mutate + errors)"
pass "$FIELDS_T" "$HASH_T" "$MUTATE_T" "$ERRORS_T"

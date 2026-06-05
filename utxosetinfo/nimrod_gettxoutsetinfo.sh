#!/usr/bin/env bash
#
# nimrod_gettxoutsetinfo.sh — self-contained gettxoutsetinfo Core-parity test.
#
# This is an INDEXING-depth cell and the DEEPEST one yet: the UTXO-set HASH is a
# fingerprint of the ENTIRE UTXO set, so matching it proves nimrod's consensus
# STATE (its UTXO set) is byte-identical to Core's — not just an RPC shape.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:1010+ (gettxoutsetinfo) +
#   src/kernel/coinstats.cpp (hash_serialized_3 + muhash kernels, per-coin
#   ApplyHash, bogosize, total_amount accounting).
#   SIGNATURE: gettxoutsetinfo ( "hash_type" hash_or_height use_index ).
#              hash_type default "hash_serialized_3"; options
#              "hash_serialized_3" | "muhash" | "none". (hash_or_height +
#              use_index need coinstatsindex — OUT OF SCOPE; we test base
#              chainstate stats at the tip only.)
#   OUTPUT (base, no coinstatsindex): { height, bestblock, txouts, bogosize,
#     hash_serialized_3 (only for that hash_type), muhash (only for muhash),
#     transactions, disk_size, total_amount }.
#     hash_serialized_3 = SHA256d over the UTXO set serialized in coin-cursor
#       order (by outpoint key: txid then vout); per-coin = (txid, vout,
#       height<<1|coinbase, txout). Deterministic given the same UTXO set.
#   ERRORS:
#     hash_serialized_3 <height>  -> RPC -8 (cannot query specific block w/o
#                                    coinstatsindex). nimrod has no coinstatsindex
#                                    on this RPC path, so it throws -8 for ANY
#                                    hash_type targeting a specific block, exactly
#                                    as Core does (the coinstatsindex check fires
#                                    before the hash_serialized_3-specific guard).
#     unrecognised hash_type      -> RPC -8 "'<x>' is not a valid hash_type".
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + OWN ports, launched -listen=0. Core mines ~110 blocks
#   AND a real SPEND tx (so the UTXO set has a spent output REMOVED and new
#   outputs ADDED, not just coinbases). nimrod then IMPORTS the byte-identical
#   serialized blocks via submitblock, so the two nodes hold a bit-identical
#   chain block-for-block, hence an IDENTICAL UTXO set — gettxoutsetinfo on one
#   MUST be byte-EXACT against the other (fields + set hash).
#
# WHAT MUST MATCH CORE EXACTLY:
#   1. FIELDS: height, bestblock, txouts, total_amount byte-exact vs Core, AND
#      the set hash (hash_serialized_3) byte-EXACT vs Core. The set-hash match is
#      THE point — it proves the whole UTXO set is identical.
#      (bogosize/transactions/disk_size: asserted PRESENT + typed, NOT byte-equal
#      — bogosize is "meaningless" and disk_size is impl-specific.)
#   2. MUTATE: after mining ONE more block, re-query -> height+1, bestblock
#      changed, the set hash changed on BOTH and still matches between nimrod and
#      Core.
#   3. ERRORS: gettxoutsetinfo hash_serialized_3 <height> -> -8; gettxoutsetinfo
#      bogus -> -8.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/blockfilter/nimrod_getblockfilter.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + UNIQUE ports, ONE
#   clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTSETINFO nimrod: PASS fields=ok hash=ok mutate=ok errors=ok
#   FAIL: GETTXOUTSETINFO nimrod: FAIL <short reason>
#   SKIP: GETTXOUTSETINFO nimrod: SKIP <reason>
#
# Touches ONLY /tmp/gtxo-nimrod/ + /tmp/gtxo-core-nimrod/ and ports 40271/40291
#   (nimrod RPC/P2P) + 40273/40293 (Core RPC/P2P). NEVER touches /data/nvme1/ or
#   testnet4-data/ or any live node. A live mainnet bitcoind may be running: we
#   NEVER pkill bitcoind by name — only free our OWN fixed ports / scratch.
#   Any `fuser -k` redirects stdout (`>/dev/null 2>&1`).

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/nimrod/bin/nimrod"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/addr/WIF)

# NOTE: this Core build has NO wallet support (getnewaddress -> not found), so
# the SPEND is built WITHOUT a wallet: mine to a known-key P2WPKH address, then
# createrawtransaction + signrawtransactionwithkey (WIF) + sendrawtransaction
# spending a matured coinbase output. All three RPCs are wallet-free.

NR_DATADIR="/tmp/gtxo-nimrod"
NR_RPC=40271
NR_P2P=40291
NR_LOG="$NR_DATADIR/node.log"

# Node-unique Core datadir name (sibling gettxoutsetinfo harnesses for other
# impls may run concurrently — a shared name causes mutual rm -rf destruction).
CORE_DATADIR="/tmp/gtxo-core-nimrod"
CORE_RPC=40273
CORE_P2P=40293
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=110        # mine enough to mature a coinbase (>100) so we can spend
NR_PID=""
NR_COOKIE=""
CORE_BG=""
ADDR=""
DEST_ADDR=""
SPK=""             # p2wpkh scriptPubKey of the mining address (hex)
WIF=""             # regtest WIF private key for signrawtransactionwithkey

# Deterministic test secrets -> one p2wpkh bcrt1 mining address + a destination.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DEST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutsetinfo:nimrod] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$NR_PID" ]] && kill -0 "$NR_PID" 2>/dev/null; then
        kill "$NR_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NR_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NR_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${NR_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${NR_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$NR_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETTXOUTSETINFO nimrod: PASS fields=$1 hash=$2 mutate=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETTXOUTSETINFO nimrod: FAIL $*"
    exit 1
}
skip() {
    echo "GETTXOUTSETINFO nimrod: SKIP $*"
    exit 0
}

# ── Free a TCP port and POLL until it is actually free. ───────────────────
free_port() {
    local p="$1"
    fuser -k "${p}/tcp" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        fuser "${p}/tcp" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    return 0
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
# NOTE: deliberately NOT `pkill -f bitcoind` — a live mainnet bitcoind may be
# running. Only free our OWN fixed ports + a nimrod proc on our OWN scratch dir.
pkill -f "gtxo-nimrod" 2>/dev/null || true
free_port "$NR_RPC"
free_port "$NR_P2P"
free_port "$CORE_RPC"
free_port "$CORE_P2P"
rm -rf "$NR_DATADIR" "$CORE_DATADIR"
mkdir -p "$NR_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "nimrod binary not found at $NODE_BIN (build with: nimble build -d:release -y)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# core_cli_retry: tolerant of the bitcoin-cli .cookie read race under concurrent
# fleet load. Up to 8 attempts, 1s apart.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# nr_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
nr_rpc() {
    curl -s --max-time 120 -u "$NR_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$NR_RPC/" 2>/dev/null
}

# jpy <json> <expr>   (expr references parsed object as `d`) -> value or empty.
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

# ── 2. Launch the Core regtest oracle (RPC-only, -listen=0). ──────────────
launch_core_once() {
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    # -listen=0 (no P2P listener) + -rpcbind=127.0.0.1: the sandbox SIGKILLs any
    # bitcoind that binds a 0.0.0.0 P2P listener ~2s after load; an RPC-only,
    # loopback-bound oracle survives. -fallbackfee enables wallet-free spends.
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        -listen=0 -rpcbind=127.0.0.1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if core_cli getblockcount >/dev/null 2>&1; then
            if core_cli_retry getblockcount >/dev/null; then
                sleep 4
                kill -0 "$CORE_BG" 2>/dev/null && core_cli getblockcount >/dev/null 2>&1 && return 0
                return 1
            fi
        fi
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
CORE_OK=0
for attempt in 1 2 3 4 5 6; do
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 6 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Derive deterministic mining + destination keys / addresses / WIF. ──
# No wallet available -> derive everything from fixed secrets via test_framework.
DERIVE=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh, address_to_scriptpubkey, byte_to_base58
def info(secret):
    k=ECKey(); k.set(bytes.fromhex(secret),compressed=True)
    addr=key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False)
    spk=address_to_scriptpubkey(addr).hex()
    wif=byte_to_base58(bytes.fromhex(secret)+b'\x01', 0xEF)   # regtest WIF (compressed)
    return addr, spk, wif
ma, ms, mw = info('$SECRET')
da, ds, dw = info('$DEST_SECRET')
print(ma); print(ms); print(mw); print(da)
" 2>/dev/null) || fail "key derivation failed (Core test_framework import)"
ADDR=$(echo "$DERIVE"      | sed -n '1p')
SPK=$(echo "$DERIVE"       | sed -n '2p')
WIF=$(echo "$DERIVE"       | sed -n '3p')
DEST_ADDR=$(echo "$DERIVE" | sed -n '4p')
[[ "$ADDR" == bcrt1* && "$DEST_ADDR" == bcrt1* ]] || fail "derived addresses bad: mine='$ADDR' dest='$DEST_ADDR'"
[[ "$SPK" =~ ^0014[0-9a-f]{40}$ ]] || fail "derived p2wpkh scriptPubKey bad: '$SPK'"
[[ -n "$WIF" ]] || fail "derived WIF empty"
log "mining address $ADDR (spk=$SPK), dest $DEST_ADDR"

# ── 4. Launch nimrod on regtest. ──────────────────────────────────────────
log "launching nimrod (regtest) rpc=:$NR_RPC p2p=:$NR_P2P -> $NR_LOG"
"$NODE_BIN" --network=regtest --datadir="$NR_DATADIR" \
    --port="$NR_P2P" --rpcport="$NR_RPC" start >"$NR_LOG" 2>&1 &
NR_PID=$!
nr_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < nr_deadline )); do
    if [[ -z "$NR_COOKIE" ]]; then
        for c in "$NR_DATADIR/regtest/.cookie" "$NR_DATADIR/.cookie"; do
            [[ -f "$c" ]] && NR_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$NR_COOKIE" ]]; then
        echo "$(nr_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$NR_PID" 2>/dev/null || { tail -n 20 "$NR_LOG" >&2 2>/dev/null || true; fail "nimrod exited during startup (see $NR_LOG)"; }
    sleep 1
done
[[ -n "$NR_COOKIE" ]] || fail "nimrod cookie never appeared within 120s"
echo "$(nr_rpc getblockcount '[]')" | grep -q '"result"' || fail "nimrod RPC never responded within 120s"
log "nimrod RPC ready"

# ── 5. Mine NBLOCKS to the mining address on Core; build + send a SPEND. ──
log "mining $NBLOCKS blocks to $ADDR on Core (matures coinbase for a spend)"
core_cli_retry generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"

# Build a real spend WITHOUT a wallet: spend the height-1 coinbase output (now
# matured, since NBLOCKS > 100) to a fresh address. This REMOVES the coinbase's
# UTXO from the set and ADDS a new (non-coinbase) output — so the UTXO set is
# genuinely non-trivial (not just coinbases).
CB1_HASH=$(core_cli_retry getblockhash 1) || fail "Core getblockhash 1 failed"
CB1_TXID=$(jpy "$(core_cli_retry getblock "$CB1_HASH" 1)" "d['tx'][0]") \
    || fail "could not read height-1 coinbase txid"
[[ -n "$CB1_TXID" && "$CB1_TXID" != "None" ]] || fail "height-1 coinbase txid empty"
log "spending matured coinbase $CB1_TXID:0 (50 BTC) -> $DEST_ADDR"

# createrawtransaction: one input (the coinbase vout 0), one output (49.999 to
# dest, 0.001 fee). version/locktime default.
RAW_UNSIGNED=$(core_cli_retry createrawtransaction \
    "[{\"txid\":\"$CB1_TXID\",\"vout\":0}]" \
    "[{\"$DEST_ADDR\":49.999}]") || fail "Core createrawtransaction failed"
[[ -n "$RAW_UNSIGNED" ]] || fail "createrawtransaction returned empty"

# signrawtransactionwithkey: needs the prevout scriptPubKey + amount because the
# input is segwit (p2wpkh). Provide the matching WIF.
SIGN_RESP=$(core_cli_retry signrawtransactionwithkey "$RAW_UNSIGNED" \
    "[\"$WIF\"]" \
    "[{\"txid\":\"$CB1_TXID\",\"vout\":0,\"scriptPubKey\":\"$SPK\",\"amount\":50.0}]") \
    || fail "Core signrawtransactionwithkey failed"
SIGNED_OK=$(jpy "$SIGN_RESP" "d.get('complete')")
RAW_SIGNED=$(jpy "$SIGN_RESP" "d.get('hex')")
[[ "$SIGNED_OK" == "true" && -n "$RAW_SIGNED" ]] || fail "signing incomplete: $SIGN_RESP"

# Broadcast the spend (wallet-free sendrawtransaction).
SPEND_TXID=$(core_cli_retry sendrawtransaction "$RAW_SIGNED") \
    || fail "Core sendrawtransaction failed: $(core_cli sendrawtransaction "$RAW_SIGNED" 2>&1)"
[[ -n "$SPEND_TXID" ]] || fail "sendrawtransaction returned empty txid"
log "broadcast spend tx $SPEND_TXID"

# Mine ONE block confirming the spend. After this the UTXO set permanently lacks
# the spent coinbase output and contains the new dest output.
core_cli_retry generatetoaddress 1 "$ADDR" >/dev/null \
    || fail "Core generatetoaddress (confirm spend) failed"
TOTAL=$(( NBLOCKS + 1 ))
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$TOTAL" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $TOTAL"

# Verify the spend tx is actually confirmed in the last-mined block.
SPEND_BLOCKHASH=$(core_cli_retry getblockhash "$TOTAL") || fail "getblockhash $TOTAL failed"
SPEND_IN=$(jpy "$(core_cli_retry getblock "$SPEND_BLOCKHASH" 1)" "'$SPEND_TXID' in d.get('tx', [])")
[[ "$SPEND_IN" == "true" ]] || fail "spend tx $SPEND_TXID not in block $SPEND_BLOCKHASH"
log "spend confirmed in block height $TOTAL ($SPEND_BLOCKHASH)"

# ── 6. Capture EVERYTHING from Core up front (short oracle window). ────────
# The sandbox SIGKILLs bitcoind after a bounded lifetime, so we read every Core
# value we will ever need — raw blocks AND the two gettxoutsetinfo snapshots
# (at TOTAL, and at TOTAL+1 after one more block) AND the error responses —
# BEFORE the slow nimrod submitblock import loop. After this, Core may die; we
# only compare nimrod against the captured values.

# Determine which strong hash field nimrod exposes by default. Core's default is
# hash_serialized_3. We compare like-for-like on whichever Core-correct hash
# nimrod returns (prefer hash_serialized_3, the default; fall back to muhash).
log "probing nimrod default hash_type field"
# (nimrod must be up to probe — it is.)

# --- Core snapshot A (default hash_type) at height TOTAL ---
CORE_GTXO_A=$(core_cli_retry gettxoutsetinfo) || fail "Core gettxoutsetinfo (default) failed"
CA_HEIGHT=$(jpy "$CORE_GTXO_A" "d['height']")
CA_BEST=$(jpy "$CORE_GTXO_A" "d['bestblock']")
CA_TXOUTS=$(jpy "$CORE_GTXO_A" "d['txouts']")
CA_TOTAL=$(jpy "$CORE_GTXO_A" "repr(d['total_amount'])")
CA_HS3=$(jpy "$CORE_GTXO_A" "d.get('hash_serialized_3','')")
[[ -n "$CA_HEIGHT" && -n "$CA_BEST" && -n "$CA_TXOUTS" && -n "$CA_HS3" ]] \
    || fail "Core default gettxoutsetinfo missing fields: $CORE_GTXO_A"
log "Core@A height=$CA_HEIGHT best=$CA_BEST txouts=$CA_TXOUTS total=$CA_TOTAL hs3=$CA_HS3"

# --- Core muhash snapshot A (in case nimrod's default is muhash) ---
CORE_MUH_A=$(core_cli_retry gettxoutsetinfo muhash) || fail "Core gettxoutsetinfo muhash failed"
CA_MUH=$(jpy "$CORE_MUH_A" "d.get('muhash','')")
log "Core@A muhash=$CA_MUH"

# --- Core error responses (while Core is alive) ---
CORE_ERR_HEIGHT=$(core_cli gettxoutsetinfo hash_serialized_3 5 2>&1 || true)
CORE_ERR_BOGUS=$(core_cli gettxoutsetinfo bogushashtype 2>&1 || true)
log "Core hash_serialized_3 <height> err: $CORE_ERR_HEIGHT"
log "Core bogus hash_type err: $CORE_ERR_BOGUS"

# --- Capture all TOTAL raw blocks for replay into nimrod ---
RAWFILE="$NR_DATADIR/core-blocks.tsv"
log "capturing $TOTAL raw blocks for replay"
: > "$RAWFILE"
for ((h=1; h<=TOTAL; h++)); do
    CH=$(core_cli_retry getblockhash "$h")
    [[ -n "$CH" ]] || fail "Core getblockhash $h returned empty"
    RAW=$(core_cli_retry getblock "$CH" 0)
    [[ -n "$RAW" ]] || fail "Core getblock $CH 0 returned empty raw hex"
    printf '%s\t%s\t%s\n' "$h" "$CH" "$RAW" >> "$RAWFILE"
done
[[ "$(wc -l < "$RAWFILE")" == "$TOTAL" ]] || fail "captured $(wc -l < "$RAWFILE") rows, expected $TOTAL"

# --- Mine ONE MORE block on Core for the MUTATE test (changes the UTXO set) ---
MUT_TOTAL=$(( TOTAL + 1 ))
core_cli_retry generatetoaddress 1 "$ADDR" >/dev/null || fail "Core mutate-mine failed"
[[ "$(core_cli_retry getblockcount)" == "$MUT_TOTAL" ]] || fail "Core height not $MUT_TOTAL after mutate-mine"
MUT_HASH=$(core_cli_retry getblockhash "$MUT_TOTAL") || fail "getblockhash $MUT_TOTAL failed"
MUT_RAW=$(core_cli_retry getblock "$MUT_HASH" 0) || fail "getblock $MUT_HASH 0 failed"
printf '%s\t%s\t%s\n' "$MUT_TOTAL" "$MUT_HASH" "$MUT_RAW" >> "$RAWFILE"

# --- Core snapshot B (default) at height MUT_TOTAL ---
CORE_GTXO_B=$(core_cli_retry gettxoutsetinfo) || fail "Core gettxoutsetinfo (mutate) failed"
CB_HEIGHT=$(jpy "$CORE_GTXO_B" "d['height']")
CB_BEST=$(jpy "$CORE_GTXO_B" "d['bestblock']")
CB_TXOUTS=$(jpy "$CORE_GTXO_B" "d['txouts']")
CB_TOTAL=$(jpy "$CORE_GTXO_B" "repr(d['total_amount'])")
CB_HS3=$(jpy "$CORE_GTXO_B" "d.get('hash_serialized_3','')")
CORE_MUH_B=$(core_cli_retry gettxoutsetinfo muhash) || fail "Core gettxoutsetinfo muhash (mutate) failed"
CB_MUH=$(jpy "$CORE_MUH_B" "d.get('muhash','')")
[[ -n "$CB_HEIGHT" && -n "$CB_BEST" && -n "$CB_HS3" ]] || fail "Core mutate gettxoutsetinfo missing fields: $CORE_GTXO_B"
log "Core@B height=$CB_HEIGHT best=$CB_BEST txouts=$CB_TXOUTS hs3=$CB_HS3 muh=$CB_MUH"

# Sanity: Core's own set hash MUST change between A and B (the extra block adds a
# new coinbase output) — proves the hash is a real fingerprint, not a constant.
[[ "$CA_HS3" != "$CB_HS3" ]] || fail "Core hash_serialized_3 unchanged A->B (oracle broken?)"
[[ "$CA_MUH" != "$CB_MUH" ]] || fail "Core muhash unchanged A->B (oracle broken?)"

# ── 7. Import the first TOTAL blocks into nimrod (snapshot-A chain). ───────
log "importing $TOTAL Core blocks into nimrod via submitblock (byte-identical chain)"
ROW_N=0
while IFS=$'\t' read -r h CH RAW; do
    ROW_N=$(( ROW_N + 1 ))
    # Only import the first TOTAL rows now; the (TOTAL+1)th row is the mutate
    # block, imported later.
    [[ "$ROW_N" -le "$TOTAL" ]] || break
    SB=$(nr_rpc submitblock "[\"$RAW\"]")
    SB_RES=$(jpy "$SB" "d.get('result')")
    SB_ERR=$(jpy "$SB" "d.get('error')")
    if [[ -n "$SB_RES" && "$SB_RES" != "None" && "$SB_RES" != "duplicate" ]]; then
        fail "nimrod submitblock height $h rejected: result='$SB_RES' err='$SB_ERR'"
    fi
    if [[ -n "$SB_ERR" && "$SB_ERR" != "None" ]]; then
        fail "nimrod submitblock height $h errored: '$SB_ERR'"
    fi
done < "$RAWFILE"
NR_HEIGHT=$(jpy "$(nr_rpc getblockcount '[]')" "d['result']")
[[ "$NR_HEIGHT" == "$TOTAL" ]] || fail "nimrod height after import is $NR_HEIGHT, expected $TOTAL"

# Confirm the chains are bit-identical at the tip (import succeeded -> identical
# UTXO set is now a hard prerequisite for the hash to match).
NR_TIP_HASH=$(jpy "$(nr_rpc getblockhash "[$TOTAL]")" "d['result']")
[[ "$NR_TIP_HASH" == "$SPEND_BLOCKHASH" ]] || \
    fail "chains diverge at tip $TOTAL (core=$SPEND_BLOCKHASH nimrod=$NR_TIP_HASH)"

# ── 8. Determine nimrod's default-hash field + pick the comparison hash. ──
NR_GTXO_A=$(nr_rpc gettxoutsetinfo '[]')
echo "$NR_GTXO_A" | grep -q '"result"' || fail "nimrod gettxoutsetinfo (default) errored: $NR_GTXO_A"
NA_HS3=$(jpy "$NR_GTXO_A" "d['result'].get('hash_serialized_3','')")
NA_MUH_DEFAULT=$(jpy "$NR_GTXO_A" "d['result'].get('muhash','')")

# HASH_KIND selects which Core-correct strong hash we compare on, like-for-like.
HASH_KIND=""
if [[ -n "$NA_HS3" ]]; then
    HASH_KIND="hash_serialized_3"
elif [[ -n "$NA_MUH_DEFAULT" ]]; then
    HASH_KIND="muhash"
else
    # Default returned neither — try the explicit muhash hash_type.
    NR_MUH_PROBE=$(nr_rpc gettxoutsetinfo '["muhash"]')
    NA_MUH_PROBE=$(jpy "$NR_MUH_PROBE" "d['result'].get('muhash','')")
    [[ -n "$NA_MUH_PROBE" ]] || fail "nimrod exposes no hash_serialized_3 NOR muhash field: default=$NR_GTXO_A muhash=$NR_MUH_PROBE"
    HASH_KIND="muhash"
fi
log "comparing on hash_type=$HASH_KIND"

# Fetch nimrod's snapshot-A on the chosen hash_type.
if [[ "$HASH_KIND" == "hash_serialized_3" ]]; then
    NR_A=$(nr_rpc gettxoutsetinfo '["hash_serialized_3"]')
    NA_HASH=$(jpy "$NR_A" "d['result'].get('hash_serialized_3','')")
    CORE_A_HASH="$CA_HS3"
else
    NR_A=$(nr_rpc gettxoutsetinfo '["muhash"]')
    NA_HASH=$(jpy "$NR_A" "d['result'].get('muhash','')")
    CORE_A_HASH="$CA_MUH"
fi
echo "$NR_A" | grep -q '"result"' || fail "nimrod gettxoutsetinfo($HASH_KIND) errored: $NR_A"

NA_HEIGHT=$(jpy "$NR_A" "d['result']['height']")
NA_BEST=$(jpy "$NR_A" "d['result']['bestblock']")
NA_TXOUTS=$(jpy "$NR_A" "d['result']['txouts']")
NA_TOTAL=$(jpy "$NR_A" "repr(d['result']['total_amount'])")
NA_BOGO=$(jpy "$NR_A" "d['result'].get('bogosize','__MISSING__')")
NA_TX=$(jpy "$NR_A" "d['result'].get('transactions','__MISSING__')")
NA_DISK=$(jpy "$NR_A" "d['result'].get('disk_size','__MISSING__')")
NA_BOGO_T=$(jpy "$NR_A" "type(d['result'].get('bogosize')).__name__")
NA_TX_T=$(jpy "$NR_A" "type(d['result'].get('transactions')).__name__")
NA_DISK_T=$(jpy "$NR_A" "type(d['result'].get('disk_size')).__name__")
log "nimrod@A height=$NA_HEIGHT best=$NA_BEST txouts=$NA_TXOUTS total=$NA_TOTAL hash=$NA_HASH"
log "nimrod@A bogosize=$NA_BOGO($NA_BOGO_T) transactions=$NA_TX($NA_TX_T) disk_size=$NA_DISK($NA_DISK_T)"

# ── 9. TEST 1 — FIELDS + HASH byte-exact at snapshot A. ───────────────────
FIELDS_T="ok"; HASH_T="ok"

# Numeric/exact fields that MUST match Core byte-for-byte.
[[ "$NA_HEIGHT" == "$CA_HEIGHT" ]]   || { FIELDS_T="bad"; log "height mismatch: nimrod=$NA_HEIGHT core=$CA_HEIGHT"; }
[[ "$NA_BEST"   == "$CA_BEST"   ]]   || { FIELDS_T="bad"; log "bestblock mismatch: nimrod=$NA_BEST core=$CA_BEST"; }
[[ "$NA_TXOUTS" == "$CA_TXOUTS" ]]   || { FIELDS_T="bad"; log "txouts mismatch: nimrod=$NA_TXOUTS core=$CA_TXOUTS"; }

# total_amount: compare numerically (avoid 49.99900000 vs 49.999 string drift).
TOTAL_EQ=$(python3 -c "
from decimal import Decimal
print('eq' if Decimal('$NA_TOTAL') == Decimal('$CA_TOTAL') else 'ne')
" 2>/dev/null)
[[ "$TOTAL_EQ" == "eq" ]] || { FIELDS_T="bad"; log "total_amount mismatch: nimrod=$NA_TOTAL core=$CA_TOTAL"; }

# bogosize / transactions / disk_size: PRESENT + typed only (NOT byte-equal).
[[ "$NA_BOGO" != "__MISSING__" && "$NA_BOGO_T" == "int" ]]   || { FIELDS_T="bad"; log "bogosize absent/not-int: val=$NA_BOGO type=$NA_BOGO_T"; }
[[ "$NA_TX"   != "__MISSING__" && "$NA_TX_T"   == "int" ]]   || { FIELDS_T="bad"; log "transactions absent/not-int: val=$NA_TX type=$NA_TX_T"; }
[[ "$NA_DISK" != "__MISSING__" && "$NA_DISK_T" == "int" ]]   || { FIELDS_T="bad"; log "disk_size absent/not-int: val=$NA_DISK type=$NA_DISK_T"; }

# THE POINT: the UTXO-set hash MUST be byte-identical to Core's.
[[ -n "$NA_HASH" && -n "$CORE_A_HASH" ]] || fail "empty hash to compare ($HASH_KIND): nimrod='$NA_HASH' core='$CORE_A_HASH'"
[[ "$NA_HASH" =~ ^[0-9a-f]{64}$ ]] || { HASH_T="bad"; log "nimrod $HASH_KIND not 64-hex: '$NA_HASH'"; }
if [[ "$NA_HASH" != "$CORE_A_HASH" ]]; then
    HASH_T="bad"; log "UTXO-set $HASH_KIND MISMATCH: nimrod=$NA_HASH core=$CORE_A_HASH"
fi

# Sanity: the set must be non-trivial (>NBLOCKS coinbases minus the spend, plus
# the new dest output) — guards against a degenerate empty-set hash collision.
[[ "$CA_TXOUTS" =~ ^[0-9]+$ && "$CA_TXOUTS" -ge 2 ]] || fail "Core txouts=$CA_TXOUTS too small (degenerate set?)"

[[ "$FIELDS_T" == "ok" ]] || fail "field parity failed (see log)"
[[ "$HASH_T"   == "ok" ]] || fail "UTXO-set hash parity failed (see log)"
log "snapshot-A: fields + $HASH_KIND byte-parity OK (set hash $NA_HASH == Core)"

# ── 10. TEST 2 — MUTATE: import one more block, re-query, hash changes+matches.
MUTATE_T="ok"
# Import the mutate block (the (TOTAL+1)th row).
MUT_ROW=$(awk -F'\t' -v h="$MUT_TOTAL" '$1==h{print $3}' "$RAWFILE")
[[ -n "$MUT_ROW" ]] || fail "mutate block raw not captured for height $MUT_TOTAL"
SB=$(nr_rpc submitblock "[\"$MUT_ROW\"]")
SB_RES=$(jpy "$SB" "d.get('result')")
SB_ERR=$(jpy "$SB" "d.get('error')")
if [[ -n "$SB_RES" && "$SB_RES" != "None" && "$SB_RES" != "duplicate" ]]; then
    fail "nimrod submitblock mutate height $MUT_TOTAL rejected: result='$SB_RES' err='$SB_ERR'"
fi
[[ -z "$SB_ERR" || "$SB_ERR" == "None" ]] || fail "nimrod submitblock mutate errored: '$SB_ERR'"

NR_H2=$(jpy "$(nr_rpc getblockcount '[]')" "d['result']")
[[ "$NR_H2" == "$MUT_TOTAL" ]] || fail "nimrod height after mutate is $NR_H2, expected $MUT_TOTAL"

if [[ "$HASH_KIND" == "hash_serialized_3" ]]; then
    NR_B=$(nr_rpc gettxoutsetinfo '["hash_serialized_3"]')
    NB_HASH=$(jpy "$NR_B" "d['result'].get('hash_serialized_3','')")
    CORE_B_HASH="$CB_HS3"
else
    NR_B=$(nr_rpc gettxoutsetinfo '["muhash"]')
    NB_HASH=$(jpy "$NR_B" "d['result'].get('muhash','')")
    CORE_B_HASH="$CB_MUH"
fi
echo "$NR_B" | grep -q '"result"' || fail "nimrod gettxoutsetinfo($HASH_KIND) after mutate errored: $NR_B"
NB_HEIGHT=$(jpy "$NR_B" "d['result']['height']")
NB_BEST=$(jpy "$NR_B" "d['result']['bestblock']")

# height advanced by exactly 1.
[[ "$NB_HEIGHT" == "$MUT_TOTAL" ]] || { MUTATE_T="bad"; log "mutate height: nimrod=$NB_HEIGHT expected=$MUT_TOTAL"; }
[[ "$NB_HEIGHT" == "$CB_HEIGHT" ]] || { MUTATE_T="bad"; log "mutate height vs Core: nimrod=$NB_HEIGHT core=$CB_HEIGHT"; }
# bestblock changed from A.
[[ "$NB_BEST" != "$NA_BEST" ]]  || { MUTATE_T="bad"; log "mutate bestblock did not change: still $NB_BEST"; }
[[ "$NB_BEST" == "$CB_BEST" ]]  || { MUTATE_T="bad"; log "mutate bestblock vs Core: nimrod=$NB_BEST core=$CB_BEST"; }
# set hash CHANGED from A on nimrod (proves it's a real fingerprint of the set).
[[ "$NB_HASH" != "$NA_HASH" ]]  || { MUTATE_T="bad"; log "mutate set hash did NOT change on nimrod: still $NB_HASH"; }
# ...and still matches Core after the mutation.
[[ "$NB_HASH" == "$CORE_B_HASH" ]] || { MUTATE_T="bad"; log "mutate set $HASH_KIND vs Core: nimrod=$NB_HASH core=$CORE_B_HASH"; }

[[ "$MUTATE_T" == "ok" ]] || fail "mutate test failed (see log)"
log "mutate: height $NA_HEIGHT->$NB_HEIGHT, set hash $NA_HASH->$NB_HASH (== Core $CORE_B_HASH)"

# ── 11. TEST 3 — ERRORS. ──────────────────────────────────────────────────
ERRORS_T="ok"

# (a) gettxoutsetinfo hash_serialized_3 <height> -> RPC -8.
ERR_RESP=$(nr_rpc gettxoutsetinfo '["hash_serialized_3", 5]')
ERR_CODE=$(jpy "$ERR_RESP" "d.get('error',{}).get('code') if isinstance(d.get('error'),dict) else None")
if [[ "$ERR_CODE" != "-8" ]]; then
    ERRORS_T="bad"; log "hash_serialized_3 <height>: expected RPC code -8, got code='$ERR_CODE' resp=$ERR_RESP"
else
    log "hash_serialized_3 <height> -> code -8 OK (resp: $ERR_RESP)"
fi
# Cross-check Core also returned -8 for the same query (defends the assertion).
echo "$CORE_ERR_HEIGHT" | grep -q "error code: -8" \
    || log "WARN: Core's hash_serialized_3 <height> error was not -8: $CORE_ERR_HEIGHT"

# (b) unrecognised hash_type -> error (Core uses RPC -8).
BOGUS_RESP=$(nr_rpc gettxoutsetinfo '["totally-bogus-hashtype"]')
BOGUS_HAS_ERR=$(jpy "$BOGUS_RESP" "1 if (isinstance(d.get('error'),dict) and d['error'].get('code') is not None) else 0")
BOGUS_CODE=$(jpy "$BOGUS_RESP" "d.get('error',{}).get('code') if isinstance(d.get('error'),dict) else None")
BOGUS_HAS_RESULT=$(jpy "$BOGUS_RESP" "1 if (d.get('result') not in (None,)) else 0")
if [[ "$BOGUS_HAS_ERR" != "1" || "$BOGUS_HAS_RESULT" == "1" ]]; then
    ERRORS_T="bad"; log "bogus hash_type: expected an error (no result), got resp=$BOGUS_RESP"
else
    log "bogus hash_type -> error code $BOGUS_CODE OK (resp: $BOGUS_RESP)"
fi
# Core returns -8 for bogus; nimrod should too — flag if it diverges (non-fatal
# only if it is still an error, but we WANT -8 parity, so assert it).
if [[ "$BOGUS_CODE" != "-8" ]]; then
    ERRORS_T="bad"; log "bogus hash_type: expected RPC code -8 (Core parity), got '$BOGUS_CODE'"
fi
echo "$CORE_ERR_BOGUS" | grep -q "error code: -8" \
    || log "WARN: Core's bogus hash_type error was not -8: $CORE_ERR_BOGUS"

[[ "$ERRORS_T" == "ok" ]] || fail "error-case parity failed (see log)"

# ── Done. ──────────────────────────────────────────────────────────────────
pass "ok" "ok" "ok" "ok"

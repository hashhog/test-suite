#!/usr/bin/env bash
#
# nimrod_scantxoutset.sh — self-contained scantxoutset Core-parity test.
#
# scantxoutset scans the CURRENT UTXO set for outputs whose scriptPubKey matches
# a supplied output descriptor (here: addr(<address>)). It is the canonical
# wallet-free "what UTXOs pay this address?" primitive. This harness proves
# nimrod's scantxoutset answers IDENTICALLY to a REAL bitcoind regtest oracle
# for a freshly-funded address on a byte-identical chain.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp::scantxoutset
#   scantxoutset "action" ( [scanobjects] )
#   action=="start" with scanobjects=[{"desc":"addr(<a>)"}] or ["addr(<a>)"]
#     -> walks the chainstate UTXO set and returns an OBJECT:
#        { success(bool), txouts(int total UTXOs scanned), height(int tip),
#          bestblock(hex tip), unspents[ {txid, vout, scriptPubKey, desc,
#          amount, coinbase, height, blockhash, confirmations} ],
#          total_amount(BTC) }.
#   action=="status" -> null when idle.   action=="abort" -> bool.
#   Key deterministic assertions vs the oracle: total_amount and the matched
#   unspents (txid/vout/amount) for a freshly-funded address.
#
# DIFFERENTIAL DESIGN (the SAME chain on BOTH nodes — true parity, not shape):
#   A wallet-DISABLED Core build + two independent regtest chains can never share
#   a byte-identical UTXO. So the two nodes share ONE chain:
#     1. Launch a real bitcoind regtest oracle (RPC-only, -listen=0).
#     2. Launch nimrod on regtest (its regtest genesis hash equals Core's, so its
#        consensus accepts Core's blocks).
#     3. Mine NBLOCKS to a deterministic wallet-free p2wpkh MINE address on Core,
#        build + send a real signed spend of block-1's matured coinbase to a
#        DEST address, mine it in. Replay EVERY Core block into nimrod via
#        submitblock. Both nodes now hold a byte-IDENTICAL chain + UTXO set.
#     4. scantxoutset start [addr(<MINE>)] on BOTH -> compare.
#   Because the UTXO set is identical, the scan answer must be EXACT.
#
# CHECKS (all must hold for PASS):
#   desc   : scantxoutset start [addr(<MINE>)] on BOTH returns success==true and
#            the SAME set of matched outpoints (txid:vout), and the MINE address's
#            mature coinbase outputs are among them.
#   amount : nimrod total_amount == Core total_amount (Decimal-exact), AND each
#            matched unspent's amount matches Core for the same txid:vout.
#   shape  : result OBJECT has success + total_amount + unspents (array); every
#            unspents[] entry carries Core's keys
#            {txid,vout,scriptPubKey,desc,amount,coinbase,height,blockhash,
#             confirmations}. A MISSING key vs Core is a real divergence -> FAIL.
#   empty  : scantxoutset start [addr(<UNFUNDED>)] -> success==true,
#            total_amount==0, unspents==[] on BOTH.
#
# STRICT UNIFORM INTERFACE (mirrors utxosetinfo/nimrod_gettxoutsetinfo.sh):
#   no required args, set -uo pipefail, idempotent, trap cleanup, scratch /tmp +
#   UNIQUE ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: SCANTXOUTSET nimrod: PASS desc=ok amount=ok shape=ok empty=ok
#   FAIL: SCANTXOUTSET nimrod: FAIL <short reason>
#   (binary missing -> a GAP_RE-compatible 'not found' message so the runner SKIPs)
#
# Touches ONLY /tmp/scan-nimrod/ + /tmp/scan-core-nimrod/ and ports 40411/40431
#   (nimrod RPC/P2P) + 40413/40433 (Core RPC/P2P). NEVER touches /data/nvme1/ or
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

# NOTE: this Core build has NO wallet support, so the SPEND is wallet-free:
# mine to a known-key p2wpkh address, then createrawtransaction +
# signrawtransactionwithkey (WIF) + sendrawtransaction. All three are wallet-free.

NR_DATADIR="/tmp/scan-nimrod"
NR_RPC=40411
NR_P2P=40431
NR_LOG="$NR_DATADIR/node.log"

# Node-unique Core datadir name (sibling scantxoutset harnesses for other impls
# may run concurrently — a shared name causes mutual rm -rf destruction).
CORE_DATADIR="/tmp/scan-core-nimrod"
CORE_RPC=40413
CORE_P2P=40433
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=110        # mine enough to mature a coinbase (>100) so we can spend
NR_PID=""
NR_COOKIE=""
CORE_BG=""
ADDR=""            # MINE address (p2wpkh, bcrt1) — funded by NBLOCKS coinbases
DEST_ADDR=""       # spend destination (p2wpkh, bcrt1) — funded by ONE spend output
UNFUNDED_ADDR=""   # a third address that NEVER receives any UTXO (empty-scan)
SPK=""             # p2wpkh scriptPubKey of the MINE address (hex)
WIF=""             # regtest WIF private key for signrawtransactionwithkey

# Deterministic test secrets -> p2wpkh bcrt1 addresses.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
DEST_SECRET="2222222222222222222222222222222222222222222222222222222222222223"
UNFUNDED_SECRET="3333333333333333333333333333333333333333333333333333333333333334"

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[scantxoutset:nimrod] $*" >&2; }

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
    echo "SCANTXOUTSET nimrod: PASS desc=$1 amount=$2 shape=$3 empty=$4"
    exit 0
}
fail() {
    echo "SCANTXOUTSET nimrod: FAIL $*"
    exit 1
}
skip() {
    echo "SCANTXOUTSET nimrod: SKIP $*"
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
pkill -f "scan-nimrod" 2>/dev/null || true
free_port "$NR_RPC"
free_port "$NR_P2P"
free_port "$CORE_RPC"
free_port "$CORE_P2P"
rm -rf "$NR_DATADIR" "$CORE_DATADIR"
mkdir -p "$NR_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
# Binary-missing uses a GAP_RE-compatible 'not found' message so the regression
# runner classifies a missing nimrod build as SKIP (not a real failure).
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

# ── 3. Derive deterministic mining / dest / unfunded keys + addresses + WIF.
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
ua, us, uw = info('$UNFUNDED_SECRET')
print(ma); print(ms); print(mw); print(da); print(ua)
" 2>/dev/null) || fail "key derivation failed (Core test_framework import)"
ADDR=$(echo "$DERIVE"          | sed -n '1p')
SPK=$(echo "$DERIVE"           | sed -n '2p')
WIF=$(echo "$DERIVE"           | sed -n '3p')
DEST_ADDR=$(echo "$DERIVE"     | sed -n '4p')
UNFUNDED_ADDR=$(echo "$DERIVE" | sed -n '5p')
[[ "$ADDR" == bcrt1* && "$DEST_ADDR" == bcrt1* && "$UNFUNDED_ADDR" == bcrt1* ]] \
    || fail "derived addresses bad: mine='$ADDR' dest='$DEST_ADDR' unfunded='$UNFUNDED_ADDR'"
[[ "$SPK" =~ ^0014[0-9a-f]{40}$ ]] || fail "derived p2wpkh scriptPubKey bad: '$SPK'"
[[ -n "$WIF" ]] || fail "derived WIF empty"
log "MINE $ADDR (spk=$SPK), DEST $DEST_ADDR, UNFUNDED $UNFUNDED_ADDR"

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

# ── 5. Mine NBLOCKS to the MINE address on Core; build + send a SPEND. ────
log "mining $NBLOCKS blocks to $ADDR on Core (matures coinbase for a spend)"
core_cli_retry generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"

# Build a real spend WITHOUT a wallet: spend the height-1 coinbase output (now
# matured, since NBLOCKS > 100) to the DEST address. This REMOVES a coinbase UTXO
# from the MINE address and ADDS a non-coinbase output to DEST — so both the
# scanned address and the destination have real, distinguishable UTXOs.
CB1_HASH=$(core_cli_retry getblockhash 1) || fail "Core getblockhash 1 failed"
CB1_TXID=$(jpy "$(core_cli_retry getblock "$CB1_HASH" 1)" "d['tx'][0]") \
    || fail "could not read height-1 coinbase txid"
[[ -n "$CB1_TXID" && "$CB1_TXID" != "None" ]] || fail "height-1 coinbase txid empty"
log "spending matured coinbase $CB1_TXID:0 (50 BTC) -> $DEST_ADDR"

RAW_UNSIGNED=$(core_cli_retry createrawtransaction \
    "[{\"txid\":\"$CB1_TXID\",\"vout\":0}]" \
    "[{\"$DEST_ADDR\":49.999}]") || fail "Core createrawtransaction failed"
[[ -n "$RAW_UNSIGNED" ]] || fail "createrawtransaction returned empty"

SIGN_RESP=$(core_cli_retry signrawtransactionwithkey "$RAW_UNSIGNED" \
    "[\"$WIF\"]" \
    "[{\"txid\":\"$CB1_TXID\",\"vout\":0,\"scriptPubKey\":\"$SPK\",\"amount\":50.0}]") \
    || fail "Core signrawtransactionwithkey failed"
SIGNED_OK=$(jpy "$SIGN_RESP" "d.get('complete')")
RAW_SIGNED=$(jpy "$SIGN_RESP" "d.get('hex')")
[[ "$SIGNED_OK" == "true" && -n "$RAW_SIGNED" ]] || fail "signing incomplete: $SIGN_RESP"

SPEND_TXID=$(core_cli_retry sendrawtransaction "$RAW_SIGNED") \
    || fail "Core sendrawtransaction failed: $(core_cli sendrawtransaction "$RAW_SIGNED" 2>&1)"
[[ -n "$SPEND_TXID" ]] || fail "sendrawtransaction returned empty txid"
log "broadcast spend tx $SPEND_TXID"

# Mine ONE block confirming the spend. After this the spent coinbase is gone from
# the UTXO set and the DEST output exists.
core_cli_retry generatetoaddress 1 "$ADDR" >/dev/null \
    || fail "Core generatetoaddress (confirm spend) failed"
TOTAL=$(( NBLOCKS + 1 ))
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$TOTAL" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $TOTAL"

SPEND_BLOCKHASH=$(core_cli_retry getblockhash "$TOTAL") || fail "getblockhash $TOTAL failed"
SPEND_IN=$(jpy "$(core_cli_retry getblock "$SPEND_BLOCKHASH" 1)" "'$SPEND_TXID' in d.get('tx', [])")
[[ "$SPEND_IN" == "true" ]] || fail "spend tx $SPEND_TXID not in block $SPEND_BLOCKHASH"
log "spend confirmed in block height $TOTAL ($SPEND_BLOCKHASH)"

# ── 6. Capture Core scantxoutset answers + raw blocks up front. ───────────
# The sandbox SIGKILLs bitcoind after a bounded lifetime, so read every Core
# value we will ever need — the two scantxoutset results (MINE addr, UNFUNDED
# addr) AND all raw blocks for replay — BEFORE the slow nimrod import loop.

# --- Core scantxoutset for the MINE address (funded) ---
# Use the OBJECT scanobject form to also exercise EvalDescriptorStringOrObject.
CORE_SCAN=$(core_cli_retry scantxoutset start "[{\"desc\":\"addr($ADDR)\"}]") \
    || fail "Core scantxoutset start (MINE) failed"
echo "$CORE_SCAN" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null \
    || fail "Core scantxoutset (MINE) returned non-JSON: ${CORE_SCAN:0:160}"
C_SUCCESS=$(jpy "$CORE_SCAN" "d.get('success')")
C_TOTAL=$(jpy "$CORE_SCAN" "repr(d.get('total_amount'))")
C_NUNSP=$(jpy "$CORE_SCAN" "len(d.get('unspents', []))")
C_HEIGHT=$(jpy "$CORE_SCAN" "d.get('height')")
[[ "$C_SUCCESS" == "true" ]]      || fail "Core scan (MINE) success != true: $C_SUCCESS"
[[ "$C_HEIGHT"  == "$TOTAL"  ]]   || fail "Core scan height $C_HEIGHT != $TOTAL"
[[ "$C_NUNSP" =~ ^[0-9]+$ && "$C_NUNSP" -ge 1 ]] \
    || fail "Core scan (MINE) found $C_NUNSP unspents (expected >=1) — oracle sanity"
log "Core scan (MINE): success=$C_SUCCESS total_amount=$C_TOTAL unspents=$C_NUNSP height=$C_HEIGHT"

# Canonical sorted "txid:vout=amount" lines for the MINE set (order-independent).
core_set_lines() {
    python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
rows = []
for u in d.get("unspents", []):
    rows.append("%s:%s=%s" % (u["txid"], u["vout"], format(float(u["amount"]), ".8f")))
print("\n".join(sorted(rows)))
' <<<"$1" 2>/dev/null
}
CORE_SET=$(core_set_lines "$CORE_SCAN")
[[ -n "$CORE_SET" ]] || fail "could not extract Core MINE unspent set"

# Core's per-unspent key set (alphabetical) — the shape contract nimrod must meet.
CORE_KEYS=$(jpy "$CORE_SCAN" "','.join(sorted(d['unspents'][0].keys()))")
log "Core unspents[0] keys: $CORE_KEYS"

# --- Core scantxoutset for the UNFUNDED address (string scanobject form) ---
CORE_EMPTY=$(core_cli_retry scantxoutset start "[\"addr($UNFUNDED_ADDR)\"]") \
    || fail "Core scantxoutset start (UNFUNDED) failed"
CE_SUCCESS=$(jpy "$CORE_EMPTY" "d.get('success')")
CE_TOTAL=$(jpy "$CORE_EMPTY" "repr(d.get('total_amount'))")
CE_NUNSP=$(jpy "$CORE_EMPTY" "len(d.get('unspents', []))")
[[ "$CE_SUCCESS" == "true" ]] || fail "Core scan (UNFUNDED) success != true: $CE_SUCCESS"
[[ "$CE_NUNSP" == "0" ]]      || fail "Core scan (UNFUNDED) found $CE_NUNSP unspents (expected 0)"
log "Core scan (UNFUNDED): success=$CE_SUCCESS total_amount=$CE_TOTAL unspents=$CE_NUNSP"

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

# ── 7. Import the TOTAL blocks into nimrod (byte-identical chain). ─────────
log "importing $TOTAL Core blocks into nimrod via submitblock (byte-identical chain)"
while IFS=$'\t' read -r h CH RAW; do
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

# Confirm the chains are bit-identical at the tip (a hard prerequisite for the
# scan answer to match).
NR_TIP_HASH=$(jpy "$(nr_rpc getblockhash "[$TOTAL]")" "d['result']")
[[ "$NR_TIP_HASH" == "$SPEND_BLOCKHASH" ]] || \
    fail "chains diverge at tip $TOTAL (core=$SPEND_BLOCKHASH nimrod=$NR_TIP_HASH)"
log "nimrod chain bit-identical at tip $TOTAL ($NR_TIP_HASH)"

# ── 8. nimrod scantxoutset for the MINE address (funded). ─────────────────
NR_SCAN_RESP=$(nr_rpc scantxoutset "[\"start\", [{\"desc\":\"addr($ADDR)\"}]]")
echo "$NR_SCAN_RESP" | grep -q '"result"' \
    || fail "nimrod scantxoutset start (MINE) errored: ${NR_SCAN_RESP:0:200}"
NR_SCAN=$(jpy "$NR_SCAN_RESP" "json.dumps(d['result'])")
[[ -n "$NR_SCAN" ]] || fail "nimrod scantxoutset (MINE) empty result"

N_SUCCESS=$(jpy "$NR_SCAN" "d.get('success')")
N_TOTAL=$(jpy "$NR_SCAN" "repr(d.get('total_amount'))")
N_NUNSP=$(jpy "$NR_SCAN" "len(d.get('unspents', []))")
N_HEIGHT=$(jpy "$NR_SCAN" "d.get('height')")
N_BEST=$(jpy "$NR_SCAN" "d.get('bestblock')")
log "nimrod scan (MINE): success=$N_SUCCESS total_amount=$N_TOTAL unspents=$N_NUNSP height=$N_HEIGHT best=$N_BEST"

# ── 9. CHECK shape — result object + per-unspent key parity with Core. ────
SHAPE_T="ok"
# Top-level: must be an OBJECT carrying success + total_amount + unspents(array).
TOP_KIND=$(jpy "$NR_SCAN" "'obj' if isinstance(d, dict) else 'not-obj'")
[[ "$TOP_KIND" == "obj" ]] || { SHAPE_T="bad"; log "result is not an object"; }
HAS_SUCCESS=$(jpy "$NR_SCAN" "1 if 'success' in d else 0")
HAS_TOTAL=$(jpy "$NR_SCAN" "1 if 'total_amount' in d else 0")
UNSP_IS_ARR=$(jpy "$NR_SCAN" "1 if isinstance(d.get('unspents'), list) else 0")
[[ "$HAS_SUCCESS" == "1" ]] || { SHAPE_T="bad"; log "result missing top-level 'success'"; }
[[ "$HAS_TOTAL"   == "1" ]] || { SHAPE_T="bad"; log "result missing top-level 'total_amount'"; }
[[ "$UNSP_IS_ARR" == "1" ]] || { SHAPE_T="bad"; log "result 'unspents' is not an array"; }
[[ "$N_SUCCESS" == "true" ]] || { SHAPE_T="bad"; log "nimrod scan success != true: $N_SUCCESS"; }

# Per-unspent: every Core key must be present on nimrod's matched unspents.
# A missing key (e.g. Core's always-present 'blockhash') is a real divergence.
if [[ "$N_NUNSP" =~ ^[0-9]+$ && "$N_NUNSP" -ge 1 ]]; then
    NR_KEYS=$(jpy "$NR_SCAN" "','.join(sorted(d['unspents'][0].keys()))")
    log "nimrod unspents[0] keys: $NR_KEYS"
    MISSING=$(python3 -c "
ck=set('''$CORE_KEYS'''.split(','))
nk=set('''$NR_KEYS'''.split(','))
print(','.join(sorted(ck - nk)))
" 2>/dev/null)
    if [[ -n "$MISSING" ]]; then
        SHAPE_T="bad"
        log "nimrod unspents[] MISSING Core key(s): $MISSING (Core=$CORE_KEYS nimrod=$NR_KEYS)"
    fi
else
    SHAPE_T="bad"; log "nimrod scan (MINE) found $N_NUNSP unspents (expected >=1)"
fi

# ── 10. CHECK desc — matched outpoint SET equality vs Core. ───────────────
DESC_T="ok"
NR_SET=$(python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
rows = []
for u in d.get("unspents", []):
    rows.append("%s:%s=%s" % (u["txid"], u["vout"], format(float(u["amount"]), ".8f")))
print("\n".join(sorted(rows)))
' <<<"$NR_SCAN" 2>/dev/null)
if [[ "$NR_SET" != "$CORE_SET" ]]; then
    DESC_T="bad"
    log "matched-outpoint SET mismatch vs Core:"
    log "  core: $(echo "$CORE_SET" | tr '\n' ' ')"
    log "  nimrod: $(echo "$NR_SET" | tr '\n' ' ')"
fi
# Sanity: at least one matched output must be a coinbase of the MINE address.
N_HAS_CB=$(jpy "$NR_SCAN" "1 if any(u.get('coinbase') for u in d.get('unspents', [])) else 0")
[[ "$N_HAS_CB" == "1" ]] || { DESC_T="bad"; log "no coinbase output among matched MINE unspents"; }

# ── 11. CHECK amount — total_amount + per-unspent amount EXACT vs Core. ────
AMOUNT_T="ok"
TOTAL_EQ=$(python3 -c "
from decimal import Decimal
try:
    print('eq' if Decimal('$N_TOTAL') == Decimal('$C_TOTAL') else 'ne')
except Exception:
    print('err')
" 2>/dev/null)
[[ "$TOTAL_EQ" == "eq" ]] || { AMOUNT_T="bad"; log "total_amount mismatch: nimrod=$N_TOTAL core=$C_TOTAL"; }
# total_amount must be > 0 (the MINE address is funded) — guards a 0==0 pass.
TOTAL_POS=$(python3 -c "from decimal import Decimal; print('y' if Decimal('$N_TOTAL')>0 else 'n')" 2>/dev/null)
[[ "$TOTAL_POS" == "y" ]] || { AMOUNT_T="bad"; log "nimrod total_amount not > 0: $N_TOTAL"; }
# Per-outpoint amount parity is already enforced by the SET-equality check
# (DESC_T) which folds the amount into each line; AMOUNT_T adds the aggregate.
[[ "$N_NUNSP" == "$C_NUNSP" ]] || { AMOUNT_T="bad"; log "unspents count mismatch: nimrod=$N_NUNSP core=$C_NUNSP"; }

# ── 12. CHECK empty — unfunded address scans empty on BOTH. ───────────────
EMPTY_T="ok"
NR_EMPTY_RESP=$(nr_rpc scantxoutset "[\"start\", [\"addr($UNFUNDED_ADDR)\"]]")
echo "$NR_EMPTY_RESP" | grep -q '"result"' \
    || fail "nimrod scantxoutset start (UNFUNDED) errored: ${NR_EMPTY_RESP:0:200}"
NR_EMPTY=$(jpy "$NR_EMPTY_RESP" "json.dumps(d['result'])")
NE_SUCCESS=$(jpy "$NR_EMPTY" "d.get('success')")
NE_TOTAL=$(jpy "$NR_EMPTY" "repr(d.get('total_amount'))")
NE_NUNSP=$(jpy "$NR_EMPTY" "len(d.get('unspents', []))")
log "nimrod scan (UNFUNDED): success=$NE_SUCCESS total_amount=$NE_TOTAL unspents=$NE_NUNSP"
[[ "$NE_SUCCESS" == "true" ]] || { EMPTY_T="bad"; log "UNFUNDED success != true: $NE_SUCCESS"; }
[[ "$NE_NUNSP" == "0" ]]      || { EMPTY_T="bad"; log "UNFUNDED unspents != 0: $NE_NUNSP"; }
EMPTY_ZERO=$(python3 -c "from decimal import Decimal; print('y' if Decimal('$NE_TOTAL')==0 else 'n')" 2>/dev/null)
[[ "$EMPTY_ZERO" == "y" ]]    || { EMPTY_T="bad"; log "UNFUNDED total_amount != 0: $NE_TOTAL"; }
# Parity with Core's empty answer (total + count).
EMPTY_PAR=$(python3 -c "
from decimal import Decimal
print('y' if (Decimal('$NE_TOTAL')==Decimal('$CE_TOTAL') and '$NE_NUNSP'=='$CE_NUNSP') else 'n')
" 2>/dev/null)
[[ "$EMPTY_PAR" == "y" ]] || { EMPTY_T="bad"; log "UNFUNDED parity vs Core: nimrod(total=$NE_TOTAL n=$NE_NUNSP) core(total=$CE_TOTAL n=$CE_NUNSP)"; }

# ── 13. Verdict. ──────────────────────────────────────────────────────────
REASONS=""
[[ "$DESC_T"   == "ok" ]] || REASONS="$REASONS desc(matched-set!=Core)"
[[ "$AMOUNT_T" == "ok" ]] || REASONS="$REASONS amount(total/count!=Core)"
[[ "$SHAPE_T"  == "ok" ]] || REASONS="$REASONS shape(missing-keys-vs-Core)"
[[ "$EMPTY_T"  == "ok" ]] || REASONS="$REASONS empty(unfunded!=0/empty)"
if [[ -n "$REASONS" ]]; then
    fail "scantxoutset diverges from Core:$REASONS (see log for details)"
fi

log "PASS: scantxoutset matched-set + total_amount EXACT vs Core; unspents carry Core's keys; unfunded scans empty on both"
pass "$DESC_T" "$AMOUNT_T" "$SHAPE_T" "$EMPTY_T"

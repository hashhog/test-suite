#!/usr/bin/env bash
#
# haskoin_scantxoutset.sh — self-contained scantxoutset Core-parity test.
#
# Mirrors test-suite/rawtx/haskoin_getrawtransaction.sh structure (uniform
# interface): set -uo pipefail, idempotent, trap cleanup, scratch /tmp + unique
# ports, ONE summary line, exit 0/1. Run under: setsid -w bash <script>.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:2316-2476 (scantxoutset).
#
# scantxoutset "action" ( [scanobjects] ):
#   action="start"  with scanobjects=[{"desc":"addr(<addr>)"}] or ["addr(<addr>)"]
#     scans the CURRENT UTXO set for outputs matching the descriptor(s) and
#     returns (only after the scan completes) an OBJECT:
#       { success(bool), txouts(int total UTXOs scanned), height(int tip),
#         bestblock(hex), unspents[ {txid, vout, scriptPubKey, desc, amount(BTC),
#         coinbase, height, blockhash, confirmations} ], total_amount(BTC) }
#   action="status" -> null when idle (a scan in progress -> {progress}).
#   action="abort"  -> bool (false when no scan running).
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) regtest oracle on its
#   own scratch + ports, launched -listen=0 (sandbox SIGKILLs a 0.0.0.0 P2P
#   listener) and -txindex=1. haskoin runs on regtest scratch /tmp/sts-haskoin
#   (RPC 22019, P2P 22039). To give BOTH nodes the IDENTICAL UTXO set (so the
#   same scantxoutset matches the same outputs on both), every block Core mines
#   is REPLAYED to haskoin via submitblock. We then create+sign a real spend on
#   Core that pays a KNOWN amount to a FRESH p2wpkh DEST address (so that
#   address has EXACTLY ONE matched unspent of a known value), mine it into a
#   block, replay that block, and scantxoutset for DEST on BOTH nodes.
#
# Differential assertions (run on BOTH impl and Core):
#   desc   : the matched unspent's txid/vout/amount + total_amount EQUAL Core's,
#            and the unspent's desc (checksum-stripped) EQUALS Core's.
#   amount : impl total_amount == Core total_amount == the funded value.
#   shape  : result OBJECT has success(true)+total_amount+unspents, and EVERY
#            per-unspent key Core emits is present with an equal value
#            (txid,vout,scriptPubKey,desc,amount,coinbase,height,blockhash,
#            confirmations). A MISSING Core key is reported as a divergence.
#   empty  : scanning an UNFUNDED fresh address -> total_amount 0 + [] unspents
#            on BOTH.
#
# Summary line (stdout):
#   SCANTXOUTSET haskoin: PASS desc=ok amount=ok shape=ok empty=ok
#   SCANTXOUTSET haskoin: FAIL <short reason>
# If the haskoin binary is missing, prints a GAP_RE-compatible "not built"
# message so the cross-impl runner can SKIP.
#
# Touches ONLY /tmp/sts-haskoin* + /tmp/sts-core* and ports 22019/22039
#   (haskoin RPC/P2P) + 22119/22139 (Core RPC/P2P). NEVER touches /data/nvme1/
#   or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$(find "$BASEDIR/haskoin/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

export haskoin_datadir="$BASEDIR/haskoin"   # BIP-39 wordlist resolution at runtime

HK_DATADIR="/tmp/sts-haskoin"
HK_RPC=22019
HK_P2P=22039
HK_LOG="$HK_DATADIR/node.log"
HK_COOKIE=""

CORE_DATADIR="/tmp/sts-core"
CORE_RPC=22119
CORE_P2P=22139
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic mining key (32-byte secret) we control, so we can sign a spend.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
NBLOCKS=110        # >100 so coinbase[1] is spendable (COINBASE_MATURITY=100)
FUND_BTC="49.999"  # amount paid to DEST in the spend (fee 0.001)

HK_PID=""
CORE_BG=""

log() { echo "[scantxoutset:haskoin] $*" >&2; }

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

pass() {
    echo "SCANTXOUTSET haskoin: PASS desc=$1 amount=$2 shape=$3 empty=$4"
    exit 0
}
fail() {
    echo "SCANTXOUTSET haskoin: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "datadir=$HK_DATADIR" 2>/dev/null || true
pkill -f "datadir=$CORE_DATADIR" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${HK_RPC}|${HK_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${HK_RPC}|${HK_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${HK_RPC}/${HK_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$HK_DATADIR" "$CORE_DATADIR"
mkdir -p "$HK_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
# GAP_RE-compatible message so the cross-impl runner SKIPs a missing binary.
[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || fail "haskoin binary not found / not built (build with: cabal build exe:haskoin)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive deterministic key material from SECRET. ─────────────────────
# mine = a bcrt1 p2wpkh address we mine coinbases to (we control its key);
# WIF  = that key, used to SIGN the spend on Core;
# dest = a FRESH p2wpkh address we pay the spend to (single known UTXO);
# unfd = a FRESH p2wpkh address we never fund (empty-scan target).
KEYINFO=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh, byte_to_base58
sec = bytes.fromhex('$SECRET')
k=ECKey(); k.set(sec, compressed=True)
mine = key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False)
wif = byte_to_base58(sec + b'\x01', 0xEF)          # regtest WIF (0xEF, compressed)
k2=ECKey(); k2.set(bytes.fromhex('22'*32), compressed=True)
dest = key_to_p2wpkh(k2.get_pubkey().get_bytes(), main=False)
k3=ECKey(); k3.set(bytes.fromhex('33'*32), compressed=True)
unfd = key_to_p2wpkh(k3.get_pubkey().get_bytes(), main=False)
print(mine); print(wif); print(dest); print(unfd)
" 2>/dev/null) || fail "could not derive key material (Core test_framework import failed)"
ADDR=$(echo "$KEYINFO" | sed -n '1p')
WIF=$(echo "$KEYINFO"  | sed -n '2p')
DEST=$(echo "$KEYINFO" | sed -n '3p')
UNFD=$(echo "$KEYINFO" | sed -n '4p')
[[ "$ADDR" == bcrt1* ]] || fail "derived mining address not regtest bech32: '$ADDR'"
[[ "$DEST" == bcrt1* ]] || fail "derived dest address not regtest bech32: '$DEST'"
[[ "$UNFD" == bcrt1* ]] || fail "derived unfunded address not regtest bech32: '$UNFD'"
[[ -n "$WIF" ]]         || fail "could not derive WIF"
log "mining=$ADDR dest=$DEST unfunded=$UNFD"

# ── JSON-RPC helpers. ─────────────────────────────────────────────────────
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
# Extract a python expression from a JSON string ($1=json, $2=expr over `d`).
jpy() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    elif v is None: print('')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# ── 3. Launch Core regtest oracle (-listen=0 -txindex=1). ─────────────────
launch_core_once() {
    # PID-scoped stop of OUR previous attempt (port-kill removed: 2026-06-10 fuser incident).
    if [[ -n "${CORE_BG:-}" ]]; then
        kill "$CORE_BG" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CORE_BG" 2>/dev/null || break; sleep 1; done
        kill -9 "$CORE_BG" 2>/dev/null || true
    fi
    for __hp in "${CORE_RPC}" "${CORE_P2P}"; do
        for _ in $(seq 1 15); do
            ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
            sleep 1
        done
    done
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -listen=0 -txindex=1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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
    log "launching Core oracle rpc=:$CORE_RPC p2p=:$CORE_P2P (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch haskoin on regtest (RPC-only). ──────────────────────────────
log "launching haskoin (regtest) rpc=:$HK_RPC p2p=:$HK_P2P -> $HK_LOG"
"$NODE_BIN" --network Regtest --datadir "$HK_DATADIR" node \
    --rpcport "$HK_RPC" --port "$HK_P2P" --listen False --metricsport 0 \
    >"$HK_LOG" 2>&1 &
HK_PID=$!
hk_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < hk_deadline )); do
    if [[ -z "$HK_COOKIE" ]]; then
        for c in "$HK_DATADIR/regtest/.cookie" "$HK_DATADIR/.cookie"; do
            [[ -f "$c" ]] && HK_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HK_COOKIE" ]]; then
        echo "$(hk_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$HK_PID" 2>/dev/null || { tail -n 30 "$HK_LOG" >&2 2>/dev/null || true; fail "haskoin exited during startup (see $HK_LOG)"; }
    sleep 1
done
[[ -n "$HK_COOKIE" ]] || fail "haskoin cookie never appeared within 120s"
echo "$(hk_rpc getblockcount '[]')" | grep -q '"result"' || fail "haskoin RPC never responded within 120s"
log "haskoin RPC ready"

# Sanity: identical regtest genesis on both nodes.
CORE_GEN=$(core_cli_retry getblockhash 0)
HK_GEN=$(jpy "$(hk_rpc getblockhash '[0]')" "d['result']")
[[ -n "$CORE_GEN" && "$CORE_GEN" == "$HK_GEN" ]] || fail "regtest genesis mismatch core=$CORE_GEN hk=$HK_GEN"

# ── 5. Mine NBLOCKS on Core, replay each block onto haskoin via submitblock. ─
log "mining $NBLOCKS blocks to $ADDR on Core, replaying to haskoin"
core_cli_retry generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null || fail "Core generatetoaddress failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS"

replay_to_height() {
    local target="$1" h cur
    cur=$(jpy "$(hk_rpc getblockcount '[]')" "d['result']")
    [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
    for (( h=cur+1; h<=target; h++ )); do
        local bh blkhex res
        bh=$(core_cli_retry getblockhash "$h")        || return 1
        blkhex=$(core_cli getblock "$bh" 0 2>/dev/null) || return 1
        [[ -n "$blkhex" ]] || return 1
        res=$(hk_rpc submitblock "[\"$blkhex\"]")
        echo "$res" | grep -q '"result":null' || {
            echo "$res" | grep -qi 'duplicate' || { log "submitblock h=$h rejected: $res"; return 1; }
        }
    done
    return 0
}
replay_to_height "$NBLOCKS" || fail "replaying Core blocks to haskoin failed"
HK_HEIGHT=$(jpy "$(hk_rpc getblockcount '[]')" "d['result']")
[[ "$HK_HEIGHT" == "$NBLOCKS" ]] || fail "haskoin height $HK_HEIGHT != $NBLOCKS after replay"
log "both nodes at height $NBLOCKS, identical chain"

# ── 6. Build + sign a real tx paying FUND_BTC to the FRESH DEST address. ───
# coinbase[1] is 50 BTC at vout 0 (mature). Spend it -> DEST (FUND_BTC), fee
# 0.001. After this confirms, DEST owns EXACTLY ONE unspent of FUND_BTC.
CB1_BH=$(core_cli_retry getblockhash 1)
CB1_TXID=$(core_cli getblock "$CB1_BH" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])")
[[ -n "$CB1_TXID" ]] || fail "could not read coinbase[1] txid"
RAW=$(core_cli createrawtransaction \
    "[{\"txid\":\"$CB1_TXID\",\"vout\":0}]" \
    "[{\"$DEST\":$FUND_BTC}]") || fail "createrawtransaction failed"
SIGNED_JSON=$(core_cli signrawtransactionwithkey "$RAW" "[\"$WIF\"]") || fail "signrawtransactionwithkey failed"
SIGNED_OK=$(jpy "$SIGNED_JSON" "d.get('complete')")
[[ "$SIGNED_OK" == "true" ]] || fail "tx not fully signed: $SIGNED_JSON"
TXHEX=$(jpy "$SIGNED_JSON" "d['hex']")
[[ -n "$TXHEX" ]] || fail "signed tx hex empty"
TXID=$(core_cli decoderawtransaction "$TXHEX" | python3 -c "import sys,json;print(json.load(sys.stdin)['txid'])")
[[ -n "$TXID" ]] || fail "could not derive spend txid"
log "spend txid=$TXID -> $DEST ($FUND_BTC BTC)"

# Submit to BOTH mempools (maxfeerate=0 disables the high-fee-rate guard).
CORE_SEND=$(core_cli sendrawtransaction "$TXHEX" 0 2>&1) || fail "Core sendrawtransaction failed: $CORE_SEND"
[[ "$CORE_SEND" == "$TXID" ]] || fail "Core sendrawtransaction returned '$CORE_SEND' != $TXID"
HK_SEND_ENV=$(hk_rpc sendrawtransaction "[\"$TXHEX\", 0]")
HK_SEND=$(jpy "$HK_SEND_ENV" "d.get('result')")
if [[ "$HK_SEND" != "$TXID" ]]; then
    HK_INMP=$(jpy "$(hk_rpc getrawmempool '[]')" "'$TXID' in d.get('result', [])")
    [[ "$HK_INMP" == "true" ]] || fail "haskoin sendrawtransaction did not accept tx: $HK_SEND_ENV"
fi

# Mine the spend into a block on Core, replay to haskoin -> DEST now in UTXO set.
NEWBLK=$(core_cli generatetoaddress 1 "$ADDR" | python3 -c "import sys,json;print(json.load(sys.stdin)[0])")
[[ -n "$NEWBLK" ]] || fail "could not mine confirming block on Core"
NEWH=$(( NBLOCKS + 1 ))
replay_to_height "$NEWH" || fail "could not replay confirming block to haskoin"
# Confirm the spend output (DEST, vout 0) is in the confirmed tx on Core.
CORE_TXBH=$(core_cli getrawtransaction "$TXID" 1 "$NEWBLK" | python3 -c "import sys,json;print(json.load(sys.stdin)['blockhash'])")
[[ "$CORE_TXBH" == "$NEWBLK" ]] || fail "Core confirmed blockhash $CORE_TXBH != $NEWBLK"
log "spend confirmed at height $NEWH on BOTH nodes"

# ── 7. scantxoutset start addr(DEST) on BOTH nodes. ───────────────────────
SCANOBJ="[{\"desc\":\"addr($DEST)\"}]"
CORE_SCAN=$(core_cli scantxoutset start "$SCANOBJ") || fail "Core scantxoutset start failed"
[[ -n "$CORE_SCAN" ]] || fail "Core scantxoutset returned empty"
HK_SCAN_ENV=$(hk_rpc scantxoutset "[\"start\", $SCANOBJ]")
echo "$HK_SCAN_ENV" | grep -q '"result"' || fail "haskoin scantxoutset errored: $HK_SCAN_ENV"
HK_SCAN=$(jpy "$HK_SCAN_ENV" "json.dumps(d['result'])")
[[ -n "$HK_SCAN" ]] || fail "haskoin scantxoutset result empty"

cs() { jpy "$CORE_SCAN" "$1"; }   # Core scan field
hs() { jpy "$HK_SCAN"   "$1"; }   # haskoin scan field

# Sanity: Core matched exactly one DEST unspent of FUND_BTC.
CORE_N=$(cs "len(d['unspents'])")
[[ "$CORE_N" == "1" ]] || fail "Core matched $CORE_N unspents for DEST, expected 1 (test setup)"
CORE_TOTAL=$(cs "format(d['total_amount'],'.8f')")
[[ "$CORE_TOTAL" == "$(printf '%.8f' "$FUND_BTC")" ]] || fail "Core total_amount $CORE_TOTAL != funded $FUND_BTC"

# ── TEST: amount — impl total_amount == Core total_amount == funded value. ──
AMOUNT_T="bad"
HK_TOTAL=$(hs "format(d['total_amount'],'.8f')")
[[ -n "$HK_TOTAL" ]] || fail "haskoin total_amount absent/unparseable in: $HK_SCAN"
[[ "$HK_TOTAL" == "$CORE_TOTAL" ]] || fail "total_amount mismatch: hk=$HK_TOTAL core=$CORE_TOTAL"
AMOUNT_T="ok"
log "amount ok: total_amount hk=$HK_TOTAL core=$CORE_TOTAL"

# ── TEST: desc — matched unspent txid/vout/amount + desc EQUAL Core's. ─────
DESC_T="bad"
HK_N=$(hs "len(d['unspents'])")
[[ "$HK_N" == "1" ]] || fail "haskoin matched $HK_N unspents for DEST, expected 1"
# The matched outpoint is (TXID, 0); compare the load-bearing per-unspent fields.
HK_U_TXID=$(hs "d['unspents'][0]['txid']")
HK_U_VOUT=$(hs "d['unspents'][0]['vout']")
HK_U_AMT=$(hs "format(d['unspents'][0]['amount'],'.8f')")
CORE_U_TXID=$(cs "d['unspents'][0]['txid']")
CORE_U_VOUT=$(cs "d['unspents'][0]['vout']")
CORE_U_AMT=$(cs "format(d['unspents'][0]['amount'],'.8f')")
[[ "$HK_U_TXID" == "$TXID" ]]      || fail "unspent txid '$HK_U_TXID' != spend txid $TXID"
[[ "$HK_U_TXID" == "$CORE_U_TXID" ]] || fail "unspent txid mismatch: hk=$HK_U_TXID core=$CORE_U_TXID"
[[ "$HK_U_VOUT" == "$CORE_U_VOUT" ]] || fail "unspent vout mismatch: hk=$HK_U_VOUT core=$CORE_U_VOUT"
[[ "$HK_U_AMT" == "$CORE_U_AMT" ]]   || fail "unspent amount mismatch: hk=$HK_U_AMT core=$CORE_U_AMT"
# desc compared modulo the optional #checksum suffix (Core: addr(..)#cksum;
# matching descriptors are equivalent with or without the checksum).
HK_U_DESC=$(hs "d['unspents'][0]['desc'].split('#')[0]")
CORE_U_DESC=$(cs "d['unspents'][0]['desc'].split('#')[0]")
[[ -n "$HK_U_DESC" ]] || fail "haskoin unspent desc absent"
[[ "$HK_U_DESC" == "$CORE_U_DESC" ]] || fail "unspent desc mismatch (checksum-stripped): hk='$HK_U_DESC' core='$CORE_U_DESC'"
DESC_T="ok"
log "desc ok: unspent txid/vout/amount/desc match Core"

# ── TEST: shape — result OBJECT carries every per-unspent key Core emits, ──
#    each with a value equal to Core's (a MISSING Core key = divergence).
SHAPE_T="bad"
# Top-level shape.
[[ "$(hs "d.get('success')")" == "true" ]] || fail "shape: success != true (hk='$(hs "d.get('success')")')"
[[ "$(hs "'total_amount' in d")" == "true" ]] || fail "shape: top-level total_amount missing"
[[ "$(hs "isinstance(d.get('unspents'), list)")" == "true" ]] || fail "shape: unspents is not an array"
# txouts/height/bestblock present and integer/hex as Core's.
[[ "$(hs "isinstance(d.get('txouts'), int)")" == "true" ]] || fail "shape: txouts not an int"
[[ "$(hs "isinstance(d.get('height'), int)")" == "true" ]] || fail "shape: height not an int"
[[ -n "$(hs "d.get('bestblock')")" ]] || fail "shape: bestblock absent"
# bestblock + height must equal Core's (deterministic at identical tip).
[[ "$(hs "d['bestblock']")" == "$(cs "d['bestblock']")" ]] || fail "shape: bestblock mismatch hk=$(hs "d['bestblock']") core=$(cs "d['bestblock']")"
[[ "$(hs "d['height']")" == "$(cs "d['height']")" ]] || fail "shape: height mismatch hk=$(hs "d['height']") core=$(cs "d['height']")"
# Per-unspent: require EVERY key Core emits, value-equal where deterministic.
MISSING=""
for k in txid vout scriptPubKey desc amount coinbase height blockhash confirmations; do
    present=$(hs "'$k' in d['unspents'][0]")
    [[ "$present" == "true" ]] || MISSING="$MISSING $k"
done
[[ -z "$MISSING" ]] || fail "shape divergence: haskoin unspent is MISSING Core key(s):$MISSING (Core emits txid,vout,scriptPubKey,desc,amount,coinbase,height,blockhash,confirmations)"
# Value-equality on the deterministic keys that exist on both.
[[ "$(hs "d['unspents'][0]['scriptPubKey']")" == "$(cs "d['unspents'][0]['scriptPubKey']")" ]] || fail "shape: scriptPubKey mismatch"
[[ "$(hs "d['unspents'][0]['coinbase']")" == "$(cs "d['unspents'][0]['coinbase']")" ]] || fail "shape: coinbase mismatch hk=$(hs "d['unspents'][0]['coinbase']") core=$(cs "d['unspents'][0]['coinbase']")"
[[ "$(hs "d['unspents'][0]['height']")" == "$(cs "d['unspents'][0]['height']")" ]] || fail "shape: unspent.height mismatch hk=$(hs "d['unspents'][0]['height']") core=$(cs "d['unspents'][0]['height']")"
[[ "$(hs "d['unspents'][0]['blockhash']")" == "$(cs "d['unspents'][0]['blockhash']")" ]] || fail "shape: blockhash mismatch hk=$(hs "d['unspents'][0]['blockhash']") core=$(cs "d['unspents'][0]['blockhash']")"
[[ "$(hs "d['unspents'][0]['confirmations']")" == "$(cs "d['unspents'][0]['confirmations']")" ]] || fail "shape: confirmations mismatch hk=$(hs "d['unspents'][0]['confirmations']") core=$(cs "d['unspents'][0]['confirmations']")"
SHAPE_T="ok"
log "shape ok: all Core unspent keys present + deterministic values equal"

# ── TEST: empty — unfunded address -> total_amount 0 + [] on BOTH. ────────
EMPTY_T="bad"
ESCAN="[{\"desc\":\"addr($UNFD)\"}]"
CORE_E=$(core_cli scantxoutset start "$ESCAN") || fail "Core empty scantxoutset failed"
HK_E_ENV=$(hk_rpc scantxoutset "[\"start\", $ESCAN]")
echo "$HK_E_ENV" | grep -q '"result"' || fail "haskoin empty scantxoutset errored: $HK_E_ENV"
HK_E=$(jpy "$HK_E_ENV" "json.dumps(d['result'])")
CORE_E_TOTAL=$(jpy "$CORE_E" "format(d['total_amount'],'.8f')")
CORE_E_N=$(jpy "$CORE_E" "len(d['unspents'])")
HK_E_TOTAL=$(jpy "$HK_E" "format(d['total_amount'],'.8f')")
HK_E_N=$(jpy "$HK_E" "len(d['unspents'])")
[[ "$CORE_E_TOTAL" == "0.00000000" && "$CORE_E_N" == "0" ]] || fail "Core empty-scan not empty: total=$CORE_E_TOTAL n=$CORE_E_N"
[[ "$HK_E_TOTAL" == "0.00000000" ]] || fail "empty-scan: haskoin total_amount $HK_E_TOTAL != 0"
[[ "$HK_E_N" == "0" ]] || fail "empty-scan: haskoin unspents not empty (n=$HK_E_N)"
[[ "$(jpy "$HK_E" "d.get('success')")" == "true" ]] || fail "empty-scan: haskoin success != true"
EMPTY_T="ok"
log "empty ok: unfunded scan -> total 0 / [] on both"

# ── BONUS: status (idle -> null) + abort (idle -> false) parity. ──────────
HK_STATUS=$(hk_rpc scantxoutset "[\"status\"]")
echo "$HK_STATUS" | grep -q '"result":null' || log "note: haskoin status (idle) not null: $HK_STATUS"
HK_ABORT=$(jpy "$(hk_rpc scantxoutset "[\"abort\"]")" "d.get('result')")
[[ "$HK_ABORT" == "false" ]] || log "note: haskoin abort (idle) != false: '$HK_ABORT'"

# ── Done. ──────────────────────────────────────────────────────────────────
log "PASS: haskoin scantxoutset matches Core (desc + amount + shape + empty)"
pass "$DESC_T" "$AMOUNT_T" "$SHAPE_T" "$EMPTY_T"

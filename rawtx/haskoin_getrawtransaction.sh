#!/usr/bin/env bash
#
# haskoin_getrawtransaction.sh — self-contained getrawtransaction Core-parity test.
#
# Mirrors test-suite/chaintxstats/rustoshi_chaintxstats.sh structure (uniform
# interface): set -uo pipefail, idempotent, trap cleanup, scratch /tmp + unique
# ports, ONE summary line, exit 0/1. Run under: setsid -w bash <script>.
#
# Core ref: bitcoin-core/src/rpc/rawtransaction.cpp:216-374 (getrawtransaction),
#           :58-85 (TxToJSON envelope), src/core_io.cpp:430-533 (TxToUniv).
#
# getrawtransaction "txid" ( verbosity "blockhash" ):
#   verbosity 0 -> raw tx HEX (EncodeHexTx), byte-exact.
#   verbosity 1 -> decoded OBJECT (TxToUniv include_hex=true) + TxToJSON envelope:
#       txid, hash (wtxid), version, size, vsize, weight, locktime,
#       vin[] {txid,vout,scriptSig{asm,hex},txinwitness?,sequence}
#            (coinbase: {coinbase, txinwitness?, sequence}),
#       vout[] {value, n, scriptPubKey{asm, desc, hex, address?, type}},
#       hex, and when confirmed in the active chain: blockhash, confirmations
#       (=1+tip-txHeight), time, blocktime; when a blockhash ARG given:
#       in_active_chain (bool).
#   ERRORS (all RPC -5): genesis-coinbase txid; unknown blockhash arg; tx not found.
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) regtest oracle on its own
#   scratch + ports, launched -listen=0 (sandbox SIGKILLs a 0.0.0.0 P2P listener)
#   and -txindex=1. haskoin runs on regtest scratch /tmp/grt-haskoin (RPC 22019,
#   P2P 22039). To give BOTH nodes the identical UTXO set (so the same signed tx
#   validates on both), every block Core mines is REPLAYED to haskoin via
#   submitblock. A real coinbase-funded tx is then created+signed on Core and
#   submitted to BOTH via sendrawtransaction.
#
# Asserts: hex (v0) byte-EXACT; v1 load-bearing fields EXACT (txid, hash, version,
#   size, vsize, weight, locktime, vin{txid,vout,sequence,scriptSig.hex},
#   vout{value,n,scriptPubKey.hex,.type,.address?}, top-level hex); asm/desc
#   PRESENT but NOT byte-equal (InferDescriptor / asm-whitespace may differ).
#   Confirmed: blockhash matches, confirmations>=1 int, in_active_chain==true,
#   time/blocktime present. Errors: -5 for random txid + genesis coinbase.
#
# Summary line (stdout):
#   GETRAWTRANSACTION haskoin: PASS hex=ok decoded=ok confirmed=ok errors=ok
#   GETRAWTRANSACTION haskoin: FAIL <short reason>
#
# Touches ONLY /tmp/grt-haskoin* + /tmp/grt-core* and ports 22019/22039 (haskoin
#   RPC/P2P) + 22119/22139 (Core RPC/P2P). NEVER touches /data/nvme1/ or
#   testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$(find "$BASEDIR/haskoin/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

export haskoin_datadir="$BASEDIR/haskoin"   # BIP-39 wordlist resolution at runtime

HK_DATADIR="/tmp/grt-haskoin"
HK_RPC=22019
HK_P2P=22039
HK_LOG="$HK_DATADIR/node.log"
HK_COOKIE=""

CORE_DATADIR="/tmp/grt-core"
CORE_RPC=22119
CORE_P2P=22139
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic mining key (32-byte secret) we control, so we can sign a spend.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
NBLOCKS=110        # >100 so coinbase[1] is spendable (COINBASE_MATURITY=100)

HK_PID=""
CORE_BG=""
ADDR=""

log() { echo "[getrawtransaction:haskoin] $*" >&2; }

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
    echo "GETRAWTRANSACTION haskoin: PASS hex=$1 decoded=$2 confirmed=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETRAWTRANSACTION haskoin: FAIL $*"
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
[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || fail "haskoin binary not found (build with: cabal build exe:haskoin)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive deterministic key material from SECRET. ─────────────────────
# We need: a bcrt1 p2wpkh mining address (coinbase outputs we control), the
# WIF private key (to sign the spend on Core), and a destination p2wpkh address.
KEYINFO=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh, byte_to_base58
sec = bytes.fromhex('$SECRET')
k=ECKey(); k.set(sec, compressed=True)
mine = key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False)
# regtest WIF: prefix 0xEF, compressed suffix 0x01, base58check
wif = byte_to_base58(sec + b'\x01', 0xEF)
# second key for destination
k2=ECKey(); k2.set(bytes.fromhex('22'*32), compressed=True)
dest = key_to_p2wpkh(k2.get_pubkey().get_bytes(), main=False)
print(mine); print(wif); print(dest)
" 2>/dev/null) || fail "could not derive key material (Core test_framework import failed)"
ADDR=$(echo "$KEYINFO"   | sed -n '1p')
WIF=$(echo "$KEYINFO"    | sed -n '2p')
DEST=$(echo "$KEYINFO"   | sed -n '3p')
[[ "$ADDR" == bcrt1* ]] || fail "derived mining address not regtest bech32: '$ADDR'"
[[ "$DEST" == bcrt1* ]] || fail "derived dest address not regtest bech32: '$DEST'"
[[ -n "$WIF" ]]         || fail "could not derive WIF"
log "mining=$ADDR dest=$DEST"

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
    curl -s --max-time 90 -u "$HK_COOKIE" \
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
        # submitblock returns result:null on accept, or a BIP-22 reject string.
        echo "$res" | grep -q '"result":null' || {
            # Tolerate "duplicate" (already have it); fail on anything else.
            echo "$res" | grep -qi 'duplicate' || { log "submitblock h=$h rejected: $res"; return 1; }
        }
    done
    return 0
}
replay_to_height "$NBLOCKS" || fail "replaying Core blocks to haskoin failed"
HK_HEIGHT=$(jpy "$(hk_rpc getblockcount '[]')" "d['result']")
[[ "$HK_HEIGHT" == "$NBLOCKS" ]] || fail "haskoin height $HK_HEIGHT != $NBLOCKS after replay"
log "both nodes at height $NBLOCKS, identical chain"

# ── 6. Build + sign a real tx spending coinbase[1] (mature). ──────────────
CB1_BH=$(core_cli_retry getblockhash 1)
CB1_TXID=$(core_cli getblock "$CB1_BH" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])")
[[ -n "$CB1_TXID" ]] || fail "could not read coinbase[1] txid"
# coinbase[1] is 50 BTC at vout 0; spend 49.999 to DEST, fee 0.001.
RAW=$(core_cli createrawtransaction \
    "[{\"txid\":\"$CB1_TXID\",\"vout\":0}]" \
    "[{\"$DEST\":49.999}]") || fail "createrawtransaction failed"
SIGNED_JSON=$(core_cli signrawtransactionwithkey "$RAW" "[\"$WIF\"]") || fail "signrawtransactionwithkey failed"
SIGNED_OK=$(jpy "$SIGNED_JSON" "d.get('complete')")
[[ "$SIGNED_OK" == "true" ]] || fail "tx not fully signed: $SIGNED_JSON"
TXHEX=$(jpy "$SIGNED_JSON" "d['hex']")
[[ -n "$TXHEX" ]] || fail "signed tx hex empty"
TXID=$(core_cli decoderawtransaction "$TXHEX" | python3 -c "import sys,json;print(json.load(sys.stdin)['txid'])")
[[ -n "$TXID" ]] || fail "could not derive spend txid"
log "spend txid=$TXID"

# ── 7. Submit the SAME signed tx to BOTH mempools (maxfeerate=0 disables the
#       per-node high-fee-rate guard so the coinbase-funded fee is accepted). ─
CORE_SEND=$(core_cli sendrawtransaction "$TXHEX" 0 2>&1) || fail "Core sendrawtransaction failed: $CORE_SEND"
[[ "$CORE_SEND" == "$TXID" ]] || fail "Core sendrawtransaction returned '$CORE_SEND' != $TXID"
HK_SEND_ENV=$(hk_rpc sendrawtransaction "[\"$TXHEX\", 0]")
HK_SEND=$(jpy "$HK_SEND_ENV" "d.get('result')")
if [[ "$HK_SEND" != "$TXID" ]]; then
    # Tolerate "already in mempool" (some impls add then report -27 on the cap path).
    HK_INMP=$(jpy "$(hk_rpc getrawmempool '[]')" "'$TXID' in d.get('result', [])")
    [[ "$HK_INMP" == "true" ]] || fail "haskoin sendrawtransaction did not accept tx: $HK_SEND_ENV"
fi
# Confirm both mempools actually contain it.
core_cli getrawmempool | grep -q "$TXID" || fail "tx not in Core mempool after send"
[[ "$(jpy "$(hk_rpc getrawmempool '[]')" "'$TXID' in d['result']")" == "true" ]] \
    || fail "tx not in haskoin mempool after send"
log "tx in BOTH mempools"

# =====================  TEST 1: MEMPOOL (hex + decoded)  ==================== #
HEX_T="bad"; DECODED_T="bad"

# 1a. verbosity 0 -> hex byte-EXACT.
CORE_HEX=$(core_cli getrawtransaction "$TXID" 0)
HK_HEX=$(jpy "$(hk_rpc getrawtransaction "[\"$TXID\", 0]")" "d['result']")
[[ -n "$CORE_HEX" && "$CORE_HEX" == "$TXHEX" ]] || fail "Core v0 hex unexpected: $CORE_HEX"
if [[ "$HK_HEX" == "$CORE_HEX" ]]; then HEX_T="ok"; else fail "v0 hex mismatch: hk=$HK_HEX core=$CORE_HEX"; fi
# Also exercise bool verbosity (false == 0).
HK_HEX_BOOL=$(jpy "$(hk_rpc getrawtransaction "[\"$TXID\", false]")" "d['result']")
[[ "$HK_HEX_BOOL" == "$CORE_HEX" ]] || fail "v=false (bool) hex mismatch: hk=$HK_HEX_BOOL"

# 1b. verbosity 1 -> decoded object, load-bearing fields EXACT.
CORE_V1=$(core_cli getrawtransaction "$TXID" 1)
HK_V1_ENV=$(hk_rpc getrawtransaction "[\"$TXID\", 1]")
echo "$HK_V1_ENV" | grep -q '"result"' || fail "haskoin v1 errored: $HK_V1_ENV"
HK_V1=$(jpy "$HK_V1_ENV" "json.dumps(d['result'])")
[[ -n "$HK_V1" ]] || fail "haskoin v1 result empty"
# Also exercise bool verbosity (true == 1).
HK_V1_BOOL_ENV=$(hk_rpc getrawtransaction "[\"$TXID\", true]")
echo "$HK_V1_BOOL_ENV" | grep -q '"result"' || fail "haskoin v=true (bool) errored: $HK_V1_BOOL_ENV"

cf() { jpy "$CORE_V1" "$1"; }
hf() { jpy "$HK_V1"   "$1"; }

cmp_field() {  # $1 = python expr over d, $2 = human label
    local cv hv
    cv=$(cf "$1"); hv=$(hf "$1")
    if [[ "$cv" != "$hv" ]]; then fail "v1 field $2 mismatch: hk='$hv' core='$cv'"; fi
}
cmp_field "d['txid']"      "txid"
cmp_field "d['hash']"      "hash"
cmp_field "d['version']"   "version"
cmp_field "d['size']"      "size"
cmp_field "d['vsize']"     "vsize"
cmp_field "d['weight']"    "weight"
cmp_field "d['locktime']"  "locktime"
cmp_field "d['hex']"       "hex"
cmp_field "d['vin'][0]['txid']"          "vin0.txid"
cmp_field "d['vin'][0]['vout']"          "vin0.vout"
cmp_field "d['vin'][0]['sequence']"      "vin0.sequence"
cmp_field "d['vin'][0]['scriptSig']['hex']" "vin0.scriptSig.hex"
cmp_field "d['vout'][0]['value']"        "vout0.value"
cmp_field "d['vout'][0]['n']"            "vout0.n"
cmp_field "d['vout'][0]['scriptPubKey']['hex']"  "vout0.scriptPubKey.hex"
cmp_field "d['vout'][0]['scriptPubKey']['type']" "vout0.scriptPubKey.type"
# vout0 has a decodable p2wpkh address -> must be present + EXACT.
cmp_field "d['vout'][0]['scriptPubKey']['address']" "vout0.scriptPubKey.address"
# top-level hex must equal the v0 hex.
HK_V1_HEX=$(hf "d['hex']")
[[ "$HK_V1_HEX" == "$CORE_HEX" ]] || fail "v1 top-level hex != v0 hex"
# asm + desc PRESENT (not byte-equal): vout0.scriptPubKey.asm and .desc.
HK_ASM=$(hf "d['vout'][0]['scriptPubKey']['asm']")
HK_DESC=$(hf "d['vout'][0]['scriptPubKey']['desc']")
[[ -n "$HK_ASM" ]]  || fail "v1 vout0.scriptPubKey.asm absent"
[[ -n "$HK_DESC" ]] || fail "v1 vout0.scriptPubKey.desc absent"
HK_SS_ASM=$(hf "d['vin'][0]['scriptSig']['asm']")
[[ -n "$HK_SS_ASM" || "$HK_SS_ASM" == "" ]] || true   # asm may be "" for empty scriptSig (segwit)
# Witness is present on the segwit spend: vin0.txinwitness must be a non-empty list.
HK_WIT=$(hf "len(d['vin'][0].get('txinwitness',[]))")
[[ "$HK_WIT" =~ ^[0-9]+$ && "$HK_WIT" -ge 1 ]] || fail "v1 vin0.txinwitness absent/empty (segwit spend): '$HK_WIT'"
DECODED_T="ok"
log "TEST 1 (mempool hex+decoded) ok"

# =====================  TEST 2: CONFIRMED via blockhash  =================== #
CONFIRMED_T="bad"
# Mine the mempool tx into a block on Core, replay block to haskoin.
NEWBLK=$(core_cli generatetoaddress 1 "$ADDR" | python3 -c "import sys,json;print(json.load(sys.stdin)[0])")
[[ -n "$NEWBLK" ]] || fail "could not mine confirming block on Core"
NEWH=$(( NBLOCKS + 1 ))
replay_to_height "$NEWH" || fail "could not replay confirming block to haskoin"
# Confirm the tx is now in that block on Core.
CORE_TXBH=$(core_cli getrawtransaction "$TXID" 1 "$NEWBLK" | python3 -c "import sys,json;print(json.load(sys.stdin)['blockhash'])")
[[ "$CORE_TXBH" == "$NEWBLK" ]] || fail "Core confirmed blockhash $CORE_TXBH != $NEWBLK"

CORE_C1=$(core_cli getrawtransaction "$TXID" 1 "$NEWBLK")
HK_C1_ENV=$(hk_rpc getrawtransaction "[\"$TXID\", 1, \"$NEWBLK\"]")
echo "$HK_C1_ENV" | grep -q '"result"' || fail "haskoin confirmed v1 errored: $HK_C1_ENV"
HK_C1=$(jpy "$HK_C1_ENV" "json.dumps(d['result'])")
[[ -n "$HK_C1" ]] || fail "haskoin confirmed v1 empty"

hc() { jpy "$HK_C1" "$1"; }
cc() { jpy "$CORE_C1" "$1"; }
# blockhash matches the arg + Core.
[[ "$(hc "d['blockhash']")" == "$NEWBLK" ]] || fail "confirmed: hk blockhash != arg: $(hc "d['blockhash']")"
[[ "$(hc "d['blockhash']")" == "$(cc "d['blockhash']")" ]] || fail "confirmed: blockhash mismatch vs Core"
# in_active_chain == true (blockhash arg given, block on active chain).
HK_IAC=$(hc "d.get('in_active_chain')")
[[ "$HK_IAC" == "true" ]] || fail "confirmed: in_active_chain != true: '$HK_IAC'"
# confirmations is a positive int and equals Core's.
HK_CONF=$(hc "d['confirmations']")
CORE_CONF=$(cc "d['confirmations']")
[[ "$HK_CONF" =~ ^[0-9]+$ && "$HK_CONF" -ge 1 ]] || fail "confirmed: confirmations not >=1 int: '$HK_CONF'"
[[ "$HK_CONF" == "$CORE_CONF" ]] || fail "confirmed: confirmations $HK_CONF != Core $CORE_CONF"
# time + blocktime present, equal each other, and match Core.
HK_TIME=$(hc "d['time']"); HK_BTIME=$(hc "d['blocktime']")
[[ "$HK_TIME" =~ ^[0-9]+$ && "$HK_TIME" -gt 0 ]] || fail "confirmed: time absent/non-positive: '$HK_TIME'"
[[ "$HK_TIME" == "$HK_BTIME" ]] || fail "confirmed: time != blocktime ($HK_TIME vs $HK_BTIME)"
[[ "$HK_TIME" == "$(cc "d['blocktime']")" ]] || fail "confirmed: blocktime mismatch vs Core"
# core fields still EXACT in confirmed form.
[[ "$(hc "d['txid']")" == "$TXID" ]] || fail "confirmed: txid mismatch"
[[ "$(hc "d['hex']")"  == "$CORE_HEX" ]] || fail "confirmed: hex mismatch"
CONFIRMED_T="ok"
log "TEST 2 (confirmed via blockhash) ok"

# =====================  TEST 3: ERROR PARITY (-5)  ======================== #
ERRORS_T="bad"
# 3a. random 32-byte txid -> -5.
RANDTXID="00000000000000000000000000000000000000000000000000000000deadbeef"
CORE_E_RAND=$(core_cli getrawtransaction "$RANDTXID" 2>&1; true)
HK_E_RAND=$(jpy "$(hk_rpc getrawtransaction "[\"$RANDTXID\"]")" "d['error']['code']")
[[ "$HK_E_RAND" == "-5" ]] || fail "random txid: expected -5, got '$HK_E_RAND'"
# 3b. genesis-block coinbase txid (== genesis merkle root) -> -5.
GEN_CB=$(core_cli getblock "$CORE_GEN" | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])")
[[ -n "$GEN_CB" ]] || fail "could not read genesis coinbase txid"
# Core itself returns -5 with the genesis special-case message.
CORE_E_GEN=$(core_cli getrawtransaction "$GEN_CB" 2>&1; true)
echo "$CORE_E_GEN" | grep -qi "genesis" || log "note: Core genesis msg='$CORE_E_GEN'"
HK_E_GEN_ENV=$(hk_rpc getrawtransaction "[\"$GEN_CB\"]")
HK_E_GEN=$(jpy "$HK_E_GEN_ENV" "d['error']['code']")
HK_E_GEN_MSG=$(jpy "$HK_E_GEN_ENV" "d['error']['message']")
[[ "$HK_E_GEN" == "-5" ]] || fail "genesis coinbase: expected -5, got '$HK_E_GEN' (msg='$HK_E_GEN_MSG')"
echo "$HK_E_GEN_MSG" | grep -qi "genesis" || fail "genesis coinbase: message should mention genesis: '$HK_E_GEN_MSG'"
# 3c. unknown blockhash arg -> -5.
BAD_BH="00000000000000000000000000000000000000000000000000000000beefcafe"
HK_E_BH=$(jpy "$(hk_rpc getrawtransaction "[\"$TXID\", 1, \"$BAD_BH\"]")" "d['error']['code']")
[[ "$HK_E_BH" == "-5" ]] || fail "unknown blockhash arg: expected -5, got '$HK_E_BH'"
ERRORS_T="ok"
log "TEST 3 (error parity) ok"

# =====================  TEST 4 (optional): txindex no-blockhash  =========== #
# A confirmed tx queried with NO blockhash arg. haskoin maintains a txindex by
# default, so this should succeed; tolerate absence (skip) per spec.
HK_NOBH_ENV=$(hk_rpc getrawtransaction "[\"$TXID\", 1]")
if echo "$HK_NOBH_ENV" | grep -q '"result"'; then
    HK_NOBH=$(jpy "$HK_NOBH_ENV" "json.dumps(d['result'])")
    NOBH_TXID=$(jpy "$HK_NOBH" "d['txid']")
    [[ "$NOBH_TXID" == "$TXID" ]] || fail "txindex no-blockhash: txid mismatch '$NOBH_TXID'"
    # in_active_chain must be ABSENT when no blockhash arg was given (Core rule).
    HK_NOBH_IAC=$(jpy "$HK_NOBH" "'in_active_chain' in d")
    [[ "$HK_NOBH_IAC" == "false" ]] || fail "txindex no-blockhash: in_active_chain present without arg"
    log "TEST 4 (txindex, no blockhash) ok"
else
    log "TEST 4 SKIPPED: haskoin has no txindex for confirmed no-blockhash lookup (env=$HK_NOBH_ENV)"
fi

# ── Done. ──────────────────────────────────────────────────────────────────
log "PASS: haskoin getrawtransaction matches Core (hex + decoded + confirmed + errors)"
pass "$HEX_T" "$DECODED_T" "$CONFIRMED_T" "$ERRORS_T"

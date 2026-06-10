#!/usr/bin/env bash
#
# blockbrew_getrawtransaction.sh — self-contained getrawtransaction Core-parity test.
#
# The RPC-surface green-cell that follows getindexinfo / getchaintxstats: the
# block-explorer keystone. NOT consensus, but byte-exact-shaped against
# Bitcoin Core (bitcoin-core/src/rpc/rawtransaction.cpp getrawtransaction +
# core_io.cpp TxToUniv).
#
# WHAT IT PROVES
#   getrawtransaction on blockbrew returns, for a REAL segwit spend tx:
#     - verbosity 0  : the byte-EXACT raw-tx hex (EncodeHexTx).
#     - verbosity 1  : a decoded object whose load-bearing fields are EXACT vs
#                      Core's decoder of the IDENTICAL bytes — txid, hash (wtxid),
#                      version, size, vsize, weight, locktime, each vin
#                      {txid,vout,sequence}+scriptSig.hex+txinwitness, each vout
#                      {value,n,scriptPubKey.hex,.type,.address?}, and the
#                      top-level hex. asm/desc are asserted PRESENT but NOT
#                      byte-equal (InferDescriptor + asm-whitespace legitimately
#                      differ between impls).
#     - bool verbosity: false == verbosity 0, true == verbosity 1.
#     - confirmed    : looked up via the blockhash arg -> blockhash matches,
#                      confirmations is a right int (>=1), in_active_chain==true,
#                      time/blocktime present and equal (= the block's nTime).
#     - txindex      : v1 with NO blockhash on a CONFIRMED tx succeeds
#                      (blockbrew launched with -txindex).
#     - errors       : random txid -> -5; genesis-coinbase txid -> -5.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core). The decoded-object
#   shape (TxToUniv) is the SAME code Core runs for getrawtransaction v1 and for
#   decoderawtransaction, MINUS the block-context envelope (blockhash/time/...).
#   Because blockbrew and Core build their coinbases differently (Core: bare
#   "5100"; blockbrew: height+extranonce + a 2nd output), mining to a shared key
#   does NOT yield identical UTXOs — so instead of cross-broadcasting bytes we:
#     1. let blockbrew's OWN wallet build+sign+broadcast a real segwit spend, and
#     2. feed that EXACT hex to Core's decoderawtransaction to get the oracle
#        decoded object for the very same bytes.
#   Identical bytes decode identically, so every load-bearing field is directly
#   comparable byte-for-byte. The block-context fields (confirmed lookup) are
#   asserted by content + Core's own emit rules.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/blockbrew_chaintxstats.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETRAWTRANSACTION blockbrew: PASS hex=ok decoded=ok confirmed=ok errors=ok
#   FAIL: GETRAWTRANSACTION blockbrew: FAIL <short reason>
#
# Touches ONLY /tmp/grt-blockbrew/ + /tmp/grt-core-bb/ and ports
#   22013/22033 (blockbrew RPC/P2P), 22015/22035 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Core is launched -listen=0 (RPC only): the sandbox SIGKILLs any bitcoind
#   binding a 0.0.0.0 P2P listener ~2s after load.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/blockbrew/blockbrew"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

BB_DATADIR="/tmp/grt-blockbrew"
BB_RPC=22013
BB_P2P=22033
BB_LOG="$BB_DATADIR/node.log"
BB_URL="http://127.0.0.1:${BB_RPC}"
BB_COOKIE_FILE="$BB_DATADIR/regtest/.cookie"

CORE_DATADIR="/tmp/grt-core-bb"
CORE_RPC=22015
CORE_P2P=22035
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS_MINE=120     # mature coinbase funds for the wallet spend

BB_PID=""
BB_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getrawtransaction:blockbrew] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BB_PID" ]] && kill -0 "$BB_PID" 2>/dev/null; then
        kill "$BB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$BB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETRAWTRANSACTION blockbrew: PASS hex=ok decoded=ok confirmed=ok errors=ok"
    exit 0
}
fail() {
    echo "GETRAWTRANSACTION blockbrew: FAIL $*"
    exit 1
}

# ── JSON field extractor (jq-free; stdlib python3). ───────────────────────
# jget <json> <path...> : path is a sequence of keys/indices into the value;
# integer tokens index into arrays. Prints the value or "<MISSING>".
jget() {
    local js="$1"; shift
    python3 - "$js" "$@" <<'PY'
import sys, json
js = sys.argv[1]
keys = sys.argv[2:]
try:
    d = json.loads(js)
except Exception:
    print("<PARSE-ERR>"); sys.exit(0)
cur = d
for k in keys:
    if isinstance(cur, list):
        try:
            idx = int(k)
        except ValueError:
            print("<MISSING>"); sys.exit(0)
        if 0 <= idx < len(cur):
            cur = cur[idx]
        else:
            print("<MISSING>"); sys.exit(0)
    elif isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        print("<MISSING>"); sys.exit(0)
if isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is None:
    print("<NULL>")
else:
    print(cur)
PY
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
if ss -tln 2>/dev/null | grep -qE ":(${BB_RPC}|${BB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${BB_RPC}/${BB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$BB_DATADIR" "$CORE_DATADIR"
mkdir -p "$BB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "blockbrew binary not found at $NODE_BIN (run build-all.sh blockbrew)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"

# ── 2. Launch the Core oracle on regtest (RPC-only, txindex=1). ───────────
# -listen=0 : the sandbox SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener.
log "launching Core oracle rpc=:$CORE_RPC (txindex=1, listen=0)"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    -listen=0 -txindex=1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < core_deadline )); do
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 && break
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
    || fail "Core oracle RPC never responded within 90s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch blockbrew on regtest (isolated: no peers, txindex on). ──────
log "launching blockbrew (regtest) rpc=:$BB_RPC p2p=:$BB_P2P txindex=on -> $BB_LOG"
# -metricsport=0 disables the Prometheus listener (fixed 0.0.0.0:9332) which
# would COLLIDE with the live mainnet blockbrew's metrics port.
"$NODE_BIN" \
    -network=regtest -datadir="$BB_DATADIR" \
    -listen="127.0.0.1:${BB_P2P}" -rpcbind="127.0.0.1:${BB_RPC}" \
    -maxoutbound=0 -nolisten -metricsport=0 -txindex \
    >"$BB_LOG" 2>&1 &
BB_PID=$!
log "blockbrew pid=$BB_PID"
bb_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < bb_deadline )); do
    if [[ -z "$BB_COOKIE" && -f "$BB_COOKIE_FILE" ]]; then
        BB_COOKIE=$(cat "$BB_COOKIE_FILE")
    fi
    if [[ -n "$BB_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$BB_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "$BB_URL/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$BB_PID" 2>/dev/null || { tail -n 20 "$BB_LOG" >&2 2>/dev/null || true; fail "blockbrew exited during startup (see $BB_LOG)"; }
    sleep 1
done
[[ -n "$BB_COOKIE" ]] || fail "blockbrew cookie never appeared within 90s"
r=$(curl -s --max-time 5 -u "$BB_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "$BB_URL/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "blockbrew RPC never responded within 90s"
log "blockbrew RPC ready"

# ── RPC helpers. ──────────────────────────────────────────────────────────
bb_rpc() {  # bb_rpc <method> <params-json> ; prints raw JSON-RPC envelope
    curl -s --max-time 90 -u "$BB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "$BB_URL/" 2>/dev/null
}
bb_result() {  # bb_result <method> <params-json> ; prints .result (string or json) or ERR:..
    python3 - "$(bb_rpc "$1" "$2")" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("ERR:parse"); raise SystemExit
if d.get("error"):
    print("ERR:" + json.dumps(d["error"])); raise SystemExit
r = d.get("result")
print(r if isinstance(r, str) else json.dumps(r))
PY
}
core_rpc() {  # core_rpc <method> <params...> ; prints the bare result (cli)
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>&1
}

# ── 4. blockbrew wallet: fund + build a REAL segwit spend tx. ─────────────
WC=$(bb_result createwallet '["grtw"]')
[[ "$WC" == ERR:* ]] && fail "blockbrew createwallet failed: ${WC#ERR:}"
ADDR=$(bb_result getnewaddress '[]')
[[ "$ADDR" == ERR:* ]] && fail "blockbrew getnewaddress failed: ${ADDR#ERR:}"
[[ -n "$ADDR" ]] || fail "blockbrew getnewaddress returned empty"
log "wallet address: $ADDR"

log "mining $NBLOCKS_MINE blocks to the wallet (mature coinbase funds)"
GEN=$(bb_result generatetoaddress "[$NBLOCKS_MINE,\"$ADDR\"]")
[[ "$GEN" == ERR:* ]] && fail "blockbrew generatetoaddress failed: ${GEN#ERR:}"
BB_H=$(bb_result getblockcount "[]")
[[ "$BB_H" == "$NBLOCKS_MINE" ]] || fail "blockbrew height $BB_H != $NBLOCKS_MINE"

# Send 1.0 BTC to our own address -> a real signed segwit tx enters the mempool.
TXID=$(bb_result sendtoaddress "[\"$ADDR\",1.0]")
[[ "$TXID" == ERR:* ]] && fail "blockbrew sendtoaddress failed: ${TXID#ERR:}"
[[ "$TXID" =~ ^[0-9a-f]{64}$ ]] || fail "sendtoaddress returned non-txid: '$TXID'"
# Confirm it is actually in the mempool.
MEMP=$(bb_result getrawmempool "[]")
echo "$MEMP" | grep -q "$TXID" || fail "tx $TXID not in blockbrew mempool (mempool=$MEMP)"
log "real spend tx in blockbrew mempool: $TXID"

# ── 5. MEMPOOL: verbosity 0 (byte-EXACT hex; the authoritative bytes). ────
BB_HEX0=$(bb_result getrawtransaction "[\"$TXID\",0]")
[[ "$BB_HEX0" == ERR:* ]] && fail "blockbrew getrawtransaction v0 errored: ${BB_HEX0#ERR:}"
[[ "$BB_HEX0" =~ ^[0-9a-f]+$ ]] || fail "blockbrew v0 hex not hex: '$BB_HEX0'"
SIGNED_HEX="$BB_HEX0"
# v0 hex must round-trip through Core's deserializer to the SAME txid.
CORE_DEC=$(core_rpc decoderawtransaction "$SIGNED_HEX")
echo "$CORE_DEC" | python3 -c 'import sys,json;json.load(sys.stdin)' >/dev/null 2>&1 \
    || fail "Core could not decode blockbrew v0 hex (malformed serialization): $CORE_DEC"
CORE_TXID=$(jget "$CORE_DEC" txid)
[[ "$CORE_TXID" == "$TXID" ]] || fail "v0 hex deserializes to wrong txid on Core: core=$CORE_TXID bb=$TXID"
# bool-verbosity: getrawtransaction <txid> false must equal verbosity 0 hex.
BB_HEX_BOOL=$(bb_result getrawtransaction "[\"$TXID\",false]")
[[ "$BB_HEX_BOOL" == "$SIGNED_HEX" ]] || fail "v(false) hex != v0 hex: bb=$BB_HEX_BOOL"
log "v0 hex byte-EXACT (round-trips through Core deserializer to same txid; bool false == v0)"

# ── 6. MEMPOOL: verbosity 1 (decoded — load-bearing fields EXACT vs Core). ─
# Oracle = Core's decoderawtransaction of the SAME bytes (TxToUniv, the very
# code getrawtransaction v1 calls, minus block-context fields).
CORE_V1="$CORE_DEC"
BB_V1=$(bb_result getrawtransaction "[\"$TXID\",1]")
[[ "$BB_V1" == ERR:* ]] && fail "blockbrew getrawtransaction v1 errored: ${BB_V1#ERR:}"
BB_V1_BOOL=$(bb_result getrawtransaction "[\"$TXID\",true]")
[[ "$BB_V1_BOOL" == ERR:* ]] && fail "blockbrew getrawtransaction v(true) errored: ${BB_V1_BOOL#ERR:}"

cf() { jget "$CORE_V1" "$@"; }
bf() { jget "$BB_V1" "$@"; }
btf() { jget "$BB_V1_BOOL" "$@"; }

# Top-level scalar fields that MUST be byte-equal vs Core.
# (Core's decoderawtransaction omits "hex"; we assert blockbrew's hex == v0 bytes.)
for f in txid hash version size vsize weight locktime; do
    c=$(cf "$f"); b=$(bf "$f")
    [[ "$c" != "<MISSING>" ]] || fail "Core decode missing top-level '$f' (oracle sanity)"
    [[ "$b" != "<MISSING>" ]] || fail "blockbrew v1 missing top-level '$f'"
    [[ "$c" == "$b" ]] || fail "v1 top-level '$f' mismatch: core=$c bb=$b"
    bt=$(btf "$f")
    [[ "$bt" == "$b" ]] || fail "v1 bool/int '$f' mismatch: int=$b bool=$bt"
done
# getrawtransaction v1 MUST carry the top-level hex == the v0 bytes.
[[ "$(bf hex)" == "$SIGNED_HEX" ]] || fail "v1 top-level hex != v0 bytes"
[[ "$(bf txid)" == "$TXID" ]] || fail "v1 txid=$(bf txid) != $TXID"
log "v1 top-level scalars EXACT vs Core OK (txid hash version size vsize weight locktime) + hex==v0"

# vin: assert txid, vout, sequence, scriptSig.hex EXACT; asm present; witness exact.
NVIN_C=$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["vin"]))' "$CORE_V1")
NVIN_B=$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["vin"]))' "$BB_V1")
[[ "$NVIN_C" == "$NVIN_B" ]] || fail "vin count mismatch: core=$NVIN_C bb=$NVIN_B"
(( NVIN_C >= 1 )) || fail "tx has no vin (oracle sanity)"
for ((i=0; i<NVIN_C; i++)); do
    for f in txid vout sequence; do
        c=$(cf vin "$i" "$f"); b=$(bf vin "$i" "$f")
        [[ "$c" == "$b" && "$b" != "<MISSING>" ]] || fail "v1 vin[$i].$f mismatch: core=$c bb=$b"
    done
    c=$(cf vin "$i" scriptSig hex); b=$(bf vin "$i" scriptSig hex)
    [[ "$c" == "$b" && "$b" != "<MISSING>" ]] || fail "v1 vin[$i].scriptSig.hex mismatch: core=$c bb=$b"
    [[ "$(bf vin "$i" scriptSig asm)" != "<MISSING>" ]] || fail "v1 vin[$i].scriptSig.asm missing"
    cw=$(python3 -c 'import sys,json;v=json.loads(sys.argv[1])["vin"]['"$i"'];print(len(v.get("txinwitness",[])))' "$CORE_V1")
    bw=$(python3 -c 'import sys,json;v=json.loads(sys.argv[1])["vin"]['"$i"'];print(len(v.get("txinwitness",[])))' "$BB_V1")
    [[ "$cw" == "$bw" ]] || fail "v1 vin[$i] txinwitness length mismatch: core=$cw bb=$bw"
    for ((j=0; j<cw; j++)); do
        c=$(cf vin "$i" txinwitness "$j"); b=$(bf vin "$i" txinwitness "$j")
        [[ "$c" == "$b" ]] || fail "v1 vin[$i].txinwitness[$j] mismatch: core=$c bb=$b"
    done
done
# Sanity: this spend is a segwit input -> witness must be present.
[[ "$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["vin"][0].get("txinwitness",[])))' "$BB_V1")" -ge 1 ]] \
    || fail "expected a witness on the segwit spend but blockbrew vin[0] has none"
log "v1 vin {txid,vout,sequence,scriptSig.hex,txinwitness} EXACT vs Core OK (asm present)"

# vout: assert value, n, scriptPubKey.hex, .type, .address EXACT; asm/desc present.
NVOUT_C=$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["vout"]))' "$CORE_V1")
NVOUT_B=$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["vout"]))' "$BB_V1")
[[ "$NVOUT_C" == "$NVOUT_B" ]] || fail "vout count mismatch: core=$NVOUT_C bb=$NVOUT_B"
(( NVOUT_C >= 1 )) || fail "tx has no vout (oracle sanity)"
SAW_ADDR=0
for ((i=0; i<NVOUT_C; i++)); do
    cv=$(cf vout "$i" value); bv=$(bf vout "$i" value)
    python3 -c 'import sys;exit(0 if abs(float(sys.argv[1])-float(sys.argv[2]))<1e-9 else 1)' "$cv" "$bv" \
        || fail "v1 vout[$i].value mismatch: core=$cv bb=$bv"
    c=$(cf vout "$i" n); b=$(bf vout "$i" n)
    [[ "$c" == "$b" ]] || fail "v1 vout[$i].n mismatch: core=$c bb=$b"
    c=$(cf vout "$i" scriptPubKey hex); b=$(bf vout "$i" scriptPubKey hex)
    [[ "$c" == "$b" && "$b" != "<MISSING>" ]] || fail "v1 vout[$i].scriptPubKey.hex mismatch: core=$c bb=$b"
    c=$(cf vout "$i" scriptPubKey type); b=$(bf vout "$i" scriptPubKey type)
    [[ "$c" == "$b" && "$b" != "<MISSING>" ]] || fail "v1 vout[$i].scriptPubKey.type mismatch: core=$c bb=$b"
    # address: present-and-EXACT iff Core emits one (decodable scripts only).
    c=$(cf vout "$i" scriptPubKey address); b=$(bf vout "$i" scriptPubKey address)
    if [[ "$c" != "<MISSING>" ]]; then
        [[ "$c" == "$b" ]] || fail "v1 vout[$i].scriptPubKey.address mismatch: core=$c bb=$b"
        SAW_ADDR=1
    fi
    [[ "$(bf vout "$i" scriptPubKey asm)" != "<MISSING>" ]]  || fail "v1 vout[$i].scriptPubKey.asm missing"
    [[ "$(bf vout "$i" scriptPubKey desc)" != "<MISSING>" ]] || fail "v1 vout[$i].scriptPubKey.desc missing"
done
(( SAW_ADDR == 1 )) || fail "expected at least one decodable address-bearing vout, saw none"
log "v1 vout {value,n,scriptPubKey.hex,.type,.address} EXACT vs Core OK (asm/desc present)"

# ── 7. CONFIRMED via blockhash arg. ───────────────────────────────────────
GEN1=$(bb_result generatetoaddress "[1,\"$ADDR\"]")
[[ "$GEN1" == ERR:* ]] && fail "blockbrew could not mine the tx into a block: ${GEN1#ERR:}"
CONF_BH=$(python3 -c 'import sys,json;print(json.loads(sys.argv[1])[0])' "$GEN1" 2>/dev/null)
[[ "$CONF_BH" =~ ^[0-9a-f]{64}$ ]] || fail "could not read confirming blockhash ($GEN1)"

BB_CONF=$(bb_result getrawtransaction "[\"$TXID\",1,\"$CONF_BH\"]")
[[ "$BB_CONF" == ERR:* ]] && fail "blockbrew confirmed-via-blockhash errored: ${BB_CONF#ERR:}"
[[ "$(jget "$BB_CONF" blockhash)" == "$CONF_BH" ]] \
    || fail "confirmed blockhash mismatch: got $(jget "$BB_CONF" blockhash) want $CONF_BH"
[[ "$(jget "$BB_CONF" in_active_chain)" == "true" ]] \
    || fail "confirmed in_active_chain != true: $(jget "$BB_CONF" in_active_chain)"
CONF_N=$(jget "$BB_CONF" confirmations)
[[ "$CONF_N" =~ ^[0-9]+$ ]] || fail "confirmations missing/non-int: '$CONF_N'"
(( CONF_N >= 1 )) || fail "confirmations not >= 1: $CONF_N"
# time/blocktime present, ints, and equal (both = the block's nTime).
BT=$(jget "$BB_CONF" blocktime); TM=$(jget "$BB_CONF" time)
[[ "$BT" =~ ^[0-9]+$ ]] || fail "blocktime missing/non-int: '$BT'"
[[ "$TM" =~ ^[0-9]+$ ]] || fail "time missing/non-int: '$TM'"
[[ "$BT" == "$TM" ]]    || fail "time ($TM) != blocktime ($BT)"
# Cross-check time == the confirming block's raw header nTime (not mediantime).
BH_HDR=$(bb_result getblockheader "[\"$CONF_BH\",true]")
BH_TIME=$(jget "$BH_HDR" time)
[[ "$BT" == "$BH_TIME" ]] || fail "blocktime ($BT) != confirming block header nTime ($BH_TIME)"
# confirmations must equal 1 + tipHeight - txHeight per Core.
TIP_H=$(bb_result getblockcount "[]")
TX_H=$(jget "$BH_HDR" height)
EXP_CONF=$(( TIP_H - TX_H + 1 ))
[[ "$CONF_N" == "$EXP_CONF" ]] || fail "confirmations=$CONF_N != 1+tip-txheight=$EXP_CONF (tip=$TIP_H txh=$TX_H)"
log "confirmed-via-blockhash OK (blockhash match, in_active_chain=true, confirmations=$CONF_N==1+tip-txh, time==blocktime==header nTime=$BT)"

# ── 8. txindex sub-check: v1 with NO blockhash on the CONFIRMED tx. ───────
# blockbrew launched with -txindex, so a confirmed tx resolves without blockhash.
BB_TXIDX=$(bb_result getrawtransaction "[\"$TXID\",1]")
[[ "$BB_TXIDX" == ERR:* ]] && fail "txindex lookup (no blockhash) errored on confirmed tx: ${BB_TXIDX#ERR:}"
[[ "$(jget "$BB_TXIDX" txid)" == "$TXID" ]] || fail "txindex lookup returned wrong txid: $(jget "$BB_TXIDX" txid)"
[[ "$(jget "$BB_TXIDX" blockhash)" == "$CONF_BH" ]] \
    || fail "txindex lookup blockhash mismatch: got $(jget "$BB_TXIDX" blockhash) want $CONF_BH"
[[ "$(jget "$BB_TXIDX" hex)" == "$SIGNED_HEX" ]] || fail "txindex lookup hex mismatch"
# v0 via txindex (no blockhash) must also return the exact bytes.
TXIDX_HEX0=$(bb_result getrawtransaction "[\"$TXID\",0]")
[[ "$TXIDX_HEX0" == "$SIGNED_HEX" ]] || fail "txindex v0 (no blockhash) hex mismatch"
log "txindex no-blockhash lookup on confirmed tx OK (v0 + v1)"

# ── 9. ERRORS: random txid -> -5; genesis-coinbase txid -> -5. ───────────
RAND_TXID="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
BB_E_RAND=$(bb_rpc getrawtransaction "[\"$RAND_TXID\"]")
E_RAND_CODE=$(jget "$BB_E_RAND" error code)
[[ "$E_RAND_CODE" == "-5" ]] || fail "random-txid error code=$E_RAND_CODE != -5 (env=$BB_E_RAND)"

# Genesis-coinbase txid == regtest genesis merkle root.
GEN_BH=$(bb_result getblockhash "[0]")
[[ "$GEN_BH" =~ ^[0-9a-f]{64}$ ]] || fail "could not read genesis blockhash ($GEN_BH)"
GEN_MR=$(jget "$(bb_result getblockheader "[\"$GEN_BH\",true]")" merkleroot)
[[ "$GEN_MR" =~ ^[0-9a-f]{64}$ ]] || fail "could not read genesis merkle root ($GEN_MR)"
BB_E_GEN=$(bb_rpc getrawtransaction "[\"$GEN_MR\"]")
E_GEN_CODE=$(jget "$BB_E_GEN" error code)
E_GEN_MSG=$(jget "$BB_E_GEN" error message)
[[ "$E_GEN_CODE" == "-5" ]] || fail "genesis-coinbase error code=$E_GEN_CODE != -5 (env=$BB_E_GEN)"
echo "$E_GEN_MSG" | grep -qi "genesis" || fail "genesis-coinbase error message lacks 'genesis': $E_GEN_MSG"
# Oracle sanity: Core -5s the same genesis-coinbase txid too.
CORE_E_GEN=$(core_rpc getrawtransaction "$GEN_MR" 0 2>&1 || true)
echo "$CORE_E_GEN" | grep -qi "genesis" || log "note: Core genesis error text differs: $CORE_E_GEN"
log "errors OK (random txid -> -5, genesis-coinbase txid -> -5 with 'genesis' message)"

# ── 10. All green. ────────────────────────────────────────────────────────
log "PASS: v0 hex byte-exact; v1 decoded load-bearing fields exact vs Core; confirmed-via-blockhash correct; txindex no-blockhash lookup works; error codes match Core"
pass

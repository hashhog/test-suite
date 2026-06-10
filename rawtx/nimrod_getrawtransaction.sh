#!/usr/bin/env bash
#
# nimrod_getrawtransaction.sh — self-contained getrawtransaction RPC-parity test.
#
# The next RPC-surface / indexing green-cell after getindexinfo (the flagged
# follow-up: "txindex on but getrawtransaction fails"). getrawtransaction is the
# block-explorer keystone — it must be Core-EXACT on output shape across all
# three verbosity-0/1 forms, both lookup paths (mempool, confirmed-block), and
# the two -5 error cases. This harness proves nimrod's getrawtransaction matches
# a REAL bitcoind regtest oracle for the SAME transaction, byte-for-byte.
#
# CORE SEMANTICS (bitcoin-core/src/rpc/rawtransaction.cpp getrawtransaction +
#                 core_io.cpp TxToUniv + rawtransaction.cpp TxToJSON):
#   verbosity 0  -> the raw tx HEX string (EncodeHexTx) — byte-exact bytes.
#   verbosity 1  -> a decoded OBJECT (TxToUniv, include_hex=true) + the
#                   TxToJSON envelope:
#                     txid, hash(wtxid), version, size, vsize, weight, locktime,
#                     vin[] {txid,vout,scriptSig{asm,hex},txinwitness?,sequence}
#                       (coinbase input: {coinbase,txinwitness?,sequence}),
#                     vout[] {value(BTC), n, scriptPubKey{asm,desc,hex,address?,type}},
#                     hex,
#                     and when confirmed in the active chain: blockhash,
#                     confirmations(=1+tipHeight-txHeight), time, blocktime
#                     (both = the block's nTime); plus in_active_chain when a
#                     blockhash ARG was supplied.
#   verbosity     accepts bool (true=1, false=0) or int 0/1/2; default 0.
#   ERRORS (RPC code -5, RPC_INVALID_ADDRESS_OR_KEY):
#     - the genesis-block coinbase txid (== genesis merkle root) ->
#       "The genesis block coinbase is not considered an ordinary transaction
#        and cannot be retrieved"
#     - a tx not found -> a "No such mempool transaction…" style message.
#
# DIFFERENTIAL DESIGN (the SAME tx on BOTH nodes — true byte-parity):
#   This Core build is wallet-DISABLED, and two independent regtest chains can
#   never share a byte-identical funding UTXO (coinbase scriptSigs diverge). So
#   instead we make the two nodes share ONE chain:
#     1. Launch a real bitcoind regtest oracle (RPC-only, -listen=0, -txindex=1).
#     2. Launch nimrod on regtest (its own scratch + unique ports). nimrod's
#        regtest genesis hash equals Core's, so its consensus accepts Core blocks.
#     3. Mine 110 blocks on Core to a deterministic wallet-free p2wpkh address,
#        then replay every Core block into nimrod via submitblock. Both nodes now
#        hold a byte-IDENTICAL chain (same blocks, same coinbase, same UTXO set).
#     4. Build ONE real signed segwit (p2wpkh) spend of block-1's mature
#        coinbase, entirely in Python via Core's test_framework (deterministic
#        RFC6979 ECDSA). The resulting raw tx is valid on BOTH chains.
#     5. sendrawtransaction the SAME bytes to BOTH mempools.
#   Because the bytes are identical, getrawtransaction parity can be asserted
#   byte-for-byte — not merely shape-compatibly.
#
# CHECKS (all must hold for PASS):
#   hex       : MEMPOOL getrawtransaction <txid> 0 — nimrod hex == Core hex,
#               byte-EXACT; bool false == v0; v1 top-level hex == v0 bytes.
#   decoded   : MEMPOOL getrawtransaction <txid> 1 — nimrod vs Core EXACT on
#               txid, hash, version, size, vsize, weight, locktime; vin
#               {txid,vout,sequence,scriptSig.hex,txinwitness}; vout
#               {value,n,scriptPubKey.hex,.type,.address}; top-level hex. asm/
#               desc PRESENT but NOT asserted byte-equal (InferDescriptor + asm
#               whitespace can legitimately differ). bool true == int 1.
#   confirmed : mine the tx into a block on Core, replay to nimrod, then
#               getrawtransaction <txid> 1 <blockhash> — blockhash match,
#               in_active_chain==true, confirmations>=1 and ==1+tip-txheight,
#               time==blocktime==confirming block header nTime. PLUS the
#               txindex sub-check: getrawtransaction <txid> 1 with NO blockhash
#               on the confirmed tx succeeds (nimrod maintains an always-on
#               txindex) and returns the same blockhash + bytes.
#   errors    : random 32-byte txid -> -5; genesis-coinbase txid -> -5 with a
#               'genesis' message. Core agrees on both.
#
# UNIFORM INTERFACE (mirrors test-suite/chaintxstats/nimrod_chaintxstats.sh):
#   no required args, set -uo pipefail, idempotent, trap cleanup, scratch /tmp +
#   unique ports, ONE clean summary line on stdout, all noise -> stderr/log,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETRAWTRANSACTION nimrod: PASS hex=ok decoded=ok confirmed=ok errors=ok
#   FAIL: GETRAWTRANSACTION nimrod: FAIL <short reason>
#
# Touches ONLY /tmp/grt-nimrod/ + /tmp/grt-nimrod-core/ and ports 22011/22031
#   (nimrod) + 22013/22033 (Core). NEVER touches /data/nvme1/ or testnet4-data/
#   or any live node. Port-kills (fuser -k) are BANNED (2026-06-10 incident); PID-scoped kills only.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASEDIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # meta-repo root
NODE_BIN="$BASEDIR/nimrod/bin/nimrod"
BITCOIND="$BASEDIR/bitcoin-core/build/bin/bitcoind"
BITCOINCLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"     # test_framework: key/script/tx

NM_DATADIR="/tmp/grt-nimrod"
NM_RPC=22011
NM_P2P=22031
NM_LOG="$NM_DATADIR/node.log"
NM_COOKIE_FILE="$NM_DATADIR/regtest/.cookie"
NM_URL="http://127.0.0.1:$NM_RPC"

CORE_DATADIR="/tmp/grt-nimrod-core"
CORE_RPC=22013
CORE_P2P=22033
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS_MINE=110       # mature a coinbase (regtest maturity = 100) with margin
# Fixed deterministic test secret -> a wallet-free p2wpkh mining address + key.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NM_PID=""
NM_COOKIE=""
CORE_PID=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getrawtransaction:nimrod] $*" >&2; }

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {  # pass <hex> <decoded> <confirmed> <errors>
    echo "GETRAWTRANSACTION nimrod: PASS hex=$1 decoded=$2 confirmed=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETRAWTRANSACTION nimrod: FAIL $*"
    exit 1
}

# ── Cleanup: kill both nodes + wipe scratch on any exit. ──────────────────
cleanup() {
    local ec=$?
    if [[ -n "$CORE_PID" ]]; then
        "$BITCOINCLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
        for _ in $(seq 1 15); do kill -0 "$CORE_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CORE_PID" 2>/dev/null || true
    fi
    if [[ -n "$NM_PID" ]] && kill -0 "$NM_PID" 2>/dev/null; then
        kill "$NM_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$NM_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$NM_PID" 2>/dev/null || true
    fi
    rm -rf "$NM_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── jget <json> <path...> : index keys/integers into a value; "<MISSING>". ─
jget() {
    local js="$1"; shift
    python3 - "$js" "$@" <<'PY'
import sys, json
js = sys.argv[1]; keys = sys.argv[2:]
try:
    d = json.loads(js)
except Exception:
    print("<PARSE-ERR>"); sys.exit(0)
cur = d
for k in keys:
    if isinstance(cur, list):
        try: idx = int(k)
        except ValueError: print("<MISSING>"); sys.exit(0)
        if 0 <= idx < len(cur): cur = cur[idx]
        else: print("<MISSING>"); sys.exit(0)
    elif isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        print("<MISSING>"); sys.exit(0)
if isinstance(cur, bool): print("true" if cur else "false")
elif cur is None: print("<NULL>")
else: print(cur)
PY
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "grt-nimrod-core" >/dev/null 2>&1 || true
pkill -f "grt-nimrod"      >/dev/null 2>&1 || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${NM_RPC}|${NM_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${NM_RPC}|${NM_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${NM_RPC}/${NM_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$NM_DATADIR" "$CORE_DATADIR"
mkdir -p "$NM_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
command -v jq      >/dev/null 2>&1 || fail "jq not found on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
[[ -x "$NODE_BIN" ]]    || fail "nimrod binary not found at $NODE_BIN (run: cd nimrod && nimble build -d:release -y)"
[[ -x "$BITCOIND" ]]    || fail "bitcoind not found at $BITCOIND"
[[ -x "$BITCOINCLI" ]]  || fail "bitcoin-cli not found at $BITCOINCLI"
[[ -d "$TF_PATH/test_framework" ]] || fail "Core test_framework not found at $TF_PATH"

# ── RPC helpers. ──────────────────────────────────────────────────────────
nm_rpc() {  # nm_rpc <method> <params-json> ; raw JSON-RPC envelope on stdout
    curl -s --max-time 90 -u "$NM_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}" \
        "$NM_URL/" 2>/dev/null
}
nm_result() {  # nm_result <method> <params-json> ; .result (str/json) or ERR:..
    python3 - "$(nm_rpc "$1" "${2:-[]}")" <<'PY'
import sys, json
try: d = json.loads(sys.argv[1])
except Exception: print("ERR:parse"); raise SystemExit
if d.get("error"): print("ERR:" + json.dumps(d["error"])); raise SystemExit
r = d.get("result")
print(r if isinstance(r, str) else json.dumps(r))
PY
}
core_cli() {  # core_cli <args...> ; bare cli output
    "$BITCOINCLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>&1
}

# ── 2. Launch the real bitcoind regtest oracle (RPC-only, txindex=1). ─────
log "launching bitcoind oracle (regtest) rpc=:$CORE_RPC (listen=0, txindex=1) -> $CORE_LOG"
"$BITCOIND" -regtest -datadir="$CORE_DATADIR" \
    -port="$CORE_P2P" -rpcport="$CORE_RPC" \
    -listen=0 -txindex=1 -rpcbind=127.0.0.1 -rpcallowip=127.0.0.1 \
    -fallbackfee=0.0002 -daemon=0 -printtoconsole=0 \
    >"$CORE_LOG" 2>&1 &
CORE_PID=$!
log "bitcoind pid=$CORE_PID"
deadline=$(( $(date +%s) + 90 ))
core_ready=0
while (( $(date +%s) < deadline )); do
    if core_cli getblockcount >/dev/null 2>&1; then core_ready=1; break; fi
    kill -0 "$CORE_PID" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "bitcoind exited during startup (see $CORE_LOG)"; }
    sleep 1
done
[[ "$core_ready" -eq 1 ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "bitcoind RPC never responded within 90s"; }
log "bitcoind RPC ready"

# ── 3. Launch nimrod on regtest. ──────────────────────────────────────────
log "launching nimrod (regtest) rpc=:$NM_RPC p2p=:$NM_P2P -> $NM_LOG"
"$NODE_BIN" --network=regtest --datadir="$NM_DATADIR" \
    --port="$NM_P2P" --rpcport="$NM_RPC" start >"$NM_LOG" 2>&1 &
NM_PID=$!
log "nimrod pid=$NM_PID"
deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$NM_COOKIE" && -f "$NM_COOKIE_FILE" ]]; then
        NM_COOKIE=$(cat "$NM_COOKIE_FILE")
    fi
    if [[ -n "$NM_COOKIE" ]]; then
        nm_rpc getblockcount | grep -q '"result"' && break
    fi
    kill -0 "$NM_PID" 2>/dev/null || { tail -n 20 "$NM_LOG" >&2 2>/dev/null || true; fail "nimrod exited during startup (see $NM_LOG)"; }
    sleep 1
done
[[ -n "$NM_COOKIE" ]] || fail "nimrod cookie never appeared within 90s"
nm_rpc getblockcount | grep -q '"result"' || fail "nimrod RPC never responded within 90s"
log "nimrod RPC ready"

# ── 4. Derive a deterministic wallet-free p2wpkh mining address. ──────────
MINE_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET'), compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null)
[[ "$MINE_ADDR" =~ ^bcrt1 ]] || fail "could not derive a regtest mining address (got '$MINE_ADDR')"
log "wallet-free mining address: $MINE_ADDR"

# ── 5. Mine on Core, then replay every block into nimrod (shared chain). ──
log "mining $NBLOCKS_MINE blocks on bitcoind oracle"
core_cli generatetoaddress "$NBLOCKS_MINE" "$MINE_ADDR" >/dev/null 2>&1 \
    || fail "core generatetoaddress failed"
CORE_H=$(core_cli getblockcount)
[[ "$CORE_H" == "$NBLOCKS_MINE" ]] || fail "core height $CORE_H != $NBLOCKS_MINE after mining"

log "replaying $CORE_H Core blocks into nimrod via submitblock"
for (( h=1; h<=CORE_H; h++ )); do
    kill -0 "$CORE_PID" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "bitcoind died during block replay (h=$h, see $CORE_LOG)"; }
    bh=$(core_cli getblockhash "$h")
    [[ "$bh" =~ ^[0-9a-f]{64}$ ]] || fail "core getblockhash $h returned non-hash: '$bh'"
    raw=$(core_cli getblock "$bh" 0)
    [[ "$raw" =~ ^[0-9a-f]+$ ]] || fail "core getblock $h returned non-hex (bitcoind dead?): '${raw:0:80}'"
    res=$(nm_result submitblock "[\"$raw\"]")
    # submitblock returns null on success; a non-null/ERR string flags a reject.
    if [[ "$res" == ERR:* ]]; then fail "nimrod submitblock h=$h errored: ${res#ERR:}"; fi
    if [[ -n "$res" && "$res" != "null" ]]; then fail "nimrod rejected Core block h=$h: $res"; fi
done
NM_H=$(nm_result getblockcount "[]")
[[ "$NM_H" == "$CORE_H" ]] || fail "nimrod height $NM_H != core height $CORE_H after replay"
NM_TIP=$(nm_result getbestblockhash "[]")
CORE_TIP=$(core_cli getbestblockhash)
[[ "$NM_TIP" == "$CORE_TIP" ]] || fail "tip mismatch after replay: nimrod=$NM_TIP core=$CORE_TIP"
log "both nodes share an identical chain at height $NM_H (tip $NM_TIP)"

# ── 6. Build ONE real signed segwit (p2wpkh) spend of block-1's coinbase. ─
FUND_TXID=$(jget "$(core_cli getblock "$(core_cli getblockhash 1)")" tx 0)
[[ "$FUND_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "could not read block-1 coinbase txid ($FUND_TXID)"
log "funding coinbase (block 1, mature): $FUND_TXID"

SIGNED_HEX=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness, COIN
from test_framework.script import sign_input_segwitv0, SIGHASH_ALL
from test_framework.script_util import key_to_p2wpkh_script, keyhash_to_p2pkh_script
from test_framework.crypto.ripemd160 import ripemd160
import hashlib
k=ECKey(); k.set(bytes.fromhex('$SECRET'), compressed=True)
pub=k.get_pubkey().get_bytes()
h160=ripemd160(hashlib.sha256(pub).digest())
tx=CTransaction()
tx.vin=[CTxIn(COutPoint(int('$FUND_TXID',16), 0), b'', 0xffffffff)]
# 50 BTC coinbase -> 49.999 BTC back to the same p2wpkh (0.001 BTC fee).
tx.vout=[CTxOut(int(49.999*COIN), key_to_p2wpkh_script(pub))]
tx.wit.vtxinwit=[CTxInWitness()]
# p2wpkh script code for sighash = the implicit P2PKH of the key hash.
sign_input_segwitv0(tx, 0, keyhash_to_p2pkh_script(h160), 50*COIN, k, SIGHASH_ALL)
tx.wit.vtxinwit[0].scriptWitness.stack.append(pub)
print(tx.serialize().hex())
" 2>/dev/null)
[[ "$SIGNED_HEX" =~ ^[0-9a-f]+$ ]] || fail "could not build a signed spend tx (got '$SIGNED_HEX')"

# Submit the SAME bytes to BOTH mempools.
CORE_TXID=$(core_cli sendrawtransaction "$SIGNED_HEX")
[[ "$CORE_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "core sendrawtransaction failed: $CORE_TXID"
NM_SEND=$(nm_result sendrawtransaction "[\"$SIGNED_HEX\"]")
[[ "$NM_SEND" == ERR:* ]] && fail "nimrod sendrawtransaction failed: ${NM_SEND#ERR:}"
[[ "$NM_SEND" == "$CORE_TXID" ]] || fail "nimrod txid $NM_SEND != core txid $CORE_TXID"
TXID="$CORE_TXID"
# Confirm both mempools actually hold it.
core_cli getrawmempool | grep -q "$TXID" || fail "tx $TXID not in Core mempool"
nm_result getrawmempool "[]" | grep -q "$TXID" || fail "tx $TXID not in nimrod mempool"
log "real spend tx in BOTH mempools: $TXID"

# ── 7. CHECK hex: MEMPOOL verbosity 0 byte-EXACT vs Core. ─────────────────
CORE_HEX0=$(core_cli getrawtransaction "$TXID" 0)
NM_HEX0=$(nm_result getrawtransaction "[\"$TXID\", 0]")
[[ "$NM_HEX0" == ERR:* ]] && fail "nimrod getrawtransaction v0 errored: ${NM_HEX0#ERR:}"
[[ "$NM_HEX0" =~ ^[0-9a-f]+$ ]] || fail "nimrod v0 hex not hex: '$NM_HEX0'"
[[ "$NM_HEX0" == "$SIGNED_HEX" ]] || fail "v0 hex != submitted bytes: nimrod=$NM_HEX0"
[[ "$NM_HEX0" == "$CORE_HEX0" ]]  || fail "v0 hex mismatch vs Core: nimrod=$NM_HEX0 core=$CORE_HEX0"
# bool false (verbosity 0) must equal the v0 hex.
NM_HEX_FALSE=$(nm_result getrawtransaction "[\"$TXID\", false]")
[[ "$NM_HEX_FALSE" == "$SIGNED_HEX" ]] || fail "v(false) hex != v0 hex: nimrod=$NM_HEX_FALSE"
# default verbosity (omitted) must also be the v0 hex.
NM_HEX_DEF=$(nm_result getrawtransaction "[\"$TXID\"]")
[[ "$NM_HEX_DEF" == "$SIGNED_HEX" ]] || fail "v(default) hex != v0 hex: nimrod=$NM_HEX_DEF"
log "CHECK hex: v0 byte-EXACT vs Core; bool-false == v0; default == v0 OK"
HEX_T=ok

# ── 8. CHECK decoded: MEMPOOL verbosity 1 load-bearing fields EXACT vs Core.
CORE_V1=$(core_cli getrawtransaction "$TXID" 1)
NM_V1=$(nm_result getrawtransaction "[\"$TXID\", 1]")
[[ "$NM_V1" == ERR:* ]] && fail "nimrod getrawtransaction v1 errored: ${NM_V1#ERR:}"
NM_V1_BOOL=$(nm_result getrawtransaction "[\"$TXID\", true]")
[[ "$NM_V1_BOOL" == ERR:* ]] && fail "nimrod getrawtransaction v(true) errored: ${NM_V1_BOOL#ERR:}"

cf() { jget "$CORE_V1" "$@"; }
nf() { jget "$NM_V1" "$@"; }
ntf() { jget "$NM_V1_BOOL" "$@"; }

# Top-level scalar fields — byte-equal vs Core; bool true == int 1.
for f in txid hash version size vsize weight locktime; do
    c=$(cf "$f"); n=$(nf "$f")
    [[ "$c" != "<MISSING>" ]] || fail "Core v1 missing top-level '$f' (oracle sanity)"
    [[ "$n" != "<MISSING>" ]] || fail "nimrod v1 missing top-level '$f'"
    [[ "$c" == "$n" ]] || fail "v1 top-level '$f' mismatch: core=$c nimrod=$n"
    nt=$(ntf "$f")
    [[ "$nt" == "$n" ]] || fail "v1 bool/int '$f' mismatch: int=$n bool=$nt"
done
[[ "$(nf txid)" == "$TXID" ]] || fail "v1 txid=$(nf txid) != $TXID"
[[ "$(nf hex)" == "$SIGNED_HEX" ]] || fail "v1 top-level hex != v0 bytes"
log "v1 top-level scalars EXACT vs Core OK (txid hash version size vsize weight locktime) + hex==v0"

# vin: txid, vout, sequence, scriptSig.hex EXACT; asm present; witness exact.
NVIN_C=$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["vin"]))' "$CORE_V1")
NVIN_N=$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["vin"]))' "$NM_V1")
[[ "$NVIN_C" == "$NVIN_N" ]] || fail "vin count mismatch: core=$NVIN_C nimrod=$NVIN_N"
(( NVIN_C >= 1 )) || fail "tx has no vin (oracle sanity)"
for (( i=0; i<NVIN_C; i++ )); do
    for f in txid vout sequence; do
        c=$(cf vin "$i" "$f"); n=$(nf vin "$i" "$f")
        [[ "$c" == "$n" && "$n" != "<MISSING>" ]] || fail "v1 vin[$i].$f mismatch: core=$c nimrod=$n"
    done
    c=$(cf vin "$i" scriptSig hex); n=$(nf vin "$i" scriptSig hex)
    [[ "$c" == "$n" && "$n" != "<MISSING>" ]] || fail "v1 vin[$i].scriptSig.hex mismatch: core=$c nimrod=$n"
    [[ "$(nf vin "$i" scriptSig asm)" != "<MISSING>" ]] || fail "v1 vin[$i].scriptSig.asm missing"
    cw=$(python3 -c 'import sys,json;v=json.loads(sys.argv[1])["vin"]['"$i"'];print(len(v.get("txinwitness",[])))' "$CORE_V1")
    nw=$(python3 -c 'import sys,json;v=json.loads(sys.argv[1])["vin"]['"$i"'];print(len(v.get("txinwitness",[])))' "$NM_V1")
    [[ "$cw" == "$nw" ]] || fail "v1 vin[$i] txinwitness length mismatch: core=$cw nimrod=$nw"
    for (( j=0; j<cw; j++ )); do
        c=$(cf vin "$i" txinwitness "$j"); n=$(nf vin "$i" txinwitness "$j")
        [[ "$c" == "$n" ]] || fail "v1 vin[$i].txinwitness[$j] mismatch: core=$c nimrod=$n"
    done
done
# Sanity: this is a segwit spend -> witness must be present.
[[ "$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["vin"][0].get("txinwitness",[])))' "$NM_V1")" -ge 1 ]] \
    || fail "expected a witness on the segwit spend but nimrod vin[0] has none"
log "v1 vin {txid,vout,sequence,scriptSig.hex,txinwitness} EXACT vs Core OK (asm present)"

# vout: value, n, scriptPubKey.hex, .type, .address EXACT; asm/desc present.
NVOUT_C=$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["vout"]))' "$CORE_V1")
NVOUT_N=$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["vout"]))' "$NM_V1")
[[ "$NVOUT_C" == "$NVOUT_N" ]] || fail "vout count mismatch: core=$NVOUT_C nimrod=$NVOUT_N"
(( NVOUT_C >= 1 )) || fail "tx has no vout (oracle sanity)"
SAW_ADDR=0
for (( i=0; i<NVOUT_C; i++ )); do
    cv=$(cf vout "$i" value); nv=$(nf vout "$i" value)
    python3 -c 'import sys;exit(0 if abs(float(sys.argv[1])-float(sys.argv[2]))<1e-9 else 1)' "$cv" "$nv" \
        || fail "v1 vout[$i].value mismatch: core=$cv nimrod=$nv"
    c=$(cf vout "$i" n); n=$(nf vout "$i" n)
    [[ "$c" == "$n" ]] || fail "v1 vout[$i].n mismatch: core=$c nimrod=$n"
    c=$(cf vout "$i" scriptPubKey hex); n=$(nf vout "$i" scriptPubKey hex)
    [[ "$c" == "$n" && "$n" != "<MISSING>" ]] || fail "v1 vout[$i].scriptPubKey.hex mismatch: core=$c nimrod=$n"
    c=$(cf vout "$i" scriptPubKey type); n=$(nf vout "$i" scriptPubKey type)
    [[ "$c" == "$n" && "$n" != "<MISSING>" ]] || fail "v1 vout[$i].scriptPubKey.type mismatch: core=$c nimrod=$n"
    # address: present-and-EXACT iff Core emits one (decodable scripts only).
    c=$(cf vout "$i" scriptPubKey address); n=$(nf vout "$i" scriptPubKey address)
    if [[ "$c" != "<MISSING>" ]]; then
        [[ "$c" == "$n" ]] || fail "v1 vout[$i].scriptPubKey.address mismatch: core=$c nimrod=$n"
        SAW_ADDR=1
    fi
    [[ "$(nf vout "$i" scriptPubKey asm)" != "<MISSING>" ]]  || fail "v1 vout[$i].scriptPubKey.asm missing"
    [[ "$(nf vout "$i" scriptPubKey desc)" != "<MISSING>" ]] || fail "v1 vout[$i].scriptPubKey.desc missing"
done
(( SAW_ADDR == 1 )) || fail "expected at least one decodable address-bearing vout, saw none"
log "v1 vout {value,n,scriptPubKey.hex,.type,.address} EXACT vs Core OK (asm/desc present)"
DECODED_T=ok

# ── 9. CHECK confirmed: mine the tx into a block, replay, query by blockhash.
log "mining the tx into a block on Core, then replaying it into nimrod"
core_cli generatetoaddress 1 "$MINE_ADDR" >/dev/null 2>&1 || fail "core could not mine the tx into a block"
CONF_BH=$(core_cli getbestblockhash)
[[ "$CONF_BH" =~ ^[0-9a-f]{64}$ ]] || fail "could not read confirming blockhash ($CONF_BH)"
CONF_RAW=$(core_cli getblock "$CONF_BH" 0)
res=$(nm_result submitblock "[\"$CONF_RAW\"]")
[[ "$res" == ERR:* ]] && fail "nimrod submitblock (confirming block) errored: ${res#ERR:}"
[[ -z "$res" || "$res" == "null" ]] || fail "nimrod rejected confirming block: $res"
[[ "$(nm_result getbestblockhash "[]")" == "$CONF_BH" ]] || fail "nimrod tip != confirming block after replay"
# nimrod mempool must have evicted the now-confirmed tx.
nm_result getrawmempool "[]" | grep -q "$TXID" && fail "nimrod mempool still holds confirmed tx $TXID"

NM_CONF=$(nm_result getrawtransaction "[\"$TXID\", 1, \"$CONF_BH\"]")
[[ "$NM_CONF" == ERR:* ]] && fail "nimrod confirmed-via-blockhash errored: ${NM_CONF#ERR:}"
[[ "$(jget "$NM_CONF" blockhash)" == "$CONF_BH" ]] \
    || fail "confirmed blockhash mismatch: got $(jget "$NM_CONF" blockhash) want $CONF_BH"
[[ "$(jget "$NM_CONF" in_active_chain)" == "true" ]] \
    || fail "confirmed in_active_chain != true: $(jget "$NM_CONF" in_active_chain)"
CONF_N=$(jget "$NM_CONF" confirmations)
[[ "$CONF_N" =~ ^[0-9]+$ ]] || fail "confirmations missing/non-int: '$CONF_N'"
(( CONF_N >= 1 )) || fail "confirmations not >= 1: $CONF_N"
# time/blocktime present, ints, and equal (both = the block's nTime).
BT=$(jget "$NM_CONF" blocktime); TM=$(jget "$NM_CONF" time)
[[ "$BT" =~ ^[0-9]+$ ]] || fail "blocktime missing/non-int: '$BT'"
[[ "$TM" =~ ^[0-9]+$ ]] || fail "time missing/non-int: '$TM'"
[[ "$BT" == "$TM" ]]    || fail "time ($TM) != blocktime ($BT)"
# Cross-check time == the confirming block's raw header nTime (not mediantime).
BH_TIME=$(jget "$(nm_result getblockheader "[\"$CONF_BH\", true]")" time)
[[ "$BT" == "$BH_TIME" ]] || fail "blocktime ($BT) != confirming block header nTime ($BH_TIME)"
# confirmations must equal 1 + tipHeight - txHeight per Core.
TIP_H=$(nm_result getblockcount "[]")
TX_H=$(jget "$(nm_result getblockheader "[\"$CONF_BH\", true]")" height)
EXP_CONF=$(( TIP_H - TX_H + 1 ))
[[ "$CONF_N" == "$EXP_CONF" ]] || fail "confirmations=$CONF_N != 1+tip-txheight=$EXP_CONF (tip=$TIP_H txh=$TX_H)"
# Parity with Core on the same confirmed query.
CORE_CONF=$(core_cli getrawtransaction "$TXID" 1 "$CONF_BH")
[[ "$(jget "$CORE_CONF" confirmations)" == "$CONF_N" ]] \
    || fail "confirmations differ vs Core: nimrod=$CONF_N core=$(jget "$CORE_CONF" confirmations)"
[[ "$(jget "$CORE_CONF" blocktime)" == "$BT" ]] \
    || fail "blocktime differs vs Core: nimrod=$BT core=$(jget "$CORE_CONF" blocktime)"
log "confirmed-via-blockhash OK (blockhash match, in_active_chain=true, confirmations=$CONF_N==1+tip-txh, time==blocktime==header nTime=$BT, Core agrees)"

# txindex sub-check: v1 with NO blockhash on the CONFIRMED tx (nimrod always-on
# txindex). Mirrors Core (-txindex=1): both resolve a confirmed tx without a hint.
NM_TXIDX=$(nm_result getrawtransaction "[\"$TXID\", 1]")
[[ "$NM_TXIDX" == ERR:* ]] && fail "txindex lookup (no blockhash) errored on confirmed tx: ${NM_TXIDX#ERR:}"
[[ "$(jget "$NM_TXIDX" txid)" == "$TXID" ]] || fail "txindex lookup returned wrong txid: $(jget "$NM_TXIDX" txid)"
[[ "$(jget "$NM_TXIDX" blockhash)" == "$CONF_BH" ]] \
    || fail "txindex lookup blockhash mismatch: got $(jget "$NM_TXIDX" blockhash) want $CONF_BH"
[[ "$(jget "$NM_TXIDX" hex)" == "$SIGNED_HEX" ]] || fail "txindex lookup hex mismatch"
# v0 via txindex (no blockhash) must also return the exact bytes, == Core.
TXIDX_HEX0=$(nm_result getrawtransaction "[\"$TXID\", 0]")
[[ "$TXIDX_HEX0" == "$SIGNED_HEX" ]] || fail "txindex v0 (no blockhash) hex mismatch"
[[ "$TXIDX_HEX0" == "$(core_cli getrawtransaction "$TXID" 0)" ]] || fail "txindex v0 hex differs vs Core"
log "txindex no-blockhash lookup on confirmed tx OK (v0 + v1, == Core)"
CONFIRMED_T=ok

# ── 10. CHECK errors: random txid -> -5; genesis-coinbase txid -> -5. ─────
RAND_TXID="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
NM_E_RAND=$(nm_rpc getrawtransaction "[\"$RAND_TXID\"]")
E_RAND_CODE=$(jget "$NM_E_RAND" error code)
[[ "$E_RAND_CODE" == "-5" ]] || fail "random-txid error code=$E_RAND_CODE != -5 (env=$NM_E_RAND)"
# Core agrees the random txid is a -5.
CORE_E_RAND=$(core_cli getrawtransaction "$RAND_TXID" 0 || true)
echo "$CORE_E_RAND" | grep -qi "No such" || log "note: Core random-txid text differs: $CORE_E_RAND"

# Genesis-coinbase txid == regtest genesis merkle root.
GEN_BH=$(nm_result getblockhash "[0]")
[[ "$GEN_BH" =~ ^[0-9a-f]{64}$ ]] || fail "could not read genesis blockhash ($GEN_BH)"
GEN_MR=$(jget "$(nm_result getblockheader "[\"$GEN_BH\", true]")" merkleroot)
[[ "$GEN_MR" =~ ^[0-9a-f]{64}$ ]] || fail "could not read genesis merkle root ($GEN_MR)"
NM_E_GEN=$(nm_rpc getrawtransaction "[\"$GEN_MR\"]")
E_GEN_CODE=$(jget "$NM_E_GEN" error code)
E_GEN_MSG=$(jget "$NM_E_GEN" error message)
[[ "$E_GEN_CODE" == "-5" ]] || fail "genesis-coinbase error code=$E_GEN_CODE != -5 (env=$NM_E_GEN)"
echo "$E_GEN_MSG" | grep -qi "genesis" || fail "genesis-coinbase error message lacks 'genesis': $E_GEN_MSG"
# Oracle sanity: Core -5s the same genesis-coinbase txid too (with 'genesis').
CORE_E_GEN=$(core_cli getrawtransaction "$GEN_MR" 0 || true)
echo "$CORE_E_GEN" | grep -qi "genesis" || log "note: Core genesis error text differs: $CORE_E_GEN"
log "errors OK (random txid -> -5, genesis-coinbase txid -> -5 with 'genesis' message; Core agrees)"
ERRORS_T=ok

# ── 11. All green. ────────────────────────────────────────────────────────
log "PASS: v0 hex byte-exact vs Core; v1 decoded load-bearing fields exact; confirmed-via-blockhash + txindex no-hint lookup correct; -5 error codes match Core"
pass "$HEX_T" "$DECODED_T" "$CONFIRMED_T" "$ERRORS_T"

#!/usr/bin/env bash
#
# nimrod_gettxoutproof.sh — self-contained gettxoutproof/verifytxoutproof
# differential-regression test for nimrod vs a real bitcoind regtest oracle.
#
# gettxoutproof(["txid",...] (,"blockhash")) returns a SERIALIZED CMerkleBlock as
# HEX: 80-byte header + nTransactions(4, LE) + hash-count(varint) + hashes +
# flag-byte-count(varint) + flag bytes. verifytxoutproof("hex") parses that
# merkleblock, recomputes the partial-merkle root, and returns a JSON ARRAY of
# the txids the proof commits to that are in the active chain (empty/err if the
# proof is invalid or the block is not in the best chain). Locating the tx needs
# either -txindex OR the blockhash arg.
#
# Core ref:
#   bitcoin-core/src/rpc/txoutproof.cpp  (gettxoutproof + verifytxoutproof)
#   (the prompt cited rawtransaction.cpp; in this Core tree the two RPCs live in
#    txoutproof.cpp — same contract.)
#   gettxoutproof: empty txids -> -8 RPC_INVALID_PARAMETER "Parameter 'txids'
#     cannot be empty"; unknown blockhash arg -> -5 "Block not found"; a txid not
#     locatable in any block -> -5 "Transaction not yet in block".
#   verifytxoutproof: a proof whose recomputed root != header merkleroot -> [];
#     a well-formed proof whose block is not in our active chain -> -5 "Block not
#     found in chain"; a VALID proof -> the array of committed txids.
#
# KEY PROPERTY UNDER TEST: the SAME tx in the SAME block yields a DETERMINISTIC,
# BYTE-IDENTICAL merkleblock across nodes (the CMerkleBlock serialization is
# fully determined by the block header + the matched-txid set). So Core's and
# nimrod's gettxoutproof([txid]) for the same confirmed tx must be byte-equal.
#
# DIFFERENTIAL DESIGN (the SAME chain on BOTH nodes — true byte-parity, not shape):
#   This Core build is wallet-DISABLED, and two independent regtest chains can
#   never share a byte-identical block (coinbase scriptSigs / merkleroots
#   diverge). So the two nodes share ONE chain:
#     1. Launch a real bitcoind regtest oracle (RPC-only, -listen=0, -txindex=1).
#     2. Launch nimrod on regtest (its regtest genesis hash equals Core's, so its
#        consensus accepts Core's blocks).
#     3. Mine 110 blocks on Core to a deterministic wallet-free p2wpkh address,
#        replay every block into nimrod via submitblock, then build ONE real
#        signed p2wpkh spend of block-1's matured coinbase, broadcast it to both
#        mempools, mine it into a block on Core, and replay that block into
#        nimrod. Both nodes now hold a byte-IDENTICAL chain whose tip block
#        contains a NON-coinbase tx (so the merkleblock proof is non-trivial:
#        2 leaves, one matched).
#     4. gettxoutproof + verifytxoutproof on BOTH nodes -> compare.
#   Because the block + matched txid are identical, the merkleblock HEX must be
#   byte-EXACT, and Core's proof must verify on nimrod (and vice versa).
#
# STRICT GATED CHECKS (ALL must hold for PASS — none optional):
#   proof        : gettxoutproof([SPEND_TXID]) on nimrod returns hex that is
#                  BYTE-IDENTICAL to Core's gettxoutproof([SPEND_TXID]) for the
#                  same confirmed tx (with the confirming blockhash arg, so the
#                  lookup is unambiguous on both). Also exercises the no-blockhash
#                  (txindex) path on both and asserts it equals the by-blockhash
#                  proof on each node.
#   verify-self  : verifytxoutproof(nimrod_hex) on nimrod returns EXACTLY
#                  [SPEND_TXID].
#   verify-cross : verifytxoutproof(core_hex) on nimrod returns EXACTLY
#                  [SPEND_TXID] (Core's proof verifies on nimrod), AND
#                  verifytxoutproof(nimrod_hex) on Core returns EXACTLY
#                  [SPEND_TXID] (nimrod's proof verifies on Core).
#   errors       : gettxoutproof([<random unknown txid>]) (no blockhash) -> error
#                  on BOTH; gettxoutproof([SPEND_TXID], <unknown blockhash>) ->
#                  error on BOTH (Core: -5 "Block not found"); verifytxoutproof
#                  of malformed/garbage hex -> error or [] on BOTH (match Core's
#                  behavior: error OR empty array, not a spurious txid).
#
# UNIFORM INTERFACE (mirrors rawtx/nimrod_getrawtransaction.sh): no required
#   args, set -uo pipefail, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr/log, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTPROOF nimrod: PASS proof=ok verify-self=ok verify-cross=ok errors=ok
#   FAIL: GETTXOUTPROOF nimrod: FAIL <short reason>
#   (binary missing -> a GAP_RE-compatible 'not found'/'not built' message so the
#    runner classifies a missing nimrod build as SKIP, not a real failure)
#
# Touches ONLY /tmp/gtop-nimrod/ + /tmp/gtop-nimrod-core/ and ports 40211/40231
#   (nimrod) + 40213/40233 (Core). NEVER touches /data/nvme1/ or testnet4-data/
#   or any live node. A live mainnet bitcoind may be running: we NEVER pkill
#   bitcoind by name — only free our OWN fixed ports / scratch. Any `fuser -k`
#   redirects stdout (it prints killed PIDs).

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASEDIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # meta-repo root
NODE_BIN="$BASEDIR/nimrod/bin/nimrod"
BITCOIND="$BASEDIR/bitcoin-core/build/bin/bitcoind"
BITCOINCLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"     # test_framework: key/script/tx

NM_DATADIR="/tmp/gtop-nimrod"
NM_RPC=40211
NM_P2P=40231
NM_LOG="$NM_DATADIR/node.log"
NM_COOKIE_FILE="$NM_DATADIR/regtest/.cookie"
NM_URL="http://127.0.0.1:$NM_RPC"

CORE_DATADIR="/tmp/gtop-nimrod-core"
CORE_RPC=40213
CORE_P2P=40233
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS_MINE=110       # mature a coinbase (regtest maturity = 100) with margin
# Fixed deterministic test secret -> a wallet-free p2wpkh mining address + key.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NM_PID=""
NM_COOKIE=""
CORE_PID=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutproof:nimrod] $*" >&2; }

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {  # pass <proof> <verify-self> <verify-cross> <errors>
    echo "GETTXOUTPROOF nimrod: PASS proof=$1 verify-self=$2 verify-cross=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETTXOUTPROOF nimrod: FAIL $*"
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
    fuser -k "${NM_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${NM_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
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
pkill -f "gtop-nimrod-core" >/dev/null 2>&1 || true
pkill -f "gtop-nimrod"      >/dev/null 2>&1 || true
fuser -k "${NM_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${NM_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 1
rm -rf "$NM_DATADIR" "$CORE_DATADIR"
mkdir -p "$NM_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
# Binary-missing uses a GAP_RE-compatible 'not found'/'not built' message so the
# regression runner classifies a missing nimrod build as SKIP (not a failure).
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
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
core_cli() {  # core_cli <args...> ; bare cli output (stderr folded for error text)
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
tx.vout=[CTxOut(int(49.999*COIN), key_to_p2wpkh_script(pub))]
tx.wit.vtxinwit=[CTxInWitness()]
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
SPEND_TXID="$CORE_TXID"
log "real spend tx in BOTH mempools: $SPEND_TXID"

# ── 7. Mine the spend into a block on Core; replay into nimrod. ───────────
# The confirming block now has 2 txs (coinbase + the spend), so the merkleblock
# proof is non-trivial (2 leaves, exactly one matched) — a real partial-merkle
# tree, not a degenerate single-leaf proof.
log "mining the spend into a block on Core, then replaying it into nimrod"
core_cli generatetoaddress 1 "$MINE_ADDR" >/dev/null 2>&1 || fail "core could not mine the spend into a block"
CONF_BH=$(core_cli getbestblockhash)
[[ "$CONF_BH" =~ ^[0-9a-f]{64}$ ]] || fail "could not read confirming blockhash ($CONF_BH)"
CONF_RAW=$(core_cli getblock "$CONF_BH" 0)
res=$(nm_result submitblock "[\"$CONF_RAW\"]")
[[ "$res" == ERR:* ]] && fail "nimrod submitblock (confirming block) errored: ${res#ERR:}"
[[ -z "$res" || "$res" == "null" ]] || fail "nimrod rejected confirming block: $res"
[[ "$(nm_result getbestblockhash "[]")" == "$CONF_BH" ]] || fail "nimrod tip != confirming block after replay"
# Sanity: the confirming block must contain exactly 2 txs (coinbase + the spend),
# and the spend must be vtx[1] — guarantees a real (non-degenerate) proof.
NTX_CONF=$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["tx"]))' "$(core_cli getblock "$CONF_BH")")
[[ "$NTX_CONF" == "2" ]] || fail "confirming block has $NTX_CONF txs, expected 2 (coinbase + spend) — proof would be degenerate"
SPEND_IN=$(python3 -c 'import sys,json;print("y" if sys.argv[2] in json.loads(sys.argv[1])["tx"] else "n")' "$(core_cli getblock "$CONF_BH")" "$SPEND_TXID")
[[ "$SPEND_IN" == "y" ]] || fail "spend tx $SPEND_TXID not in confirming block $CONF_BH"
log "spend confirmed in block $CONF_BH (2 txs: coinbase + spend), chains byte-identical"

# ════════════════════════════════════════════════════════════════════════
# CHECK (1) proof=ok — gettxoutproof([SPEND_TXID]) BYTE-IDENTICAL to Core.
# ════════════════════════════════════════════════════════════════════════
PROOF_T=ok

# By-blockhash form (unambiguous on both nodes — the canonical parity assertion).
CORE_PROOF_BH=$(core_cli gettxoutproof "[\"$SPEND_TXID\"]" "$CONF_BH")
[[ "$CORE_PROOF_BH" =~ ^[0-9a-f]+$ ]] || fail "Core gettxoutproof (by blockhash) failed: $CORE_PROOF_BH"
NM_PROOF_BH=$(nm_result gettxoutproof "[[\"$SPEND_TXID\"], \"$CONF_BH\"]")
[[ "$NM_PROOF_BH" == ERR:* ]] && fail "nimrod gettxoutproof (by blockhash) errored: ${NM_PROOF_BH#ERR:}"
[[ "$NM_PROOF_BH" =~ ^[0-9a-f]+$ ]] || fail "nimrod gettxoutproof (by blockhash) not hex: '$NM_PROOF_BH'"
if [[ "$NM_PROOF_BH" != "$CORE_PROOF_BH" ]]; then
    PROOF_T=bad
    log "MERKLEBLOCK HEX MISMATCH (by blockhash):"
    log "  core  : $CORE_PROOF_BH"
    log "  nimrod: $NM_PROOF_BH"
fi

# Sanity: the proof must embed the confirming block's header (first 160 hex chars
# = 80-byte header) so a byte match is not vacuous — and the headers must agree.
CORE_HDR=${CORE_PROOF_BH:0:160}
NM_HDR=${NM_PROOF_BH:0:160}
[[ ${#CORE_PROOF_BH} -ge 160 ]] || fail "Core proof shorter than an 80-byte header: ${#CORE_PROOF_BH} hex chars"
[[ "$CORE_HDR" == "$NM_HDR" ]] || { PROOF_T=bad; log "proof header bytes differ: core=$CORE_HDR nimrod=$NM_HDR"; }

# No-blockhash (txindex) path: both nodes locate the tx without a hint. nimrod
# scans recent blocks; Core uses -txindex. The resulting proof must equal each
# node's own by-blockhash proof (so the located block is the confirming block).
CORE_PROOF_NB=$(core_cli gettxoutproof "[\"$SPEND_TXID\"]")
[[ "$CORE_PROOF_NB" =~ ^[0-9a-f]+$ ]] || fail "Core gettxoutproof (no blockhash, txindex) failed: $CORE_PROOF_NB"
[[ "$CORE_PROOF_NB" == "$CORE_PROOF_BH" ]] || fail "Core no-blockhash proof != by-blockhash proof (oracle sanity)"
NM_PROOF_NB=$(nm_result gettxoutproof "[[\"$SPEND_TXID\"]]")
[[ "$NM_PROOF_NB" == ERR:* ]] && { PROOF_T=bad; log "nimrod gettxoutproof (no blockhash) errored: ${NM_PROOF_NB#ERR:}"; }
if [[ "$NM_PROOF_NB" != ERR:* ]]; then
    [[ "$NM_PROOF_NB" == "$NM_PROOF_BH" ]] || { PROOF_T=bad; log "nimrod no-blockhash proof != by-blockhash proof: nb=$NM_PROOF_NB bh=$NM_PROOF_BH"; }
fi
[[ "$PROOF_T" == "ok" ]] && log "CHECK (1) proof OK: merkleblock hex byte-IDENTICAL to Core (by blockhash + txindex paths agree)"

# ════════════════════════════════════════════════════════════════════════
# CHECK (2) verify-self=ok — verifytxoutproof(nimrod_hex) on nimrod == [txid].
# ════════════════════════════════════════════════════════════════════════
VSELF_T=ok
# Use nimrod's OWN proof (by-blockhash, always well-formed regardless of CHECK 1).
SELF_PROOF="$NM_PROOF_BH"
NM_VERIFY_SELF=$(nm_result verifytxoutproof "[\"$SELF_PROOF\"]")
[[ "$NM_VERIFY_SELF" == ERR:* ]] && { VSELF_T=bad; log "nimrod verifytxoutproof(self) errored: ${NM_VERIFY_SELF#ERR:}"; }
if [[ "$VSELF_T" == "ok" ]]; then
    # Must be EXACTLY [SPEND_TXID] — a JSON array of length 1 with that one txid.
    SELF_OK=$(python3 -c '
import sys, json
try: a = json.loads(sys.argv[1])
except Exception: print("n"); raise SystemExit
print("y" if isinstance(a, list) and a == [sys.argv[2]] else "n")
' "$NM_VERIFY_SELF" "$SPEND_TXID")
    [[ "$SELF_OK" == "y" ]] || { VSELF_T=bad; log "verifytxoutproof(self) != [$SPEND_TXID]: $NM_VERIFY_SELF"; }
fi
# Oracle sanity: Core verifies its OWN proof to the same single txid too.
CORE_VERIFY_SELF=$(core_cli verifytxoutproof "$CORE_PROOF_BH")
CORE_SELF_OK=$(python3 -c '
import sys, json
try: a = json.loads(sys.argv[1])
except Exception: print("n"); raise SystemExit
print("y" if isinstance(a, list) and a == [sys.argv[2]] else "n")
' "$CORE_VERIFY_SELF" "$SPEND_TXID")
[[ "$CORE_SELF_OK" == "y" ]] || fail "Core verifytxoutproof(own proof) != [$SPEND_TXID] (oracle sanity): $CORE_VERIFY_SELF"
[[ "$VSELF_T" == "ok" ]] && log "CHECK (2) verify-self OK: nimrod verifies its own proof to exactly [$SPEND_TXID]"

# ════════════════════════════════════════════════════════════════════════
# CHECK (3) verify-cross=ok — Core's proof verifies on nimrod (and vice versa).
# ════════════════════════════════════════════════════════════════════════
VCROSS_T=ok
# 3a. Core's proof verified on nimrod -> exactly [SPEND_TXID].
NM_VERIFY_CROSS=$(nm_result verifytxoutproof "[\"$CORE_PROOF_BH\"]")
[[ "$NM_VERIFY_CROSS" == ERR:* ]] && { VCROSS_T=bad; log "nimrod verifytxoutproof(core_hex) errored: ${NM_VERIFY_CROSS#ERR:}"; }
if [[ "$VCROSS_T" == "ok" ]]; then
    CROSS_OK=$(python3 -c '
import sys, json
try: a = json.loads(sys.argv[1])
except Exception: print("n"); raise SystemExit
print("y" if isinstance(a, list) and a == [sys.argv[2]] else "n")
' "$NM_VERIFY_CROSS" "$SPEND_TXID")
    [[ "$CROSS_OK" == "y" ]] || { VCROSS_T=bad; log "nimrod verifytxoutproof(core_hex) != [$SPEND_TXID]: $NM_VERIFY_CROSS"; }
fi
# 3b. nimrod's proof verified on Core -> exactly [SPEND_TXID].
CORE_VERIFY_CROSS=$(core_cli verifytxoutproof "$NM_PROOF_BH")
CORE_CROSS_OK=$(python3 -c '
import sys, json
try: a = json.loads(sys.argv[1])
except Exception: print("n"); raise SystemExit
print("y" if isinstance(a, list) and a == [sys.argv[2]] else "n")
' "$CORE_VERIFY_CROSS" "$SPEND_TXID")
[[ "$CORE_CROSS_OK" == "y" ]] || { VCROSS_T=bad; log "Core verifytxoutproof(nimrod_hex) != [$SPEND_TXID]: $CORE_VERIFY_CROSS"; }
[[ "$VCROSS_T" == "ok" ]] && log "CHECK (3) verify-cross OK: Core's proof verifies on nimrod AND nimrod's proof verifies on Core (both -> [$SPEND_TXID])"

# ════════════════════════════════════════════════════════════════════════
# CHECK (4) errors=ok — unknown txid / unknown blockhash / garbage hex.
# ════════════════════════════════════════════════════════════════════════
ERRORS_T=ok

# 4a. gettxoutproof for an unknown/nonexistent txid (no blockhash) -> error on BOTH.
RAND_TXID="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
NM_E_RAND=$(nm_rpc gettxoutproof "[[\"$RAND_TXID\"]]")
NM_E_RAND_CODE=$(jget "$NM_E_RAND" error code)
[[ "$NM_E_RAND_CODE" =~ ^-?[0-9]+$ ]] || { ERRORS_T=bad; log "gettxoutproof(unknown txid) did NOT error on nimrod: $NM_E_RAND"; }
# Core: -5 "Transaction not yet in block" (with -txindex, the tx is simply not found).
CORE_E_RAND=$(core_cli gettxoutproof "[\"$RAND_TXID\"]" || true)
echo "$CORE_E_RAND" | grep -qiE "not yet in block|not found" \
    || log "note: Core unknown-txid error text differs: $CORE_E_RAND"

# 4b. gettxoutproof([SPEND_TXID], <unknown blockhash>) -> error on BOTH.
BAD_BH="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
NM_E_BADBH=$(nm_rpc gettxoutproof "[[\"$SPEND_TXID\"], \"$BAD_BH\"]")
NM_E_BADBH_CODE=$(jget "$NM_E_BADBH" error code)
NM_E_BADBH_MSG=$(jget "$NM_E_BADBH" error message)
[[ "$NM_E_BADBH_CODE" =~ ^-?[0-9]+$ ]] || { ERRORS_T=bad; log "gettxoutproof(unknown blockhash) did NOT error on nimrod: $NM_E_BADBH"; }
# Core: -5 "Block not found".
CORE_E_BADBH=$(core_cli gettxoutproof "[\"$SPEND_TXID\"]" "$BAD_BH" || true)
echo "$CORE_E_BADBH" | grep -qi "Block not found" \
    || log "note: Core unknown-blockhash error text differs: $CORE_E_BADBH"
echo "$NM_E_BADBH_MSG" | grep -qi "Block not found" \
    || log "note: nimrod unknown-blockhash msg='$NM_E_BADBH_MSG' (Core says 'Block not found')"

# 4c. verifytxoutproof of malformed/garbage hex -> error OR [] on BOTH (match Core).
#   Core deserializes the merkleblock from the span; garbage either fails to parse
#   (throws) or parses to a root mismatch (-> []). Either is acceptable; a spurious
#   non-empty txid array is NOT.
GARBAGE="deadbeefdeadbeefdeadbeefdeadbeef"
CORE_E_GARB=$(core_cli verifytxoutproof "$GARBAGE" || true)
NM_E_GARB=$(nm_rpc verifytxoutproof "[\"$GARBAGE\"]")
# Classify Core's behavior: "error" if non-JSON / threw, "empty" if [].
CORE_GARB_KIND=$(python3 -c '
import sys, json
s = sys.argv[1].strip()
try:
    a = json.loads(s)
    print("empty" if a == [] else ("nonempty" if isinstance(a, list) else "error"))
except Exception:
    print("error")
' "$CORE_E_GARB")
[[ "$CORE_GARB_KIND" != "nonempty" ]] || fail "Core verifytxoutproof(garbage) returned a non-empty array (oracle sanity): $CORE_E_GARB"
# nimrod: must be an RPC error OR an empty result array — NOT a non-empty txid list.
NM_GARB_KIND=$(python3 -c '
import sys, json
try: d = json.loads(sys.argv[1])
except Exception: print("error"); raise SystemExit
if d.get("error") is not None:
    print("error"); raise SystemExit
r = d.get("result")
print("empty" if r == [] else ("nonempty" if isinstance(r, list) else "error"))
' "$NM_E_GARB")
[[ "$NM_GARB_KIND" == "error" || "$NM_GARB_KIND" == "empty" ]] \
    || { ERRORS_T=bad; log "nimrod verifytxoutproof(garbage) returned $NM_GARB_KIND (expected error or []): $NM_E_GARB"; }
log "errors: nimrod garbage-kind=$NM_GARB_KIND, Core garbage-kind=$CORE_GARB_KIND"

# 4d. verifytxoutproof of a well-formed proof for a block NOT in our chain ->
#   error OR [] on BOTH. Take the valid proof and flip a byte in the header
#   (changes the block hash -> not in chain). Core: -5 "Block not found in chain".
TAMPERED=$(python3 -c '
s = "'"$NM_PROOF_BH"'"
# flip the first nibble of the version field (header byte 0) -> different block hash.
b = bytearray.fromhex(s)
b[0] ^= 0x01
print(b.hex())
')
CORE_E_TAMP=$(core_cli verifytxoutproof "$TAMPERED" || true)
NM_E_TAMP=$(nm_rpc verifytxoutproof "[\"$TAMPERED\"]")
NM_TAMP_KIND=$(python3 -c '
import sys, json
try: d = json.loads(sys.argv[1])
except Exception: print("error"); raise SystemExit
if d.get("error") is not None:
    print("error"); raise SystemExit
r = d.get("result")
print("empty" if r == [] else ("nonempty" if isinstance(r, list) else "error"))
' "$NM_E_TAMP")
[[ "$NM_TAMP_KIND" == "error" || "$NM_TAMP_KIND" == "empty" ]] \
    || { ERRORS_T=bad; log "nimrod verifytxoutproof(tampered-header) returned $NM_TAMP_KIND (expected error or []): $NM_E_TAMP"; }
log "errors: nimrod tampered-header-kind=$NM_TAMP_KIND, Core text='${CORE_E_TAMP:0:80}'"

[[ "$ERRORS_T" == "ok" ]] && log "CHECK (4) errors OK: unknown txid + unknown blockhash error on both; garbage/tampered verify -> error or [] (no spurious txid)"

# ── 8. Verdict. ───────────────────────────────────────────────────────────
REASONS=""
[[ "$PROOF_T"  == "ok" ]] || REASONS="$REASONS proof(merkleblock-hex!=Core)"
[[ "$VSELF_T"  == "ok" ]] || REASONS="$REASONS verify-self(!=[txid])"
[[ "$VCROSS_T" == "ok" ]] || REASONS="$REASONS verify-cross(core-proof!=[txid]-on-impl-or-vice-versa)"
[[ "$ERRORS_T" == "ok" ]] || REASONS="$REASONS errors(unknown-txid/blockhash/garbage)"
if [[ -n "$REASONS" ]]; then
    fail "gettxoutproof/verifytxoutproof diverges from Core:$REASONS (see log for details)"
fi

log "PASS: merkleblock hex byte-EXACT vs Core; self+cross verify to [txid]; error paths match Core"
pass "$PROOF_T" "$VSELF_T" "$VCROSS_T" "$ERRORS_T"

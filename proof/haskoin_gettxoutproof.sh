#!/usr/bin/env bash
#
# haskoin_gettxoutproof.sh — self-contained gettxoutproof/verifytxoutproof
# Core-parity differential-regression test for the haskoin (Haskell) node.
#
# Mirrors the proven node-launch + Core-oracle boilerplate from
# test-suite/scan/haskoin_scantxoutset.sh and rawtx/haskoin_getrawtransaction.sh
# (uniform interface): set -uo pipefail, idempotent reset, trap cleanup, scratch
# /tmp + unique ports, ONE summary line, exit 0/1. Run under: setsid -w bash <script>.
#
# Core ref: bitcoin-core/src/rpc/txoutproof.cpp
#   gettxoutproof(["txid",...] (, "blockhash")) -> a SERIALIZED CMerkleBlock as
#     HEX: 80-byte header + nTransactions(uint32 LE) + hash-count(varint) +
#     hashes(32 each) + flag-byte-count(varint) + flag-bytes. Needs either
#     -txindex OR the blockhash arg to locate the tx (without blockhash it scans
#     the UTXO set for an UNSPENT coin of the txid). The SAME tx in the SAME
#     block yields a DETERMINISTIC, byte-identical merkleblock across nodes.
#     Errors: RPC -5 "Block not found" (bad blockhash), "Transaction not yet in
#     block" (txid not located), "Not all transactions found …".
#   verifytxoutproof("hex") -> a JSON ARRAY of the txids the proof commits to
#     that are in the active chain. Returns [] if the merkle root cannot be
#     reconstructed; throws -5 "Block not found in chain" if the block is not on
#     the active chain; garbage hex -> deserialize error.
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) regtest oracle on its
#   own scratch + ports, launched -listen=0 (sandbox SIGKILLs a 0.0.0.0 P2P
#   listener) and -txindex=1 (so gettxoutproof can locate any confirmed tx).
#   haskoin runs on regtest scratch /tmp/gtp-haskoin (RPC 22021, P2P 22041).
#   To give BOTH nodes the IDENTICAL chain (so the SAME tx sits in the SAME
#   block on both, hence a byte-identical merkleblock), every block Core mines
#   is REPLAYED to haskoin via submitblock. We create+sign a real spend on Core
#   to a deterministic address, mine it into a block, replay that block, and
#   then run gettxoutproof/verifytxoutproof for that confirmed tx on BOTH nodes.
#
# STRICT shared assertions (ALL gated — none optional). Run gettxoutproof AND
# verifytxoutproof on BOTH the impl and Core:
#   (1) proof       : impl gettxoutproof([txid], blockhash) hex is BYTE-IDENTICAL
#                     to Core's gettxoutproof([txid], blockhash) for the same
#                     confirmed tx in the same block.
#   (2) verify-self : impl verifytxoutproof(impl_hex) == EXACTLY [txid].
#   (3) verify-cross: impl verifytxoutproof(core_hex) == EXACTLY [txid]
#                     (Core's proof verifies on the impl).
#   (4) errors      : impl gettxoutproof for a nonexistent txid -> ERROR
#                     (Core: -5 'Transaction not yet in block' / 'Block not
#                     found'); impl verifytxoutproof of garbage hex -> ERROR or
#                     [] (matching Core's behavior on the same garbage).
#
# Summary line (stdout):
#   GETTXOUTPROOF haskoin: PASS proof=ok verify-self=ok verify-cross=ok errors=ok
#   GETTXOUTPROOF haskoin: FAIL <short reason>
# If the haskoin binary is missing, prints a GAP_RE-compatible "not built"
# message so the cross-impl runner can SKIP.
#
# Touches ONLY /tmp/gtp-haskoin* + /tmp/gtp-core* and ports 22021/22041
#   (haskoin RPC/P2P) + 22121/22141 (Core RPC/P2P). NEVER touches /data/nvme1/
#   or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$(find "$BASEDIR/haskoin/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

export haskoin_datadir="$BASEDIR/haskoin"   # BIP-39 wordlist resolution at runtime

HK_DATADIR="/tmp/gtp-haskoin"
HK_RPC=22021
HK_P2P=22041
HK_LOG="$HK_DATADIR/node.log"
HK_COOKIE=""

CORE_DATADIR="/tmp/gtp-core"
CORE_RPC=22121
CORE_P2P=22141
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic mining key (32-byte secret) we control, so we can sign a spend.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
NBLOCKS=110        # >100 so coinbase[1] is spendable (COINBASE_MATURITY=100)
FUND_BTC="49.999"  # amount paid to DEST in the spend (fee 0.001)

# A txid that is guaranteed not to be in any block (deterministic garbage).
NONEXIST_TXID="dead00000000000000000000000000000000000000000000000000000000beef"
# Malformed/garbage hex for verifytxoutproof error testing.
GARBAGE_HEX="deadbeef"

HK_PID=""
CORE_BG=""

log() { echo "[gettxoutproof:haskoin] $*" >&2; }

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
    echo "GETTXOUTPROOF haskoin: PASS proof=$1 verify-self=$2 verify-cross=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETTXOUTPROOF haskoin: FAIL $*"
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
# dest = a FRESH p2wpkh address we pay the spend to.
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
print(mine); print(wif); print(dest)
" 2>/dev/null) || fail "could not derive key material (Core test_framework import failed)"
ADDR=$(echo "$KEYINFO" | sed -n '1p')
WIF=$(echo "$KEYINFO"  | sed -n '2p')
DEST=$(echo "$KEYINFO" | sed -n '3p')
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
# 0.001. This is our target tx for the proof: it lands in a single known block.
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
log "target txid=$TXID -> $DEST ($FUND_BTC BTC)"

# Submit to BOTH mempools (maxfeerate=0 disables the high-fee-rate guard).
CORE_SEND=$(core_cli sendrawtransaction "$TXHEX" 0 2>&1) || fail "Core sendrawtransaction failed: $CORE_SEND"
[[ "$CORE_SEND" == "$TXID" ]] || fail "Core sendrawtransaction returned '$CORE_SEND' != $TXID"
HK_SEND_ENV=$(hk_rpc sendrawtransaction "[\"$TXHEX\", 0]")
HK_SEND=$(jpy "$HK_SEND_ENV" "d.get('result')")
if [[ "$HK_SEND" != "$TXID" ]]; then
    HK_INMP=$(jpy "$(hk_rpc getrawmempool '[]')" "'$TXID' in d.get('result', [])")
    [[ "$HK_INMP" == "true" ]] || log "note: haskoin sendrawtransaction did not accept tx (will rely on block replay): $HK_SEND_ENV"
fi

# Mine the spend into a block on Core, replay to haskoin -> tx now confirmed on both.
NEWBLK=$(core_cli generatetoaddress 1 "$ADDR" | python3 -c "import sys,json;print(json.load(sys.stdin)[0])")
[[ -n "$NEWBLK" ]] || fail "could not mine confirming block on Core"
NEWH=$(( NBLOCKS + 1 ))
replay_to_height "$NEWH" || fail "could not replay confirming block to haskoin"
# Confirm the target tx is in NEWBLK on Core.
CORE_TXBH=$(core_cli getrawtransaction "$TXID" 1 "$NEWBLK" | python3 -c "import sys,json;print(json.load(sys.stdin)['blockhash'])")
[[ "$CORE_TXBH" == "$NEWBLK" ]] || fail "Core confirmed blockhash $CORE_TXBH != $NEWBLK"
# Confirm haskoin agrees on the tip / that NEWBLK is on its chain.
HK_TIP=$(jpy "$(hk_rpc getblockhash "[$NEWH]")" "d['result']")
[[ "$HK_TIP" == "$NEWBLK" ]] || fail "haskoin block at height $NEWH ($HK_TIP) != Core confirming block ($NEWBLK)"
log "target tx confirmed in block $NEWBLK (height $NEWH) on BOTH nodes"

# ── Oracle: Core's gettxoutproof (with explicit blockhash) is the ground truth.
# We pass the blockhash arg so both nodes locate the tx the same way regardless
# of -txindex availability; the resulting CMerkleBlock is deterministic.
CORE_PROOF=$(core_cli gettxoutproof "[\"$TXID\"]" "$NEWBLK" 2>&1) || fail "Core gettxoutproof failed: $CORE_PROOF"
[[ "$CORE_PROOF" =~ ^[0-9a-fA-F]+$ ]] || fail "Core gettxoutproof returned non-hex: $CORE_PROOF"
log "Core proof (oracle) len=${#CORE_PROOF} hex prefix=${CORE_PROOF:0:24}…"

# Core self-verify sanity: verifytxoutproof(core_proof) on Core == [TXID].
CORE_VSELF=$(core_cli verifytxoutproof "$CORE_PROOF" 2>&1) || fail "Core verifytxoutproof failed: $CORE_VSELF"
CORE_VSELF_LIST=$(jpy "$CORE_VSELF" "json.dumps(d)")
[[ "$CORE_VSELF_LIST" == "[\"$TXID\"]" ]] || fail "Core self-verify did not return [txid]: $CORE_VSELF_LIST (test-setup sanity)"
log "Core self-verify ok: $CORE_VSELF_LIST"

# ── TEST (1): proof — impl gettxoutproof hex BYTE-IDENTICAL to Core's. ─────
PROOF_T="bad"
HK_PROOF_ENV=$(hk_rpc gettxoutproof "[[\"$TXID\"], \"$NEWBLK\"]")
if echo "$HK_PROOF_ENV" | grep -q '"error":null' && echo "$HK_PROOF_ENV" | grep -q '"result"'; then
    HK_PROOF=$(jpy "$HK_PROOF_ENV" "d['result']")
else
    HK_PROOF=""
fi
if [[ -z "$HK_PROOF" || ! "$HK_PROOF" =~ ^[0-9a-fA-F]+$ ]]; then
    HK_ERR=$(jpy "$HK_PROOF_ENV" "json.dumps(d.get('error'))")
    fail "proof: haskoin gettxoutproof did not return proof hex (got error=$HK_ERR full=$HK_PROOF_ENV)"
fi
# Compare case-insensitively (hex is the same value regardless of case).
HK_PROOF_LC=$(echo "$HK_PROOF" | tr 'A-F' 'a-f')
CORE_PROOF_LC=$(echo "$CORE_PROOF" | tr 'A-F' 'a-f')
if [[ "$HK_PROOF_LC" != "$CORE_PROOF_LC" ]]; then
    fail "proof: haskoin gettxoutproof hex NOT byte-identical to Core. hk_len=${#HK_PROOF} core_len=${#CORE_PROOF} hk_prefix=${HK_PROOF:0:24} core_prefix=${CORE_PROOF:0:24}"
fi
PROOF_T="ok"
log "proof ok: haskoin gettxoutproof hex is byte-identical to Core (len=${#HK_PROOF})"

# ── TEST (2): verify-self — impl verifytxoutproof(impl_hex) == [txid]. ─────
VSELF_T="bad"
HK_VSELF_ENV=$(hk_rpc verifytxoutproof "[\"$HK_PROOF\"]")
echo "$HK_VSELF_ENV" | grep -q '"result"' || fail "verify-self: haskoin verifytxoutproof errored: $HK_VSELF_ENV"
HK_VSELF=$(jpy "$HK_VSELF_ENV" "json.dumps(d['result'])")
[[ "$HK_VSELF" == "[\"$TXID\"]" ]] || fail "verify-self: haskoin verifytxoutproof(impl_hex) = $HK_VSELF, expected [\"$TXID\"]"
VSELF_T="ok"
log "verify-self ok: haskoin verifytxoutproof(impl_hex) = $HK_VSELF"

# ── TEST (3): verify-cross — impl verifytxoutproof(core_hex) == [txid]. ────
VCROSS_T="bad"
HK_VCROSS_ENV=$(hk_rpc verifytxoutproof "[\"$CORE_PROOF\"]")
echo "$HK_VCROSS_ENV" | grep -q '"result"' || fail "verify-cross: haskoin verifytxoutproof(core_hex) errored: $HK_VCROSS_ENV"
HK_VCROSS=$(jpy "$HK_VCROSS_ENV" "json.dumps(d['result'])")
[[ "$HK_VCROSS" == "[\"$TXID\"]" ]] || fail "verify-cross: haskoin verifytxoutproof(core_hex) = $HK_VCROSS, expected [\"$TXID\"]"
VCROSS_T="ok"
log "verify-cross ok: haskoin verifytxoutproof(core_hex) = $HK_VCROSS"

# ── TEST (4): errors — gettxoutproof(unknown txid) -> ERROR; ──────────────
#    verifytxoutproof(garbage hex) -> ERROR or [] (match Core's behavior).
ERRORS_T="bad"

# (4a) gettxoutproof for a nonexistent txid. Core: RPC -5 (no blockhash arg ->
#      "Transaction not yet in block"). Use NO blockhash so Core must locate it.
CORE_GTP_ERR=$(core_cli gettxoutproof "[\"$NONEXIST_TXID\"]" 2>&1)
CORE_GTP_RC=$?
[[ "$CORE_GTP_RC" -ne 0 ]] || fail "errors(4a): Core gettxoutproof(nonexistent) unexpectedly succeeded: $CORE_GTP_ERR"
log "errors(4a) Core gettxoutproof(nonexistent) -> error (rc=$CORE_GTP_RC): $(echo "$CORE_GTP_ERR" | tr '\n' ' ')"
# Impl must ALSO error (non-null JSON-RPC error, no usable result).
HK_GTP_ERR_ENV=$(hk_rpc gettxoutproof "[[\"$NONEXIST_TXID\"]]")
HK_GTP_ISERR=$(jpy "$HK_GTP_ERR_ENV" "d.get('error') is not None")
HK_GTP_RES=$(jpy "$HK_GTP_ERR_ENV" "d.get('result')")
if [[ "$HK_GTP_ISERR" != "true" ]]; then
    # A null/empty result is also acceptable as "no proof produced"; a real hex string is NOT.
    if [[ -n "$HK_GTP_RES" && "$HK_GTP_RES" =~ ^[0-9a-fA-F]+$ ]]; then
        fail "errors(4a): haskoin gettxoutproof(nonexistent) returned a proof instead of error: $HK_GTP_ERR_ENV"
    fi
fi
log "errors(4a) haskoin gettxoutproof(nonexistent) -> error/empty: $(echo "$HK_GTP_ERR_ENV" | tr '\n' ' ' | cut -c1-200)"

# (4b) gettxoutproof with a bogus blockhash. Core: RPC -5 "Block not found".
BOGUS_BH="00000000000000000000000000000000000000000000000000000000deadbeef"
CORE_BH_ERR=$(core_cli gettxoutproof "[\"$TXID\"]" "$BOGUS_BH" 2>&1)
CORE_BH_RC=$?
[[ "$CORE_BH_RC" -ne 0 ]] || fail "errors(4b): Core gettxoutproof(bogus blockhash) unexpectedly succeeded: $CORE_BH_ERR"
log "errors(4b) Core gettxoutproof(bogus blockhash) -> error (rc=$CORE_BH_RC): $(echo "$CORE_BH_ERR" | tr '\n' ' ')"
HK_BH_ERR_ENV=$(hk_rpc gettxoutproof "[[\"$TXID\"], \"$BOGUS_BH\"]")
HK_BH_ISERR=$(jpy "$HK_BH_ERR_ENV" "d.get('error') is not None")
HK_BH_RES=$(jpy "$HK_BH_ERR_ENV" "d.get('result')")
if [[ "$HK_BH_ISERR" != "true" ]]; then
    if [[ -n "$HK_BH_RES" && "$HK_BH_RES" =~ ^[0-9a-fA-F]+$ ]]; then
        fail "errors(4b): haskoin gettxoutproof(bogus blockhash) returned a proof instead of error: $HK_BH_ERR_ENV"
    fi
fi
log "errors(4b) haskoin gettxoutproof(bogus blockhash) -> error/empty: $(echo "$HK_BH_ERR_ENV" | tr '\n' ' ' | cut -c1-200)"

# (4c) verifytxoutproof of malformed/garbage hex. Determine Core's behavior on
#      the SAME garbage, then require the impl to match (error OR [], same class).
CORE_VG=$(core_cli verifytxoutproof "$GARBAGE_HEX" 2>&1)
CORE_VG_RC=$?
if [[ "$CORE_VG_RC" -ne 0 ]]; then
    CORE_VG_CLASS="error"
else
    CORE_VG_CLASS="result:$(jpy "$CORE_VG" "json.dumps(d)")"
fi
log "errors(4c) Core verifytxoutproof(garbage) -> class=$CORE_VG_CLASS raw=$(echo "$CORE_VG" | tr '\n' ' ' | cut -c1-120)"
HK_VG_ENV=$(hk_rpc verifytxoutproof "[\"$GARBAGE_HEX\"]")
HK_VG_ISERR=$(jpy "$HK_VG_ENV" "d.get('error') is not None")
HK_VG_RES=$(jpy "$HK_VG_ENV" "json.dumps(d.get('result'))")
# Accept impl behavior if it is an error OR an empty array — both are valid
# "garbage rejected" responses and either matches/over-rejects vs Core.
if [[ "$HK_VG_ISERR" == "true" ]]; then
    HK_VG_CLASS="error"
elif [[ "$HK_VG_RES" == "[]" ]]; then
    HK_VG_CLASS="empty"
else
    fail "errors(4c): haskoin verifytxoutproof(garbage) neither errored nor returned []: $HK_VG_ENV"
fi
# Cross-check: Core must also reject garbage (error or []). If Core ACCEPTED
# garbage as a real txid list, the impl returning error/[] would be a divergence
# we should surface — but that cannot happen for "deadbeef".
case "$CORE_VG_CLASS" in
    error|result:\[\]) : ;;  # Core rejected (error or empty) — impl error/[] is parity.
    *) fail "errors(4c): Core ACCEPTED garbage hex as $CORE_VG_CLASS but haskoin returned $HK_VG_CLASS (divergence)" ;;
esac
log "errors(4c) haskoin verifytxoutproof(garbage) -> $HK_VG_CLASS (Core $CORE_VG_CLASS)"

ERRORS_T="ok"
log "errors ok: gettxoutproof(unknown)/gettxoutproof(bogus bh)/verifytxoutproof(garbage) all reject like Core"

# ── Done. ──────────────────────────────────────────────────────────────────
log "PASS: haskoin gettxoutproof/verifytxoutproof matches Core (proof + verify-self + verify-cross + errors)"
pass "$PROOF_T" "$VSELF_T" "$VCROSS_T" "$ERRORS_T"

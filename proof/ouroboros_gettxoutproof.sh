#!/usr/bin/env bash
#
# ouroboros_gettxoutproof.sh — self-contained gettxoutproof / verifytxoutproof
# DIFFERENTIAL-REGRESSION test against a real Bitcoin Core oracle.
#
# gettxoutproof + verifytxoutproof are the SPV-proof pair. gettxoutproof(["txid"]
# [,"blockhash"]) returns a SERIALIZED, hex-encoded CMerkleBlock:
#     80-byte block header
#     nTransactions          (uint32 LE)
#     hash count (varint) + hashes (32 bytes each, internal/LE order)
#     flag-byte count (varint) + flag bytes
# verifytxoutproof("hex") deserializes that merkleblock, re-derives the Merkle
# root from the partial tree, checks the committed block is in the active chain,
# and returns a JSON ARRAY of the txids the proof commits to (display/BE order),
# or an empty array / RPC error if the proof cannot be validated.
#
# The proof is FULLY DETERMINISTIC: the SAME tx in the SAME block yields a
# BYTE-IDENTICAL merkleblock on every node, because the header, the tx set, and
# the partial-Merkle-tree traversal are all fixed by consensus. So two nodes on
# an identical chain MUST emit the identical hex, and EITHER node's proof MUST
# verify on the OTHER.
#
# Core ref: bitcoin-core/src/rpc/txoutproof.cpp
#   gettxoutproof:     CMerkleBlock(block,setTxids); ssMB << mb; HexStr(ssMB).
#                      -5 'Block not found'              (bad blockhash arg)
#                      -5 'Transaction not yet in block' (txid not located)
#   verifytxoutproof:  ExtractMatches() == header.hashMerkleRoot ? push txids
#                      : return [].  -5 'Block not found in chain' if the
#                      committed block is not on the active chain.
#
# WHAT THIS PROVES (all FOUR gated, none optional):
#   Drive ouroboros + a real bitcoind oracle onto an IDENTICAL regtest chain
#   (Core mines, ouroboros replays Core's blocks via submitblock -> identical
#   block bodies), fund a deterministic address and CONFIRM the tx in a block
#   that both nodes carry byte-for-byte, then:
#     (1) proof=ok      gettxoutproof([txid]) on ouroboros == Core's, BYTE-IDENTICAL.
#                       (both with the explicit blockhash arg AND, separately,
#                        the no-blockhash UTXO/txindex-lookup path.)
#     (2) verify-self   verifytxoutproof(ouroboros_hex) on ouroboros == EXACTLY [txid].
#     (3) verify-cross  verifytxoutproof(core_hex)      on ouroboros == EXACTLY [txid].
#     (4) errors        gettxoutproof([nonexistent txid]) -> RPC error on BOTH;
#                       gettxoutproof([txid],<unknown blockhash>) -> error on BOTH;
#                       verifytxoutproof(<garbage hex>) -> error/[] on BOTH
#                       (matched to Core's behavior).
#
# CORE ORACLE: a real bitcoind regtest node on its own scratch + ports owns the
#   ground truth. Launched with -listen=0 (sandbox SIGKILLs a 0.0.0.0 P2P
#   listener; RPC-only is fine) and -txindex=1 (gettxoutproof needs either
#   -txindex OR an unspent output OR the blockhash arg to locate the tx).
#
# STRICT UNIFORM INTERFACE (mirrors scan/ouroboros_scantxoutset.sh +
#   rawtx/ouroboros_getrawtransaction.sh): no required args, idempotent, trap
#   cleanup, scratch /tmp datadirs + UNIQUE ports, ONE clean summary line on
#   stdout, noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTPROOF ouroboros: PASS proof=ok verify-self=ok verify-cross=ok errors=ok
#   FAIL: GETTXOUTPROOF ouroboros: FAIL <short reason>
#   SKIP (runner GAP_RE): a "not found"/"not built" reason if the impl is absent.
#
# Touches ONLY /tmp/proof-ouroboros-impl + /tmp/proof-ouroboros-core and ports
#   22212/22232 (ouroboros RPC/P2P) + 22222/22242 (Core RPC/P2P). The datadir
#   names + reset/cleanup scoping are keyed to "proof-ouroboros" so this runs
#   SAFELY in parallel with any sibling per-impl proof test.
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#
# Port-kills (fuser -k) are BANNED (2026-06-10 incident); PID-scoped kills only.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OURO_DIR="$REPO_ROOT/ouroboros"

# Datadir names are keyed to this impl ("proof-ouroboros-*") so we never collide
# with — or rm -rf — a sibling per-impl test's scratch.
OU_DATADIR="/tmp/proof-ouroboros-impl"
OU_RPC=22212
OU_P2P=22232
OU_LOG="$OU_DATADIR/node.log"

CORE_DATADIR="/tmp/proof-ouroboros-core"
CORE_RPC=22222
CORE_P2P=22242
CORE_LOG="$CORE_DATADIR/core.log"

# Funding source: deterministic keypair #1 (privkey 0x11..11). We mine coinbase
# rewards here so we control a spendable matured output to fund the proof target.
WIF1="cN9spWsvaxA8taS7DFMxnk1yJD2gaF2PX1npuTpy3vuZFJdwavaw"
ADDR1="bcrt1ql3e9pgs3mmwuwrh95fecme0s0qtn2880hlwwpw"
SPK1="0014fc7250a211deddc70ee5a2738de5f07817351cef"

# Proof TARGET: deterministic keypair #2 (privkey 0x22..22). Freshly funded with
# one known-amount output, then CONFIRMED in a block — the tx we build a proof
# for. Using a non-coinbase tx (a real spend in a >1-tx block) exercises a
# non-trivial partial Merkle tree, not the degenerate single-tx case.
ADDR2="bcrt1q2vfxp232rx0z9rzn0hay9jptagk8c86ddphpjv"
FUND_AMT="49.99990000"   # value sent to ADDR2 (block-1 coinbase 50 BTC minus fee)

NBLOCKS=101            # 101 blocks: block-1 coinbase matures at height 101

OU_PID=""
OU_COOKIE=""
CORE_BG=""

log() { echo "[gettxoutproof:ouroboros] $*" >&2; }

cleanup() {
    local ec=$?
    if [[ -n "$OU_PID" ]] && kill -0 "$OU_PID" 2>/dev/null; then
        kill "$OU_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$OU_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$OU_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    # Scope process kills to OUR datadirs only — never a sibling test's.
    pkill -9 -f "proof-ouroboros-impl" >/dev/null 2>&1 || true
    pkill -9 -f "proof-ouroboros-core" >/dev/null 2>&1 || true
    rm -rf "$OU_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "GETTXOUTPROOF ouroboros: PASS proof=ok verify-self=ok verify-cross=ok errors=ok"
    exit 0
}
fail() {
    echo "GETTXOUTPROOF ouroboros: FAIL $*"
    exit 1
}

# Core CLI shorthand.
ccli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# ouroboros JSON-RPC over curl: ou_rpc <method> <json-params-array> -> raw envelope.
ou_rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 120 -u "$OU_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$OU_RPC/" 2>/dev/null
}

# Unwrap a JSON-RPC envelope to its .result (prints "<ERR>code=..msg=..." on error).
ou_result() {
    python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('<PARSEERR>'); sys.exit(0)
if d.get('error') is not None:
    e=d['error']; print('<ERR>code=%s msg=%s' % (e.get('code'), e.get('message'))); sys.exit(0)
r=d.get('result')
print(r if isinstance(r,str) else json.dumps(r))
"
}

# True (exit 0) iff the JSON-RPC envelope on stdin carries a non-null .error.
ou_is_err() {
    python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)   # parse failure -> treat as error
sys.exit(0 if d.get('error') is not None else 1)
"
}

# Extract the JSON-RPC error code (or empty) from an envelope on stdin.
ou_err_code() {
    python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit(0)
e=d.get('error') or {}
print(e.get('code',''))
"
}

# Compare a JSON array (arg1) against an expected single-element list [txid].
# Prints EQ / NE.  Tolerant of value vs string-typed entries.
arr_is_single_txid() {
    python3 - "$1" "$2" <<'PYEOF'
import json, sys
try:
    arr = json.loads(sys.argv[1])
except Exception:
    print("NE"); sys.exit(0)
want = sys.argv[2]
if isinstance(arr, list) and len(arr) == 1 and str(arr[0]).lower() == want.lower():
    print("EQ")
else:
    print("NE")
PYEOF
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "proof-ouroboros-impl" 2>/dev/null || true
pkill -f "proof-ouroboros-core" 2>/dev/null || true
for _ in $(seq 1 10); do
    pgrep -f "proof-ouroboros-impl" >/dev/null 2>&1 || pgrep -f "proof-ouroboros-core" >/dev/null 2>&1 || break
    sleep 1
done
pkill -9 -f "proof-ouroboros-impl" 2>/dev/null || true
pkill -9 -f "proof-ouroboros-core" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${OU_RPC}|${OU_P2P}|${CORE_RPC}|${CORE_P2P}|$((CORE_P2P + 1))) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${OU_RPC}|${OU_P2P}|${CORE_RPC}|${CORE_P2P}|$((CORE_P2P + 1))) "; then
    fail "port ${OU_RPC}/${OU_P2P}/${CORE_RPC}/${CORE_P2P}/$((CORE_P2P + 1)) already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 2
rm -rf "$OU_DATADIR" "$CORE_DATADIR"
mkdir -p "$OU_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1        || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1           || fail "curl not found on PATH"
[[ -f "$OURO_DIR/src/ouroboros/cli.py" ]] || fail "ouroboros checkout not found at $OURO_DIR (not built)"
[[ -x "$CORE_BIN" ]]                      || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                      || fail "bitcoin-cli not found at $CORE_CLI"

OURO_PY="$OURO_DIR/.venv/bin/python3"
[[ -x "$OURO_PY" ]] || OURO_PY="python3"

# ── 2. Launch the Core regtest oracle (-listen=0, -txindex=1). ────────────
log "launching Core regtest oracle rpc=:$CORE_RPC (listen=0, txindex=1)"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    -rpcbind=127.0.0.1 -listen=0 -discover=0 -dnsseed=0 \
    -txindex=1 -fallbackfee=0.0002 -daemonwait=0 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 60 ))
core_ready=0
while (( $(date +%s) < core_deadline )); do
    if ccli getblockcount >/dev/null 2>&1; then core_ready=1; break; fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
[[ "$core_ready" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 60s"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Mine NBLOCKS blocks on Core to our funding address. ─────────────────
log "mining $NBLOCKS blocks on Core to $ADDR1"
ccli generatetoaddress "$NBLOCKS" "$ADDR1" >/dev/null 2>&1 \
    || fail "Core generatetoaddress failed (see $CORE_LOG)"
CORE_TIP=$(ccli getblockcount 2>/dev/null)
[[ "$CORE_TIP" == "$NBLOCKS" ]] || fail "Core tip=$CORE_TIP != $NBLOCKS after mining"

# ── 4. Launch ouroboros on regtest. ───────────────────────────────────────
log "launching ouroboros (regtest, --nolisten) rpc=:$OU_RPC -> $OU_LOG"
(
    cd "$OURO_DIR" || exit 1
    exec "$OURO_PY" -m ouroboros.cli \
        --network regtest --data-dir "$OU_DATADIR" \
        start --force --nolisten --rpc-port "$OU_RPC" --p2p-port "$OU_P2P"
) >"$OU_LOG" 2>&1 &
OU_PID=$!
log "ouroboros pid=$OU_PID"
ou_deadline=$(( $(date +%s) + 180 ))
while (( $(date +%s) < ou_deadline )); do
    if [[ -z "$OU_COOKIE" ]]; then
        for c in "$OU_DATADIR/.cookie" "$OU_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && OU_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$OU_COOKIE" ]]; then
        r=$(ou_rpc getblockcount)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$OU_PID" 2>/dev/null || { tail -n 20 "$OU_LOG" >&2 2>/dev/null || true; fail "ouroboros exited during startup (see $OU_LOG)"; }
    sleep 1
done
[[ -n "$OU_COOKIE" ]] || fail "ouroboros cookie never appeared within 180s"
r=$(ou_rpc getblockcount)
echo "$r" | grep -q '"result"' || fail "ouroboros RPC never responded within 180s"
log "ouroboros RPC ready"

# ── 5. Replicate Core's chain onto ouroboros via submitblock. ─────────────
log "replicating Core blocks 1..$NBLOCKS onto ouroboros via submitblock"
for h in $(seq 1 "$NBLOCKS"); do
    BH=$(ccli getblockhash "$h" 2>/dev/null) || fail "Core getblockhash($h) failed"
    RAW=$(ccli getblock "$BH" 0 2>/dev/null) || fail "Core getblock($h) raw failed"
    sb=$(ou_rpc submitblock "[\"$RAW\"]" | ou_result)
    case "$sb" in
        "<ERR>"*) fail "ouroboros submitblock($h) error: ${sb#<ERR>}" ;;
        "null"|"") : ;;                       # null == accepted (Core convention)
        *) fail "ouroboros submitblock($h) rejected: $sb" ;;
    esac
done
OU_TIP=$(ou_rpc getblockcount | ou_result)
[[ "$OU_TIP" == "$NBLOCKS" ]] || fail "ouroboros tip=$OU_TIP != $NBLOCKS after replication"
CORE_TIPHASH=$(ccli getblockhash "$NBLOCKS" 2>/dev/null)
OU_TIPHASH=$(ou_rpc getblockhash "[$NBLOCKS]" | ou_result)
[[ "$OU_TIPHASH" == "$CORE_TIPHASH" ]] \
    || fail "tip hash mismatch after replication: core=$CORE_TIPHASH ouroboros=$OU_TIPHASH"
log "chains identical (tip $NBLOCKS hash=$CORE_TIPHASH)"

# ── 6. Build + sign a real tx paying ADDR2; confirm it in a block. ─────────
# Spend block-1's matured coinbase (paid to ADDR1) -> FUND_AMT to ADDR2. The
# confirming block then carries 2 txs (coinbase + this spend) -> a non-trivial
# partial Merkle tree for the proof.
CB1=$(ccli getblock "$(ccli getblockhash 1)" 1 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['tx'][0])")
[[ "$CB1" =~ ^[0-9a-f]{64}$ ]] || fail "could not resolve block-1 coinbase txid"
log "spending block-1 coinbase $CB1 -> $FUND_AMT to ADDR2"
RAW_UNSIGNED=$(ccli createrawtransaction \
    "[{\"txid\":\"$CB1\",\"vout\":0}]" "[{\"$ADDR2\":$FUND_AMT}]" 2>/dev/null) \
    || fail "createrawtransaction failed"
SIGNED_JSON=$(ccli signrawtransactionwithkey "$RAW_UNSIGNED" "[\"$WIF1\"]" \
    "[{\"txid\":\"$CB1\",\"vout\":0,\"scriptPubKey\":\"$SPK1\",\"amount\":50.0}]" 2>/dev/null) \
    || fail "signrawtransactionwithkey failed"
COMPLETE=$(echo "$SIGNED_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('complete'))")
[[ "$COMPLETE" == "True" ]] || { log "sign reply: $SIGNED_JSON"; fail "tx signing not complete"; }
TX_HEX=$(echo "$SIGNED_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['hex'])")
[[ -n "$TX_HEX" ]] || fail "signed tx hex empty"

# Broadcast on Core, mine a confirming block, replay that block to ouroboros so
# BOTH chainstates carry the new ADDR2 UTXO + the same confirming block.
TXID=$(ccli sendrawtransaction "$TX_HEX" 2>/dev/null) || { tail -n 5 "$CORE_LOG" >&2; fail "Core sendrawtransaction failed"; }
[[ "$TXID" =~ ^[0-9a-f]{64}$ ]] || fail "Core sendrawtransaction returned no txid"
log "funding tx in Core mempool: $TXID"
# Put it into ouroboros's mempool too (harmless; the block replay below is what
# actually confirms it on ouroboros).
ou_send=$(ou_rpc sendrawtransaction "[\"$TX_HEX\"]" | ou_result)
case "$ou_send" in "<ERR>"*) log "note: ouroboros sendrawtransaction said ${ou_send#<ERR>} (non-fatal; block replay confirms)";; esac

NEWBH=$(ccli generatetoaddress 1 "$ADDR1" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)[0])")
[[ "$NEWBH" =~ ^[0-9a-f]{64}$ ]] || fail "Core did not mine the confirming block"
NEWH=$((NBLOCKS + 1))
RAW_NEWBLOCK=$(ccli getblock "$NEWBH" 0 2>/dev/null)
sb=$(ou_rpc submitblock "[\"$RAW_NEWBLOCK\"]" | ou_result)
case "$sb" in
    "<ERR>"*) fail "ouroboros submitblock(confirming) error: ${sb#<ERR>}" ;;
    "null"|"") : ;;
    *) fail "ouroboros submitblock(confirming) rejected: $sb" ;;
esac
OU_CONF_TIP=$(ou_rpc getblockcount | ou_result)
[[ "$OU_CONF_TIP" == "$NEWH" ]] || fail "ouroboros tip=$OU_CONF_TIP != $NEWH after confirming block"
[[ "$(ou_rpc getblockhash "[$NEWH]" | ou_result)" == "$NEWBH" ]] \
    || fail "confirming block hash differs between nodes"
# Sanity: the confirming block really carries our tx (and a coinbase) on Core.
NTX_IN_BLOCK=$(ccli getblock "$NEWBH" 1 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['tx']))")
[[ "$NTX_IN_BLOCK" -ge 2 ]] || fail "confirming block has <2 txs ($NTX_IN_BLOCK); expected coinbase + spend"
log "tx $TXID confirmed in block $NEWH ($NEWBH; $NTX_IN_BLOCK txs) on BOTH nodes"

# ── 7. CHECK (1) proof=ok — gettxoutproof([txid]) BYTE-IDENTICAL vs Core. ──
# 7a. WITH the explicit blockhash arg (the always-deterministic path).
CORE_PROOF_BH=$(ccli gettxoutproof "[\"$TXID\"]" "$NEWBH" 2>/dev/null) \
    || { tail -n 5 "$CORE_LOG" >&2; fail "Core gettxoutproof (with blockhash) failed"; }
[[ "$CORE_PROOF_BH" =~ ^[0-9a-f]+$ ]] || fail "Core gettxoutproof (blockhash) returned non-hex: $CORE_PROOF_BH"
OU_PROOF_BH=$(ou_rpc gettxoutproof "[[\"$TXID\"],\"$NEWBH\"]" | ou_result)
case "$OU_PROOF_BH" in "<ERR>"*) fail "ouroboros gettxoutproof (blockhash) error: ${OU_PROOF_BH#<ERR>}" ;; esac
[[ "$OU_PROOF_BH" =~ ^[0-9a-f]+$ ]] || fail "ouroboros gettxoutproof (blockhash) returned non-hex: $OU_PROOF_BH"
[[ "$OU_PROOF_BH" == "$CORE_PROOF_BH" ]] \
    || fail "proof hex (blockhash arg) NOT byte-identical: core=$CORE_PROOF_BH ouro=$OU_PROOF_BH"
log "proof (blockhash arg): BYTE-IDENTICAL vs Core (len=${#CORE_PROOF_BH})"

# 7b. WITHOUT the blockhash arg (txid located via txindex / unspent UTXO). The
# coin paid to ADDR2 is still unspent, so both nodes can locate the block.
CORE_PROOF=$(ccli gettxoutproof "[\"$TXID\"]" 2>/dev/null) \
    || { tail -n 5 "$CORE_LOG" >&2; fail "Core gettxoutproof (no blockhash) failed"; }
OU_PROOF=$(ou_rpc gettxoutproof "[[\"$TXID\"]]" | ou_result)
case "$OU_PROOF" in "<ERR>"*) fail "ouroboros gettxoutproof (no blockhash) error: ${OU_PROOF#<ERR>}" ;; esac
[[ "$OU_PROOF" == "$CORE_PROOF" ]] \
    || fail "proof hex (no blockhash) NOT byte-identical: core=$CORE_PROOF ouro=$OU_PROOF"
# And the no-blockhash form must equal the with-blockhash form (same block).
[[ "$OU_PROOF" == "$OU_PROOF_BH" ]] \
    || fail "ouroboros proof differs between blockhash and no-blockhash paths"
log "proof (no-blockhash lookup): BYTE-IDENTICAL vs Core and matches blockhash path (proof=ok)"

# Structural sanity on the merkleblock: header(80) + nTx(4) + body, header's
# first 4 bytes are the version, bytes 36..68 are the merkle root == block's.
BLOCK_MROOT=$(ccli getblock "$NEWBH" 1 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['merkleroot'])")
PROOF_MROOT=$(python3 -c "
import sys
h=bytes.fromhex('$OU_PROOF')
# header bytes 36:68 are the merkle root (internal/LE) -> display order reverses.
print(h[36:68][::-1].hex())
")
[[ "$PROOF_MROOT" == "$BLOCK_MROOT" ]] \
    || fail "merkleblock header merkle root ($PROOF_MROOT) != block merkleroot ($BLOCK_MROOT)"
log "merkleblock header merkle root matches block merkleroot ($BLOCK_MROOT)"

# ── 8. CHECK (2) verify-self — verifytxoutproof(ouroboros_hex) == [txid]. ──
OU_VS=$(ou_rpc verifytxoutproof "[\"$OU_PROOF\"]" | ou_result)
case "$OU_VS" in "<ERR>"*) fail "ouroboros verifytxoutproof(self) error: ${OU_VS#<ERR>}" ;; esac
[[ "$(arr_is_single_txid "$OU_VS" "$TXID")" == "EQ" ]] \
    || fail "verify-self: ouroboros verifytxoutproof(own proof) != [$TXID] (got $OU_VS)"
# Core must agree on Core's own proof too (oracle sanity).
CORE_VS=$(ccli verifytxoutproof "$CORE_PROOF" 2>/dev/null) \
    || fail "Core verifytxoutproof(own proof) failed (oracle sanity)"
[[ "$(arr_is_single_txid "$CORE_VS" "$TXID")" == "EQ" ]] \
    || fail "Core verifytxoutproof(own proof) != [$TXID] (oracle sanity; got $CORE_VS)"
log "verify-self: ouroboros verifytxoutproof(own proof) == [$TXID] (verify-self=ok)"

# ── 9. CHECK (3) verify-cross — verifytxoutproof(core_hex) on impl == [txid]. ─
# Core's proof bytes (== ouroboros's, proven in step 7) MUST verify on ouroboros.
OU_VC=$(ou_rpc verifytxoutproof "[\"$CORE_PROOF\"]" | ou_result)
case "$OU_VC" in "<ERR>"*) fail "ouroboros verifytxoutproof(Core's proof) error: ${OU_VC#<ERR>}" ;; esac
[[ "$(arr_is_single_txid "$OU_VC" "$TXID")" == "EQ" ]] \
    || fail "verify-cross: ouroboros verifytxoutproof(Core proof) != [$TXID] (got $OU_VC)"
# And the symmetric direction (ouroboros's proof verifies on Core) for full cross-parity.
CORE_VC=$(ccli verifytxoutproof "$OU_PROOF" 2>/dev/null) \
    || fail "verify-cross: Core verifytxoutproof(ouroboros proof) failed"
[[ "$(arr_is_single_txid "$CORE_VC" "$TXID")" == "EQ" ]] \
    || fail "verify-cross: Core verifytxoutproof(ouroboros proof) != [$TXID] (got $CORE_VC)"
log "verify-cross: Core<->ouroboros proofs verify on the OTHER node == [$TXID] (verify-cross=ok)"

# ── 10. CHECK (4) errors — gettxoutproof bad inputs + verifytxoutproof garbage. ─
# 10a. gettxoutproof for a nonexistent txid -> error on BOTH (Core: -5
#      'Transaction not yet in block'). We do NOT require exact code parity
#      (ouroboros maps to its generic RPC failure code); the GATE is "errors".
BOGUS_TXID="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
ccli gettxoutproof "[\"$BOGUS_TXID\"]" "$NEWBH" >/dev/null 2>&1 \
    && fail "Core unexpectedly produced a proof for a nonexistent txid"
CORE_BOGUS_CODE=$(ccli gettxoutproof "[\"$BOGUS_TXID\"]" "$NEWBH" 2>&1 \
    | sed -n 's/^error code: \(-\?[0-9]*\).*/\1/p' | head -1)
[[ "$CORE_BOGUS_CODE" == "-5" ]] || fail "Core nonexistent-txid code != -5 (got '$CORE_BOGUS_CODE')"
OU_BOGUS=$(ou_rpc gettxoutproof "[[\"$BOGUS_TXID\"],\"$NEWBH\"]")
echo "$OU_BOGUS" | ou_is_err \
    || fail "ouroboros gettxoutproof(nonexistent txid) did NOT error (got $OU_BOGUS)"
log "gettxoutproof(nonexistent txid): error on BOTH (Core=-5, ouroboros code=$(echo "$OU_BOGUS" | ou_err_code))"

# 10b. gettxoutproof with an UNKNOWN blockhash -> error on BOTH (Core: -5
#      'Block not found').
BOGUS_BH="00000000000000000000000000000000000000000000000000000000deadbeef"
ccli gettxoutproof "[\"$TXID\"]" "$BOGUS_BH" >/dev/null 2>&1 \
    && fail "Core unexpectedly produced a proof for an unknown blockhash"
CORE_BBH_CODE=$(ccli gettxoutproof "[\"$TXID\"]" "$BOGUS_BH" 2>&1 \
    | sed -n 's/^error code: \(-\?[0-9]*\).*/\1/p' | head -1)
[[ "$CORE_BBH_CODE" == "-5" ]] || fail "Core unknown-blockhash code != -5 (got '$CORE_BBH_CODE')"
OU_BBH=$(ou_rpc gettxoutproof "[[\"$TXID\"],\"$BOGUS_BH\"]")
echo "$OU_BBH" | ou_is_err \
    || fail "ouroboros gettxoutproof(unknown blockhash) did NOT error (got $OU_BBH)"
log "gettxoutproof(unknown blockhash): error on BOTH (Core=-5, ouroboros code=$(echo "$OU_BBH" | ou_err_code))"

# 10c. verifytxoutproof of GARBAGE hex -> error OR [] on BOTH, MATCHED.
#      Core: 'deadbeef' is valid hex but too short to deserialize a CMerkleBlock
#      -> SpanReader throws -> RPC error. ouroboros: <84 bytes -> error.
GARBAGE="deadbeef"
CORE_GARBAGE_OUT=$(ccli verifytxoutproof "$GARBAGE" 2>&1)
CORE_GARBAGE_RC=$?
OU_GARBAGE=$(ou_rpc verifytxoutproof "[\"$GARBAGE\"]")
if [[ $CORE_GARBAGE_RC -ne 0 ]]; then
    # Core errored -> ouroboros must error too.
    echo "$OU_GARBAGE" | ou_is_err \
        || fail "Core errored on garbage hex but ouroboros did not (got $OU_GARBAGE)"
    log "verifytxoutproof(garbage hex): Core errors, ouroboros errors (matched)"
else
    # Core returned [] (some malformed inputs deserialize but fail extraction).
    [[ "$CORE_GARBAGE_OUT" == "[]" || "$CORE_GARBAGE_OUT" == "["*"]" ]] \
        || fail "Core verifytxoutproof(garbage) unexpected output: $CORE_GARBAGE_OUT"
    OU_G_RES=$(echo "$OU_GARBAGE" | ou_result)
    if echo "$OU_GARBAGE" | ou_is_err; then
        # ouroboros erroring where Core returns [] is ACCEPTABLE per the contract
        # ("error OR []"), since an unverifiable proof yields no committed txids.
        log "verifytxoutproof(garbage hex): Core=[] ouroboros=error (both reject; acceptable)"
    else
        [[ "$OU_G_RES" == "[]" ]] \
            || fail "verifytxoutproof(garbage): Core=[] but ouroboros returned $OU_G_RES"
        log "verifytxoutproof(garbage hex): Core=[] ouroboros=[] (matched)"
    fi
fi

# 10d. verifytxoutproof of a STRUCTURALLY-VALID-but-foreign proof: take our real
#      proof and corrupt the header so the committed block is NOT in the chain.
#      Core -> -5 'Block not found in chain'; ouroboros -> error. Both reject.
FOREIGN_PROOF=$(python3 -c "
h=bytearray(bytes.fromhex('$OU_PROOF'))
# Flip a byte inside the header's prevhash (offset 4..36) -> a block hash that
# is not on either node's chain, but keep the rest structurally parseable.
h[10] ^= 0xff
print(bytes(h).hex())
")
ccli verifytxoutproof "$FOREIGN_PROOF" >/dev/null 2>&1 \
    && fail "Core unexpectedly accepted a proof for an off-chain block"
CORE_FOREIGN_CODE=$(ccli verifytxoutproof "$FOREIGN_PROOF" 2>&1 \
    | sed -n 's/^error code: \(-\?[0-9]*\).*/\1/p' | head -1)
OU_FOREIGN=$(ou_rpc verifytxoutproof "[\"$FOREIGN_PROOF\"]")
# Core errors (-5) here; ouroboros must NOT return a non-empty txid list.
if echo "$OU_FOREIGN" | ou_is_err; then
    log "verifytxoutproof(off-chain block): Core=$CORE_FOREIGN_CODE ouroboros=error (both reject)"
else
    OU_F_RES=$(echo "$OU_FOREIGN" | ou_result)
    [[ "$OU_F_RES" == "[]" ]] \
        || fail "verifytxoutproof(off-chain block): ouroboros returned committed txids for an off-chain block: $OU_F_RES"
    log "verifytxoutproof(off-chain block): Core=$CORE_FOREIGN_CODE ouroboros=[] (both reject)"
fi
log "errors: gettxoutproof bad txid/blockhash + verifytxoutproof garbage/off-chain all reject (errors=ok)"

# ── 11. Verdict. ──────────────────────────────────────────────────────────
log "PASS: proof byte-identical vs Core; self+cross verify == [txid]; bad inputs reject on both"
pass

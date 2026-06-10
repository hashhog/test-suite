#!/usr/bin/env bash
#
# ouroboros_getrawtransaction.sh — self-contained getrawtransaction DIFFERENTIAL test.
#
# The next RPC-surface green-cell after getindexinfo (the flagged follow-up:
# "txindex on but getrawtransaction fails"). getrawtransaction is the
# block-explorer keystone — given a txid it returns either the byte-exact raw
# hex (verbosity 0) or a decoded JSON object (verbosity 1). The SHAPE and the
# load-bearing fields must match Bitcoin Core EXACTLY for the same transaction.
#
# WHAT IT PROVES (Core ref: bitcoin-core/src/rpc/rawtransaction.cpp
#                  getrawtransaction + core_io.cpp TxToUniv):
#   Drive ouroboros and a REAL bitcoind oracle onto an IDENTICAL regtest chain
#   (Core mines, ouroboros replays Core's blocks via submitblock -> identical
#   UTXO sets), then put the SAME signed transaction into BOTH mempools and
#   compare getrawtransaction outputs:
#     1. MEMPOOL:
#        * getrawtransaction <txid> 0  -> raw hex BYTE-EXACT vs Core
#        * getrawtransaction <txid> 1  -> decoded object; assert txid, hash
#          (wtxid), version, size, vsize, weight, locktime, the vin
#          {txid,vout,sequence}+scriptSig.hex+txinwitness, the vout
#          {value,n,scriptPubKey.hex,.type,.address}, and top-level hex ALL
#          EXACT vs Core. asm/desc PRESENT but NOT required byte-equal
#          (InferDescriptor + asm whitespace can legitimately differ).
#     2. CONFIRMED via blockhash arg (no txindex needed): mine the tx, then
#        getrawtransaction <txid> 1 <blockhash> -> assert blockhash matches,
#        confirmations is a correct int (>=1), in_active_chain==true,
#        time/blocktime present.
#     3. ERRORS (Core RPC code -5, RPC_INVALID_ADDRESS_OR_KEY):
#        * a random 32-byte txid                       -> -5 on BOTH
#        * the genesis-block coinbase txid (==merkleroot) -> -5 on BOTH
#     4. (Only if ouroboros has txindex:) getrawtransaction <txid> 1 with NO
#        blockhash on a CONFIRMED tx -> succeeds. ouroboros builds a txindex by
#        default, so this is exercised; skipped+noted otherwise.
#
# CORE ORACLE: a real bitcoind regtest node on its own scratch + ports owns the
#   ground truth. Launched with -listen=0 (sandbox SIGKILLs a 0.0.0.0 P2P
#   listener; RPC-only is fine) and -txindex=1.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/ouroboros_chaintxstats.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + UNIQUE
#   ports, ONE clean summary line on stdout, noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETRAWTRANSACTION ouroboros: PASS hex=ok decoded=ok confirmed=ok errors=ok
#   FAIL: GETRAWTRANSACTION ouroboros: FAIL <short reason>
#
# Touches ONLY /tmp/grt-ouroboros-impl + /tmp/grt-ouroboros-core and ports
#   22012/22032 (ouroboros RPC/P2P) + 22022/22042 (Core RPC/P2P). The datadir
#   names + the reset/cleanup scoping are keyed to "grt-ouroboros" so this test
#   runs SAFELY in parallel with the sibling per-impl getrawtransaction tests
#   (which share the generic /tmp/grt-core scratch).
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

# Datadir names are keyed to this impl ("grt-ouroboros-*") so we never collide
# with — or rm -rf — a sibling per-impl test's scratch (e.g. the generic
# /tmp/grt-core shared by other rawtx tests).
OU_DATADIR="/tmp/grt-ouroboros-impl"
OU_RPC=22012
OU_P2P=22032
OU_LOG="$OU_DATADIR/node.log"

CORE_DATADIR="/tmp/grt-ouroboros-core"
CORE_RPC=22022
CORE_P2P=22042
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test keypair (privkey 0x11..11). We mine coinbase rewards to
# this address so we control a spendable matured output, then spend it.
PRIV_HEX="1111111111111111111111111111111111111111111111111111111111111111"
WIF="cN9spWsvaxA8taS7DFMxnk1yJD2gaF2PX1npuTpy3vuZFJdwavaw"
ADDR="bcrt1ql3e9pgs3mmwuwrh95fecme0s0qtn2880hlwwpw"
SPK="0014fc7250a211deddc70ee5a2738de5f07817351cef"

NBLOCKS=101            # 101 blocks: block-1 coinbase matures at height 101

OU_PID=""
OU_COOKIE=""
CORE_BG=""

log() { echo "[getrawtransaction:ouroboros] $*" >&2; }

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
    pkill -9 -f "grt-ouroboros-impl" >/dev/null 2>&1 || true
    pkill -9 -f "grt-ouroboros-core" >/dev/null 2>&1 || true
    rm -rf "$OU_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "GETRAWTRANSACTION ouroboros: PASS hex=ok decoded=ok confirmed=ok errors=ok"
    exit 0
}
fail() {
    echo "GETRAWTRANSACTION ouroboros: FAIL $*"
    exit 1
}

# Core CLI shorthand.
ccli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# ouroboros JSON-RPC over curl: ou <method> <json-params-array> -> raw envelope.
ou_rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 40 -u "$OU_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$OU_RPC/" 2>/dev/null
}

# Unwrap a JSON-RPC envelope to its .result (prints "<ERR>...code...msg..." on error).
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

# Field extractor: jget '<json>' '<dotted.path>' -> value (type-tagged), or
# <MISSING>/<NULL>/<PARSEERR>. Supports a.b and a[i].b paths.
jget() {
    python3 - "$1" "$2" <<'PYEOF'
import json, sys, re
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("<PARSEERR>"); sys.exit(0)
path = sys.argv[2]
cur = d
for tok in re.findall(r'[^.\[\]]+|\[\d+\]', path):
    if tok.startswith('['):
        idx = int(tok[1:-1])
        if not isinstance(cur, list) or idx >= len(cur):
            print("<MISSING>"); sys.exit(0)
        cur = cur[idx]
    else:
        if not isinstance(cur, dict) or tok not in cur:
            print("<MISSING>"); sys.exit(0)
        cur = cur[tok]
if cur is None: print("<NULL>")
elif isinstance(cur, bool): print("bool:" + ("true" if cur else "false"))
elif isinstance(cur, int): print("int:" + str(cur))
elif isinstance(cur, float): print("float:" + repr(cur))
else: print("str:" + str(cur))
PYEOF
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
# Kill only OUR leftover nodes (datadir-keyed) so we run safely alongside the
# sibling per-impl getrawtransaction tests.
log "resetting scratch state"
pkill -f "grt-ouroboros-impl" 2>/dev/null || true
pkill -f "grt-ouroboros-core" 2>/dev/null || true
for _ in $(seq 1 10); do
    pgrep -f "grt-ouroboros-impl" >/dev/null 2>&1 || pgrep -f "grt-ouroboros-core" >/dev/null 2>&1 || break
    sleep 1
done
pkill -9 -f "grt-ouroboros-impl" 2>/dev/null || true
pkill -9 -f "grt-ouroboros-core" 2>/dev/null || true
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
[[ -f "$OURO_DIR/src/ouroboros/cli.py" ]] || fail "ouroboros checkout not found at $OURO_DIR"
[[ -x "$CORE_BIN" ]]                      || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                      || fail "bitcoin-cli not found at $CORE_CLI"

OURO_PY="$OURO_DIR/.venv/bin/python3"
[[ -x "$OURO_PY" ]] || OURO_PY="python3"

# ── 2. Launch the Core regtest oracle (-listen=0, -txindex=1). ────────────
log "launching Core regtest oracle rpc=:$CORE_RPC (listen=0, txindex=1)"
# -listen=0 -> no inbound P2P listener (the sandbox SIGKILLs a 0.0.0.0 P2P
# bind ~2s after load; RPC-only is fine). -rpcbind/-discover/-dnsseed keep it
# strictly loopback + quiet.
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

# ── 3. Mine NBLOCKS blocks on Core to our controlled address. ─────────────
log "mining $NBLOCKS blocks on Core to $ADDR"
ccli generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null 2>&1 \
    || fail "Core generatetoaddress failed (see $CORE_LOG)"
CORE_TIP=$(ccli getblockcount 2>/dev/null)
[[ "$CORE_TIP" == "$NBLOCKS" ]] || fail "Core tip=$CORE_TIP != $NBLOCKS after mining"

# ── 4. Launch ouroboros on regtest (Python — generous >=180s wait). ───────
# --nolisten: do NOT bind a 0.0.0.0 P2P listener (the sandbox SIGKILLs those
# ~2s after load). The test drives ouroboros purely over RPC (submitblock +
# sendrawtransaction), so inbound P2P is unnecessary.
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
# Both nodes end with IDENTICAL block bodies -> identical UTXO sets, so a tx
# signed against Core's chain is also valid on ouroboros's chain.
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
# Cross-check tip hashes are byte-identical (proves the chains truly match).
CORE_TIPHASH=$(ccli getblockhash "$NBLOCKS" 2>/dev/null)
OU_TIPHASH=$(ou_rpc getblockhash "[$NBLOCKS]" | ou_result)
[[ "$OU_TIPHASH" == "$CORE_TIPHASH" ]] \
    || fail "tip hash mismatch after replication: core=$CORE_TIPHASH ouroboros=$OU_TIPHASH"
log "chains identical (tip $NBLOCKS hash=$CORE_TIPHASH)"

# ── 6. Build + sign a real tx spending block-1's matured coinbase. ────────
CB1=$(ccli getblock "$(ccli getblockhash 1)" 1 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['tx'][0])")
[[ "$CB1" =~ ^[0-9a-f]{64}$ ]] || fail "could not resolve block-1 coinbase txid"
log "block-1 coinbase txid: $CB1"
RAW_UNSIGNED=$(ccli createrawtransaction \
    "[{\"txid\":\"$CB1\",\"vout\":0}]" "[{\"$ADDR\":49.9999}]" 2>/dev/null) \
    || fail "createrawtransaction failed"
SIGNED_JSON=$(ccli signrawtransactionwithkey "$RAW_UNSIGNED" "[\"$WIF\"]" \
    "[{\"txid\":\"$CB1\",\"vout\":0,\"scriptPubKey\":\"$SPK\",\"amount\":50.0}]" 2>/dev/null) \
    || fail "signrawtransactionwithkey failed"
COMPLETE=$(echo "$SIGNED_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('complete'))")
[[ "$COMPLETE" == "True" ]] || { log "sign reply: $SIGNED_JSON"; fail "tx signing not complete"; }
TX_HEX=$(echo "$SIGNED_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['hex'])")
[[ -n "$TX_HEX" ]] || fail "signed tx hex empty"

# ── 7. Broadcast the SAME tx into BOTH mempools. ──────────────────────────
TXID=$(ccli sendrawtransaction "$TX_HEX" 2>/dev/null) || { tail -n 5 "$CORE_LOG" >&2; fail "Core sendrawtransaction failed"; }
[[ "$TXID" =~ ^[0-9a-f]{64}$ ]] || fail "Core sendrawtransaction returned no txid"
log "tx in Core mempool: $TXID"
ou_send=$(ou_rpc sendrawtransaction "[\"$TX_HEX\"]" | ou_result)
case "$ou_send" in
    "<ERR>"*) fail "ouroboros sendrawtransaction error: ${ou_send#<ERR>}" ;;
esac
[[ "$ou_send" == "$TXID" ]] || fail "ouroboros sendrawtransaction txid mismatch: $ou_send != $TXID"
log "tx in ouroboros mempool: $ou_send"

# ── 8. MEMPOOL verbosity 0: raw hex BYTE-EXACT. ───────────────────────────
CORE_HEX=$(ccli getrawtransaction "$TXID" 0 2>/dev/null)
OU_HEX=$(ou_rpc getrawtransaction "[\"$TXID\",0]" | ou_result)
[[ "$OU_HEX" == "$CORE_HEX" ]] || fail "v0 hex mismatch: core=$CORE_HEX ouro=$OU_HEX"
[[ "$OU_HEX" == "$TX_HEX" ]]   || fail "v0 hex != the broadcast tx hex"
log "v0 mempool hex: BYTE-EXACT vs Core"

# Also accept verbosity passed as the BOOL false (== 0).
OU_HEX_BOOL=$(ou_rpc getrawtransaction "[\"$TXID\",false]" | ou_result)
[[ "$OU_HEX_BOOL" == "$CORE_HEX" ]] || fail "v=false hex mismatch: core=$CORE_HEX ouro=$OU_HEX_BOOL"
log "v=false (bool) treated as verbosity 0: ok"

# ── 9. MEMPOOL verbosity 1: decoded object, load-bearing fields EXACT. ────
CORE_V1=$(ccli getrawtransaction "$TXID" 1 2>/dev/null)
OU_V1=$(ou_rpc getrawtransaction "[\"$TXID\",1]" | ou_result)
case "$OU_V1" in "<ERR>"*) fail "ouroboros getrawtransaction v1 error: ${OU_V1#<ERR>}" ;; esac

# Top-level scalar fields that MUST be byte/value identical.
for F in txid hash version size vsize weight locktime hex; do
    cv=$(jget "$CORE_V1" "$F")
    ov=$(jget "$OU_V1"   "$F")
    [[ "$cv" == "$ov" ]] || fail "v1 field '$F' mismatch: core=$cv ouro=$ov"
done
# txid must equal the queried txid (display order).
[[ "$(jget "$OU_V1" txid)" == "str:$TXID" ]] || fail "v1 txid != queried txid"
# Mempool tx -> NO block context fields, and (no blockhash arg) NO in_active_chain.
[[ "$(jget "$OU_V1" blockhash)"       == "<MISSING>" ]] || fail "v1 mempool tx must not carry blockhash"
[[ "$(jget "$OU_V1" confirmations)"   == "<MISSING>" ]] || fail "v1 mempool tx must not carry confirmations"
[[ "$(jget "$OU_V1" in_active_chain)" == "<MISSING>" ]] || fail "v1 (no blockhash arg) must not carry in_active_chain"
log "v1 top-level fields (txid/hash/version/size/vsize/weight/locktime/hex): EXACT"

# vin[0]: txid, vout, sequence, scriptSig.hex, txinwitness EXACT.
for F in "vin[0].txid" "vin[0].vout" "vin[0].sequence" "vin[0].scriptSig.hex" \
         "vin[0].txinwitness[0]" "vin[0].txinwitness[1]"; do
    cv=$(jget "$CORE_V1" "$F")
    ov=$(jget "$OU_V1"   "$F")
    [[ "$cv" == "$ov" ]] || fail "v1 input field '$F' mismatch: core=$cv ouro=$ov"
done
# scriptSig.asm must be PRESENT (not required byte-equal).
[[ "$(jget "$OU_V1" "vin[0].scriptSig.asm")" != "<MISSING>" ]] || fail "v1 scriptSig.asm missing"
log "v1 vin[0] (txid/vout/sequence/scriptSig.hex/txinwitness): EXACT; asm present"

# vout[0]: value, n, scriptPubKey.hex, .type, .address EXACT.
for F in "vout[0].value" "vout[0].n" "vout[0].scriptPubKey.hex" \
         "vout[0].scriptPubKey.type" "vout[0].scriptPubKey.address"; do
    cv=$(jget "$CORE_V1" "$F")
    ov=$(jget "$OU_V1"   "$F")
    [[ "$cv" == "$ov" ]] || fail "v1 output field '$F' mismatch: core=$cv ouro=$ov"
done
# scriptPubKey.asm + .desc PRESENT (not required byte-equal).
[[ "$(jget "$OU_V1" "vout[0].scriptPubKey.asm")"  != "<MISSING>" ]] || fail "v1 scriptPubKey.asm missing"
[[ "$(jget "$OU_V1" "vout[0].scriptPubKey.desc")" != "<MISSING>" ]] || fail "v1 scriptPubKey.desc missing"
log "v1 vout[0] (value/n/scriptPubKey.hex/.type/.address): EXACT; asm+desc present"

# ── 10. CONFIRMED via blockhash arg: mine the tx into a block. ────────────
NEWBH=$(ccli generatetoaddress 1 "$ADDR" 2>/dev/null \
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
# Both chains must agree on the confirming block hash.
[[ "$(ou_rpc getblockhash "[$NEWH]" | ou_result)" == "$NEWBH" ]] \
    || fail "confirming block hash differs between nodes"
log "tx confirmed in block $NEWH ($NEWBH) on BOTH nodes"

CORE_CONF=$(ccli getrawtransaction "$TXID" 1 "$NEWBH" 2>/dev/null)
OU_CONF=$(ou_rpc getrawtransaction "[\"$TXID\",1,\"$NEWBH\"]" | ou_result)
case "$OU_CONF" in "<ERR>"*) fail "ouroboros confirmed getrawtransaction error: ${OU_CONF#<ERR>}" ;; esac

# blockhash must equal the supplied hash on both.
[[ "$(jget "$OU_CONF" blockhash)"   == "str:$NEWBH" ]] || fail "confirmed: ouroboros blockhash != $NEWBH (got $(jget "$OU_CONF" blockhash))"
[[ "$(jget "$CORE_CONF" blockhash)" == "str:$NEWBH" ]] || fail "confirmed: Core blockhash != $NEWBH"
# confirmations: integer >= 1, and == Core (deterministic on identical chains).
ocf=$(jget "$OU_CONF" confirmations)
ccf=$(jget "$CORE_CONF" confirmations)
[[ "$ocf" == int:* ]]      || fail "confirmed: confirmations not int (got $ocf)"
[[ "${ocf#int:}" -ge 1 ]]  || fail "confirmed: confirmations < 1 (got $ocf)"
[[ "$ocf" == "$ccf" ]]     || fail "confirmed: confirmations mismatch core=$ccf ouro=$ocf"
# in_active_chain MUST be true (blockhash arg present + block on active chain).
[[ "$(jget "$OU_CONF" in_active_chain)" == "bool:true" ]] || fail "confirmed: in_active_chain != true (got $(jget "$OU_CONF" in_active_chain))"
# time + blocktime present, integer, equal to each other and to Core's.
ot=$(jget "$OU_CONF" time); obt=$(jget "$OU_CONF" blocktime)
ct=$(jget "$CORE_CONF" time)
[[ "$ot" == int:* ]]   || fail "confirmed: time not int (got $ot)"
[[ "$obt" == int:* ]]  || fail "confirmed: blocktime not int (got $obt)"
[[ "$ot" == "$obt" ]]  || fail "confirmed: time != blocktime (got $ot vs $obt)"
[[ "$ot" == "$ct" ]]   || fail "confirmed: time mismatch core=$ct ouro=$ot"
# v0 over the confirmed tx (witness-serialized) still byte-exact.
OU_CONF_HEX=$(ou_rpc getrawtransaction "[\"$TXID\",0,\"$NEWBH\"]" | ou_result)
[[ "$OU_CONF_HEX" == "$TX_HEX" ]] || fail "confirmed v0 hex != broadcast tx hex"
log "confirmed via blockhash: blockhash/confirmations/in_active_chain/time/blocktime: ok"

# ── 11. txindex path: confirmed tx, NO blockhash arg, succeeds. ───────────
# ouroboros builds a txindex by default (getindexinfo cell), so exercise it.
IDX=$(ou_rpc getrawtransaction "[\"$TXID\",1]" | ou_result)
case "$IDX" in
    "<ERR>"*)
        log "note: ouroboros getrawtransaction (no blockhash, confirmed) errored: ${IDX#<ERR>} — txindex sub-check SKIPPED"
        ;;
    *)
        [[ "$(jget "$IDX" txid)"      == "str:$TXID" ]]  || fail "txindex path: txid wrong"
        [[ "$(jget "$IDX" blockhash)" == "str:$NEWBH" ]] || fail "txindex path: blockhash wrong"
        # No blockhash ARG -> no in_active_chain field (Core semantics).
        [[ "$(jget "$IDX" in_active_chain)" == "<MISSING>" ]] || fail "txindex path: in_active_chain must be absent w/o blockhash arg"
        log "txindex path (confirmed, no blockhash arg): ok"
        ;;
esac

# ── 12. ERRORS: both must return RPC code -5. ─────────────────────────────
RAND_TXID="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
# Core: -5 for unknown tx (txindex enabled but not present).
ccli getrawtransaction "$RAND_TXID" 0 >/dev/null 2>&1 \
    && fail "Core unexpectedly returned a tx for a random txid"
core_rand_code=$(ccli getrawtransaction "$RAND_TXID" 0 2>&1 \
    | sed -n 's/^error code: \(-\?[0-9]*\).*/\1/p' | head -1)
[[ "$core_rand_code" == "-5" ]] || fail "Core random-txid code != -5 (got '$core_rand_code')"
ou_rand=$(ou_rpc getrawtransaction "[\"$RAND_TXID\",0]")
ou_rand_code=$(echo "$ou_rand" | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('error') or {}).get('code'))")
[[ "$ou_rand_code" == "-5" ]] || fail "ouroboros random-txid code != -5 (got '$ou_rand_code'; raw=$ou_rand)"
log "random txid -> -5 on BOTH (RPC_INVALID_ADDRESS_OR_KEY)"

# genesis-block coinbase txid (== genesis merkle root) -> -5 special case.
GEN_HASH=$(ccli getblockhash 0 2>/dev/null)
GEN_CB=$(ccli getblock "$GEN_HASH" 1 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['tx'][0])")
[[ "$GEN_CB" =~ ^[0-9a-f]{64}$ ]] || fail "could not resolve genesis coinbase txid"
core_gen_code=$(ccli getrawtransaction "$GEN_CB" 0 2>&1 \
    | sed -n 's/^error code: \(-\?[0-9]*\).*/\1/p' | head -1)
[[ "$core_gen_code" == "-5" ]] || fail "Core genesis-coinbase code != -5 (got '$core_gen_code')"
ou_gen=$(ou_rpc getrawtransaction "[\"$GEN_CB\",0]")
ou_gen_code=$(echo "$ou_gen" | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('error') or {}).get('code'))")
ou_gen_msg=$(echo "$ou_gen" | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('error') or {}).get('message',''))")
[[ "$ou_gen_code" == "-5" ]] || fail "ouroboros genesis-coinbase code != -5 (got '$ou_gen_code'; raw=$ou_gen)"
echo "$ou_gen_msg" | grep -qi "genesis block coinbase" \
    || fail "ouroboros genesis-coinbase message not Core-shaped (got '$ou_gen_msg')"
log "genesis-coinbase txid -> -5 on BOTH; message Core-shaped"

# ── 13. Verdict. ──────────────────────────────────────────────────────────
log "PASS: v0 hex byte-exact; v1 load-bearing fields == Core; confirmed-via-blockhash ok; -5 errors ok"
pass

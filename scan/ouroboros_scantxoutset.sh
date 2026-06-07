#!/usr/bin/env bash
#
# ouroboros_scantxoutset.sh — self-contained scantxoutset DIFFERENTIAL test.
#
# scantxoutset is the UTXO-set scanner: given an output descriptor (the simplest
# being addr(<address>)) it walks the CURRENT unspent-transaction-output set and
# returns every coin whose scriptPubKey matches, plus the running totals. It is
# the wallet-less "what does this address hold?" primitive — the SHAPE and the
# load-bearing numeric fields (total_amount, and the matched unspent's
# txid/vout/amount) must match Bitcoin Core EXACTLY for an identical chain.
#
# WHAT IT PROVES (Core ref: bitcoin-core/src/rpc/blockchain.cpp scantxoutset,
#                  action='start' [scanobjects]):
#   Drive ouroboros and a REAL bitcoind oracle onto an IDENTICAL regtest chain
#   (Core mines, ouroboros replays Core's blocks via submitblock -> identical
#   UTXO sets), fund a known address with a deterministic amount, confirm it,
#   then compare scantxoutset on BOTH nodes:
#     1. DESC MATCH: scantxoutset start [{"desc":"addr(<addr2>)"}] returns
#        success==true and EXACTLY ONE matched unspent on both nodes, whose
#        txid/vout/amount are byte/value identical to Core.
#     2. AMOUNT: top-level total_amount equals Core's (numeric equality).
#     3. SHAPE: result OBJECT carries success + txouts + height + bestblock +
#        unspents + total_amount; each matched unspent carries Core's keys
#        (txid,vout,scriptPubKey,desc,amount,coinbase,height,blockhash,
#        confirmations). 'desc' is PRESENT but not required byte-equal (Core's
#        InferDescriptor adds a #checksum; an impl may echo the input form).
#     4. EMPTY: scanning an address with NO matching UTXO returns success==true,
#        total_amount==0 and an EMPTY unspents array on BOTH nodes.
#   The bare-string scanobject form ["addr(<addr2>)"] is also exercised and must
#   agree with the {"desc":...} object form (Core accepts both).
#
# CORE ORACLE: a real bitcoind regtest node on its own scratch + ports owns the
#   ground truth. Launched with -listen=0 (sandbox SIGKILLs a 0.0.0.0 P2P
#   listener; RPC-only is fine).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/rawtx/ouroboros_getrawtransaction.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + UNIQUE
#   ports, ONE clean summary line on stdout, noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: SCANTXOUTSET ouroboros: PASS desc=ok amount=ok shape=ok empty=ok
#   FAIL: SCANTXOUTSET ouroboros: FAIL <short reason>
#   SKIP (runner GAP_RE): a "not found"/"not built" reason if the impl is absent.
#
# Touches ONLY /tmp/scan-ouroboros-impl + /tmp/scan-ouroboros-core and ports
#   40212/40232 (ouroboros RPC/P2P) + 40222/40242 (Core RPC/P2P). Datadir names +
#   cleanup scoping are keyed to "scan-ouroboros" so this runs SAFELY in parallel
#   with any sibling per-impl scantxoutset test.
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#
# Any fuser -k redirects stdout (it prints killed PIDs to STDOUT).

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OURO_DIR="$REPO_ROOT/ouroboros"

# Datadir names are keyed to this impl ("scan-ouroboros-*") so we never collide
# with — or rm -rf — a sibling per-impl test's scratch.
OU_DATADIR="/tmp/scan-ouroboros-impl"
OU_RPC=40212
OU_P2P=40232
OU_LOG="$OU_DATADIR/node.log"

CORE_DATADIR="/tmp/scan-ouroboros-core"
CORE_RPC=40222
CORE_P2P=40242
CORE_LOG="$CORE_DATADIR/core.log"

# Funding source: deterministic keypair #1 (privkey 0x11..11). We mine coinbase
# rewards here so we control a spendable matured output to fund the scan target.
WIF1="cN9spWsvaxA8taS7DFMxnk1yJD2gaF2PX1npuTpy3vuZFJdwavaw"
ADDR1="bcrt1ql3e9pgs3mmwuwrh95fecme0s0qtn2880hlwwpw"
SPK1="0014fc7250a211deddc70ee5a2738de5f07817351cef"

# Scan TARGET: deterministic keypair #2 (privkey 0x22..22). Freshly funded with
# one known-amount output so the scan matches EXACTLY ONE deterministic unspent.
ADDR2="bcrt1q2vfxp232rx0z9rzn0hay9jptagk8c86ddphpjv"
SPK2="0014531260aa2a199e228c537dfa42c82bea2c7c1f4d"
FUND_AMT="49.99990000"   # value sent to ADDR2 (block-1 coinbase 50 BTC minus fee)

# An address that holds NOTHING on this chain (the empty-scan control). Valid
# regtest P2WPKH for the deterministic key 0x33..33; we never pay to it.
ADDR_EMPTY="bcrt1q80pg6mvjmyrnld0r4h6gz7274azxhnhdf7k5gu"

NBLOCKS=101            # 101 blocks: block-1 coinbase matures at height 101

OU_PID=""
OU_COOKIE=""
CORE_BG=""

log() { echo "[scantxoutset:ouroboros] $*" >&2; }

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
    pkill -9 -f "scan-ouroboros-impl" >/dev/null 2>&1 || true
    pkill -9 -f "scan-ouroboros-core" >/dev/null 2>&1 || true
    fuser -k "${OU_RPC}/tcp"         >/dev/null 2>&1 || true
    fuser -k "${OU_P2P}/tcp"         >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp"       >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp"       >/dev/null 2>&1 || true
    fuser -k "$((CORE_P2P + 1))/tcp" >/dev/null 2>&1 || true
    rm -rf "$OU_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "SCANTXOUTSET ouroboros: PASS desc=ok amount=ok shape=ok empty=ok"
    exit 0
}
fail() {
    echo "SCANTXOUTSET ouroboros: FAIL $*"
    exit 1
}

# Core CLI shorthand.
ccli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# ouroboros JSON-RPC over curl: ou <method> <json-params-array> -> raw envelope.
ou_rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 120 -u "$OU_COOKIE" \
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

# Numeric equality of two amount-like values (Core emits decimal strings, an
# impl may emit a float). Compares as satoshi integers (round to 8 dp).
amt_eq() {
    python3 - "$1" "$2" <<'PYEOF'
import sys
from decimal import Decimal, InvalidOperation
def sats(x):
    try:
        return int((Decimal(str(x)) * 100_000_000).to_integral_value())
    except (InvalidOperation, ValueError):
        return None
a, b = sats(sys.argv[1]), sats(sys.argv[2])
print("EQ" if (a is not None and a == b) else "NE")
PYEOF
}

# Count entries in a JSON array at <json> .<path>; prints int or <ERR>.
jlen() {
    python3 - "$1" "$2" <<'PYEOF'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("<ERR>"); sys.exit(0)
cur = d
for tok in sys.argv[2].split("."):
    if not tok: continue
    if not isinstance(cur, dict) or tok not in cur:
        print("<ERR>"); sys.exit(0)
    cur = cur[tok]
print(len(cur) if isinstance(cur, list) else "<ERR>")
PYEOF
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "scan-ouroboros-impl" 2>/dev/null || true
pkill -f "scan-ouroboros-core" 2>/dev/null || true
for _ in $(seq 1 10); do
    pgrep -f "scan-ouroboros-impl" >/dev/null 2>&1 || pgrep -f "scan-ouroboros-core" >/dev/null 2>&1 || break
    sleep 1
done
pkill -9 -f "scan-ouroboros-impl" 2>/dev/null || true
pkill -9 -f "scan-ouroboros-core" 2>/dev/null || true
fuser -k "${OU_RPC}/tcp"         >/dev/null 2>&1 || true
fuser -k "${OU_P2P}/tcp"         >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp"       >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp"       >/dev/null 2>&1 || true
fuser -k "$((CORE_P2P + 1))/tcp" >/dev/null 2>&1 || true
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

# ── 2. Launch the Core regtest oracle (-listen=0). ────────────────────────
log "launching Core regtest oracle rpc=:$CORE_RPC (listen=0)"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    -rpcbind=127.0.0.1 -listen=0 -discover=0 -dnsseed=0 \
    -fallbackfee=0.0002 -daemonwait=0 >"$CORE_LOG" 2>&1 &
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

# ── 6. Fund the scan TARGET (ADDR2) with one known-amount output. ─────────
# Spend block-1's matured coinbase (paid to ADDR1) -> FUND_AMT to ADDR2. This
# creates EXACTLY ONE UTXO at ADDR2 -> a deterministic single scan match.
CB1=$(ccli getblock "$(ccli getblockhash 1)" 1 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['tx'][0])")
[[ "$CB1" =~ ^[0-9a-f]{64}$ ]] || fail "could not resolve block-1 coinbase txid"
log "funding ADDR2 from block-1 coinbase $CB1"
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
# BOTH chainstates carry the new ADDR2 UTXO (scantxoutset reads the UTXO set).
FUND_TXID=$(ccli sendrawtransaction "$TX_HEX" 2>/dev/null) || { tail -n 5 "$CORE_LOG" >&2; fail "Core sendrawtransaction failed"; }
[[ "$FUND_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "Core sendrawtransaction returned no txid"
log "funding tx in Core mempool: $FUND_TXID"
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
log "ADDR2 funded + confirmed at height $NEWH on BOTH nodes (txid=$FUND_TXID vout=0 amt=$FUND_AMT)"

# ── 7. SCAN (desc/object form) on BOTH nodes; compare. ─────────────────────
# Core takes scantxoutset start '[{"desc":"addr(<addr>)"}]' and returns ONLY
# after the scan completes (synchronous).
SCANOBJ="[{\"desc\":\"addr($ADDR2)\"}]"
log "scantxoutset start (object form) addr($ADDR2)"
CORE_SCAN=$(ccli scantxoutset start "[{\"desc\":\"addr($ADDR2)\"}]" 2>/dev/null) \
    || { tail -n 10 "$CORE_LOG" >&2; fail "Core scantxoutset start failed"; }
OU_SCAN=$(ou_rpc scantxoutset "[\"start\",$SCANOBJ]" | ou_result)
case "$OU_SCAN" in "<ERR>"*) fail "ouroboros scantxoutset start error: ${OU_SCAN#<ERR>}" ;; esac
[[ -n "$OU_SCAN" && "$OU_SCAN" != "null" ]] || fail "ouroboros scantxoutset start returned null/empty"

# 7a. success==true on both.
[[ "$(jget "$CORE_SCAN" success)" == "bool:true" ]] || fail "Core scan success != true"
[[ "$(jget "$OU_SCAN" success)"   == "bool:true" ]] || fail "ouroboros scan success != true (got $(jget "$OU_SCAN" success))"

# 7b. EXACTLY ONE matched unspent on both.
CORE_N=$(jlen "$CORE_SCAN" "unspents")
OU_N=$(jlen "$OU_SCAN" "unspents")
[[ "$CORE_N" == "1" ]] || fail "Core matched $CORE_N unspents, expected 1"
[[ "$OU_N"   == "1" ]] || fail "ouroboros matched $OU_N unspents, expected 1 (chain divergence or scan miss)"
log "both nodes matched exactly 1 unspent"

# 7c. matched unspent txid/vout/amount EXACT vs Core.
for F in "unspents[0].txid" "unspents[0].vout"; do
    cv=$(jget "$CORE_SCAN" "$F"); ov=$(jget "$OU_SCAN" "$F")
    [[ "$cv" == "$ov" ]] || fail "matched unspent '$F' mismatch: core=$cv ouro=$ov"
done
# The matched coin MUST be our funding tx, vout 0.
[[ "$(jget "$OU_SCAN" "unspents[0].txid")" == "str:$FUND_TXID" ]] \
    || fail "matched txid != funding txid (got $(jget "$OU_SCAN" "unspents[0].txid"))"
[[ "$(jget "$OU_SCAN" "unspents[0].vout")" == "int:0" ]] \
    || fail "matched vout != 0 (got $(jget "$OU_SCAN" "unspents[0].vout"))"
# amount: numeric equality vs Core, and == FUND_AMT.
CORE_UAMT=$(jget "$CORE_SCAN" "unspents[0].amount"); CORE_UAMT="${CORE_UAMT#*:}"
OU_UAMT=$(jget "$OU_SCAN" "unspents[0].amount");     OU_UAMT="${OU_UAMT#*:}"
[[ "$(amt_eq "$CORE_UAMT" "$OU_UAMT")" == "EQ" ]] \
    || fail "matched unspent amount mismatch: core=$CORE_UAMT ouro=$OU_UAMT"
[[ "$(amt_eq "$OU_UAMT" "$FUND_AMT")" == "EQ" ]] \
    || fail "matched unspent amount != funded $FUND_AMT (got $OU_UAMT)"
# scriptPubKey of the matched coin == ADDR2's SPK on both.
[[ "$(jget "$OU_SCAN" "unspents[0].scriptPubKey")" == "str:$SPK2" ]] \
    || fail "matched scriptPubKey != ADDR2 SPK (got $(jget "$OU_SCAN" "unspents[0].scriptPubKey"))"
[[ "$(jget "$CORE_SCAN" "unspents[0].scriptPubKey")" == "str:$SPK2" ]] \
    || fail "Core matched scriptPubKey != ADDR2 SPK"
log "matched unspent txid/vout/amount/scriptPubKey: EXACT vs Core (desc=ok)"

# 7d. AMOUNT: top-level total_amount equals Core's, and == FUND_AMT.
CORE_TOT=$(jget "$CORE_SCAN" total_amount); CORE_TOT="${CORE_TOT#*:}"
OU_TOT=$(jget "$OU_SCAN" total_amount);     OU_TOT="${OU_TOT#*:}"
[[ "$(amt_eq "$CORE_TOT" "$OU_TOT")" == "EQ" ]] \
    || fail "total_amount mismatch: core=$CORE_TOT ouro=$OU_TOT"
[[ "$(amt_eq "$OU_TOT" "$FUND_AMT")" == "EQ" ]] \
    || fail "total_amount != funded $FUND_AMT (got $OU_TOT)"
log "total_amount == Core ($OU_TOT) (amount=ok)"

# 7e. bare-string scanobject form ["addr(<addr>)"] agrees with the object form.
OU_SCAN_STR=$(ou_rpc scantxoutset "[\"start\",[\"addr($ADDR2)\"]]" | ou_result)
case "$OU_SCAN_STR" in "<ERR>"*) fail "ouroboros scan (bare-string form) error: ${OU_SCAN_STR#<ERR>}" ;; esac
OS_TOT=$(jget "$OU_SCAN_STR" total_amount); OS_TOT="${OS_TOT#*:}"
[[ "$(amt_eq "$OS_TOT" "$OU_TOT")" == "EQ" ]] \
    || fail "bare-string scanobject total_amount ($OS_TOT) != object-form ($OU_TOT)"
[[ "$(jlen "$OU_SCAN_STR" "unspents")" == "1" ]] \
    || fail "bare-string scanobject matched != 1 unspent"
log "bare-string scanobject form agrees with object form"

# ── 8. SHAPE: result object + matched-unspent keys carry Core's full key set. ─
# Top-level result keys (Core: success,txouts,height,bestblock,unspents,total_amount).
for K in success txouts height bestblock unspents total_amount; do
    [[ "$(jget "$OU_SCAN" "$K")" != "<MISSING>" ]] || fail "result missing top-level key '$K'"
done
# txouts/height must be ints; bestblock a 64-hex tip hash == both nodes' tip.
[[ "$(jget "$OU_SCAN" txouts)" == int:* ]] || fail "txouts not an int (got $(jget "$OU_SCAN" txouts))"
[[ "$(jget "$OU_SCAN" height)" == "int:$NEWH" ]] \
    || fail "height != tip $NEWH (got $(jget "$OU_SCAN" height))"
[[ "$(jget "$OU_SCAN" bestblock)" == "str:$NEWBH" ]] \
    || fail "bestblock != tip hash $NEWBH (got $(jget "$OU_SCAN" bestblock))"
[[ "$(jget "$CORE_SCAN" height)" == "int:$NEWH" ]]     || fail "Core height != tip $NEWH"
[[ "$(jget "$CORE_SCAN" bestblock)" == "str:$NEWBH" ]] || fail "Core bestblock != tip hash $NEWBH"

# Matched-unspent keys must carry Core's FULL key set. Per-key diff so a missing
# key names itself in the failure (a real divergence — NOT papered over).
declare -a MISSING_KEYS=()
for K in txid vout scriptPubKey desc amount coinbase height blockhash confirmations; do
    # Core MUST have every key (sanity on the oracle).
    [[ "$(jget "$CORE_SCAN" "unspents[0].$K")" != "<MISSING>" ]] \
        || fail "Core unspent missing key '$K' (oracle sanity failed)"
    if [[ "$(jget "$OU_SCAN" "unspents[0].$K")" == "<MISSING>" ]]; then
        MISSING_KEYS+=("$K")
    fi
done
if (( ${#MISSING_KEYS[@]} > 0 )); then
    fail "matched unspent missing Core key(s): ${MISSING_KEYS[*]} (impl unspent omits fields Core emits)"
fi
# 'desc' present on both (Core adds a #checksum via InferDescriptor; impl may
# echo the input addr() form — present-only, not byte-equal).
[[ "$(jget "$OU_SCAN" "unspents[0].desc")" != "<MISSING>" ]] || fail "matched unspent desc missing"
# coinbase: our funding coin spends a coinbase but is itself NOT a coinbase ->
# coinbase==false on both (deterministic).
[[ "$(jget "$OU_SCAN" "unspents[0].coinbase")"   == "bool:false" ]] \
    || fail "matched coin coinbase != false (got $(jget "$OU_SCAN" "unspents[0].coinbase"))"
[[ "$(jget "$CORE_SCAN" "unspents[0].coinbase")" == "bool:false" ]] || fail "Core coin coinbase != false"
# height of the coin == confirming block height on both.
[[ "$(jget "$OU_SCAN" "unspents[0].height")"   == "int:$NEWH" ]] \
    || fail "matched coin height != $NEWH (got $(jget "$OU_SCAN" "unspents[0].height"))"
[[ "$(jget "$CORE_SCAN" "unspents[0].height")" == "int:$NEWH" ]] || fail "Core coin height != $NEWH"
log "shape: result object + matched unspent carry Core's full key set (shape=ok)"

# ── 9. EMPTY: scan an address that holds nothing -> 0 / [] on both. ────────
log "scantxoutset start addr($ADDR_EMPTY) (empty control)"
CORE_EMPTY=$(ccli scantxoutset start "[{\"desc\":\"addr($ADDR_EMPTY)\"}]" 2>/dev/null) \
    || fail "Core scantxoutset (empty) failed"
OU_EMPTY=$(ou_rpc scantxoutset "[\"start\",[{\"desc\":\"addr($ADDR_EMPTY)\"}]]" | ou_result)
case "$OU_EMPTY" in "<ERR>"*) fail "ouroboros scantxoutset (empty) error: ${OU_EMPTY#<ERR>}" ;; esac
[[ "$(jget "$CORE_EMPTY" success)" == "bool:true" ]] || fail "Core empty-scan success != true"
[[ "$(jget "$OU_EMPTY" success)"   == "bool:true" ]] || fail "ouroboros empty-scan success != true"
[[ "$(jlen "$CORE_EMPTY" "unspents")" == "0" ]] || fail "Core empty-scan unspents != [] (got $(jlen "$CORE_EMPTY" unspents))"
[[ "$(jlen "$OU_EMPTY" "unspents")"   == "0" ]] || fail "ouroboros empty-scan unspents != [] (got $(jlen "$OU_EMPTY" unspents))"
CE_TOT=$(jget "$CORE_EMPTY" total_amount); CE_TOT="${CE_TOT#*:}"
OE_TOT=$(jget "$OU_EMPTY" total_amount);   OE_TOT="${OE_TOT#*:}"
[[ "$(amt_eq "$CE_TOT" "0")" == "EQ" ]] || fail "Core empty-scan total_amount != 0 (got $CE_TOT)"
[[ "$(amt_eq "$OE_TOT" "0")" == "EQ" ]] || fail "ouroboros empty-scan total_amount != 0 (got $OE_TOT)"
log "empty scan: total_amount=0 + empty unspents on BOTH (empty=ok)"

# ── 10. Verdict. ──────────────────────────────────────────────────────────
log "PASS: matched unspent txid/vout/amount + total_amount == Core; full Core key set present; empty scan ok"
pass

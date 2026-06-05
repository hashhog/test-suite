#!/usr/bin/env bash
#
# lunarblock_rbf.sh — self-contained RBF (BIP125) replacement + fee-rule
# differential-parity test against a REAL bitcoind regtest oracle.
#
# The SECOND mempool-policy cell (after testmempoolaccept reject-parity in
# test-suite/policy/lunarblock_policy.sh).  Where the policy cell proved the
# standardness GATE, this proves the mempool REPLACEMENT subsystem: an incoming
# tx that double-spends an input already spent by a mempool tx must be handled
# per BIP125 — evicted+replaced when the fee rules pass, rejected with the Core
# reject-reason CATEGORY when they fail.  Consensus-ADJACENT (relay policy).
#
# GROUND TRUTH = the box's REAL bitcoind (Bitcoin Core) on a SEPARATE regtest
#   instance (own scratch datadir + ports, -listen=0).  The SAME sequence of
#   submits is replayed against Core and against lunarblock; the mempool state
#   (getrawmempool) and reject-reason CATEGORY must agree.
#
# CONSTRUCTION (portable, no impl raw-tx machinery — lunarblock has no
#   createrawtransaction, so we build + SIGN every tx in Python via Core's
#   test_framework BIP143 SegwitV0SignatureHash, exactly like the policy cell):
#     * A deterministic p2wpkh keypair from a fixed 32-byte secret.
#     * Mine NBLOCKS to that key on each node (its OWN coinbase txid).
#     * Read that node's height-1 mature coinbase as the single shared prevout.
#     * Build A / B / C / D as 1-in (the coinbase) / 1-out p2wpkh spends, all
#       SIGNALING RBF (nSequence 0xfffffffd) so Rule 1 is satisfied
#       deterministically regardless of the full-rbf setting.  They differ only
#       in the OUTPUT amount (= the fee), so they all conflict on the SAME input.
#
# THE THREE ASSERTIONS (the helper drives ONE node and emits a result line per
#   probe; the bash driver compares lunarblock's lines to Core's):
#   1. HAPPY PATH (replace):  send A (fee f1) -> in mempool.  send B (same input,
#        fee f2 >> f1, meets Rules 3+4) -> REPLACES A.  getrawmempool now holds B
#        and NOT A — on BOTH nodes.
#   2. RULE 3 (insufficient fee, "less fees than conflicting txs"):  with A in the
#        mempool, testmempoolaccept C (same input, fee <= f1) -> rejected, CATEGORY
#        "insufficient-fee" — on BOTH.  (C never enters the mempool.)
#   3. RULE 4 (insufficient fee, "not enough additional fees to relay"):
#        testmempoolaccept D (same input, fee slightly > f1 but the delta is below
#        incrementalRelayFee*vsize) -> rejected, CATEGORY "insufficient-fee" —
#        on BOTH.
#   Rule 5 (>100 replacements) is OUT OF SCOPE per the brief.
#
# NORMALIZATION: reject-reason strings are compared by CATEGORY via classify().
#   Core emits "insufficient fee" (detail "less fees than conflicting txs" /
#   "not enough additional fees to relay"); lunarblock is Core-faithful but
#   phrases the detail differently ("replacement fee not higher than conflicting
#   txs", "insufficient fee for relay: additional .. < required ..").  A case
#   PASSES when impl and Core map to the same category.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/lunarblock_policy.sh): no
#   required args, idempotent, trap cleanup, scratch datadirs + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS:  RBF lunarblock: PASS replace=ok rule3=ok rule4=ok
#   FAIL:  RBF lunarblock: FAIL <short reason> [replace=.. rule3=.. rule4=..]
#   SKIP:  RBF lunarblock: SKIP <build/raw-tx gap>
#
# Touches ONLY /tmp/rbf-lunarblock + /tmp/rbf-core and ports
#   40198/40218 (lunarblock RPC/P2P), 40196/40216 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/tx builders)

LB_DATADIR="/tmp/rbf-lunarblock"
LB_RPC=40198
LB_P2P=40218
LB_LOG="$LB_DATADIR/node.log"

CORE_DATADIR="/tmp/rbf-core"
CORE_RPC=40196
CORE_P2P=40216
CORE_LOG="$CORE_DATADIR/core.log"

# Fixed deterministic test secret (32 bytes) -> one p2wpkh keypair.
SECRET="2222222222222222222222222222222222222222222222222222222222222223"

NBLOCKS=101            # mine to maturity: height-1 coinbase spendable at tip 101

# lunarblock defaults to an EMPTY rpcpassword on regtest -> RPC auth disabled.
LB_COOKIE_SENTINEL="NONE"

LB_PID=""
CORE_BG=""
HELPER=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[rbf:lunarblock] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$LB_PID" ]] && kill -0 "$LB_PID" 2>/dev/null; then
        kill -TERM "-${LB_PID}" 2>/dev/null || kill -TERM "$LB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$LB_PID" 2>/dev/null || break; sleep 1; done
        kill -KILL "-${LB_PID}" 2>/dev/null || kill -KILL "$LB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${LB_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${LB_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$LB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <replace> <rule3> <rule4>
pass() { echo "RBF lunarblock: PASS replace=$1 rule3=$2 rule4=$3"; exit 0; }
fail() { echo "RBF lunarblock: FAIL $*"; exit 1; }
skip() { echo "RBF lunarblock: SKIP $*"; exit 0; }

# ── Reject-reason category classifier (the NORMALIZATION map). ────────────
# Maps any impl/Core reject string to a canonical category token. Empty input
# (accepted) -> "accept".  RBF fee-rule rejects (Rules 3 & 4) -> "insufficient-fee".
# A non-signaling / not-allowed conflict -> "mempool-conflict".
classify() {
    local s="$1"
    [[ -z "$s" ]] && { echo "accept"; return; }
    local l="${s,,}"
    case "$l" in
        # Rule 3 (less fees than conflicting) + Rule 4 (not enough additional fees)
        # + the generic Core "insufficient fee" reject-reason all map together.
        *"insufficient fee"*|*"not higher than conflicting"*|*"less fees than conflicting"*|\
        *"not enough additional fees"*|*"insufficient fee for relay"*|*"fee not higher"*|\
        *"does not improve feerate"*|*"insufficient feerate"*) echo "insufficient-fee" ;;
        # Non-signaling conflict when RBF not allowed.
        *"txn-mempool-conflict"*|*"bad-txns-spends-conflicting"*|*"conflict with existing"*|\
        *"does not signal rbf"*|*"spends conflicting"*)         echo "mempool-conflict" ;;
        *"replacement-adds-unconfirmed"*|*"adds new unconfirmed"*) echo "replacement-adds-unconfirmed" ;;
        *)                                                       echo "other:$s" ;;
    esac
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "rbf-lunarblock" 2>/dev/null || true
fuser -k "${LB_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${LB_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
# A just-SIGKILLed LuaJIT holder can keep its listen socket briefly, so a flat
# `sleep 1` races -> "address already in use" under sustained load (caught by the
# 2026-06-05 consolidation guard). Poll until the RPC+P2P ports actually release.
for _ in $(seq 1 15); do
  fuser "${LB_RPC}/tcp" >/dev/null 2>&1 || fuser "${LB_P2P}/tcp" >/dev/null 2>&1 || break
  sleep 1
done
rm -rf "$LB_DATADIR" "$CORE_DATADIR"
mkdir -p "$LB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v luajit  >/dev/null 2>&1   || skip "luajit not found on PATH"
command -v python3 >/dev/null 2>&1   || skip "python3 not found on PATH"
[[ -f "$LB_DIR/src/main.lua" ]]      || skip "lunarblock src/main.lua not found at $LB_DIR"
[[ -x "$CORE_BIN" ]]                 || skip "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || skip "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || skip "Core test_framework not found at $TF_PATH"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || skip "Core test_framework Python imports failed (need key/script/messages/address)"

# ── 2. Write the RBF-corpus driver Python helper. ─────────────────────────
# It connects to ONE node's RPC, mines a coinbase to the fixed key, reads that
# node's OWN height-1 coinbase, then runs the THREE probes in order and prints
# tab-separated result lines to stdout:
#   SEND     <name> <ok:true|false> <txid|err>          (sendrawtransaction)
#   TMA      <name> <allowed:true|false> <reject-reason> (testmempoolaccept)
#   MEMPOOL  <after>  <txidA|-> <txidB|->                 (getrawmempool snapshot:
#                                                           contains-A? contains-B?)
# Cookie arg: "user:pass" -> Basic auth; literal "NONE" -> no auth header.
HELPER="$LB_DATADIR/rbf_driver.py"
cat > "$HELPER" <<'PYEOF'
import sys, json, base64, urllib.request
sys.path.insert(0, sys.argv[1])  # test_framework path
RPC_URL = sys.argv[2]
COOKIE  = sys.argv[3]            # "user:pass" form, or "NONE" for no-auth
SECRET  = sys.argv[4]
NBLOCKS = int(sys.argv[5])

from test_framework.key import ECKey
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness, COIN
from test_framework.script import (CScript, OP_0, hash160, SegwitV0SignatureHash, SIGHASH_ALL,
    OP_DUP, OP_HASH160, OP_EQUALVERIFY, OP_CHECKSIG)
from test_framework.address import key_to_p2wpkh

_HEADERS = {"Content-Type": "application/json"}
if COOKIE != "NONE":
    _HEADERS["Authorization"] = "Basic " + base64.b64encode(COOKIE.encode()).decode()

_id = [0]
def rpc(method, params=None):
    _id[0] += 1
    body = json.dumps({"jsonrpc": "1.0", "id": _id[0], "method": method,
                       "params": params or []}).encode()
    req = urllib.request.Request(RPC_URL, data=body, headers=_HEADERS)
    with urllib.request.urlopen(req, timeout=120) as r:
        d = json.loads(r.read())
    return d  # caller inspects error/result

def rpc_ok(method, params=None):
    d = rpc(method, params)
    if d.get("error"):
        raise RuntimeError(f"{method} rpc error: {d['error']}")
    return d["result"]

# Deterministic keypair -> p2wpkh address + scriptPubKey.
priv = ECKey(); priv.set(bytes.fromhex(SECRET), compressed=True)
pub  = priv.get_pubkey().get_bytes()
pkh  = hash160(pub)
spk  = CScript([OP_0, pkh])               # p2wpkh output
addr = key_to_p2wpkh(pub, main=False)     # bcrt1...

# Mine to maturity (this node's own coinbase) and read the height-1 coinbase.
rpc_ok("generatetoaddress", [NBLOCKS, addr])
if int(rpc_ok("getblockcount")) < NBLOCKS:
    print("ERR height did not advance", file=sys.stderr); sys.exit(2)
bh  = rpc_ok("getblockhash", [1])
blk = rpc_ok("getblock", [bh, 2])
cb  = blk["tx"][0]
cb_txid = cb["txid"]
val = int(round(cb["vout"][0]["value"] * COIN))   # ~50 BTC in sats
prevout = COutPoint(int(cb_txid, 16), 0)

SEQ_RBF = 0xfffffffd  # signal opt-in RBF deterministically (Rule 1 satisfied)

def build(fee, version=2):
    """1-in (shared coinbase, RBF-signaling) / 1-out p2wpkh spend; fee = val - out."""
    tx = CTransaction(); tx.version = version
    tx.vin  = [CTxIn(prevout, b"", SEQ_RBF)]
    tx.vout = [CTxOut(val - fee, spk)]
    tx.wit.vtxinwit = [CTxInWitness()]
    sc = CScript([OP_DUP, OP_HASH160, pkh, OP_EQUALVERIFY, OP_CHECKSIG])  # BIP143 scriptCode
    sh = SegwitV0SignatureHash(sc, tx, 0, SIGHASH_ALL, val)
    tx.wit.vtxinwit[0].scriptWitness.stack = [priv.sign_ecdsa(sh) + bytes([SIGHASH_ALL]), pub]
    return tx

def txid_of(tx):
    return tx.txid_hex  # display (little-endian) txid hex

def send(name, tx):
    d = rpc("sendrawtransaction", [tx.serialize_with_witness().hex()])
    if d.get("error"):
        msg = str(d["error"].get("message", "")) or "rejected"
        safe = msg.replace("\t", " ").replace("\n", " ")
        print(f"SEND\t{name}\tfalse\t{safe}")
        return False
    print(f"SEND\t{name}\ttrue\t{d['result']}")
    return True

def tma(name, tx):
    r = rpc_ok("testmempoolaccept", [[tx.serialize_with_witness().hex()]])[0]
    allowed = bool(r.get("allowed"))
    reason  = "" if allowed else (r.get("reject-reason") or "rejected")
    safe = reason.replace("\t", " ").replace("\n", " ")
    print(f"TMA\t{name}\t{'true' if allowed else 'false'}\t{safe}")
    return allowed

def mempool_snapshot(label, txid_a, txid_b):
    mp = set(rpc_ok("getrawmempool"))
    has_a = txid_a in mp
    has_b = txid_b in mp
    print(f"MEMPOOL\t{label}\t{'A' if has_a else '-'}\t{'B' if has_b else '-'}")

# ── Fee schedule (sats).  Control A is ~110 vB; ~9 sat/vB clears the floor. ──
FEE_A = 1000     # A: baseline replaceable tx
FEE_B = 5000     # B: big bump -> satisfies Rule 3 (>=) AND Rule 4 (delta huge)
FEE_C = 1000     # C: equal fee -> FAILS Rule 3 (replacement fees < ... is strict
                 #    less-than; equal passes Rule3 but then FAILS Rule4 delta=0;
                 #    use fee < f1 to land squarely on Rule 3). Use 500 below.
FEE_C = 500      # C: LOWER fee -> fails Rule 3 (less fees than conflicting txs)
FEE_D = 1010     # D: tiny bump (+10 sat) -> passes Rule 3 but delta 10 sat <<
                 #    incrementalRelayFee*vsize (~11 sat at 100 sat/kvB on ~110 vB)
                 #    -> fails Rule 4 (not enough additional fees to relay)

txA = build(FEE_A)
txB = build(FEE_B)
txC = build(FEE_C)
txD = build(FEE_D)
idA = txid_of(txA)
idB = txid_of(txB)

# ── PROBE 1: HAPPY PATH (replace). ───────────────────────────────────────
send("A", txA)
mempool_snapshot("after_A", idA, idB)        # expect A present, B absent
send("B", txB)
mempool_snapshot("after_B", idA, idB)        # expect A GONE, B present (replaced)

# ── PROBE 2 & 3: rebuild clean state so A is the sole conflict, then test C/D.
# After B replaced A, the mempool holds B (spends the same coinbase outpoint).
# Rules 3/4 must be evaluated against the CURRENT conflict (B, fee 5000).  To
# test C/D against A specifically (fee 1000) we restart from a clean mempool:
# mine B away is heavy; instead we evaluate C/D as conflicts against B — but B's
# fee (5000) would change the thresholds.  Cleanest: snapshot C/D parity as
# *conflicts vs whatever single tx currently occupies the outpoint*, by first
# clearing the mempool.  We clear by mining the current mempool into a block,
# which empties it, then re-send A and test C/D against A deterministically.
rpc_ok("generatetoaddress", [1, addr])       # confirm B -> mempool empty
mempool_snapshot("after_mine", idA, idB)     # expect both absent (confirmed/clear)

# Re-fund: we already spent the height-1 coinbase. Use a FRESH coinbase (the
# block we just mined matured? no). Instead reuse a different mature coinbase:
# read height-2 coinbase (also mature: tip is now NBLOCKS+1).
bh2  = rpc_ok("getblockhash", [2])
blk2 = rpc_ok("getblock", [bh2, 2])
cb2  = blk2["tx"][0]
val2 = int(round(cb2["vout"][0]["value"] * COIN))
prevout2 = COutPoint(int(cb2["txid"], 16), 0)

def build2(fee, version=2):
    tx = CTransaction(); tx.version = version
    tx.vin  = [CTxIn(prevout2, b"", SEQ_RBF)]
    tx.vout = [CTxOut(val2 - fee, spk)]
    tx.wit.vtxinwit = [CTxInWitness()]
    sc = CScript([OP_DUP, OP_HASH160, pkh, OP_EQUALVERIFY, OP_CHECKSIG])
    sh = SegwitV0SignatureHash(sc, tx, 0, SIGHASH_ALL, val2)
    tx.wit.vtxinwit[0].scriptWitness.stack = [priv.sign_ecdsa(sh) + bytes([SIGHASH_ALL]), pub]
    return tx

txA2 = build2(FEE_A)
txC2 = build2(FEE_C)
txD2 = build2(FEE_D)
idA2 = txid_of(txA2)

send("A2", txA2)                              # seed the conflict (fee 1000)
mempool_snapshot("after_A2", idA2, "x")      # expect A2 present
# Rule 3: C2 has LOWER fee than A2 -> testmempoolaccept must reject.
tma("C_rule3", txC2)
# Rule 4: D2 fee just above A2 but delta below incrementalRelayFee*vsize -> reject.
tma("D_rule4", txD2)
# A2 must still be in the mempool (neither C nor D should have evicted it).
mempool_snapshot("after_CD", idA2, "x")
PYEOF
[[ -s "$HELPER" ]] || fail "failed to write RBF driver helper"

# ── Launch helper for a Core regtest oracle. ──────────────────────────────
# usage: launch_core <datadir> <rpcport> <p2pport> <logfile>
# echoes the background PID on success; returns non-zero on startup error.
launch_core() {
    local dd="$1" rpc="$2" p2p="$3" lf="$4"
    "$CORE_BIN" -regtest -datadir="$dd" -rpcport="$rpc" -port="$p2p" -listen=0 \
        -fallbackfee=0.0002 >"$lf" 2>&1 &
    local bg=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if "$CORE_CLI" -regtest -datadir="$dd" -rpcport="$rpc" getblockcount >/dev/null 2>&1; then
            echo "$bg"; return 0
        fi
        kill -0 "$bg" 2>/dev/null || { tail -n 20 "$lf" >&2 2>/dev/null || true; return 1; }
        sleep 1
    done
    return 1
}

# ── 3. Launch the Core oracle. ────────────────────────────────────────────
log "launching Core oracle rpc=:$CORE_RPC"
CORE_BG=$(launch_core "$CORE_DATADIR" "$CORE_RPC" "$CORE_P2P" "$CORE_LOG") \
    || fail "Core oracle failed to start within 90s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "Core cookie not found at $CORE_DATADIR/regtest/.cookie"

# ── 4. Launch lunarblock on regtest. ──────────────────────────────────────
log "launching lunarblock (regtest) rpc=:$LB_RPC p2p=:$LB_P2P -> $LB_LOG"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$LB_DATADIR' \
    --port '$LB_P2P' --rpcport '$LB_RPC' --nov2transport" \
    >"$LB_LOG" 2>&1 &
LB_PID=$!
log "lunarblock pid=$LB_PID"
lb_deadline=$(( $(date +%s) + 90 ))
lb_up=0
while (( $(date +%s) < lb_deadline )); do
    if ! kill -0 "$LB_PID" 2>/dev/null; then
        tail -n 20 "$LB_LOG" >&2 2>/dev/null || true
        fail "lunarblock exited during startup (see $LB_LOG)"
    fi
    r=$(curl -s --max-time 5 \
        --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockchaininfo","params":[]}' \
        "http://127.0.0.1:$LB_RPC/" 2>/dev/null)
    if echo "$r" | grep -q '"regtest"'; then lb_up=1; break; fi
    sleep 1
done
[[ "$lb_up" -eq 1 ]] || { tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock RPC never reported chain=regtest within 90s"; }
log "lunarblock RPC ready"

# ── 5. Run the RBF driver against both nodes. ─────────────────────────────
log "running RBF driver against Core oracle"
CORE_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_RPC/" "$CORE_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_LOG")
[[ -n "$CORE_OUT" ]] || { tail -n 30 "$CORE_LOG" >&2 2>/dev/null || true; fail "RBF driver produced no output for Core oracle"; }

log "running RBF driver against lunarblock"
LB_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$LB_RPC/" "$LB_COOKIE_SENTINEL" "$SECRET" "$NBLOCKS" 2>>"$LB_LOG")
[[ -n "$LB_OUT" ]] || { tail -n 30 "$LB_LOG" >&2 2>/dev/null || true; fail "RBF driver produced no output for lunarblock"; }

log "=== Core driver output ==="
echo "$CORE_OUT" >&2
log "=== lunarblock driver output ==="
echo "$LB_OUT" >&2

# ── 6. Parse both result sets. ────────────────────────────────────────────
# Build assoc maps keyed by "<TAG>:<name>".
declare -A CORE_KV LB_KV
parse_into() {
    local -n out=$1
    local data="$2"
    while IFS=$'\t' read -r tag name f3 f4; do
        case "$tag" in
            SEND|TMA)  out["$tag:$name"]="$f3|$f4" ;;
            MEMPOOL)   out["MEMPOOL:$name"]="$f3|$f4" ;;
        esac
    done <<< "$data"
}
parse_into CORE_KV "$CORE_OUT"
parse_into LB_KV   "$LB_OUT"

# ── 7. Evaluate the three probes (lunarblock vs Core). ────────────────────
REPLACE_T="?"; RULE3_T="?"; RULE4_T="?"
FAILS=()

# helper: split "a|b" -> echo a or b
f1() { echo "${1%%|*}"; }
f2() { echo "${1#*|}"; }

# ---- PROBE 1: HAPPY PATH (replace) ----
# Required Core behavior (the oracle defines truth): A sent ok, B sent ok,
# after_B mempool = A absent + B present.  lunarblock must match Core.
core_send_a=$(f1 "${CORE_KV[SEND:A]:-false|}")
core_send_b=$(f1 "${CORE_KV[SEND:B]:-false|}")
core_after_b="${CORE_KV[MEMPOOL:after_B]:-?|?}"
lb_send_a=$(f1 "${LB_KV[SEND:A]:-false|}")
lb_send_b=$(f1 "${LB_KV[SEND:B]:-false|}")
lb_after_b="${LB_KV[MEMPOOL:after_B]:-?|?}"

# Core sanity: the oracle itself must show a real replacement, else the test
# construction is broken (not lunarblock's fault).
if [[ "$core_send_a" != "true" || "$core_send_b" != "true" || "$core_after_b" != "-|B" ]]; then
    fail "Core oracle did not perform the expected replacement (send_a=$core_send_a send_b=$core_send_b after_B=$core_after_b); test construction broken, not a lunarblock verdict"
fi

if [[ "$lb_send_a" == "true" && "$lb_send_b" == "true" && "$lb_after_b" == "-|B" ]]; then
    REPLACE_T="ok"
else
    REPLACE_T="MISMATCH"
    FAILS+=("replace: lunarblock send_a=$lb_send_a send_b=$lb_send_b after_B=$lb_after_b (Core after_B=$core_after_b: A-gone,B-present)")
fi

# ---- PROBE 2: RULE 3 (insufficient fee) ----
core_c_allowed=$(f1 "${CORE_KV[TMA:C_rule3]:-?|}")
core_c_reason=$(f2 "${CORE_KV[TMA:C_rule3]:-?|}")
lb_c_allowed=$(f1 "${LB_KV[TMA:C_rule3]:-?|}")
lb_c_reason=$(f2 "${LB_KV[TMA:C_rule3]:-?|}")
core_c_cat=$(classify "$core_c_reason"); lb_c_cat=$(classify "$lb_c_reason")

# Core sanity: C must be REJECTED by Core with the insufficient-fee category.
if [[ "$core_c_allowed" != "false" ]]; then
    fail "Core oracle ACCEPTED the Rule-3 conflict C (allowed=$core_c_allowed); test construction broken"
fi
if [[ "$lb_c_allowed" == "false" && "$lb_c_cat" == "$core_c_cat" ]]; then
    RULE3_T="ok"
elif [[ "$lb_c_allowed" == "false" ]]; then
    RULE3_T="cat-mismatch"
    FAILS+=("rule3: both reject but category differs (lunarblock='$lb_c_reason'[$lb_c_cat] vs Core='$core_c_reason'[$core_c_cat])")
else
    RULE3_T="ACCEPTED"
    FAILS+=("rule3: lunarblock ACCEPTED a lower-fee conflict that Core rejects ($core_c_reason)")
fi

# ---- PROBE 3: RULE 4 (insufficient fee, bandwidth) ----
core_d_allowed=$(f1 "${CORE_KV[TMA:D_rule4]:-?|}")
core_d_reason=$(f2 "${CORE_KV[TMA:D_rule4]:-?|}")
lb_d_allowed=$(f1 "${LB_KV[TMA:D_rule4]:-?|}")
lb_d_reason=$(f2 "${LB_KV[TMA:D_rule4]:-?|}")
core_d_cat=$(classify "$core_d_reason"); lb_d_cat=$(classify "$lb_d_reason")

if [[ "$core_d_allowed" != "false" ]]; then
    fail "Core oracle ACCEPTED the Rule-4 conflict D (allowed=$core_d_allowed); test construction broken"
fi
if [[ "$lb_d_allowed" == "false" && "$lb_d_cat" == "$core_d_cat" ]]; then
    RULE4_T="ok"
elif [[ "$lb_d_allowed" == "false" ]]; then
    RULE4_T="cat-mismatch"
    FAILS+=("rule4: both reject but category differs (lunarblock='$lb_d_reason'[$lb_d_cat] vs Core='$core_d_reason'[$core_d_cat])")
else
    RULE4_T="ACCEPTED"
    FAILS+=("rule4: lunarblock ACCEPTED a tiny-bump conflict that Core rejects ($core_d_reason)")
fi

# ── 8. Verdict. ───────────────────────────────────────────────────────────
if [[ "${#FAILS[@]}" -gt 0 ]]; then
    msg="$(IFS=' | '; echo "${FAILS[*]}")"
    fail "$msg [replace=$REPLACE_T rule3=$RULE3_T rule4=$RULE4_T]"
fi

log "PASS: BIP125 replace + Rule3 + Rule4 parity with Core (categories match)"
pass "$REPLACE_T" "$RULE3_T" "$RULE4_T"

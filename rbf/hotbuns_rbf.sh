#!/usr/bin/env bash
#
# hotbuns_rbf.sh — self-contained RBF / BIP-125 replacement DIFFERENTIAL test.
#
# The SECOND mempool-policy cell (after testmempoolaccept reject-parity in
# test-suite/policy/hotbuns_policy.sh). Where the policy cell proved the
# standardness reject gate, this cell proves the mempool's *conflict-handling
# subsystem*: when an incoming tx double-spends an input already spent by a
# mempool tx, hotbuns must do EXACTLY what Bitcoin Core does — replace the old
# tx when the BIP-125 fee rules pass, and reject (without disturbing the
# mempool) with the same reject-reason CATEGORY when they fail.
#
# DIFFERENTIAL (not a hardcoded oracle): this cell launches a REAL bitcoind
# regtest node alongside hotbuns and runs the IDENTICAL submit sequence against
# BOTH, then asserts the two nodes agree on every step. The two nodes are
# independent (each funds its own coinbase, builds conflicts over its own
# input) — the differential is "same construction, same logic ⇒ same decision".
#
# Construction (PORTABLE, deterministic, no createrawtransaction object-output
# ambiguity): mine a coinbase to a wallet address, mine to maturity, take a
# mature wallet UTXO, then build A and its conflicts over A's EXACT prevout
# via createrawtransaction (array-of-inputs + object-of-outputs) at different
# output amounts (= different fees) + signrawtransactionwithwallet +
# sendrawtransaction / testmempoolaccept. All inputs use nSequence 0xfffffffd
# so they SIGNAL opt-in RBF — deterministic regardless of any full-rbf setting.
#
# Assertions (hotbuns vs Core, SAME sequence on each):
#   1. HAPPY PATH (replace): submit A (fee f1, signals RBF) -> accepted (in
#      getrawmempool). Submit B (same input, fee f2 >> f1, meets rules 3+4) ->
#      REPLACES A: getrawmempool now has B and NOT A on both nodes.
#   2. RULE 3: re-fund, submit A, then C (same input, fee <= f1) ->
#      testmempoolaccept rejects category "insufficient fee" on both; the
#      conflict does NOT enter the mempool (A still there).
#   3. RULE 4: submit D (same input, fee slightly > f1 but delta <
#      incrementalRelayFee*vsize) -> rejected category "insufficient fee" on
#      both; A still there.
#
# NORMALIZATION (category-level, mirrors the policy chapter): each reject reason
# is classified by substring to {insufficient-fee, mempool-conflict, accept,
# other}. Rules 3 and 4 both surface "insufficient fee" in Core; hotbuns
# decorates the token ("RBF replacement fee ... must be >= ...", "RBF
# incremental fee ...") — both classify to insufficient-fee. A case PASSES when
# the hotbuns category == the Core category.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/hotbuns_policy.sh): no
# required args, idempotent, trap cleanup, scratch /tmp + UNIQUE ports, ONE
# clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: RBF hotbuns: PASS replace=ok rule3=ok rule4=ok
#   FAIL: RBF hotbuns: FAIL <short reason> [replace=.. rule3=.. rule4=..]
#   SKIP: RBF hotbuns: SKIP <build/raw-tx gap>
#
# Touches ONLY /tmp/rbf-hotbuns/ and ports 40194/40214 (hotbuns) +
# 40196/40216 (bitcoind oracle). NEVER touches /data/nvme1/ or testnet4-data/
# or any live node. Any `fuser -k` redirects stdout.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_DIR="$BASEDIR/hotbuns"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin"
BITCOIND="$CORE_BIN/bitcoind"
BCLI="$CORE_BIN/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/tx builders)

# Deterministic 32-byte test secret -> one p2wpkh keypair the whole corpus is
# built from. WALLET-FREE: the on-box bitcoind is built without wallet support,
# so we fund + sign in Python via the Core test_framework (BIP143 sighash).
SECRET="1111111111111111111111111111111111111111111111111111111111111113"

SCRATCH="/tmp/rbf-hotbuns"

# hotbuns ports (per the cell brief).
HB_DATADIR="$SCRATCH/hotbuns"
HB_RPC=40194
HB_P2P=40214
HB_LOG="$SCRATCH/hotbuns.log"

# bitcoind oracle ports (distinct from hotbuns).
BD_DATADIR="$SCRATCH/bitcoind"
BD_RPC=40196
BD_P2P=40216
BD_LOG="$SCRATCH/bitcoind.log"

NBLOCKS=110          # mine to maturity (>100) so a coinbase UTXO is spendable

HB_PID=""
HB_COOKIE=""
BD_PID=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[rbf:hotbuns] $*" >&2; }

# ── Cleanup: kill both nodes + wipe scratch on any exit. ──────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BD_PID" ]]; then
        "$BCLI" -datadir="$BD_DATADIR" -rpcport=$BD_RPC stop >/dev/null 2>&1 || true
        for _ in $(seq 1 15); do kill -0 "$BD_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BD_PID" 2>/dev/null || true
    fi
    if [[ -n "$HB_PID" ]] && kill -0 "$HB_PID" 2>/dev/null; then
        kill "$HB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HB_PID" 2>/dev/null || true
    fi
    fuser -k "${HB_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${HB_P2P}/tcp" >/dev/null 2>&1 || true
    fuser -k "${BD_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${BD_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$SCRATCH" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() { echo "RBF hotbuns: PASS replace=$1 rule3=$2 rule4=$3"; exit 0; }
fail() { echo "RBF hotbuns: FAIL $*"; exit 1; }
skip() { echo "RBF hotbuns: SKIP $*"; exit 0; }

# ── Reject-reason category classifier (the NORMALIZATION map). ────────────
# Empty input (accepted) -> "accept". Maps an impl reject string to a category.
classify() {
    local s="$1"
    [[ -z "$s" ]] && { echo "accept"; return; }
    local l="${s,,}"
    case "$l" in
        *"insufficient fee"*|*insufficient-fee*|*"not enough additional fees"*|*"less fees than"*|\
        *"incremental fee"*|*"replacement fee"*|*"too low to be a replacement"*|*"replacement-failed"*|\
        *"not enough additional"*|*"rbf"*fee*|*fee*rbf*) echo "insufficient-fee" ;;
        *"txn-mempool-conflict"*|*"bad-txns-spends-conflicting"*|*"replacement-disallowed"*|\
        *"bip125-replacement-disallowed"*|*"conflicting"*) echo "mempool-conflict" ;;
        *) echo "other:$s" ;;
    esac
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "rbf-hotbuns/hotbuns" >/dev/null 2>&1 || true
pkill -f "rbf-hotbuns/bitcoind" >/dev/null 2>&1 || true
fuser -k "${HB_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${HB_P2P}/tcp" >/dev/null 2>&1 || true
fuser -k "${BD_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${BD_P2P}/tcp" >/dev/null 2>&1 || true
sleep 1
rm -rf "$SCRATCH"
mkdir -p "$HB_DATADIR" "$BD_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v bun  >/dev/null 2>&1     || fail "bun runtime not found on PATH"
command -v curl >/dev/null 2>&1     || fail "curl not found on PATH"
command -v python3 >/dev/null 2>&1  || fail "python3 not found on PATH"
[[ -x "$BITCOIND" ]]                || skip "bitcoind oracle not built at $BITCOIND"
[[ -x "$BCLI" ]]                    || skip "bitcoin-cli not built at $BCLI"
[[ -d "$TF_PATH/test_framework" ]]  || fail "Core test_framework not found at $TF_PATH"
[[ -f "$NODE_DIR/src/index.ts" ]]   || fail "hotbuns entrypoint not found at $NODE_DIR/src/index.ts"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || fail "Core test_framework Python imports failed (need key/script/messages/address)"

# ── 2. Launch bitcoind oracle on regtest. ─────────────────────────────────
log "launching bitcoind oracle (regtest) rpc=:$BD_RPC p2p=:$BD_P2P -> $BD_LOG"
"$BITCOIND" -regtest -datadir="$BD_DATADIR" -listen=0 \
    -rpcbind=127.0.0.1 -rpcallowip=127.0.0.1 \
    -rpcport=$BD_RPC \
    -fallbackfee=0.0001 -txindex=1 -server=1 \
    >"$BD_LOG" 2>&1 &
BD_PID=$!
log "bitcoind pid=$BD_PID"
bd() { "$BCLI" -regtest -datadir="$BD_DATADIR" -rpcport=$BD_RPC "$@"; }
deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < deadline )); do
    bd getblockcount >/dev/null 2>&1 && break
    kill -0 "$BD_PID" 2>/dev/null || { tail -n 20 "$BD_LOG" >&2 2>/dev/null || true; fail "bitcoind exited during startup (see $BD_LOG)"; }
    sleep 1
done
bd getblockcount >/dev/null 2>&1 || fail "bitcoind RPC never responded within 90s"
log "bitcoind RPC ready"

# ── 3. Launch hotbuns on regtest. ─────────────────────────────────────────
log "launching hotbuns (regtest) rpc=:$HB_RPC p2p=:$HB_P2P -> $HB_LOG"
(
    cd "$NODE_DIR" || exit 1
    exec bun run src/index.ts \
        --network=regtest --datadir="$HB_DATADIR" \
        --port="$HB_P2P" --rpcport="$HB_RPC"
) >"$HB_LOG" 2>&1 &
HB_PID=$!
log "hotbuns pid=$HB_PID"
deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < deadline )); do
    if [[ -z "$HB_COOKIE" ]]; then
        for c in "$HB_DATADIR/.cookie" "$HB_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && HB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HB_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$HB_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$HB_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$HB_PID" 2>/dev/null || { tail -n 20 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns exited during startup (see $HB_LOG)"; }
    sleep 1
done
[[ -n "$HB_COOKIE" ]] || fail "hotbuns cookie never appeared within 90s"
r=$(curl -s --max-time 5 -u "$HB_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$HB_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "hotbuns RPC never responded within 90s"
log "hotbuns RPC ready"

# ── 4. Driver helper (one Python program drives EITHER node). ─────────────
# Argv: <node-tag> <rpc-url> <auth user:pass> <tf-path> <secret> <nblocks>
# WALLET-FREE: the on-box bitcoind is built without wallet support, so the
# driver funds + signs with the Core test_framework (ECKey + BIP143 sighash),
# exactly like test-suite/policy/hotbuns_policy.sh. It mines NBLOCKS to a
# deterministic p2wpkh key, reads THIS node's own height-1 coinbase, and builds
# every tx (A and its conflicts) over that coinbase prevout in Python — no
# wallet / createrawtransaction RPC dependency for the differential itself.
#
# It ADDITIONALLY exercises the hotbuns createrawtransaction impl fix: for the
# hotbuns node it asks the node to build the unsigned A via createrawtransaction
# and asserts byte-identity with the Python-built unsigned tx (CRT step).
#
# Prints tab-separated step lines:
#   STEP crt          <ok|skip|mismatch>     (createrawtransaction byte-parity)
#   STEP submitA      <accepted:true|false> <reason>
#   STEP memHasA      <true|false>
#   STEP submitB      <accepted:true|false> <reason>
#   STEP memHasB      <true|false>
#   STEP memHasA2     <true|false>     (after B: A must be gone)
#   STEP rule3        <allowed:true|false> <reason>
#   STEP rule3memA    <true|false>     (live tx still present after C rejected)
#   STEP rule4        <allowed:true|false> <reason>
#   STEP rule4memA    <true|false>     (live tx still present after D rejected)
# A leading "ERR <msg>" line + nonzero exit means a build/raw-tx gap -> SKIP.
HELPER="$SCRATCH/rbf_driver.py"
cat > "$HELPER" <<'PYEOF'
import sys, json, base64, urllib.request

TAG     = sys.argv[1]
RPC_URL = sys.argv[2]
AUTHRAW = sys.argv[3]          # "user:pass"
TF_PATH = sys.argv[4]          # Core test_framework path
SECRET  = sys.argv[5]          # 32-byte hex test secret
NBLOCKS = int(sys.argv[6])

sys.path.insert(0, TF_PATH)
from test_framework.key import ECKey
from test_framework.messages import (CTransaction, CTxIn, CTxOut, COutPoint,
                                      CTxInWitness, COIN)
from test_framework.script import (CScript, OP_0, hash160, SegwitV0SignatureHash,
                                    SIGHASH_ALL, OP_DUP, OP_HASH160, OP_EQUALVERIFY,
                                    OP_CHECKSIG)
from test_framework.address import key_to_p2wpkh

AUTH = "Basic " + base64.b64encode(AUTHRAW.encode()).decode()
_id = [0]

def _post(url, method, params):
    _id[0] += 1
    body = json.dumps({"jsonrpc":"1.0","id":_id[0],"method":method,"params":params}).encode()
    req = urllib.request.Request(url, data=body,
        headers={"Authorization":AUTH, "Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as he:
        raw = he.read()
        try:
            return json.loads(raw)
        except Exception:
            return {"error": {"code": he.code, "message": he.reason or "http error"}}

def rpc(method, params=None, allow_err=False):
    params = params or []
    try:
        d = _post(RPC_URL, method, params)
    except Exception as e:
        if allow_err:
            return None, {"message": str(e)}
        raise
    if d.get("error"):
        if allow_err:
            return None, d["error"]
        raise RuntimeError(f"{method} rpc error: {d['error']}")
    return d["result"], None

def err(msg):
    print(f"ERR {msg}")
    sys.exit(3)

# ── deterministic keypair -> p2wpkh address + scriptPubKey. ───────────────
priv = ECKey(); priv.set(bytes.fromhex(SECRET), compressed=True)
pub  = priv.get_pubkey().get_bytes()
pkh  = hash160(pub)
spk  = CScript([OP_0, pkh])               # p2wpkh output scriptPubKey
addr = key_to_p2wpkh(pub, main=False)     # bcrt1...

# ── fund: mine NBLOCKS to our key (this node's own coinbase to maturity). ─
rpc("generatetoaddress", [NBLOCKS, addr])
h, _ = rpc("getblockcount", [])
if int(h) < NBLOCKS:
    err(f"chain did not advance to {NBLOCKS} (got {h})")

# Read THIS node's height-1 coinbase (mature: tip >= 101).
bh, _  = rpc("getblockhash", [1])
blk, _ = rpc("getblock", [bh, 2])
cb     = blk["tx"][0]
cb_txid = cb["txid"]
in_sats = int(round(cb["vout"][0]["value"] * COIN))    # 50 BTC in sats
prevout = COutPoint(int(cb_txid, 16), 0)

def build_signed(out_sats, sequence=0xfffffffd):
    """1-in/1-out RBF-signaling tx over the coinbase prevout, signed (BIP143)."""
    tx = CTransaction(); tx.version = 2
    tx.vin  = [CTxIn(prevout, b"", sequence)]
    tx.vout = [CTxOut(out_sats, spk)]
    tx.wit.vtxinwit = [CTxInWitness()]
    sc = CScript([OP_DUP, OP_HASH160, pkh, OP_EQUALVERIFY, OP_CHECKSIG])  # scriptCode
    sh = SegwitV0SignatureHash(sc, tx, 0, SIGHASH_ALL, in_sats)
    tx.wit.vtxinwit[0].scriptWitness.stack = [priv.sign_ecdsa(sh) + bytes([SIGHASH_ALL]), pub]
    return tx.serialize_with_witness().hex()

def build_unsigned_py(out_sats, sequence=0xfffffffd):
    """Python-built UNSIGNED tx (for createrawtransaction byte-parity check)."""
    tx = CTransaction(); tx.version = 2
    tx.vin  = [CTxIn(prevout, b"", sequence)]
    tx.vout = [CTxOut(out_sats, spk)]
    return tx.serialize_without_witness().hex()

def vsize_of(rawhex):
    d, e = rpc("decoderawtransaction", [rawhex], allow_err=True)
    if d and "vsize" in d:
        return int(d["vsize"])
    return 110   # typical 1-in/1-out p2wpkh

def tma(rawhex):
    r, e = rpc("testmempoolaccept", [[rawhex]], allow_err=True)
    if r is None:
        return False, f"testmempoolaccept error: {e}"
    row = r[0]
    allowed = bool(row.get("allowed"))
    reason = "" if allowed else (row.get("reject-reason") or "rejected")
    return allowed, reason

def send(rawhex):
    r, e = rpc("sendrawtransaction", [rawhex], allow_err=True)
    if r is not None:
        return True, ""
    msg = e.get("message", str(e)) if isinstance(e, dict) else str(e)
    return False, msg

def mempool():
    r, _ = rpc("getrawmempool", [])
    return set(r or [])

def txid_of(rawhex):
    d, _ = rpc("decoderawtransaction", [rawhex], allow_err=True)
    return d["txid"] if d else None

def step(name, *vals):
    # Tab-separated throughout (incl. after STEP) so the bash reader splitting
    # on IFS=$'\t' gets tag="STEP" as a clean first field.
    print("STEP\t" + name + "\t" + "\t".join(str(v) for v in vals))

# ── Fee schedule (sats). Control A modest; B pays much more. ──────────────
FEE_A = 2000
A_out = in_sats - FEE_A
rawA = build_signed(A_out)
A_txid = txid_of(rawA)

# ── createrawtransaction byte-parity (exercises the hotbuns impl fix). ────
# Build the SAME unsigned A through the node's createrawtransaction RPC and
# compare bytes with the Python serialization. bitcoind here lacks the RPC's
# wallet context but DOES expose createrawtransaction; if the node lacks it
# entirely, report "skip" (does not fail the differential).
crt_status = "skip"
inputs  = [{"txid": cb_txid, "vout": 0, "sequence": 0xfffffffd}]
outputs = {addr: round(A_out / COIN, 8)}
node_raw, e = rpc("createrawtransaction", [inputs, outputs], allow_err=True)
if node_raw:
    py_unsigned = build_unsigned_py(A_out)
    crt_status = "ok" if node_raw.lower() == py_unsigned.lower() else f"mismatch(node={node_raw[:24]}..,py={py_unsigned[:24]}..)"
step("crt", crt_status)

# ── Assertion 1: HAPPY PATH replace. ──────────────────────────────────────
okA, rA = send(rawA)
step("submitA", str(okA).lower(), rA)
step("memHasA", str(A_txid in mempool()).lower())

# B: same input, fee 20000 sats (>> f1, easily meets rules 3+4).
FEE_B = 20000
rawB = build_signed(in_sats - FEE_B)
B_txid = txid_of(rawB)
okB, rB = send(rawB)
step("submitB", str(okB).lower(), rB)
mp = mempool()
step("memHasB", str(B_txid in mp).lower())
step("memHasA2", str(A_txid in mp).lower())   # expect false: A replaced

# After the replace, B is the live tx spending the coinbase. Probe insufficient
# replacements of it (same prevout). Both nodes are in the same post-replace
# state, so the differential holds.
live_fee = FEE_B

# ── Assertion 2: RULE 3 (replacement absolute fee < original fee). ────────
# C: same input, fee = live_fee - 1000 (strictly LESS than the live tx's fee).
rawC = build_signed(in_sats - (live_fee - 1000))
C_allowed, C_reason = tma(rawC)
step("rule3", str(C_allowed).lower(), C_reason)
step("rule3memA", str(B_txid in mempool()).lower())   # live tx still present

# ── Assertion 3: RULE 4 (fee higher but delta < incrementalRelayFee*vsize). ─
# incrementalRelayFee default = 0.1 sat/vB -> required delta ~= ceil(0.1*110)=11
# sats. Pay only +1 sat over the live fee: delta=1 < 11 -> reject.
rawD = build_signed(in_sats - (live_fee + 1))
D_allowed, D_reason = tma(rawD)
step("rule4", str(D_allowed).lower(), D_reason)
step("rule4memA", str(B_txid in mempool()).lower())   # live tx still present
PYEOF
[[ -s "$HELPER" ]] || fail "failed to write rbf driver helper"

# ── 5. Run the driver against bitcoind oracle, then hotbuns. ──────────────
# bitcoind cookie auth.
BD_COOKIE_FILE="$BD_DATADIR/regtest/.cookie"
deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < deadline )); do [[ -f "$BD_COOKIE_FILE" ]] && break; sleep 1; done
[[ -f "$BD_COOKIE_FILE" ]] || fail "bitcoind cookie not found at $BD_COOKIE_FILE"
BD_COOKIE=$(cat "$BD_COOKIE_FILE")

log "running RBF driver against bitcoind oracle"
BD_OUT=$(python3 "$HELPER" core "http://127.0.0.1:$BD_RPC/" "$BD_COOKIE" "$TF_PATH" "$SECRET" "$NBLOCKS" 2>>"$BD_LOG")
if echo "$BD_OUT" | grep -q '^ERR '; then
    skip "bitcoind raw-tx build gap: $(echo "$BD_OUT" | grep '^ERR ' | head -1)"
fi
[[ -n "$BD_OUT" ]] || { tail -n 30 "$BD_LOG" >&2 2>/dev/null || true; fail "driver produced no output for bitcoind"; }

log "running RBF driver against hotbuns"
HB_OUT=$(python3 "$HELPER" hotbuns "http://127.0.0.1:$HB_RPC/" "$HB_COOKIE" "$TF_PATH" "$SECRET" "$NBLOCKS" 2>>"$HB_LOG")
if echo "$HB_OUT" | grep -q '^ERR '; then
    skip "hotbuns raw-tx build gap: $(echo "$HB_OUT" | grep '^ERR ' | head -1)"
fi
[[ -n "$HB_OUT" ]] || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "driver produced no output for hotbuns"; }

# ── 6. Parse step lines into assoc arrays. ────────────────────────────────
declare -A BD CORE_R HB HB_R
parse() {
    # $1 = output blob, $2 = "BD" or "HB" prefix for two parallel arrays
    local blob="$1" who="$2"
    while IFS=$'\t' read -r tag name v1 v2; do
        [[ "$tag" == "STEP" ]] || continue
        if [[ "$who" == "BD" ]]; then BD["$name"]="$v1"; CORE_R["$name"]="${v2:-}"
        else HB["$name"]="$v1"; HB_R["$name"]="${v2:-}"; fi
    done <<< "$blob"
}
parse "$BD_OUT" BD
parse "$HB_OUT" HB

log "=== RBF DIFFERENTIAL (hotbuns vs bitcoind oracle, regtest) ==="
for k in crt submitA memHasA submitB memHasB memHasA2 rule3 rule3memA rule4 rule4memA; do
    printf '  %-12s core=%-6s hot=%-6s  core-reason=%-32s hot-reason=%s\n' \
        "$k" "${BD[$k]:-?}" "${HB[$k]:-?}" "${CORE_R[$k]:- }" "${HB_R[$k]:- }" >&2
done

# Required step keys present (crt is optional — reported, not required).
for k in submitA memHasA submitB memHasB memHasA2 rule3 rule3memA rule4 rule4memA; do
    [[ -n "${BD[$k]:-}" ]] || fail "oracle missing step '$k' (driver output incomplete)"
    [[ -n "${HB[$k]:-}" ]] || fail "hotbuns missing step '$k' (driver output incomplete)"
done

# createrawtransaction byte-parity (exercises the hotbuns impl fix). A
# "mismatch" on hotbuns is a real raw-tx machinery bug -> FAIL. "ok"/"skip"
# both pass (skip = node lacks the RPC; the differential signs in Python).
CRT_HB="${HB[crt]:-skip}"
if [[ "$CRT_HB" == mismatch* ]]; then
    fail "hotbuns createrawtransaction byte-mismatch vs reference: $CRT_HB"
fi
log "createrawtransaction byte-parity: hotbuns=$CRT_HB core=${BD[crt]:-skip}"

# ── 7a. HAPPY PATH (replace). ─────────────────────────────────────────────
# Oracle sanity: Core must accept A, accept B, end with B-in / A-out.
if [[ "${BD[submitA]}" != "true" || "${BD[memHasA]}" != "true" ]]; then
    fail "oracle did not accept control tx A (core submitA=${BD[submitA]} memHasA=${BD[memHasA]} reason=${CORE_R[submitA]}); harness funding broken"
fi
if [[ "${BD[submitB]}" != "true" || "${BD[memHasB]}" != "true" || "${BD[memHasA2]}" != "false" ]]; then
    fail "oracle replace path unexpected (core submitB=${BD[submitB]} memHasB=${BD[memHasB]} memHasA2=${BD[memHasA2]}); harness broken"
fi

REPLACE="ok"
# hotbuns must accept A.
if [[ "${HB[submitA]}" != "true" || "${HB[memHasA]}" != "true" ]]; then
    fail "hotbuns did not accept control tx A (submitA=${HB[submitA]} memHasA=${HB[memHasA]} reason=${HB_R[submitA]}); cannot assess RBF | replace=broken-control"
fi
# hotbuns must accept B AND evict A (B in, A out) — Core parity.
if [[ "${HB[submitB]}" != "true" ]]; then
    REPLACE="FAIL-B-rejected(${HB_R[submitB]})"
elif [[ "${HB[memHasB]}" != "true" ]]; then
    REPLACE="FAIL-B-not-in-mempool"
elif [[ "${HB[memHasA2]}" != "false" ]]; then
    REPLACE="FAIL-A-not-evicted"
fi

# ── 7b. RULE 3 (insufficient absolute fee). ───────────────────────────────
# Oracle category for the rule-3 reject.
BD_R3_CAT=$(classify "${CORE_R[rule3]}")
[[ "${BD[rule3]}" == "false" ]] || fail "oracle did not reject rule-3 case (core rule3=${BD[rule3]} reason=${CORE_R[rule3]}); harness fee schedule wrong"
HB_R3_CAT=$(classify "${HB_R[rule3]}")
RULE3="ok"
if [[ "${HB[rule3]}" == "true" ]]; then
    RULE3="FAIL-hotbuns-accepts(HOLE)"
elif [[ "${HB[rule3memA]}" != "true" ]]; then
    RULE3="FAIL-live-tx-disturbed"
elif [[ "$HB_R3_CAT" != "$BD_R3_CAT" ]]; then
    RULE3="FAIL-category(core=$BD_R3_CAT hot=$HB_R3_CAT)"
fi

# ── 7c. RULE 4 (insufficient incremental fee). ────────────────────────────
BD_R4_CAT=$(classify "${CORE_R[rule4]}")
[[ "${BD[rule4]}" == "false" ]] || fail "oracle did not reject rule-4 case (core rule4=${BD[rule4]} reason=${CORE_R[rule4]}); harness incremental-fee delta wrong"
HB_R4_CAT=$(classify "${HB_R[rule4]}")
RULE4="ok"
if [[ "${HB[rule4]}" == "true" ]]; then
    RULE4="FAIL-hotbuns-accepts(HOLE)"
elif [[ "${HB[rule4memA]}" != "true" ]]; then
    RULE4="FAIL-live-tx-disturbed"
elif [[ "$HB_R4_CAT" != "$BD_R4_CAT" ]]; then
    RULE4="FAIL-category(core=$BD_R4_CAT hot=$HB_R4_CAT)"
fi

# ── 8. Verdict. ───────────────────────────────────────────────────────────
if [[ "$REPLACE" == "ok" && "$RULE3" == "ok" && "$RULE4" == "ok" ]]; then
    log "PASS: hotbuns matches Core on RBF replace + rule3 + rule4 (category-normalized)"
    pass ok ok ok
fi
fail "RBF parity gap | replace=$REPLACE rule3=$RULE3 rule4=$RULE4"

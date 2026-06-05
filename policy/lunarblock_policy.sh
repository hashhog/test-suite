#!/usr/bin/env bash
#
# lunarblock_policy.sh — self-contained MEMPOOL/POLICY reject-parity test.
#
# The consensus-adjacent successor to the wallet harnesses (recovery / spend /
# history / import). Where those proved the wallet round-trip, this proves the
# *mempool standardness gate*: a transaction that violates a relay-policy rule
# must be rejected with the SAME reject-reason CATEGORY Bitcoin Core emits.
#
# Why a new harness (the existing test-suite/mempool_tests.py is permissive):
#   The old suite spends OP_TRUE anyone-can-spend coinbases, so every submitted
#   tx fails at *input-existence* and NEVER reaches the standardness gate — it
#   can't tell "policy rejected" from "input missing", and never asserts the
#   reject STRING. This harness fixes that: it builds a REAL, SIGNED p2wpkh
#   spend of a mature coinbase (so the tx PASSES input-existence and REACHES
#   the policy gate), then derives one variant per standardness rule.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core v31.99) on SEPARATE
#   regtest instances (own scratch datadirs + ports). The SAME corpus is rebuilt
#   + submitted to Core's testmempoolaccept and Core's exact reject-reason is
#   recorded. lunarblock is compared against that oracle.
#
#   TWO Core oracles run side by side:
#     * STRICT  (-permitbaremultisig=0 -datacarriersize=80): the classic
#       relay-policy floor; every corpus violation rejects deterministically here.
#     * DEFAULT (no policy flags): Bitcoin Core v31.99 relaxed two classic rules
#       — bare multisig is relayed by default (DEFAULT_PERMIT_BAREMULTISIG=true)
#       and the OP_RETURN cap rose from 80 B to MAX_STANDARD_TX_WEIGHT/4 (100000).
#       So bare-multisig + an 83-byte OP_RETURN only reject on STRICT Core;
#       DEFAULT Core ACCEPTS them.
#
# GENUINE-FLOOR FRAMING (the key design decision):
#   The verdict is anchored to what DEFAULT (out-of-the-box) Core does, because
#   that is the config-independent must-reject floor. The GENUINE must-reject
#   floor = { dust, bad-version, below-min-relay } — rejected by BOTH strict AND
#   default Core — plus the valid-control which MUST be ACCEPTED.
#     * dust            : a fee-paying tx with a dust output (Core's ephemeral-
#                         dust 0-fee gate: PreCheckEphemeralTx, ephemeral_policy.cpp
#                         — a tx with any dust output that pays a nonzero fee is
#                         rejected "tx with dust output must be 0-fee").
#     * bad-version     : nVersion outside [1,3] (IsStandardTx "version").
#     * below-min-relay : a zero-fee tx (below the min-relay floor).
#   bare-multisig + oversize-op_return are STRICT-FLAG-ONLY: DEFAULT Core ACCEPTS
#   them, so lunarblock ACCEPTING them is parity-with-default-Core, NOT a hole.
#   They are reported but do NOT fail the harness.
#
#   A GENUINE POLICY HOLE = lunarblock ACCEPTS a tx that even DEFAULT Core
#   REJECTS. That is the highest-value finding; the harness FAILs loudly on it
#   (never masked). An over-rejection (Core accepts, lunarblock rejects) and a
#   reject-category mismatch on a genuine-floor case are also failures.
#
# CORPUS (each is the valid signed spend with ONE rule violated):
#   - valid-control      : the clean 1-in/1-out p2wpkh spend          -> ACCEPT
#   - dust               : a 1-sat p2wpkh output on a fee-paying tx   -> "dust"
#   - bare-multisig      : a bare (non-P2SH) 1-of-1 multisig output   -> strict-only
#   - oversize-op_return : an 83-byte OP_RETURN payload (>80)         -> strict-only
#   - bad-version        : nVersion=4 (outside standard {1,2,3})      -> "version"
#   - below-min-relay    : a zero-fee tx (below the min-relay floor)  -> "min relay fee not met"
#
# NORMALIZATION: reject-reason strings are compared by CATEGORY via classify().
#   Core emits the bare token ("dust", "version", "min relay fee not met");
#   lunarblock is Core-faithful but decorates some tokens (e.g.
#   "version: tx version 4 not in [1, 3]", "fee rate too low: .. < 1000 sat/KB").
#   A case PASSES when impl and Core map to the same category.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/spend/lunarblock_spend.sh): no
#   required args, idempotent, trap cleanup, scratch datadirs + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: POLICY lunarblock: PASS dust=ok version=ok min-relay=ok control=accept bare-multisig=.. op_return=..
#   FAIL: POLICY lunarblock: FAIL <short reason> [dust=.. version=.. ...]
#
# Touches ONLY /tmp/policyfleet-lunarblock + /tmp/policyfleet-core-{strict,def}
#   and ports 39948/39968 (lunarblock RPC/P2P), 39942/39962 (strict Core RPC/P2P),
#   39944/39964 (default Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/tx builders)

LB_DATADIR="/tmp/policyfleet-lunarblock"
LB_RPC=39948
LB_P2P=39968
LB_LOG="$LB_DATADIR/node.log"

CORE_DATADIR="/tmp/policyfleet-core-strict"
CORE_RPC=39942
CORE_P2P=39962
CORE_LOG="$CORE_DATADIR/core.log"

CORE_DEF_DATADIR="/tmp/policyfleet-core-def"
CORE_DEF_RPC=39944
CORE_DEF_P2P=39964
CORE_DEF_LOG="$CORE_DEF_DATADIR/core.log"

# Strict-policy flags so EVERY corpus violation rejects on the primary oracle.
CORE_STRICT_FLAGS=(-permitbaremultisig=0 -datacarriersize=80)

# Fixed deterministic test secret (32 bytes) -> one p2wpkh keypair the whole
# corpus is built from. Passed to the Python helper.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=101            # mine to maturity: height-1 coinbase (50 BTC) spendable at tip 101

# lunarblock defaults to an EMPTY rpcpassword on regtest -> RPC auth disabled.
# The helper sends NO Authorization header when the cookie sentinel is "NONE".
LB_COOKIE_SENTINEL="NONE"

LB_PID=""
CORE_BG=""
CORE_DEF_BG=""
HELPER=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[policy:lunarblock] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$LB_PID" ]] && kill -0 "$LB_PID" 2>/dev/null; then
        kill -TERM "-${LB_PID}" 2>/dev/null || kill -TERM "$LB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$LB_PID" 2>/dev/null || break; sleep 1; done
        kill -KILL "-${LB_PID}" 2>/dev/null || kill -KILL "$LB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    "$CORE_CLI" -regtest -datadir="$CORE_DEF_DATADIR" -rpcport="$CORE_DEF_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || "$CORE_CLI" -regtest -datadir="$CORE_DEF_DATADIR" -rpcport="$CORE_DEF_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    [[ -n "$CORE_DEF_BG" ]] && kill "$CORE_DEF_BG" 2>/dev/null || true
    fuser -k "${LB_RPC}/tcp"       2>/dev/null || true
    fuser -k "${LB_P2P}/tcp"       2>/dev/null || true
    fuser -k "${CORE_RPC}/tcp"     2>/dev/null || true
    fuser -k "${CORE_P2P}/tcp"     2>/dev/null || true
    fuser -k "${CORE_DEF_RPC}/tcp" 2>/dev/null || true
    fuser -k "${CORE_DEF_P2P}/tcp" 2>/dev/null || true
    rm -rf "$LB_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <dust> <ver> <minrelay> <control> <bare> <opret>
pass() {
    echo "POLICY lunarblock: PASS dust=$1 version=$2 min-relay=$3 control=$4 bare-multisig=$5 op_return=$6"
    exit 0
}
fail() {
    echo "POLICY lunarblock: FAIL $*"
    exit 1
}

# ── Reject-reason category classifier (the NORMALIZATION map). ────────────
# Maps any impl/Core reject string to a canonical category token. Empty input
# (accepted) -> "accept". Anything unmatched -> "other:<verbatim>".
classify() {
    local s="$1"
    [[ -z "$s" ]] && { echo "accept"; return; }
    local l="${s,,}"
    case "$l" in
        *dust*)                                              echo "dust" ;;
        *bare-multisig*|*"bare multisig"*)                   echo "bare-multisig" ;;
        *datacarrier*|*op_return*|*op-return*|*"scriptpubkey"*nulldata*) echo "datacarrier" ;;
        *"min relay fee"*|*min-relay*|*"minimum relay fee"*|*"mempool min fee"*|*"fee not met"*|*"fee below minimum"*|*"fee rate too low"*|*"fee too low"*) echo "min-relay" ;;
        version*|*"tx version"*|*nversion*|*"version range"*|*"transaction version"*|*"version: tx"*) echo "version" ;;
        *)                                                   echo "other:$s" ;;
    esac
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "policyfleet-lunarblock" 2>/dev/null || true
fuser -k "${LB_RPC}/tcp"       2>/dev/null || true
fuser -k "${LB_P2P}/tcp"       2>/dev/null || true
fuser -k "${CORE_RPC}/tcp"     2>/dev/null || true
fuser -k "${CORE_P2P}/tcp"     2>/dev/null || true
fuser -k "${CORE_DEF_RPC}/tcp" 2>/dev/null || true
fuser -k "${CORE_DEF_P2P}/tcp" 2>/dev/null || true
sleep 1
rm -rf "$LB_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR"
mkdir -p "$LB_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v luajit  >/dev/null 2>&1   || fail "luajit not found on PATH"
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
[[ -f "$LB_DIR/src/main.lua" ]]      || fail "lunarblock src/main.lua not found at $LB_DIR"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || fail "Core test_framework Python imports failed (need key/script/messages/address)"

# ── 2. Write the corpus-builder Python helper. ────────────────────────────
# It connects to ONE node's RPC, mines a coinbase to the fixed key, reads that
# node's OWN height-1 coinbase (coinbase txids differ per impl), builds + SIGNS
# (in Python, via BIP143 SegwitV0SignatureHash — NO wallet dependency) every
# corpus variant against it, runs testmempoolaccept, and prints one
#   CASE <name> <allowed:true|false> <reject-reason>
# tab-separated line per case to stdout. Driven once per node (3 oracles).
#
# Cookie arg: "user:pass" -> Basic auth header. The literal "NONE" -> no auth
# header (lunarblock regtest runs with an empty rpcpassword).
HELPER="$LB_DATADIR/policy_corpus.py"
cat > "$HELPER" <<'PYEOF'
import sys, json, base64, urllib.request
sys.path.insert(0, sys.argv[1])  # test_framework path
RPC_URL   = sys.argv[2]
COOKIE    = sys.argv[3]          # "user:pass" form, or "NONE" for no-auth
SECRET    = sys.argv[4]
NBLOCKS   = int(sys.argv[5])

from test_framework.key import ECKey
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness, COIN
from test_framework.script import (CScript, OP_0, OP_RETURN, OP_CHECKMULTISIG, OP_1, hash160,
    SegwitV0SignatureHash, SIGHASH_ALL, OP_DUP, OP_HASH160, OP_EQUALVERIFY, OP_CHECKSIG)
from test_framework.address import key_to_p2wpkh

_HEADERS = {"Content-Type": "application/json"}
if COOKIE != "NONE":
    _HEADERS["Authorization"] = "Basic " + base64.b64encode(COOKIE.encode()).decode()

_id = [0]
def rpc(method, params=None):
    _id[0] += 1
    body = json.dumps({"jsonrpc":"1.0","id":_id[0],"method":method,"params":params or []}).encode()
    req = urllib.request.Request(RPC_URL, data=body, headers=_HEADERS)
    with urllib.request.urlopen(req, timeout=120) as r:
        d = json.loads(r.read())
    if d.get("error"):
        raise RuntimeError(f"{method} rpc error: {d['error']}")
    return d["result"]

# Deterministic keypair -> p2wpkh address + scriptPubKey.
priv = ECKey(); priv.set(bytes.fromhex(SECRET), compressed=True)
pub  = priv.get_pubkey().get_bytes()
pkh  = hash160(pub)
spk  = CScript([OP_0, pkh])                 # p2wpkh output
addr = key_to_p2wpkh(pub, main=False)       # bcrt1...

# Mine to maturity (this node's own coinbase) and read the height-1 coinbase.
rpc("generatetoaddress", [NBLOCKS, addr])
if int(rpc("getblockcount")) < NBLOCKS:
    print("ERR height did not advance", file=sys.stderr); sys.exit(2)
bh  = rpc("getblockhash", [1])
blk = rpc("getblock", [bh, 2])
cb  = blk["tx"][0]
cb_txid = cb["txid"]
val = int(round(cb["vout"][0]["value"] * COIN))      # 50 BTC in sats
prevout = COutPoint(int(cb_txid, 16), 0)

def signed(outs, version=2):
    """outs = [(value_sat, CScript), ...]; single input = the mature coinbase."""
    tx = CTransaction(); tx.version = version
    tx.vin  = [CTxIn(prevout, b"", 0xffffffff)]
    tx.vout = [CTxOut(v, s) for (v, s) in outs]
    tx.wit.vtxinwit = [CTxInWitness()]
    sc = CScript([OP_DUP, OP_HASH160, pkh, OP_EQUALVERIFY, OP_CHECKSIG])  # BIP143 scriptCode
    sh = SegwitV0SignatureHash(sc, tx, 0, SIGHASH_ALL, val)
    tx.wit.vtxinwit[0].scriptWitness.stack = [priv.sign_ecdsa(sh) + bytes([SIGHASH_ALL]), pub]
    return tx.serialize_with_witness().hex()

def tma(rawhex):
    r = rpc("testmempoolaccept", [[rawhex]])[0]
    allowed = bool(r.get("allowed"))
    reason  = "" if allowed else (r.get("reject-reason") or "rejected")
    return allowed, reason

FEE = 1000  # ~9 sat/vB on the ~110-vbyte control: well above the 0.1 sat/vB floor.
ms  = CScript([OP_1, pub, OP_1, OP_CHECKMULTISIG])  # bare 1-of-1 multisig

corpus = [
    ("valid-control",      signed([(val - FEE, spk)], 2)),
    ("dust",               signed([(1, spk), (val - 1 - FEE, spk)], 2)),
    ("bare-multisig",      signed([(100000, ms), (val - 100000 - FEE, spk)], 2)),
    ("oversize-op_return", signed([(0, CScript([OP_RETURN, b"\xab" * 83])), (val - FEE, spk)], 2)),
    ("bad-version",        signed([(val - FEE, spk)], 4)),
    ("below-min-relay",    signed([(val, spk)], 2)),   # zero fee
]
for name, rawhex in corpus:
    allowed, reason = tma(rawhex)
    safe = reason.replace("\t", " ").replace("\n", " ")
    print(f"CASE\t{name}\t{'true' if allowed else 'false'}\t{safe}")
PYEOF
[[ -s "$HELPER" ]] || fail "failed to write corpus helper"

# ── Launch helper for a Core regtest oracle. ──────────────────────────────
# usage: launch_core <datadir> <rpcport> <p2pport> <logfile> <extra-flags...>
# echoes the background PID on success; returns non-zero on startup error.
launch_core() {
    local dd="$1" rpc="$2" p2p="$3" lf="$4"; shift 4
    "$CORE_BIN" -regtest -datadir="$dd" -rpcport="$rpc" -port="$p2p" \
        -fallbackfee=0.0002 "$@" >"$lf" 2>&1 &
    local bg=$!
    local deadline=$(( $(date +%s) + 60 ))
    while (( $(date +%s) < deadline )); do
        if "$CORE_CLI" -regtest -datadir="$dd" -rpcport="$rpc" getblockcount >/dev/null 2>&1; then
            echo "$bg"; return 0
        fi
        kill -0 "$bg" 2>/dev/null || { tail -n 20 "$lf" >&2 2>/dev/null || true; return 1; }
        sleep 1
    done
    return 1
}

# ── 3. Launch the STRICT Core oracle. ─────────────────────────────────────
log "launching STRICT Core oracle rpc=:$CORE_RPC flags=${CORE_STRICT_FLAGS[*]}"
CORE_BG=$(launch_core "$CORE_DATADIR" "$CORE_RPC" "$CORE_P2P" "$CORE_LOG" "${CORE_STRICT_FLAGS[@]}") \
    || fail "STRICT Core oracle failed to start within 60s (see $CORE_LOG)"
log "STRICT Core oracle ready (pid=$CORE_BG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "STRICT Core cookie not found at $CORE_DATADIR/regtest/.cookie"

# ── 4. Launch the DEFAULT Core oracle (no policy flags). ──────────────────
log "launching DEFAULT Core oracle rpc=:$CORE_DEF_RPC (no policy flags)"
CORE_DEF_BG=$(launch_core "$CORE_DEF_DATADIR" "$CORE_DEF_RPC" "$CORE_DEF_P2P" "$CORE_DEF_LOG") \
    || fail "DEFAULT Core oracle failed to start within 60s (see $CORE_DEF_LOG)"
log "DEFAULT Core oracle ready (pid=$CORE_DEF_BG)"
CORE_DEF_COOKIE=$(cat "$CORE_DEF_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_DEF_COOKIE" ]] || fail "DEFAULT Core cookie not found at $CORE_DEF_DATADIR/regtest/.cookie"

# ── 5. Launch lunarblock on regtest. ──────────────────────────────────────
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

# ── 6. Run the corpus against all three nodes. ────────────────────────────
log "running corpus against STRICT Core oracle"
CORE_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_RPC/" "$CORE_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_LOG")
[[ -n "$CORE_OUT" ]] || { tail -n 30 "$CORE_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for STRICT Core oracle"; }

log "running corpus against DEFAULT Core oracle"
CORE_DEF_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_DEF_RPC/" "$CORE_DEF_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_DEF_LOG")
[[ -n "$CORE_DEF_OUT" ]] || { tail -n 30 "$CORE_DEF_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for DEFAULT Core oracle"; }

log "running corpus against lunarblock"
LB_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$LB_RPC/" "$LB_COOKIE_SENTINEL" "$SECRET" "$NBLOCKS" 2>>"$LB_LOG")
[[ -n "$LB_OUT" ]] || { tail -n 30 "$LB_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for lunarblock"; }

# ── 7. Parse all result sets into name -> allowed / reason. ───────────────
declare -A CORE_ALLOWED CORE_REASON DEF_ALLOWED DEF_REASON LB_ALLOWED LB_REASON
while IFS=$'\t' read -r tag name allowed reason; do
    [[ "$tag" == "CASE" ]] || continue
    CORE_ALLOWED["$name"]="$allowed"; CORE_REASON["$name"]="$reason"
done <<< "$CORE_OUT"
while IFS=$'\t' read -r tag name allowed reason; do
    [[ "$tag" == "CASE" ]] || continue
    DEF_ALLOWED["$name"]="$allowed"; DEF_REASON["$name"]="$reason"
done <<< "$CORE_DEF_OUT"
while IFS=$'\t' read -r tag name allowed reason; do
    [[ "$tag" == "CASE" ]] || continue
    LB_ALLOWED["$name"]="$allowed"; LB_REASON["$name"]="$reason"
done <<< "$LB_OUT"

CASES=(valid-control dust bare-multisig oversize-op_return bad-version below-min-relay)
for c in "${CASES[@]}"; do
    [[ -n "${CORE_ALLOWED[$c]:-}" ]] || fail "STRICT Core oracle missing result for case '$c' (helper output incomplete)"
    [[ -n "${DEF_ALLOWED[$c]:-}"  ]] || fail "DEFAULT Core oracle missing result for case '$c'"
    [[ -n "${LB_ALLOWED[$c]:-}"   ]] || fail "lunarblock missing result for case '$c' (helper output incomplete)"
done

# ── 8. Compare per case against BOTH oracles. Emit a forensic table. ──────
# Per-case status token:
#   ok        lunarblock matches STRICT Core (accept==accept, or both reject same category)
#   parity-d  STRICT Core rejects, DEFAULT Core ACCEPTS, lunarblock ACCEPTS
#             -> lunarblock tracks Core's DEFAULT policy (e.g. v31.99 relaxed
#                bare-multisig + the OP_RETURN cap). NOT a hole; gate is strict-only.
#   HOLE      DEFAULT Core REJECTS but lunarblock ACCEPTS -> a GENUINE policy gap
#             (lunarblock more permissive than even out-of-the-box Core).
#   over      STRICT Core accepts but lunarblock rejects (impl too strict)
#   mism      both reject but the reject CATEGORY differs
log "=== POLICY REJECT-PARITY ==="
log "  primary oracle   = STRICT Core (-permitbaremultisig=0 -datacarriersize=80)"
log "  genuine-floor oracle = DEFAULT Core (out-of-the-box v31.99 relay policy)"
printf '%-20s | %-7s %-7s | %-7s %-44s | %s\n' \
    "case" "C-strict" "C-deflt" "lunar" "lunarblock-reason" "verdict" >&2

declare -A STATUS
HOLES=()          # genuine: DEFAULT Core rejects, lunarblock accepts
PARITY_D=()       # strict-only divergence: lunarblock == DEFAULT Core
NORMALIZED_ANY=0
for c in "${CASES[@]}"; do
    ca="${CORE_ALLOWED[$c]}"; cr="${CORE_REASON[$c]}"     # strict Core
    da="${DEF_ALLOWED[$c]}"                                # default Core (allowed)
    ia="${LB_ALLOWED[$c]}";   ir="${LB_REASON[$c]}"        # lunarblock
    ccat=$(classify "$cr"); icat=$(classify "$ir")
    local_status=""
    if [[ "$ca" == "true" && "$ia" == "true" ]]; then
        local_status="ok"                       # both accept (valid control)
    elif [[ "$ca" == "false" && "$ia" == "false" ]]; then
        if [[ "$ccat" == "$icat" ]]; then
            local_status="ok"
            [[ "$cr" != "$ir" ]] && NORMALIZED_ANY=1
        else
            local_status="mism"
        fi
    elif [[ "$ca" == "false" && "$ia" == "true" ]]; then
        # strict Core rejects, lunarblock accepts -> split on what DEFAULT Core does.
        if [[ "$da" == "false" ]]; then
            local_status="HOLE"                 # default Core ALSO rejects -> genuine hole
            HOLES+=("$c")
        else
            local_status="parity-d"             # default Core accepts -> tracks default
            PARITY_D+=("$c")
        fi
    else
        local_status="over"                     # Core accepts, lunarblock rejects
    fi
    STATUS["$c"]="$local_status"
    printf '%-20s | %-7s %-7s | %-7s %-44s | %s\n' \
        "$c" "$ca" "$da" "$ia" "${ir:- (accepted)}" "$local_status" >&2
done

# ── 9. Map case -> summary token. ─────────────────────────────────────────
tok() {  # tok <case>
    case "${STATUS[$1]}" in
        ok)       echo "ok" ;;
        parity-d) echo "ok-default" ;;     # parity with default-Core (gate is strict-only)
        HOLE)     echo "HOLE-accepts" ;;
        over)     echo "over-rejects" ;;
        mism)     echo "mismatch" ;;
        *)        echo "${STATUS[$1]}" ;;
    esac
}
DUST_T=$(tok dust)
VER_T=$(tok bad-version)
RELAY_T=$(tok below-min-relay)
BARE_T=$(tok bare-multisig)
OPRET_T=$(tok oversize-op_return)
CTRL_S="${STATUS[valid-control]}"

# ── 10. Verdict. ──────────────────────────────────────────────────────────
# The valid-control MUST be accepted by lunarblock (the funded input reaches the
# gate and the clean spend is relayable) — otherwise the harness itself is
# broken (e.g. sighash/funding wrong) and nothing else is trustworthy.
if [[ "$CTRL_S" != "ok" ]]; then
    fail "valid-control not accepted by lunarblock (control=${LB_REASON[valid-control]:-rejected}); harness funding/signing broken — investigate before trusting other cases | dust=$DUST_T version=$VER_T min-relay=$RELAY_T bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Report strict-only divergences (parity with default Core — informational).
if [[ "${#PARITY_D[@]}" -gt 0 ]]; then
    log "strict-only divergences (lunarblock matches DEFAULT Core; reject only under non-default flags): ${PARITY_D[*]}"
    for c in "${PARITY_D[@]}"; do
        log "  parity-default $c: strict-Core='${CORE_REASON[$c]}'  default-Core=ACCEPT  lunarblock=ACCEPT"
    done
fi

# A GENUINE HOLE (default Core rejects, lunarblock accepts) is a real policy gap.
# Per the brief we FAIL loudly + report it (never mask a hole to force green).
if [[ "${#HOLES[@]}" -gt 0 ]]; then
    log "GENUINE POLICY HOLES (DEFAULT Core rejects, lunarblock ACCEPTS): ${HOLES[*]}"
    for c in "${HOLES[@]}"; do
        log "  HOLE $c: Core(strict & default)='${CORE_REASON[$c]}'  lunarblock=ACCEPTED"
    done
    fail "lunarblock accepts $(IFS=,; echo "${HOLES[*]}") that even DEFAULT Core rejects | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Any category mismatch (both reject, different category) is also a failure.
MISM=()
for c in "${CASES[@]}"; do [[ "${STATUS[$c]}" == "mism" ]] && MISM+=("$c"); done
if [[ "${#MISM[@]}" -gt 0 ]]; then
    fail "reject-category mismatch on $(IFS=,; echo "${MISM[*]}") | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# Any over-rejection (Core accepts, lunarblock rejects) is a failure too.
OVER=()
for c in "${CASES[@]}"; do [[ "${STATUS[$c]}" == "over" ]] && OVER+=("$c"); done
if [[ "${#OVER[@]}" -gt 0 ]]; then
    fail "lunarblock over-rejects $(IFS=,; echo "${OVER[*]}") that Core accepts | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

# No genuine holes, no mismatches, no over-rejections, control accepted.
[[ "$NORMALIZED_ANY" -eq 1 ]] && log "note: some cases matched via NORMALIZATION (category-level), not byte-exact strings"
[[ "${#PARITY_D[@]}" -gt 0 ]] && log "note: ${#PARITY_D[@]} case(s) pass as parity-with-default-Core (strict-flag-only gates)"
log "PASS: genuine-floor {dust,version,min-relay} all reject + valid-control accepted; no genuine policy holes"
pass "$DUST_T" "$VER_T" "$RELAY_T" accept "$BARE_T" "$OPRET_T"

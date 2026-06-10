#!/usr/bin/env bash
#
# haskoin_policy.sh — self-contained MEMPOOL/POLICY reject-parity test.
#
# Mirrors test-suite/policy/blockbrew_policy.sh.  Proves haskoin's mempool
# standardness gate: a transaction that violates a relay-policy rule must be
# rejected with the SAME reject-reason CATEGORY Bitcoin Core emits, via
# haskoin's testmempoolaccept RPC, on a REAL SIGNED p2wpkh spend of a mature
# coinbase (so the tx passes input-existence and REACHES the policy gate).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core v31.99) on TWO SEPARATE
#   regtest instances:
#     * STRICT  (-permitbaremultisig=0 -datacarriersize=80): names the canonical
#       reject token per case; every corpus violation rejects here.
#     * DEFAULT (no policy flags): the GENUINE FLOOR. v31.99 relaxed bare-multisig
#       + OP_RETURN to default-accept, so the must-reject floor (rejected by BOTH
#       strict AND default Core) = { dust, bad-version, below-min-relay }, plus
#       the valid-control MUST ACCEPT. bare-multisig + oversize-op_return are
#       strict-flag-only → haskoin ACCEPT on them is parity-with-default-Core.
#
# CORPUS (each = the valid signed spend with ONE rule violated):
#   - valid-control      : clean 1-in/1-out p2wpkh spend          -> ACCEPT
#   - dust               : a 1-sat p2wpkh output on a fee-paying tx-> "dust"        [FLOOR]
#   - bare-multisig      : a bare (non-P2SH) 1-of-1 multisig output-> default ACCEPT
#   - oversize-op_return : an 83-byte OP_RETURN payload (>80)      -> default ACCEPT
#   - bad-version        : nVersion=4 (outside standard {1,2,3})   -> "version"     [FLOOR]
#   - below-min-relay    : a zero-fee tx (below the min-relay floor)-> "min relay fee not met" [FLOOR]
#
# NORMALIZATION: reject reasons compared by CATEGORY via classify(). Core emits
#   the bare token ("dust"/"version"/"min relay fee not met"); haskoin's
#   testmempoolaccept surfaces "dust (output 0)" / "version" / "min-fee-not-met".
#   A case PASSES when impl and Core map to the SAME category.
#
# POLICY HOLE = a case where haskoin ACCEPTS a tx the GENUINE FLOOR (default
#   Core) REJECTS — FAILs loudly (never masked).
#
# Summary line (stdout):
#   PASS: POLICY haskoin: PASS dust=ok version=ok min-relay=ok control=accept bare-multisig=ok-default op_return=ok-default
#   FAIL: POLICY haskoin: FAIL <short reason> [dust=.. version=.. ...]
#
# Touches ONLY /tmp/hk-policy/ + /tmp/hk-policy-core-{strict,def}/ and ports
#   22740/22760 (haskoin RPC/P2P), 22742/22762 (strict Core), 22744/22764 (default Core).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$(find "$BASEDIR/haskoin/dist-newstyle" -name haskoin -type f -executable 2>/dev/null | head -1)"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

export haskoin_datadir="$BASEDIR/haskoin"

HK_DATADIR="/tmp/hk-policy"
HK_RPC=22740
HK_P2P=22760
HK_LOG="$HK_DATADIR/node.log"
HK_URL="http://127.0.0.1:${HK_RPC}"
HK_COOKIE=""

CORE_DATADIR="/tmp/hk-policy-core-strict"
CORE_RPC=22742
CORE_P2P=22762
CORE_LOG="$CORE_DATADIR/core.log"

CORE_DEF_DATADIR="/tmp/hk-policy-core-def"
CORE_DEF_RPC=22744
CORE_DEF_P2P=22764
CORE_DEF_LOG="$CORE_DEF_DATADIR/core.log"

CORE_STRICT_FLAGS=(-permitbaremultisig=0 -datacarriersize=80)
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
NBLOCKS=101            # mine to maturity: height-1 coinbase (50 BTC) spendable at tip 101

HK_PID=""
CORE_BG=""
CORE_DEF_BG=""
HELPER=""

log() { echo "[policy:haskoin] $*" >&2; }

cleanup() {
    local ec=$?
    if [[ -n "$HK_PID" ]] && kill -0 "$HK_PID" 2>/dev/null; then
        kill "$HK_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HK_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HK_PID" 2>/dev/null || true
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
    rm -rf "$HK_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "POLICY haskoin: PASS dust=$1 version=$2 min-relay=$3 control=$4 bare-multisig=$5 op_return=$6"
    exit 0
}
fail() {
    echo "POLICY haskoin: FAIL $*"
    exit 1
}

classify() {
    local s="$1"
    [[ -z "$s" ]] && { echo "accept"; return; }
    local l="${s,,}"
    case "$l" in
        *dust*)                                              echo "dust" ;;
        *bare-multisig*|*"bare multisig"*)                   echo "bare-multisig" ;;
        *datacarrier*|*op_return*|*op-return*|*"scriptpubkey"*nulldata*) echo "datacarrier" ;;
        *"min relay fee"*|*min-relay*|*"min-fee"*|*"minimum relay fee"*|*"mempool min fee"*|*"fee not met"*|*"fee below minimum"*) echo "min-relay" ;;
        version*|*"tx version"*|*nversion*|*"version range"*|*"transaction version"*|*"version out of"*) echo "version" ;;
        *)                                                   echo "other:$s" ;;
    esac
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "hk-policy" 2>/dev/null || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${HK_RPC}|${HK_P2P}|${CORE_RPC}|${CORE_P2P}|${CORE_DEF_RPC}|${CORE_DEF_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${HK_RPC}|${HK_P2P}|${CORE_RPC}|${CORE_P2P}|${CORE_DEF_RPC}|${CORE_DEF_P2P}) "; then
    fail "port ${HK_RPC}/${HK_P2P}/${CORE_RPC}/${CORE_P2P}/${CORE_DEF_RPC}/${CORE_DEF_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$HK_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR"
mkdir -p "$HK_DATADIR" "$CORE_DATADIR" "$CORE_DEF_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || fail "curl not found on PATH"
[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || fail "haskoin binary not found (build with: cabal build exe:haskoin)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"
python3 -c "import sys; sys.path.insert(0,'$TF_PATH'); import test_framework.key, test_framework.script, test_framework.messages, test_framework.address" 2>/dev/null \
    || fail "Core test_framework Python imports failed (need key/script/messages/address)"

# ── 2. Write the corpus-builder Python helper (identical to the fleet sibling). ─
HELPER="$HK_DATADIR/policy_corpus.py"
cat > "$HELPER" <<'PYEOF'
import sys, json, base64, urllib.request
sys.path.insert(0, sys.argv[1])  # test_framework path
RPC_URL   = sys.argv[2]
COOKIE    = sys.argv[3]          # "user:pass" form
SECRET    = sys.argv[4]
NBLOCKS   = int(sys.argv[5])

from test_framework.key import ECKey
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness, COIN
from test_framework.script import (CScript, OP_0, OP_RETURN, OP_CHECKMULTISIG, OP_1, hash160,
    SegwitV0SignatureHash, SIGHASH_ALL, OP_DUP, OP_HASH160, OP_EQUALVERIFY, OP_CHECKSIG)
from test_framework.address import key_to_p2wpkh

AUTH = "Basic " + base64.b64encode(COOKIE.encode()).decode()
_id = [0]
def rpc(method, params=None):
    _id[0] += 1
    body = json.dumps({"jsonrpc":"1.0","id":_id[0],"method":method,"params":params or []}).encode()
    req = urllib.request.Request(RPC_URL, data=body,
        headers={"Authorization":AUTH, "Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=90) as r:
        d = json.loads(r.read())
    if d.get("error"):
        raise RuntimeError(f"{method} rpc error: {d['error']}")
    return d["result"]

priv = ECKey(); priv.set(bytes.fromhex(SECRET), compressed=True)
pub  = priv.get_pubkey().get_bytes()
pkh  = hash160(pub)
spk  = CScript([OP_0, pkh])
addr = key_to_p2wpkh(pub, main=False)

rpc("generatetoaddress", [NBLOCKS, addr])
if int(rpc("getblockcount")) < NBLOCKS:
    print("ERR height did not advance", file=sys.stderr); sys.exit(2)
bh  = rpc("getblockhash", [1])
blk = rpc("getblock", [bh, 2])
cb  = blk["tx"][0]
cb_txid = cb["txid"]
val = int(round(cb["vout"][0]["value"] * COIN))
prevout = COutPoint(int(cb_txid, 16), 0)

def signed(outs, version=2):
    tx = CTransaction(); tx.version = version
    tx.vin  = [CTxIn(prevout, b"", 0xffffffff)]
    tx.vout = [CTxOut(v, s) for (v, s) in outs]
    tx.wit.vtxinwit = [CTxInWitness()]
    sc = CScript([OP_DUP, OP_HASH160, pkh, OP_EQUALVERIFY, OP_CHECKSIG])
    sh = SegwitV0SignatureHash(sc, tx, 0, SIGHASH_ALL, val)
    tx.wit.vtxinwit[0].scriptWitness.stack = [priv.sign_ecdsa(sh) + bytes([SIGHASH_ALL]), pub]
    return tx.serialize_with_witness().hex()

def tma(rawhex):
    r = rpc("testmempoolaccept", [[rawhex]])[0]
    allowed = bool(r.get("allowed"))
    reason  = "" if allowed else (r.get("reject-reason") or "rejected")
    return allowed, reason

FEE = 1000
ms  = CScript([OP_1, pub, OP_1, OP_CHECKMULTISIG])

corpus = [
    ("valid-control",      signed([(val - FEE, spk)], 2)),
    ("dust",               signed([(1, spk), (val - 1 - FEE, spk)], 2)),
    ("bare-multisig",      signed([(100000, ms), (val - 100000 - FEE, spk)], 2)),
    ("oversize-op_return", signed([(0, CScript([OP_RETURN, b"\xab" * 83])), (val - FEE, spk)], 2)),
    ("bad-version",        signed([(val - FEE, spk)], 4)),
    ("below-min-relay",    signed([(val, spk)], 2)),
]
for name, rawhex in corpus:
    allowed, reason = tma(rawhex)
    safe = reason.replace("\t", " ").replace("\n", " ")
    print(f"CASE\t{name}\t{'true' if allowed else 'false'}\t{safe}")
PYEOF
[[ -s "$HELPER" ]] || fail "failed to write corpus helper"

# ── Launch helper for a Core regtest oracle (-listen=0). ──────────────────
launch_core() {
    local dd="$1" rpc="$2" p2p="$3" lf="$4"; shift 4
    "$CORE_BIN" -regtest -datadir="$dd" -rpcport="$rpc" -port="$p2p" \
        -listen=0 -fallbackfee=0.0002 "$@" >"$lf" 2>&1 &
    local bg=$!
    local deadline=$(( $(date +%s) + 120 ))
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
    || fail "STRICT Core oracle failed to start (see $CORE_LOG)"
log "STRICT Core oracle ready (pid=$CORE_BG)"
CORE_COOKIE=$(cat "$CORE_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_COOKIE" ]] || fail "STRICT Core cookie not found at $CORE_DATADIR/regtest/.cookie"

# ── 4. Launch the DEFAULT Core oracle (no policy flags) = genuine floor. ──
log "launching DEFAULT Core oracle rpc=:$CORE_DEF_RPC (no policy flags)"
CORE_DEF_BG=$(launch_core "$CORE_DEF_DATADIR" "$CORE_DEF_RPC" "$CORE_DEF_P2P" "$CORE_DEF_LOG") \
    || fail "DEFAULT Core oracle failed to start (see $CORE_DEF_LOG)"
log "DEFAULT Core oracle ready (pid=$CORE_DEF_BG)"
CORE_DEF_COOKIE=$(cat "$CORE_DEF_DATADIR/regtest/.cookie" 2>/dev/null) || true
[[ -n "$CORE_DEF_COOKIE" ]] || fail "DEFAULT Core cookie not found at $CORE_DEF_DATADIR/regtest/.cookie"

# ── 5. Launch haskoin on regtest (--listen False, RPC-only). ──────────────
log "launching haskoin (regtest) rpc=:$HK_RPC p2p=:$HK_P2P -> $HK_LOG"
"$NODE_BIN" --network Regtest --datadir "$HK_DATADIR" node \
    --rpcport "$HK_RPC" --port "$HK_P2P" --listen False --metricsport 0 \
    >"$HK_LOG" 2>&1 &
HK_PID=$!
log "haskoin pid=$HK_PID"
hk_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < hk_deadline )); do
    if [[ -z "$HK_COOKIE" ]]; then
        for c in "$HK_DATADIR/regtest/.cookie" "$HK_DATADIR/.cookie"; do
            [[ -f "$c" ]] && HK_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HK_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$HK_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "$HK_URL/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$HK_PID" 2>/dev/null || { tail -n 30 "$HK_LOG" >&2 2>/dev/null || true; fail "haskoin exited during startup (see $HK_LOG)"; }
    sleep 1
done
[[ -n "$HK_COOKIE" ]] || fail "haskoin cookie never appeared within 90s"
r=$(curl -s --max-time 5 -u "$HK_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "$HK_URL/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "haskoin RPC never responded within 90s"
log "haskoin RPC ready"

# ── 6. Run the corpus against all three nodes. ────────────────────────────
log "running corpus against STRICT Core oracle"
CORE_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_RPC/" "$CORE_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_LOG")
[[ -n "$CORE_OUT" ]] || { tail -n 30 "$CORE_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for STRICT Core oracle"; }

log "running corpus against DEFAULT Core oracle"
CORE_DEF_OUT=$(python3 "$HELPER" "$TF_PATH" "http://127.0.0.1:$CORE_DEF_RPC/" "$CORE_DEF_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$CORE_DEF_LOG")
[[ -n "$CORE_DEF_OUT" ]] || { tail -n 30 "$CORE_DEF_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for DEFAULT Core oracle"; }

log "running corpus against haskoin"
HK_OUT=$(python3 "$HELPER" "$TF_PATH" "$HK_URL/" "$HK_COOKIE" "$SECRET" "$NBLOCKS" 2>>"$HK_LOG")
[[ -n "$HK_OUT" ]] || { tail -n 30 "$HK_LOG" >&2 2>/dev/null || true; fail "corpus helper produced no output for haskoin"; }

# ── 7. Parse all result sets into name -> allowed / reason. ───────────────
declare -A CORE_ALLOWED CORE_REASON DEF_ALLOWED DEF_REASON HK_ALLOWED HK_REASON
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
    HK_ALLOWED["$name"]="$allowed"; HK_REASON["$name"]="$reason"
done <<< "$HK_OUT"

CASES=(valid-control dust bare-multisig oversize-op_return bad-version below-min-relay)
for c in "${CASES[@]}"; do
    [[ -n "${CORE_ALLOWED[$c]:-}" ]] || fail "STRICT Core oracle missing result for case '$c' (helper output incomplete)"
    [[ -n "${DEF_ALLOWED[$c]:-}"  ]] || fail "DEFAULT Core oracle missing result for case '$c'"
    [[ -n "${HK_ALLOWED[$c]:-}"   ]] || fail "haskoin missing result for case '$c' (helper output incomplete)"
done

# ── 8. Compare per case. Emit a forensic table + collect verdicts. ────────
log "=== POLICY REJECT-PARITY  (primary oracle: STRICT -permitbaremultisig=0 -datacarriersize=80) ==="
log "  GENUINE FLOOR (reject on BOTH strict AND default Core) = { dust, bad-version, below-min-relay }"
printf '%-20s | %-7s %-26s | %-7s | %-7s %-44s | %s\n' \
    "case" "Cstrict" "Cstrict-reason" "Cdeflt" "hask" "haskoin-reason" "verdict" >&2

declare -A STATUS
HOLES=()
NORMALIZED_ANY=0
for c in "${CASES[@]}"; do
    ca="${CORE_ALLOWED[$c]}"; cr="${CORE_REASON[$c]}"
    da="${DEF_ALLOWED[$c]}"
    ia="${HK_ALLOWED[$c]}";   ir="${HK_REASON[$c]}"
    ccat=$(classify "$cr"); icat=$(classify "$ir")
    local_status=""
    if [[ "$ca" == "true" && "$ia" == "true" ]]; then
        local_status="ok"
    elif [[ "$ca" == "false" && "$ia" == "false" ]]; then
        if [[ "$ccat" == "$icat" ]]; then
            local_status="ok"
            [[ "$cr" != "$ir" ]] && NORMALIZED_ANY=1
        else
            local_status="mism"
        fi
    elif [[ "$ca" == "false" && "$ia" == "true" ]]; then
        if [[ "$da" == "false" ]]; then
            local_status="BUG-HOLE"
            HOLES+=("$c")
        else
            local_status="ok-deflt"
        fi
    else
        local_status="over"
    fi
    STATUS["$c"]="$local_status"
    printf '%-20s | %-7s %-26s | %-7s | %-7s %-44s | %s\n' \
        "$c" "$ca" "${cr:- (accepted)}" "$da" "$ia" "${ir:- (accepted)}" "$local_status" >&2
done

# ── 9. Map case -> summary token. ─────────────────────────────────────────
tok() {
    local s="${STATUS[$1]}"
    case "$s" in
        ok)        echo "ok" ;;
        ok-deflt)  echo "ok-default" ;;
        BUG-HOLE)  echo "BUG-HOLE-accepts" ;;
        over)      echo "over-rejects" ;;
        mism)      echo "mismatch" ;;
        *)         echo "$s" ;;
    esac
}
DUST_T=$(tok dust)
VER_T=$(tok bad-version)
RELAY_T=$(tok below-min-relay)
BARE_T=$(tok bare-multisig)
OPRET_T=$(tok oversize-op_return)
CTRL_S="${STATUS[valid-control]}"

# ── 10. Verdict. ──────────────────────────────────────────────────────────
if [[ "$CTRL_S" != "ok" ]]; then
    fail "valid-control not accepted by haskoin (control=${HK_REASON[valid-control]:-rejected}); harness funding/signing broken — investigate before trusting other cases | dust=$DUST_T version=$VER_T min-relay=$RELAY_T bare-multisig=$BARE_T op_return=$OPRET_T"
fi

if [[ "${#HOLES[@]}" -gt 0 ]]; then
    log "GENUINE-FLOOR POLICY HOLES (DEFAULT Core rejects, haskoin ACCEPTS):"
    for c in "${HOLES[@]}"; do
        log "  BUG-HOLE $c: STRICT-Core='${CORE_REASON[$c]}' DEFAULT-Core='${DEF_REASON[$c]}' haskoin=ACCEPTS"
    done
    fail "haskoin accepts $(IFS=,; echo "${HOLES[*]}") that even DEFAULT Core rejects | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

MISM=()
for c in "${CASES[@]}"; do [[ "${STATUS[$c]}" == "mism" ]] && MISM+=("$c"); done
if [[ "${#MISM[@]}" -gt 0 ]]; then
    fail "reject-category mismatch on $(IFS=,; echo "${MISM[*]}") | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

OVER=()
for c in "${CASES[@]}"; do [[ "${STATUS[$c]}" == "over" ]] && OVER+=("$c"); done
if [[ "${#OVER[@]}" -gt 0 ]]; then
    fail "haskoin over-rejects $(IFS=,; echo "${OVER[*]}") that strict Core accepts | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
fi

for c in dust bad-version below-min-relay; do
    [[ "${STATUS[$c]}" == "ok" ]] || \
        fail "genuine-floor case '$c' did not reach 'ok' (status=${STATUS[$c]}) | dust=$DUST_T version=$VER_T min-relay=$RELAY_T control=accept bare-multisig=$BARE_T op_return=$OPRET_T"
done

[[ "$NORMALIZED_ANY" -eq 1 ]] && log "note: some cases matched via NORMALIZATION (category-level), not byte-exact strings"
log "PASS: genuine floor (dust + bad-version + below-min-relay) rejected Core-shaped; valid-control accepted; bare-multisig/op_return = default-Core parity"
pass "$DUST_T" "$VER_T" "$RELAY_T" accept "$BARE_T" "$OPRET_T"

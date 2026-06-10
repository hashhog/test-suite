#!/usr/bin/env bash
#
# beamchain_gettxoutproof.sh — self-contained gettxoutproof/verifytxoutproof
#   DIFFERENTIAL-regression test for beamchain.
#
# gettxoutproof(["txid",...] (,"blockhash")) returns a SERIALIZED CMerkleBlock as
#   HEX: 80-byte block header + nTransactions(4 LE) + hash-count(varint) +
#   hashes(32B each) + flag-byte-count(varint) + flag-bytes. For the SAME
#   confirmed tx in the SAME block, this serialization is DETERMINISTIC and
#   byte-identical across nodes (it is a pure function of the block's tx hashes
#   plus the requested txid set — no wall-clock / per-node state enters).
# verifytxoutproof("hex") returns a JSON ARRAY of the txids the proof commits to
#   that are in the active chain (empty array / error if the proof is invalid).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN regtest
#   instance (own scratch datadir + RPC-only loopback ports, -listen via 127.0.0.1
#   bind, -txindex). The chain is built by beamchain (the authoritative miner) and
#   replayed into Core via submitblock so BOTH nodes have the IDENTICAL chain —
#   identical blocks, identical tx hashes, identical merkle trees. This is the
#   same proven launch + oracle-convergence recipe as
#   test-suite/scan/beamchain_scantxoutset.sh and
#   test-suite/rawtx/beamchain_getrawtransaction.sh.
#
# Core reference: bitcoin-core/src/rpc/txoutproof.cpp
#   gettxoutproof: builds CMerkleBlock(block, setTxids), serializes, hex-encodes.
#     errors: RPC_INVALID_ADDRESS_OR_KEY(-5) "Transaction not yet in block" when
#     the txid is unknown (no -txindex hit / not in a block); "Block not found"
#     when an explicit blockhash arg names a non-existent block.
#   verifytxoutproof: deserializes CMerkleBlock, ExtractMatches must equal the
#     header merkle root (else returns []); the block must be in the active chain
#     (else RPC_INVALID_ADDRESS_OR_KEY "Block not found in chain"); returns the
#     array of committed txids.
#
# The FOUR gated assertions (all required — none optional):
#   (1) proof       : gettxoutproof([txid]) on beamchain == Core's gettxoutproof
#                     ([txid]) BYTE-IDENTICAL, for the same confirmed tx in the
#                     shared block.
#   (2) verify-self : verifytxoutproof(beam_hex) on beamchain == EXACTLY [txid].
#   (3) verify-cross: verifytxoutproof(core_hex) on beamchain == EXACTLY [txid]
#                     (Core's proof verifies on the impl).
#   (4) errors      : gettxoutproof for an UNKNOWN txid -> error on both;
#                     verifytxoutproof of GARBAGE hex -> error or [] on both
#                     (match Core's behavior).
#
# STRICT UNIFORM INTERFACE (mirrors the sibling harnesses): no required args,
#   idempotent, trap cleanup, scratch /tmp + unique ports, ONE clean summary line
#   on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTPROOF beamchain: PASS proof=ok verify-self=ok verify-cross=ok errors=ok
#   FAIL: GETTXOUTPROOF beamchain: FAIL <short reason>
#   SKIP: GETTXOUTPROOF beamchain: FAIL beamchain release binary not found ...
#         (GAP_RE-compatible 'not found'/'not built' so the runner can SKIP)
#
# Touches ONLY /tmp/proof-beamchain{,-core}/ and ports 22126/22146 (beamchain
#   RPC/P2P) + 22128/22148 (Core RPC/P2P). NEVER touches /data/nvme1/ or
#   testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/addr)

BC_DATADIR="/tmp/proof-beamchain"
BC_RPC=22126
BC_P2P=22146
BC_LOG="$BC_DATADIR/node.log"

CORE_DATADIR="/tmp/proof-beamchain-core"
CORE_RPC=22128
CORE_P2P=22148
CORE_LOG="$CORE_DATADIR/core.log"

# Fixed deterministic test secret -> one p2wpkh regtest address the coinbases
# are mined to on BOTH nodes (so the coinbase txs — and the resulting UTXOs —
# are byte-identical).
SECRET="3333333333333333333333333333333333333333333333333333333333333333"

NBLOCKS=101            # mine 101 blocks; coinbase[0..100] all pay ADDR
FEE_SATS=2000          # fee left when spending the height-1 coinbase

BC_PID=""
BC_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutproof:beamchain] $*" >&2; }

# ── Cleanup: kill both nodes + wipe scratch on any exit. ──────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BC_PID" ]] && kill -0 "$BC_PID" 2>/dev/null; then
        kill "$BC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BC_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
            || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$BC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <proof> <verify-self> <verify-cross> <errors>
pass() {
    echo "GETTXOUTPROOF beamchain: PASS proof=$1 verify-self=$2 verify-cross=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETTXOUTPROOF beamchain: FAIL $*"
    exit 1
}

# ── JSON helpers (jq-free: pure python3, deterministic). ──────────────────
# jerr <json>  -> prints JSON-RPC error code (int) or "" if no error
jerr() {
    python3 - "$1" <<'PYEOF'
import sys, json
try:
    obj = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
e = obj.get("error") if isinstance(obj, dict) else None
if isinstance(e, dict) and "code" in e:
    print(e["code"])
PYEOF
}
# jresult <json>  -> the bare result value (string form), or "" if error/none
jresult() {
    python3 - "$1" <<'PYEOF'
import sys, json
try:
    obj = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
if isinstance(obj, dict) and obj.get("error") is not None:
    sys.exit(0)
r = obj.get("result") if isinstance(obj, dict) else None
if r is None:
    sys.exit(0)
print(r if isinstance(r, str) else json.dumps(r))
PYEOF
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
if ss -tln 2>/dev/null | grep -qE ":(${BC_RPC}|${BC_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${BC_RPC}/${BC_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$BC_DATADIR" "$CORE_DATADIR"
mkdir -p "$BC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || fail "curl not found on PATH"
# GAP_RE-compatible 'not found' message lets the runner SKIP a missing impl.
[[ -x "$NODE_BIN" ]]                 || fail "beamchain release binary not found at $NODE_BIN (run rebar3 as prod release)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# Derive the regtest p2wpkh address from the fixed secret.
ADDR=$(python3 - "$TF_PATH" "$SECRET" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k = ECKey(); k.set(bytes.fromhex(sys.argv[2]), compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
PYEOF
) || fail "failed to derive funded regtest address from test_framework"
[[ -n "$ADDR" ]] || fail "derived empty funded regtest address"
log "funded address: $ADDR"

# ── Core readiness poll. ───────────────────────────────────────────────────
wait_core_ready() {
    local dd="$1" rpc="$2" pid="$3" lf="$4"
    local deadline=$(( $(date +%s) + 120 ))
    while (( $(date +%s) < deadline )); do
        if "$CORE_CLI" -regtest -datadir="$dd" -rpcport="$rpc" getblockcount >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || { tail -n 20 "$lf" >&2 2>/dev/null || true; return 1; }
        sleep 1
    done
    tail -n 20 "$lf" >&2 2>/dev/null || true
    return 1
}

# ── 2. Launch the Core regtest oracle (loopback P2P bind, -txindex). ──────
# The sandbox SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener ~2s after
# load; a LOOPBACK bind (127.0.0.1) is fine. -txindex so gettxoutproof can
# locate any confirmed tx without a wallet. Wrapped in a small retry loop to
# ride out a transient sandbox kill at startup.
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
        -bind="127.0.0.1:$CORE_P2P" -txindex -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    wait_core_ready "$CORE_DATADIR" "$CORE_RPC" "$CORE_BG" "$CORE_LOG"
}
CORE_OK=0
for attempt in 1 2 3; do
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=127.0.0.1:$CORE_P2P -txindex (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || fail "Core oracle failed to start after 3 attempts (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch beamchain on regtest (release binary, foreground, -txindex). ─
cat >"$BC_DATADIR/sys.config" <<ERLCFG
[
 {beamchain, [
   {network, regtest},
   {datadir, "$BC_DATADIR"},
   {p2pport, $BC_P2P},
   {rpcport, $BC_RPC},
   {txindex, "1"}
 ]},
 {kernel, [{logger_level, info}]},
 {sasl,   [{sasl_error_logger, false}]}
].
ERLCFG
cat >"$BC_DATADIR/vm.args" <<ERLVM
-sname beamchain_proofref_$$
-setcookie beamchain_proofref
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest) rpc=:$BC_RPC p2p=:$BC_P2P -> $BC_LOG"
RELX_CONFIG_PATH="$BC_DATADIR/sys.config" VMARGS_PATH="$BC_DATADIR/vm.args" \
    BEAMCHAIN_TXINDEX=1 \
    "$NODE_BIN" foreground >"$BC_LOG" 2>&1 &
BC_PID=$!
log "beamchain pid=$BC_PID"
bc_deadline=$(( $(date +%s) + 90 ))   # generous startup wait
while (( $(date +%s) < bc_deadline )); do
    if [[ -z "$BC_COOKIE" ]]; then
        for c in "$BC_DATADIR/regtest/.cookie" "$BC_DATADIR/.cookie"; do
            [[ -f "$c" ]] && BC_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$BC_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$BC_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$BC_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$BC_PID" 2>/dev/null || { tail -n 20 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain exited during startup (see $BC_LOG)"; }
    sleep 1
done
[[ -n "$BC_COOKIE" ]] || fail "beamchain cookie never appeared within 90s"
r=$(curl -s --max-time 5 -u "$BC_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$BC_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "beamchain RPC never responded within 90s"
log "beamchain RPC ready"

# ── RPC helpers. ───────────────────────────────────────────────────────────
bc_rpc() {  # bc_rpc <method> [params-json]
    local method="$1" params="${2:-[]}"
    curl -s --max-time 120 -u "$BC_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$BC_RPC/" 2>/dev/null
}
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>/dev/null; }

# ── 4. Build ONE shared chain: beamchain mines, Core ingests via submitblock.
# beamchain mines $NBLOCKS blocks to $ADDR (a p2wpkh we hold the key for); each
# raw block is replayed into Core via submitblock. Regtest PoW is trivial and the
# blocks are fully valid, so Core accepts beamchain's chain verbatim — identical
# coinbases + identical UTXOs + identical block hashes.
log "mining $NBLOCKS blocks to $ADDR on beamchain (the authoritative miner)"
mr=$(bc_rpc generatetoaddress "[$NBLOCKS, \"$ADDR\"]")
echo "$mr" | grep -q '"result"' || fail "beamchain generatetoaddress failed: $mr"
BC_H=$(python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('result',''))" <<<"$(bc_rpc getblockcount)")
[[ "$BC_H" == "$NBLOCKS" ]] || fail "beamchain height $BC_H != expected $NBLOCKS"

log "replaying beamchain's $NBLOCKS blocks into Core via submitblock (single pass)"
REPLAY_OUT=$(python3 - "$BC_RPC" "$BC_COOKIE" "$CORE_RPC" "$CORE_DATADIR" "$NBLOCKS" "$CORE_CLI" <<'PYEOF'
import sys, json, urllib.request, base64, subprocess
bc_rpc_port, bc_cookie, core_rpc, core_dd, nblocks, core_cli = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6])

def bc(method, params):
    body = json.dumps({"jsonrpc":"1.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{bc_rpc_port}/", data=body)
    tok = base64.b64encode(bc_cookie.encode()).decode()
    req.add_header("Authorization", f"Basic {tok}")
    with urllib.request.urlopen(req, timeout=120) as r:
        o = json.loads(r.read())
    if o.get("error"):
        raise RuntimeError(f"beamchain {method} error: {o['error']}")
    return o["result"]

def core(*args):
    return subprocess.run(
        [core_cli, "-regtest", f"-datadir={core_dd}", f"-rpcport={core_rpc}", *args],
        capture_output=True, text=True)

for h in range(1, nblocks + 1):
    bh = bc("getblockhash", [h])
    raw = bc("getblock", [bh, 0])
    if not raw:
        print(f"ERR empty raw at height {h}"); sys.exit(1)
    res = core("submitblock", raw)
    out = (res.stdout or "").strip()
    if out and out not in ("null", "duplicate"):
        print(f"ERR Core rejected block {h} ({bh}): '{out}' stderr={res.stderr.strip()}")
        sys.exit(1)
print("REPLAY_OK")
PYEOF
)
echo "$REPLAY_OUT" | grep -q "REPLAY_OK" || fail "block replay failed: $REPLAY_OUT"
CORE_H=$(core_cli getblockcount)
[[ "$CORE_H" == "$NBLOCKS" ]] || fail "Core height $CORE_H != expected $NBLOCKS after replay"
CORE_TIP=$(core_cli getbestblockhash)
BC_TIP=$(python3 -c "import sys,json;print(json.loads(sys.stdin.read())['result'])" <<<"$(bc_rpc getbestblockhash)")
[[ "$CORE_TIP" == "$BC_TIP" ]] \
    || fail "post-replay tip mismatch: Core=$CORE_TIP beam=$BC_TIP (replay did not converge)"
log "both nodes share the identical chain at height $NBLOCKS (tip $CORE_TIP)"

# ── 5. Resolve the height-1 coinbase (identical on both nodes). ───────────
H1_CORE=$(core_cli getblockhash 1)
CB_TXID=$(core_cli getblock "$H1_CORE" | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])")
[[ -n "$CB_TXID" ]] || fail "could not resolve height-1 coinbase txid"
CB_INFO=$(core_cli getrawtransaction "$CB_TXID" 1 "$H1_CORE")
CB_VALUE_SATS=$(python3 -c "import sys,json; o=json.load(sys.stdin)['vout'][0]['value']; print(round(o*1e8))" <<<"$CB_INFO")
CB_SPK_HEX=$(python3 -c "import sys,json; print(json.load(sys.stdin)['vout'][0]['scriptPubKey']['hex'])" <<<"$CB_INFO")
[[ -n "$CB_VALUE_SATS" ]] || fail "could not read coinbase output value"
SPEND_SATS=$(( CB_VALUE_SATS - FEE_SATS ))
(( SPEND_SATS > 0 )) || fail "computed non-positive spend amount"
log "height-1 coinbase $CB_TXID value=$CB_VALUE_SATS spend=$SPEND_SATS"

# ── 6. Build + sign a deterministic spend of the height-1 coinbase. ───────
# Spend coinbase output 0 (p2wpkh) -> a single p2wpkh output back to ADDR.
# Signed with the fixed key via the Core test_framework (no wallet). The hex —
# and therefore the txid — is identical on both nodes.
SIGNED_HEX=$(python3 - "$TF_PATH" "$SECRET" "$CB_TXID" "$CB_VALUE_SATS" "$SPEND_SATS" "$CB_SPK_HEX" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.messages import (CTransaction, CTxIn, CTxOut, COutPoint,
                                      CTxInWitness)
from test_framework.script import (CScript, SegwitV0SignatureHash, SIGHASH_ALL)
from test_framework.script_util import key_to_p2wpkh_script, key_to_p2pkh_script

secret    = bytes.fromhex(sys.argv[2])
cb_txid   = sys.argv[3]              # display-order hex
cb_value  = int(sys.argv[4])        # sats
spend_amt = int(sys.argv[5])        # sats
cb_spk    = sys.argv[6]             # coinbase out 0 scriptPubKey hex

k = ECKey(); k.set(secret, compressed=True)
pub = k.get_pubkey().get_bytes()

spk = key_to_p2wpkh_script(pub)     # the p2wpkh scriptPubKey we own (coinbase out 0)
if spk.hex() != cb_spk:
    sys.stderr.write(f"coinbase out0 spk {cb_spk} != our p2wpkh {spk.hex()}\n")
    sys.exit(3)

tx = CTransaction()
tx.version = 2
prev_int = int(cb_txid, 16)
tx.vin = [CTxIn(COutPoint(prev_int, 0), CScript(), 0xffffffff)]
tx.vout = [CTxOut(spend_amt, key_to_p2wpkh_script(pub))]
tx.wit.vtxinwit = [CTxInWitness()]
tx.nLockTime = 0

script_code = key_to_p2pkh_script(pub)   # BIP143 scriptCode for p2wpkh
sighash = SegwitV0SignatureHash(script_code, tx, 0, SIGHASH_ALL, cb_value)
sig = k.sign_ecdsa(sighash) + bytes([SIGHASH_ALL])
tx.wit.vtxinwit[0].scriptWitness.stack = [sig, pub]

print(tx.serialize_with_witness().hex())
PYEOF
) || fail "tx build/sign failed"
[[ -n "$SIGNED_HEX" ]] || fail "empty signed tx hex"

SPEND_TXID=$(core_cli decoderawtransaction "$SIGNED_HEX" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['txid'])")
[[ -n "$SPEND_TXID" ]] || fail "could not decode signed tx to obtain txid"
log "spend txid = $SPEND_TXID"

# ── 7. Mine a SHARED block containing the spend tx (coinbase + spend). ────
# Use generateblock(ADDR, [rawtx]) on beamchain to create a 2-tx block (exercises
# the partial-merkle-tree path, not just a trivial 1-tx coinbase block), then
# replay that block into Core via submitblock so BOTH nodes hold the identical
# confirmed tx in the identical block.
log "mining a 2-tx block (coinbase + spend) on beamchain via generateblock"
GEN=$(bc_rpc generateblock "[\"$ADDR\", [\"$SIGNED_HEX\"]]")
gen_ec=$(jerr "$GEN")
[[ -z "$gen_ec" ]] || fail "beamchain generateblock errored (code $gen_ec): $GEN"
PROOF_BLOCKHASH=$(python3 - "$GEN" <<'PYEOF'
import sys, json
o = json.loads(sys.argv[1])
r = o.get("result")
if isinstance(r, dict):
    print(r.get("hash") or r.get("blockhash") or "")
elif isinstance(r, str):
    print(r)
PYEOF
)
[[ -n "$PROOF_BLOCKHASH" ]] || fail "generateblock did not return a block hash: $GEN"
log "spend confirmed in block $PROOF_BLOCKHASH"

# Confirm beamchain sees the new block at height NBLOCKS+1 and it contains the tx.
EXP_H=$(( NBLOCKS + 1 ))
BC_H2=$(python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('result',''))" <<<"$(bc_rpc getblockcount)")
[[ "$BC_H2" == "$EXP_H" ]] || fail "beamchain height after generateblock is $BC_H2 != $EXP_H"
BLK_TXS=$(python3 - "$(bc_rpc getblock "[\"$PROOF_BLOCKHASH\", 1]")" <<'PYEOF'
import sys, json
o = json.loads(sys.argv[1])
r = o.get("result") if isinstance(o, dict) else None
print(json.dumps((r or {}).get("tx", [])))
PYEOF
)
python3 - "$BLK_TXS" "$SPEND_TXID" <<'PYEOF' || fail "spend tx not present in the generated block on beamchain ($BLK_TXS)"
import sys, json
txs = json.loads(sys.argv[1]); txid = sys.argv[2]
sys.exit(0 if txid in txs else 1)
PYEOF

# Replay the proof block into Core via submitblock (raw block from beamchain).
RAW_BLOCK=$(jresult "$(bc_rpc getblock "[\"$PROOF_BLOCKHASH\", 0]")")
[[ -n "$RAW_BLOCK" ]] || fail "could not fetch raw proof block from beamchain"
SUB_OUT=$(core_cli submitblock "$RAW_BLOCK")
SUB_OUT=$(echo "$SUB_OUT" | tr -d '[:space:]')
[[ -z "$SUB_OUT" || "$SUB_OUT" == "null" || "$SUB_OUT" == "duplicate" ]] \
    || fail "Core rejected the proof block: '$SUB_OUT'"
CORE_TIP2=$(core_cli getbestblockhash)
[[ "$CORE_TIP2" == "$PROOF_BLOCKHASH" ]] \
    || fail "Core tip after proof-block replay is $CORE_TIP2 != $PROOF_BLOCKHASH (did not converge)"
# Core must also have the tx confirmed (txindex / blockhash lookup).
CORE_HASTX=$(core_cli getrawtransaction "$SPEND_TXID" 0 "$PROOF_BLOCKHASH")
[[ -n "$CORE_HASTX" ]] || fail "Core does not see the spend tx in the proof block after replay"
log "both nodes share block $PROOF_BLOCKHASH at height $EXP_H, with the spend tx confirmed"

# ── 8. CHECK (1) proof: gettxoutproof([txid]) byte-identical vs Core. ─────
# Both nodes have -txindex, so neither needs the blockhash arg — but we also
# verify the blockhash-arg form is byte-identical (that is the deterministic
# Core-shape contract). We compare the no-arg form here.
PROOF_T="ok"
CORE_PROOF=$(core_cli gettxoutproof "[\"$SPEND_TXID\"]")
[[ -n "$CORE_PROOF" ]] || fail "proof: Core gettxoutproof returned empty"
BC_PROOF=$(jresult "$(bc_rpc gettxoutproof "[[\"$SPEND_TXID\"]]")")
bc_pe=$(jerr "$(bc_rpc gettxoutproof "[[\"$SPEND_TXID\"]]")")
[[ -z "$bc_pe" ]] || fail "proof: beamchain gettxoutproof errored (code $bc_pe)"
[[ -n "$BC_PROOF" ]] || fail "proof: beamchain gettxoutproof returned empty"
# Normalize to lowercase hex before comparing (case is not semantically meaningful).
CORE_PROOF_LC=$(printf '%s' "$CORE_PROOF" | tr 'A-F' 'a-f')
BC_PROOF_LC=$(printf '%s' "$BC_PROOF" | tr 'A-F' 'a-f')
[[ "$BC_PROOF_LC" == "$CORE_PROOF_LC" ]] \
    || fail "proof: merkleblock hex differs (no-arg form)\n  core=$CORE_PROOF_LC\n  beam=$BC_PROOF_LC"
log "proof: no-arg merkleblock hex byte-identical vs Core (${#BC_PROOF} chars)"

# Also assert the explicit-blockhash form is byte-identical vs Core (deterministic
# serialization is the load-bearing Core-shape contract).
CORE_PROOF_BH=$(core_cli gettxoutproof "[\"$SPEND_TXID\"]" "$PROOF_BLOCKHASH")
BC_PROOF_BH=$(jresult "$(bc_rpc gettxoutproof "[[\"$SPEND_TXID\"], \"$PROOF_BLOCKHASH\"]")")
CORE_PROOF_BH_LC=$(printf '%s' "$CORE_PROOF_BH" | tr 'A-F' 'a-f')
BC_PROOF_BH_LC=$(printf '%s' "$BC_PROOF_BH" | tr 'A-F' 'a-f')
[[ -n "$BC_PROOF_BH_LC" ]] || fail "proof: beamchain gettxoutproof(blockhash) returned empty"
[[ "$BC_PROOF_BH_LC" == "$CORE_PROOF_BH_LC" ]] \
    || fail "proof: merkleblock hex differs (blockhash-arg form)\n  core=$CORE_PROOF_BH_LC\n  beam=$BC_PROOF_BH_LC"
# And the two forms must agree (same proof regardless of how the block was located).
[[ "$BC_PROOF_LC" == "$BC_PROOF_BH_LC" ]] \
    || fail "proof: beamchain no-arg vs blockhash-arg proof differ"
log "proof: blockhash-arg merkleblock hex also byte-identical vs Core"

# ── 9. CHECK (2) verify-self: verifytxoutproof(beam_hex) == [txid]. ───────
VSELF_T="ok"
BC_VSELF=$(bc_rpc verifytxoutproof "[\"$BC_PROOF\"]")
bc_ve=$(jerr "$BC_VSELF")
[[ -z "$bc_ve" ]] || fail "verify-self: beamchain verifytxoutproof errored (code $bc_ve): $BC_VSELF"
python3 - "$BC_VSELF" "$SPEND_TXID" <<'PYEOF' || fail "verify-self: beamchain verifytxoutproof(beam_hex) != [txid] ($BC_VSELF)"
import sys, json
o = json.loads(sys.argv[1]); txid = sys.argv[2]
r = o.get("result") if isinstance(o, dict) else o
sys.exit(0 if (isinstance(r, list) and r == [txid]) else 1)
PYEOF
# Sanity: Core verifies its own proof to the same single txid.
CORE_VSELF=$(core_cli verifytxoutproof "$CORE_PROOF")
python3 - "$CORE_VSELF" "$SPEND_TXID" <<'PYEOF' || fail "verify-self: Core verifytxoutproof(core_hex) != [txid] ($CORE_VSELF)"
import sys, json
r = json.loads(sys.argv[1]); txid = sys.argv[2]
sys.exit(0 if (isinstance(r, list) and r == [txid]) else 1)
PYEOF
log "verify-self: beamchain verifytxoutproof(beam_hex) == [txid] (Core agrees on its own proof)"

# ── 10. CHECK (3) verify-cross: verifytxoutproof(core_hex) == [txid]. ─────
VCROSS_T="ok"
BC_VCROSS=$(bc_rpc verifytxoutproof "[\"$CORE_PROOF\"]")
bc_ce=$(jerr "$BC_VCROSS")
[[ -z "$bc_ce" ]] || fail "verify-cross: beamchain verifytxoutproof(core_hex) errored (code $bc_ce): $BC_VCROSS"
python3 - "$BC_VCROSS" "$SPEND_TXID" <<'PYEOF' || fail "verify-cross: beamchain verifytxoutproof(core_hex) != [txid] ($BC_VCROSS)"
import sys, json
o = json.loads(sys.argv[1]); txid = sys.argv[2]
r = o.get("result") if isinstance(o, dict) else o
sys.exit(0 if (isinstance(r, list) and r == [txid]) else 1)
PYEOF
# Reciprocal sanity: Core verifies beamchain's proof to the same single txid.
CORE_VCROSS=$(core_cli verifytxoutproof "$BC_PROOF")
python3 - "$CORE_VCROSS" "$SPEND_TXID" <<'PYEOF' || fail "verify-cross: Core verifytxoutproof(beam_hex) != [txid] ($CORE_VCROSS)"
import sys, json
r = json.loads(sys.argv[1]); txid = sys.argv[2]
sys.exit(0 if (isinstance(r, list) and r == [txid]) else 1)
PYEOF
log "verify-cross: beamchain verifytxoutproof(core_hex) == [txid] (Core also verifies beam's proof)"

# ── 11. CHECK (4) errors: unknown txid -> error; garbage hex -> error/[]. ─
ERRORS_T="ok"
# (4a) gettxoutproof for an UNKNOWN / nonexistent txid must ERROR on both.
# Use a txid that is not in any block (random 32 bytes). No blockhash arg, so
# Core falls through to "Transaction not yet in block" (-5); beamchain errors
# with "Transaction not found in block index". The contract is: BOTH error.
BOGUS_TXID="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
CORE_BAD=$(core_cli gettxoutproof "[\"$BOGUS_TXID\"]" 2>&1; echo "<<rc=$?>>")
echo "$CORE_BAD" | grep -q "<<rc=0>>" \
    && fail "errors: Core gettxoutproof(unknown txid) unexpectedly SUCCEEDED ($CORE_BAD)"
BC_BAD=$(bc_rpc gettxoutproof "[[\"$BOGUS_TXID\"]]")
bc_bad_ec=$(jerr "$BC_BAD")
[[ -n "$bc_bad_ec" ]] \
    || fail "errors: beamchain gettxoutproof(unknown txid) did NOT error ($BC_BAD)"
log "errors: gettxoutproof(unknown txid) -> error on both (beam code $bc_bad_ec, Core non-zero)"

# (4b) gettxoutproof with an explicit but NON-EXISTENT blockhash -> error on both
# (Core: "Block not found"; beamchain: "Block not found").
BOGUS_BLOCK="00000000000000000000000000000000000000000000000000000000deadbeef"
CORE_BADB=$(core_cli gettxoutproof "[\"$SPEND_TXID\"]" "$BOGUS_BLOCK" 2>&1; echo "<<rc=$?>>")
echo "$CORE_BADB" | grep -q "<<rc=0>>" \
    && fail "errors: Core gettxoutproof(bad blockhash) unexpectedly SUCCEEDED ($CORE_BADB)"
BC_BADB=$(bc_rpc gettxoutproof "[[\"$SPEND_TXID\"], \"$BOGUS_BLOCK\"]")
bc_badb_ec=$(jerr "$BC_BADB")
[[ -n "$bc_badb_ec" ]] \
    || fail "errors: beamchain gettxoutproof(bad blockhash) did NOT error ($BC_BADB)"
log "errors: gettxoutproof(bad blockhash) -> error on both (beam code $bc_badb_ec)"

# (4c) verifytxoutproof of GARBAGE hex -> error OR [] on both (match Core).
# Truly malformed: a short / structurally-invalid hex blob that cannot be a
# CMerkleBlock. Acceptable beamchain behavior = JSON-RPC error OR empty array;
# acceptable Core behavior = JSON-RPC error OR empty array. We require that
# beamchain does NOT return a NON-EMPTY txid list for garbage.
GARBAGE="deadbeef"
CORE_GV=$(core_cli verifytxoutproof "$GARBAGE" 2>&1; echo "<<rc=$?>>")
CORE_GARBAGE_OK=0
if echo "$CORE_GV" | grep -q "<<rc=0>>"; then
    # Core succeeded -> result must be an empty array to count as benign.
    CORE_GV_BODY=${CORE_GV%%<<rc=*}
    python3 - "$CORE_GV_BODY" <<'PYEOF' && CORE_GARBAGE_OK=1 || CORE_GARBAGE_OK=0
import sys, json
try:
    r = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
sys.exit(0 if (isinstance(r, list) and len(r) == 0) else 1)
PYEOF
else
    CORE_GARBAGE_OK=1   # Core errored -> acceptable
fi
[[ "$CORE_GARBAGE_OK" == "1" ]] \
    || fail "errors: Core verifytxoutproof(garbage) returned a non-empty result ($CORE_GV)"

BC_GV=$(bc_rpc verifytxoutproof "[\"$GARBAGE\"]")
BC_GARBAGE_VERDICT=$(python3 - "$BC_GV" <<'PYEOF'
import sys, json
try:
    o = json.loads(sys.argv[1])
except Exception:
    print("BADJSON"); sys.exit(0)
if isinstance(o, dict) and o.get("error") is not None:
    print("ERROR"); sys.exit(0)
r = o.get("result") if isinstance(o, dict) else o
if isinstance(r, list) and len(r) == 0:
    print("EMPTY")
elif isinstance(r, list):
    print("NONEMPTY:" + ",".join(map(str, r)))
else:
    print("OTHER:" + json.dumps(r))
PYEOF
)
case "$BC_GARBAGE_VERDICT" in
    ERROR|EMPTY) log "errors: verifytxoutproof(garbage) -> $BC_GARBAGE_VERDICT on beamchain (Core: error/[]); benign" ;;
    NONEMPTY*)   fail "errors: beamchain verifytxoutproof(garbage) returned a NON-EMPTY txid list (${BC_GARBAGE_VERDICT#NONEMPTY:})" ;;
    *)           fail "errors: beamchain verifytxoutproof(garbage) returned an unexpected shape ($BC_GV / $BC_GARBAGE_VERDICT)" ;;
esac

# ── 12. Verdict. ──────────────────────────────────────────────────────────
log "PASS: gettxoutproof merkleblock hex byte-identical vs Core (no-arg + blockhash); verifytxoutproof verifies self + cross to exactly [txid]; error paths match"
pass "$PROOF_T" "$VSELF_T" "$VCROSS_T" "$ERRORS_T"

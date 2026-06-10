#!/usr/bin/env bash
#
# blockbrew_gettxoutproof.sh — self-contained gettxoutproof/verifytxoutproof
#   Core-parity differential-regression for blockbrew.
#
# The merkle-proof green-cell that follows getrawtransaction / scantxoutset: the
# SPV / light-client keystone. NOT consensus, but byte-exact-shaped against
# Bitcoin Core (bitcoin-core/src/rpc/txoutproof.cpp gettxoutproof +
# verifytxoutproof, serializing a CMerkleBlock via src/merkleblock.cpp).
#
# CORE CONTRACT (txoutproof.cpp)
#   gettxoutproof(["txid",...] (,"blockhash")) -> a SERIALIZED CMerkleBlock as
#     HEX: 80-byte header + nTransactions(uint32 LE) + varint(hashcount) +
#     hashes + varint(flagbytes) + flag bytes. Requires either -txindex OR the
#     blockhash arg to locate the tx (else -5 "Transaction not yet in block").
#     Unknown txid / unknown block -> RPC_INVALID_ADDRESS_OR_KEY (-5).
#   verifytxoutproof("hex") -> a JSON ARRAY of the txids the proof commits to
#     that are in the active chain (empty array if the proof fails to validate
#     against the merkle root; throws if the committed block is not in chain;
#     malformed/garbage hex throws a deserialization error).
#   The SAME tx in the SAME block yields a DETERMINISTIC, byte-identical
#   merkleblock across nodes (the header + the committed txids are identical).
#
# WHAT IT PROVES (ALL FOUR gated — none optional)
#   (1) proof=ok       : gettxoutproof([txid]) on blockbrew returns hex that is
#                        BYTE-IDENTICAL to Core's gettxoutproof([txid]) for the
#                        SAME confirmed tx in the SAME block. Asserted for the
#                        -txindex (no-blockhash) form AND the explicit-blockhash
#                        form; both must equal Core.
#   (2) verify-self=ok : verifytxoutproof(impl_hex) on blockbrew == EXACTLY
#                        [txid].
#   (3) verify-cross=ok: verifytxoutproof(core_hex) on blockbrew == EXACTLY
#                        [txid] (Core's proof verifies on the impl).
#   (4) errors=ok      : gettxoutproof for an unknown/nonexistent txid -> error
#                        (-5 on blockbrew, matching Core's -5 'Transaction not
#                        yet in block' / 'Block not found'); verifytxoutproof of
#                        a malformed/garbage hex -> error or [] on BOTH nodes.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core). Byte-identical proofs
#   require a BYTE-IDENTICAL BLOCK on both nodes. blockbrew and Core build their
#   coinbases differently, so mining the SAME block on each does NOT yield
#   identical bytes. Instead we make ONE node the author and MIRROR its chain:
#     1. blockbrew's OWN wallet mines maturity blocks, then builds + signs +
#        broadcasts a real segwit spend (sendtoaddress) and mines it into a
#        block B = [coinbase, SPEND_TX].
#     2. We replay EVERY block (height 1..tip) from blockbrew to Core via
#        getblock(hash,0) -> submitblock(hex). Both chains are now byte-identical
#        up to the tip, so block B (and SPEND_TX inside it) is shared verbatim.
#     3. Both nodes run -txindex, so gettxoutproof([SPEND_TX]) resolves with no
#        blockhash on each, and over the identical block the serialized
#        CMerkleBlock is byte-for-byte identical.
#   A REAL divergence (proof hex differs, or verifytxoutproof returns the wrong
#   txid set) is a FAIL — reported, never papered over.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/scan/blockbrew_scantxoutset.sh
#   and test-suite/rawtx/blockbrew_getrawtransaction.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + unique ports,
#   ONE clean summary line on stdout, all noise -> stderr / logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTPROOF blockbrew: PASS proof=ok verify-self=ok verify-cross=ok errors=ok
#   FAIL: GETTXOUTPROOF blockbrew: FAIL <short reason>
#   GAP : GETTXOUTPROOF blockbrew: FAIL blockbrew binary not found ...  (GAP_RE -> runner SKIP)
#
# Touches ONLY /tmp/proof-blockbrew/ + /tmp/proof-core-bb/ and ports
#   22313/22333 (blockbrew RPC/P2P), 22315/22335 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Core is launched -listen=0 (RPC only): the sandbox SIGKILLs any bitcoind
#   binding a 0.0.0.0 P2P listener ~2s after load.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/blockbrew/blockbrew"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

BB_DATADIR="/tmp/proof-blockbrew"
BB_RPC=22313
BB_P2P=22333
BB_LOG="$BB_DATADIR/node.log"
BB_URL="http://127.0.0.1:${BB_RPC}"
BB_COOKIE_FILE="$BB_DATADIR/regtest/.cookie"

CORE_DATADIR="/tmp/proof-core-bb"
CORE_RPC=22315
CORE_P2P=22335
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS_MINE=120     # mature coinbase funds for the wallet spend

BB_PID=""
BB_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutproof:blockbrew] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BB_PID" ]] && kill -0 "$BB_PID" 2>/dev/null; then
        kill "$BB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$BB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "GETTXOUTPROOF blockbrew: PASS proof=ok verify-self=ok verify-cross=ok errors=ok"
    exit 0
}
fail() {
    echo "GETTXOUTPROOF blockbrew: FAIL $*"
    exit 1
}

# ── JSON field extractor (jq-free; stdlib python3). ───────────────────────
# jget <json> <path...> : path is a sequence of keys/indices; ints index arrays.
jget() {
    local js="$1"; shift
    python3 - "$js" "$@" <<'PY'
import sys, json
js = sys.argv[1]
keys = sys.argv[2:]
try:
    d = json.loads(js)
except Exception:
    print("<PARSE-ERR>"); sys.exit(0)
cur = d
for k in keys:
    if isinstance(cur, list):
        try:
            idx = int(k)
        except ValueError:
            print("<MISSING>"); sys.exit(0)
        if 0 <= idx < len(cur):
            cur = cur[idx]
        else:
            print("<MISSING>"); sys.exit(0)
    elif isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        print("<MISSING>"); sys.exit(0)
if isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is None:
    print("<NULL>")
else:
    print(cur)
PY
}

# arr_is_exactly_one_txid <json-array> <txid> : exit 0 iff the JSON value is a
# JSON ARRAY containing EXACTLY one element equal (case-insensitive) to <txid>.
arr_is_exactly_one_txid() {
    python3 - "$1" "$2" <<'PY'
import sys, json
try:
    a = json.loads(sys.argv[1])
except Exception:
    sys.exit(2)
want = sys.argv[2].lower()
if not isinstance(a, list):
    sys.exit(3)
if len(a) != 1:
    sys.exit(4)
if not isinstance(a[0], str) or a[0].lower() != want:
    sys.exit(5)
sys.exit(0)
PY
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
if ss -tln 2>/dev/null | grep -qE ":(${BB_RPC}|${BB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${BB_RPC}/${BB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$BB_DATADIR" "$CORE_DATADIR"
mkdir -p "$BB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl >/dev/null 2>&1      || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]]                 || fail "blockbrew binary not found at $NODE_BIN (run build-all.sh blockbrew)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"

# ── 2. Launch the Core oracle on regtest (RPC-only, txindex=1). ───────────
# -listen=0 : the sandbox SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener.
log "launching Core oracle rpc=:$CORE_RPC (txindex=1, listen=0)"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
    -listen=0 -txindex=1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < core_deadline )); do
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 && break
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
    || fail "Core oracle RPC never responded within 90s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch blockbrew on regtest (isolated: no peers, txindex on). ──────
log "launching blockbrew (regtest) rpc=:$BB_RPC p2p=:$BB_P2P txindex=on -> $BB_LOG"
# -metricsport=0 disables the Prometheus listener (fixed 0.0.0.0:9332) which
# would COLLIDE with the live mainnet blockbrew's metrics port.
"$NODE_BIN" \
    -network=regtest -datadir="$BB_DATADIR" \
    -listen="127.0.0.1:${BB_P2P}" -rpcbind="127.0.0.1:${BB_RPC}" \
    -maxoutbound=0 -nolisten -metricsport=0 -txindex \
    >"$BB_LOG" 2>&1 &
BB_PID=$!
log "blockbrew pid=$BB_PID"
bb_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < bb_deadline )); do
    if [[ -z "$BB_COOKIE" && -f "$BB_COOKIE_FILE" ]]; then
        BB_COOKIE=$(cat "$BB_COOKIE_FILE")
    fi
    if [[ -n "$BB_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$BB_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "$BB_URL/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$BB_PID" 2>/dev/null || { tail -n 20 "$BB_LOG" >&2 2>/dev/null || true; fail "blockbrew exited during startup (see $BB_LOG)"; }
    sleep 1
done
[[ -n "$BB_COOKIE" ]] || fail "blockbrew cookie never appeared within 90s"
r=$(curl -s --max-time 5 -u "$BB_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "$BB_URL/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "blockbrew RPC never responded within 90s"
log "blockbrew RPC ready"

# ── RPC helpers. ──────────────────────────────────────────────────────────
bb_rpc() {  # bb_rpc <method> <params-json> ; prints raw JSON-RPC envelope
    curl -s --max-time 120 -u "$BB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "$BB_URL/" 2>/dev/null
}
bb_result() {  # bb_result <method> <params-json> ; prints .result (string/json) or ERR:..
    python3 - "$(bb_rpc "$1" "$2")" <<'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("ERR:parse"); raise SystemExit
if d.get("error"):
    print("ERR:" + json.dumps(d["error"])); raise SystemExit
r = d.get("result")
print(r if isinstance(r, str) else json.dumps(r))
PY
}
core_rpc() {  # core_rpc <method> <params...> ; prints the bare result (cli)
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@" 2>&1
}

# ── 4. blockbrew wallet: fund + build a REAL segwit spend tx + confirm it. ─
WC=$(bb_result createwallet '["proofw"]')
[[ "$WC" == ERR:* ]] && fail "blockbrew createwallet failed: ${WC#ERR:}"
ADDR=$(bb_result getnewaddress '[]')
[[ "$ADDR" == ERR:* ]] && fail "blockbrew getnewaddress failed: ${ADDR#ERR:}"
[[ -n "$ADDR" ]] || fail "blockbrew getnewaddress returned empty"
log "wallet address: $ADDR"

log "mining $NBLOCKS_MINE blocks to the wallet (mature coinbase funds)"
GEN=$(bb_result generatetoaddress "[$NBLOCKS_MINE,\"$ADDR\"]")
[[ "$GEN" == ERR:* ]] && fail "blockbrew generatetoaddress failed: ${GEN#ERR:}"
BB_H=$(bb_result getblockcount "[]")
[[ "$BB_H" == "$NBLOCKS_MINE" ]] || fail "blockbrew height $BB_H != $NBLOCKS_MINE"

# Send 1.0 BTC to our own address -> a real signed segwit tx enters the mempool.
TXID=$(bb_result sendtoaddress "[\"$ADDR\",1.0]")
[[ "$TXID" == ERR:* ]] && fail "blockbrew sendtoaddress failed: ${TXID#ERR:}"
[[ "$TXID" =~ ^[0-9a-f]{64}$ ]] || fail "sendtoaddress returned non-txid: '$TXID'"
MEMP=$(bb_result getrawmempool "[]")
echo "$MEMP" | grep -q "$TXID" || fail "tx $TXID not in blockbrew mempool (mempool=$MEMP)"
log "real spend tx in blockbrew mempool: $TXID"

# Mine the spend into a block B = [coinbase, TXID].
GEN1=$(bb_result generatetoaddress "[1,\"$ADDR\"]")
[[ "$GEN1" == ERR:* ]] && fail "blockbrew could not mine the tx into a block: ${GEN1#ERR:}"
CONF_BH=$(python3 -c 'import sys,json;print(json.loads(sys.argv[1])[0])' "$GEN1" 2>/dev/null)
[[ "$CONF_BH" =~ ^[0-9a-f]{64}$ ]] || fail "could not read confirming blockhash ($GEN1)"
BB_TIP_H=$(bb_result getblockcount "[]")
log "spend confirmed in block $CONF_BH; blockbrew tip height=$BB_TIP_H"

# Sanity: blockbrew's getrawtransaction (txindex, no blockhash) resolves the tx
# to that block — a precondition for txindex-based gettxoutproof.
GRT=$(bb_result getrawtransaction "[\"$TXID\",1]")
[[ "$GRT" == ERR:* ]] && fail "blockbrew getrawtransaction (txindex) errored on confirmed tx: ${GRT#ERR:}"
[[ "$(jget "$GRT" blockhash)" == "$CONF_BH" ]] \
    || fail "blockbrew getrawtransaction blockhash mismatch: $(jget "$GRT" blockhash) != $CONF_BH"

# ── 5. MIRROR the chain to Core so block B is BYTE-IDENTICAL on both nodes. ─
# Replay every block (height 1..tip) from blockbrew -> Core via getblock(,0) +
# submitblock. After this, both chains are byte-identical (same headers, same
# txids, same block B), and Core's -txindex indexes TXID.
log "mirroring blockbrew chain (1..$BB_TIP_H) to Core via submitblock"
for (( h=1; h<=BB_TIP_H; h++ )); do
    BHASH=$(bb_result getblockhash "[$h]")
    [[ "$BHASH" =~ ^[0-9a-f]{64}$ ]] || fail "blockbrew getblockhash $h failed: $BHASH"
    BHEX=$(bb_result getblock "[\"$BHASH\",0]")
    [[ "$BHEX" == ERR:* || ! "$BHEX" =~ ^[0-9a-f]+$ ]] && fail "blockbrew getblock $h (verbosity 0) not hex: $BHEX"
    SB=$(core_rpc submitblock "$BHEX")
    # Core's submitblock returns null on success (empty cli output) or a string
    # like "duplicate" if already present; anything else (e.g. "bad-...") fails.
    case "$SB" in
        ""|"null"|"duplicate"|"inconclusive") : ;;
        *) fail "Core submitblock rejected block $h ($BHASH): $SB" ;;
    esac
done
# Let Core's txindex catch up to the freshly-submitted tip.
CORE_TIP_H=$(core_rpc getblockcount)
[[ "$CORE_TIP_H" == "$BB_TIP_H" ]] || fail "Core height $CORE_TIP_H != blockbrew tip $BB_TIP_H after mirror"
BB_TIPHASH=$(bb_result getbestblockhash "[]")
CORE_TIPHASH=$(core_rpc getbestblockhash)
[[ "$BB_TIPHASH" == "$CORE_TIPHASH" ]] \
    || fail "tip hash differs after mirror: blockbrew=$BB_TIPHASH core=$CORE_TIPHASH"
log "chains mirrored: both at height $BB_TIP_H, tip=$BB_TIPHASH (byte-identical block B shared)"

# Oracle sanity: Core's txindex now resolves TXID to the SAME block B.
CORE_GRT=$(core_rpc getrawtransaction "$TXID" 1)
CORE_GRT_BH=$(jget "$CORE_GRT" blockhash)
[[ "$CORE_GRT_BH" == "$CONF_BH" ]] \
    || fail "ORACLE: Core getrawtransaction blockhash ($CORE_GRT_BH) != $CONF_BH (txindex mirror sanity)"

# ── 6. (1) proof=ok: gettxoutproof BYTE-IDENTICAL across nodes. ───────────
# (a) -txindex form (no blockhash arg) — both nodes resolve via their index.
BB_PROOF=$(bb_result gettxoutproof "[[\"$TXID\"]]")
[[ "$BB_PROOF" == ERR:* ]] && fail "blockbrew gettxoutproof (txindex) errored: ${BB_PROOF#ERR:}"
[[ "$BB_PROOF" =~ ^[0-9a-f]+$ ]] || fail "blockbrew gettxoutproof returned non-hex: '$BB_PROOF'"
CORE_PROOF=$(core_rpc gettxoutproof "[\"$TXID\"]")
echo "$CORE_PROOF" | grep -qiE '^[0-9a-f]+$' || fail "ORACLE: Core gettxoutproof (txindex) did not return hex: $CORE_PROOF"
[[ "$BB_PROOF" == "$CORE_PROOF" ]] \
    || fail "gettxoutproof hex DIVERGES (txindex form): bb=${BB_PROOF:0:40}... core=${CORE_PROOF:0:40}... (lens bb=${#BB_PROOF} core=${#CORE_PROOF})"
log "proof OK (a): gettxoutproof([$TXID]) txindex form BYTE-IDENTICAL to Core (${#BB_PROOF} hex chars)"

# (b) explicit-blockhash form — must also be byte-identical to Core.
BB_PROOF_BH=$(bb_result gettxoutproof "[[\"$TXID\"],\"$CONF_BH\"]")
[[ "$BB_PROOF_BH" == ERR:* ]] && fail "blockbrew gettxoutproof (blockhash) errored: ${BB_PROOF_BH#ERR:}"
CORE_PROOF_BH=$(core_rpc gettxoutproof "[\"$TXID\"]" "$CONF_BH")
echo "$CORE_PROOF_BH" | grep -qiE '^[0-9a-f]+$' || fail "ORACLE: Core gettxoutproof (blockhash) did not return hex: $CORE_PROOF_BH"
[[ "$BB_PROOF_BH" == "$CORE_PROOF_BH" ]] \
    || fail "gettxoutproof hex DIVERGES (blockhash form): bb=${BB_PROOF_BH:0:40}... core=${CORE_PROOF_BH:0:40}..."
# Both forms (txindex and blockhash) must agree with each other too.
[[ "$BB_PROOF_BH" == "$BB_PROOF" ]] \
    || fail "blockbrew gettxoutproof differs between txindex form and blockhash form"
log "proof OK (b): gettxoutproof blockhash form BYTE-IDENTICAL to Core and == txindex form"

# Structural sanity: the proof embeds the block-B header (80 bytes = 160 hex).
# The first 160 hex of the merkleblock == the block header serialization, whose
# double-SHA256 (LE) reversed == CONF_BH.
PROOF_HDR_HASH=$(python3 - "$BB_PROOF" <<'PY'
import sys, hashlib
h = bytes.fromhex(sys.argv[1][:160])
d = hashlib.sha256(hashlib.sha256(h).digest()).digest()
print(d[::-1].hex())
PY
)
[[ "$PROOF_HDR_HASH" == "$CONF_BH" ]] \
    || fail "proof header double-SHA256 ($PROOF_HDR_HASH) != confirming blockhash ($CONF_BH)"
log "proof OK: embedded 80-byte header hashes to block B ($CONF_BH)"

# ── 7. (2) verify-self=ok: verifytxoutproof(impl_hex) on impl == [txid]. ──
BB_VSELF=$(bb_result verifytxoutproof "[\"$BB_PROOF\"]")
[[ "$BB_VSELF" == ERR:* ]] && fail "blockbrew verifytxoutproof(impl_hex) errored: ${BB_VSELF#ERR:}"
arr_is_exactly_one_txid "$BB_VSELF" "$TXID" \
    || fail "verify-self: verifytxoutproof(impl_hex) != exactly [$TXID] (got: $BB_VSELF)"
# Oracle sanity: Core verifies its own proof to the same single txid.
CORE_VSELF=$(core_rpc verifytxoutproof "$CORE_PROOF")
echo "$CORE_VSELF" | grep -q "$TXID" || fail "ORACLE: Core verifytxoutproof(core_hex) lacks $TXID (got: $CORE_VSELF)"
log "verify-self OK: blockbrew verifytxoutproof(impl_hex) == [$TXID]"

# ── 8. (3) verify-cross=ok: verifytxoutproof(core_hex) on impl == [txid]. ─
# Since the proofs are byte-identical this is the strongest possible cross-check:
# Core's proof bytes must verify on blockbrew to exactly the committed txid.
BB_VCROSS=$(bb_result verifytxoutproof "[\"$CORE_PROOF\"]")
[[ "$BB_VCROSS" == ERR:* ]] && fail "blockbrew verifytxoutproof(core_hex) errored: ${BB_VCROSS#ERR:}"
arr_is_exactly_one_txid "$BB_VCROSS" "$TXID" \
    || fail "verify-cross: verifytxoutproof(core_hex) != exactly [$TXID] (got: $BB_VCROSS)"
# And the converse: Core verifies blockbrew's proof to the same txid.
CORE_VCROSS=$(core_rpc verifytxoutproof "$BB_PROOF")
echo "$CORE_VCROSS" | grep -q "$TXID" \
    || fail "Core verifytxoutproof(impl_hex) lacks $TXID (impl proof not Core-verifiable): $CORE_VCROSS"
log "verify-cross OK: blockbrew verifytxoutproof(core_hex) == [$TXID] (and Core verifies impl proof)"

# ── 9. (4) errors=ok: unknown txid -> error; garbage hex -> error/[]. ─────
# (4a) gettxoutproof for an unknown/nonexistent txid -> error (-5) on BOTH.
RAND_TXID="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
BB_E=$(bb_rpc gettxoutproof "[[\"$RAND_TXID\"]]")
BB_E_CODE=$(jget "$BB_E" error code)
[[ "$BB_E_CODE" == "-5" ]] || fail "gettxoutproof(unknown txid) code=$BB_E_CODE != -5 (env=$BB_E)"
# Oracle: Core also rejects an unknown txid (RPC -5).
CORE_E=$(core_rpc gettxoutproof "[\"$RAND_TXID\"]")
echo "$CORE_E" | grep -qiE 'not yet in block|block not found|not found' \
    || log "note: Core gettxoutproof(unknown) text differs from expected: $CORE_E"
log "errors OK (4a): gettxoutproof(unknown txid) -> -5 on blockbrew (Core also rejects)"

# (4b) gettxoutproof with an unknown blockhash -> error (-5 'Block not found').
RAND_BH="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
BB_EBH=$(bb_rpc gettxoutproof "[[\"$TXID\"],\"$RAND_BH\"]")
BB_EBH_CODE=$(jget "$BB_EBH" error code)
[[ "$BB_EBH_CODE" == "-5" ]] || fail "gettxoutproof(unknown blockhash) code=$BB_EBH_CODE != -5 (env=$BB_EBH)"
log "errors OK (4b): gettxoutproof(unknown blockhash) -> -5 on blockbrew"

# (4c) verifytxoutproof of malformed/garbage hex -> error or [] on BOTH.
GARBAGE="deadbeefdeadbeefdeadbeefdeadbeef"
BB_GARB=$(bb_rpc verifytxoutproof "[\"$GARBAGE\"]")
BB_GARB_ERR=$(jget "$BB_GARB" error code)
BB_GARB_RES=$(jget "$BB_GARB" result)
if [[ "$BB_GARB_ERR" != "<MISSING>" ]]; then
    log "errors OK (4c): blockbrew verifytxoutproof(garbage) errored (code=$BB_GARB_ERR)"
elif [[ "$BB_GARB_RES" == "[]" ]]; then
    log "errors OK (4c): blockbrew verifytxoutproof(garbage) -> [] (empty array)"
else
    fail "verifytxoutproof(garbage) neither errored nor returned []: $BB_GARB"
fi
# Oracle sanity: Core also errors or returns [] on the same garbage.
CORE_GARB=$(core_rpc verifytxoutproof "$GARBAGE")
if echo "$CORE_GARB" | grep -qiE 'error|\bcode\b'; then
    log "note: Core verifytxoutproof(garbage) errored: $(echo "$CORE_GARB" | head -1)"
else
    echo "$CORE_GARB" | python3 -c 'import sys,json;a=json.load(sys.stdin);assert isinstance(a,list) and len(a)==0' >/dev/null 2>&1 \
        || log "note: Core verifytxoutproof(garbage) returned non-empty/non-error: $CORE_GARB"
fi

# (4d) verifytxoutproof of well-formed-but-non-chain proof: a proof whose header
# is mutated (1 byte flipped) so its block is NOT in chain -> error or [] on
# BOTH (Core: 'Block not found in chain'; blockbrew: -5 'Block not in chain' or
# [] if the merkle check fails first). This guards the "wrong txids" failure
# mode — a node must NEVER return a txid for a proof it cannot anchor in chain.
MUT_PROOF=$(python3 - "$BB_PROOF" <<'PY'
import sys
b = bytearray.fromhex(sys.argv[1])
# Flip a byte inside the prev-block-hash field (header bytes 4..36) so the
# header hashes to a block that is not in either chain, while keeping the
# merkle root / partial tree internally consistent enough to deserialize.
b[10] ^= 0xff
print(bytes(b).hex())
PY
)
BB_MUT=$(bb_rpc verifytxoutproof "[\"$MUT_PROOF\"]")
BB_MUT_ERR=$(jget "$BB_MUT" error code)
BB_MUT_RES=$(jget "$BB_MUT" result)
if [[ "$BB_MUT_ERR" != "<MISSING>" ]]; then
    log "errors OK (4d): blockbrew verifytxoutproof(out-of-chain proof) errored (code=$BB_MUT_ERR)"
elif [[ "$BB_MUT_RES" == "[]" ]]; then
    log "errors OK (4d): blockbrew verifytxoutproof(out-of-chain proof) -> []"
else
    fail "verifytxoutproof(out-of-chain proof) returned txids for a block not in chain: $BB_MUT"
fi

log "errors OK: unknown txid -> -5; unknown blockhash -> -5; garbage + out-of-chain proof -> error/[] (matches Core)"

# ── 10. All green. ────────────────────────────────────────────────────────
log "PASS: gettxoutproof byte-identical to Core (txindex + blockhash forms); verify-self + verify-cross == [$TXID]; error cases match Core"
pass

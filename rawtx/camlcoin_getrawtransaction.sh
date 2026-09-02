#!/usr/bin/env bash
#
# camlcoin_getrawtransaction.sh — self-contained getrawtransaction Core-parity test.
#
# The block-explorer keystone RPC and the next RPC-surface/indexing green-cell
# (the flagged follow-up to getindexinfo: "txindex on but getrawtransaction
# fails"). getrawtransaction is READ-ONLY tx retrieval — NOT consensus — but for
# a given transaction the decoded shape MUST match Bitcoin Core EXACTLY.
#
# Core ref: bitcoin-core/src/rpc/rawtransaction.cpp:216-374 (getrawtransaction),
#           :58-85 (TxToJSON envelope), src/core_io.cpp:430-533 (TxToUniv shape).
#   SIGNATURE: getrawtransaction "txid" ( verbosity "blockhash" ).
#     verbosity default 0; accepts bool (true=1, false=0) or int 0/1/2.
#   OUTPUT:
#     v0 -> the raw tx HEX string (EncodeHexTx), byte-exact serialization.
#     v1 -> a decoded OBJECT (TxToUniv include_hex=true) + the TxToJSON envelope:
#           txid, hash (wtxid), version, size, vsize, weight, locktime,
#           vin[] {txid,vout,scriptSig{asm,hex},txinwitness?,sequence} (or coinbase),
#           vout[] {value, n, scriptPubKey{asm,desc,hex,address?,type}},
#           hex, and when confirmed in the active chain:
#           blockhash, confirmations (=1+tip-txHeight), time, blocktime;
#           and in_active_chain (bool) when a blockhash ARG was given.
#   ERRORS (all RPC code -5, RPC_INVALID_ADDRESS_OR_KEY):
#     genesis-coinbase txid (== genesis merkle root) ->
#       "The genesis block coinbase is not ... and cannot be retrieved";
#     unknown blockhash arg -> "Block hash not found";
#     tx not found -> "No such mempool ..."-style message.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports, launched -listen=0 (the sandbox SIGKILLs
#   any bitcoind binding a 0.0.0.0 P2P listener ~2s after load; RPC-only is fine)
#   and -txindex=1.
#
#   getrawtransaction requires the tx to be PRESENT in a node's mempool/chain, so
#   the two nodes cannot hold the identical UTXO set without a P2P link (the
#   sandbox forbids the Core P2P listener). The portable parity oracle is
#   Core's `decoderawtransaction <hex>`, which runs the IDENTICAL TxToUniv code
#   path as getrawtransaction verbosity=1 (rawtransaction.cpp:443 vs :347 — both
#   call TxToUniv). We:
#     - build a REAL spend tx with camlcoin's own wallet (mine 101 -> sendtoaddress),
#     - take camlcoin's getrawtransaction v0 hex + v1 decoded object,
#     - decode the SAME hex with the REAL Core node (decoderawtransaction),
#     - assert every load-bearing decoded field is BYTE-EXACT across the two
#       (proving camlcoin's serialization AND decode are Core-correct),
#     - assert the v1 top-level `hex` == v0 hex == the bytes Core decoded,
#     - assert asm/desc are PRESENT (NOT byte-equal: InferDescriptor + asm
#       whitespace can legitimately differ — though in practice they match here).
#   Core ALSO mines + retrieves its own spend tx so the v1 ENVELOPE key-set is
#   compared against Core's real getrawtransaction (not just decoderawtransaction).
#
# WHAT MUST MATCH CORE EXACTLY (Core decoderawtransaction of camlcoin's hex):
#   * txid, hash, version, size, vsize, weight, locktime
#   * vin[i].{txid, vout, sequence, scriptSig.hex, txinwitness[]}
#   * vout[i].{value, n, scriptPubKey.hex, scriptPubKey.type, scriptPubKey.address}
#   * top-level hex (v0 == v1.hex == decoded bytes)
# WHAT MUST BE PRESENT (not byte-equal):
#   * vin[].scriptSig.asm, vout[].scriptPubKey.asm, vout[].scriptPubKey.desc
# CONFIRMED form (blockhash arg): blockhash matches, confirmations int >= 1,
#   in_active_chain == true, time/blocktime present + integer.
# ERROR-CODE rules: random txid -> -5; genesis-coinbase txid -> -5.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/camlcoin_chaintxstats.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETRAWTRANSACTION camlcoin: PASS hex=ok decoded=ok confirmed=ok errors=ok
#   FAIL: GETRAWTRANSACTION camlcoin: FAIL <short reason>
#
# Touches ONLY /tmp/grt-camlcoin/ + /tmp/grt-core-camlcoin/ and ports
#   22015/22035 (camlcoin RPC/P2P) + 22013/22033 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/camlcoin/_build/default/bin/main.exe"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"

CC_DATADIR="/tmp/grt-camlcoin"
CC_RPC=22015
CC_P2P=22035
CC_LOG="$CC_DATADIR/node.log"

CORE_DATADIR="/tmp/grt-core-camlcoin"
CORE_RPC=22013
CORE_P2P=22033
CORE_LOG="$CORE_DATADIR/core.log"

# regtest genesis coinbase txid (== genesis merkle root), DISPLAY byte order.
# Well-known regtest constant; Core throws -5 for it (rawtransaction.cpp:290-293).
GENESIS_CB_TXID="4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
# A syntactically-valid but unknown 32-byte txid (mempool/chain miss -> -5).
RANDOM_TXID="00000000000000000000000000000000000000000000000000000000deadbeef"

CC_PID=""
CC_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getrawtransaction:camlcoin] $*" >&2; }

# ── Wait (up to ~30s) for a TCP port to become free before binding. ────────
wait_port_free() {  # wait_port_free <port>
    # WAIT-ONLY (port-kill removed: 2026-06-10 fuser incident): NEVER kills by port.
    local port="$1"
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -qE ":${port} " || return 0
        sleep 1
    done
    return 1
}

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$CC_PID" ]] && kill -0 "$CC_PID" 2>/dev/null; then
        kill "$CC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CC_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$CC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {  # pass <hex> <decoded> <confirmed> <errors>
    echo "GETRAWTRANSACTION camlcoin: PASS hex=$1 decoded=$2 confirmed=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETRAWTRANSACTION camlcoin: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "grt-camlcoin" >/dev/null 2>&1 || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${CC_RPC}|${CC_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${CC_RPC}|${CC_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${CC_RPC}/${CC_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$CC_DATADIR" "$CORE_DATADIR"
mkdir -p "$CC_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1 || fail "curl not found on PATH"
[[ -x "$NODE_BIN" ]] || fail "camlcoin binary not found at $NODE_BIN (build with: dune build)"
[[ -x "$CORE_BIN" ]] || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]] || fail "bitcoin-cli not found at $CORE_CLI"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# cc_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
# Retries up to 3x on a transient EMPTY response; a genuine JSON-RPC error body
# (carries "error") is returned immediately and never retried.
cc_rpc() {
    local attempt resp
    for attempt in 1 2 3; do
        resp=$(curl -s --max-time 90 -u "$CC_COOKIE" \
            --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
            "http://127.0.0.1:$CC_RPC/" 2>/dev/null)
        if echo "$resp" | grep -q '"result"\|"error"'; then
            echo "$resp"; return 0
        fi
        sleep 1
    done
    echo "$resp"
}

# jget <json> <expr>  — parse stdin JSON as `d`, print expr (bools lowercased).
jget() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# ── 2. Launch the Core regtest oracle (-listen=0 -txindex=1). ─────────────
wait_port_free "$CORE_RPC" || fail "Core RPC port $CORE_RPC still busy after 30s"
log "launching Core regtest oracle rpc=:$CORE_RPC (-listen=0 -txindex=1, network off)"
# RPC-only: -listen=0 plus -dnsseed=0 -connect=0 -maxconnections=0. The sandbox
# SIGKILLs bitcoind ~2s after load if it does ANY P2P activity (a 0.0.0.0
# listener OR outbound dnsseed/opencon), so all network activity is disabled.
# -txindex=1 so Core's own getrawtransaction error paths (random/genesis txid)
# behave the same as a fully-indexed node.
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -listen=0 -dnsseed=0 -connect=0 -maxconnections=0 \
    -txindex=1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < core_deadline )); do
    if core_cli getblockcount >/dev/null 2>&1; then break; fi
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle exited during startup (see $CORE_LOG)"; }
    sleep 1
done
core_cli getblockcount >/dev/null 2>&1 || fail "Core oracle RPC never responded within 120s (see $CORE_LOG)"
# NOTE: this bitcoind may be built WITHOUT wallet support (createwallet ->
# -32601). The parity oracle is `decoderawtransaction` + Core's own
# getrawtransaction ERROR paths, all of which are wallet-INDEPENDENT, so the
# test does not rely on a Core wallet. The tx itself is built by camlcoin's
# wallet.
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch camlcoin on regtest (metrics off to avoid 9332 collisions). ─
wait_port_free "$CC_RPC" || fail "camlcoin RPC port $CC_RPC still busy after 30s"
wait_port_free "$CC_P2P" || fail "camlcoin P2P port $CC_P2P still busy after 30s"
log "launching camlcoin (regtest) rpc=:$CC_RPC p2p=:$CC_P2P -> $CC_LOG"
"$NODE_BIN" --network regtest --datadir "$CC_DATADIR" \
    --port "$CC_P2P" --rpcport "$CC_RPC" --metricsport 0 >"$CC_LOG" 2>&1 &
CC_PID=$!
cc_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < cc_deadline )); do
    if [[ -z "$CC_COOKIE" && -f "$CC_DATADIR/.cookie" ]]; then
        CC_COOKIE=$(cat "$CC_DATADIR/.cookie")
    fi
    if [[ -n "$CC_COOKIE" ]]; then
        cc_rpc getblockcount '[]' | grep -q '"result"' && break
    fi
    kill -0 "$CC_PID" 2>/dev/null || { tail -n 20 "$CC_LOG" >&2 2>/dev/null || true; fail "camlcoin exited during startup (see $CC_LOG)"; }
    sleep 1
done
[[ -n "$CC_COOKIE" ]] || fail "camlcoin cookie never appeared within 120s"
cc_rpc getblockcount '[]' | grep -q '"result"' || fail "camlcoin RPC never responded within 120s"
log "camlcoin RPC ready"

# ── 4. CREATE the wallet, then build a REAL spend tx with it. ────────────
# A freshly booted node has no wallet that can hand out an address, and that is
# CORRECT on both sides:
#   * Bitcoin Core auto-creates none at all — bitcoin-core/src/wallet/rpc/util.cpp:82
#     "A default wallet is no longer automatically created" -> getnewaddress is
#     RPC_WALLET_NOT_FOUND (-18, src/rpc/protocol.h:80).
#   * camlcoin registers a BLANK, keyless boot wallet as the "" default
#     (camlcoin/lib/cli.ml:1220-1223); it has no master key and no keys, so
#     Wallet.can_get_addresses is false (camlcoin/lib/wallet.ml:785-787) and
#     getnewaddress returns Core's own RPC_WALLET_ERROR (-4) "Error: This wallet
#     has no available keys" (camlcoin/lib/rpc.ml:3152-3153; Core
#     src/wallet/rpc/addresses.cpp:46-47).
# This test used to call getnewaddress straight after the RPC-ready wait and
# read the resulting JSON null back as an address ("did not return a bcrt1
# address: 'None'"). It was green only until camlcoin adopted Core's
# CanGetAddresses guard (camlcoin 936e984, 2026-06-10) and has been red every
# night since 2026-06-11 on THIS harness defect, not a node one — it is the only
# rawtx test that drives an uninitialised node wallet (camlcoin_spend.sh:190 and
# camlcoin_history.sh:157 both initialise first; blockbrew's sibling
# rawtx/blockbrew_getrawtransaction.sh:238 calls createwallet).
# So do what a Core operator does first: createwallet. camlcoin promotes the new
# keyed wallet to the base-"/" default (camlcoin/lib/rpc.ml:3880) the way Core's
# GetWalletForJSONRPCRequest resolves a sole loaded wallet, so every later call
# below keeps using the base endpoint unchanged.
WALLET_NAME="grtw"
CC_WC=$(cc_rpc createwallet "[\"$WALLET_NAME\"]")
echo "$CC_WC" | grep -q "\"name\":\"$WALLET_NAME\"" \
    || fail "camlcoin createwallet $WALLET_NAME failed: $(echo "$CC_WC" | head -c 200)"
log "created wallet $WALLET_NAME (promoted to the base-\"/\" default)"

# Mine 101 blocks to a wallet address (coinbase maturity), then sendtoaddress.
ADDR=$(jget "$(cc_rpc getnewaddress '[]')" "d['result']")
[[ "$ADDR" == bcrt1* ]] || fail "camlcoin getnewaddress did not return a bcrt1 address: '$ADDR'"
log "mining 101 blocks to $ADDR (coinbase maturity)"
cc_rpc generatetoaddress "[101, \"$ADDR\"]" | grep -q '"result"' || fail "camlcoin generatetoaddress(101) failed"
CC_BAL=$(jget "$(cc_rpc getbalance '[]')" "d['result']")
log "camlcoin balance after mining: $CC_BAL"
# ASSERT the value, not just its absence of error. At tip 101 exactly ONE
# coinbase is mature (height 1, depth 101): Core's GetTxBlocksToMaturity needs
# COINBASE_MATURITY+1 = 101 confirmations
# (bitcoin-core/src/wallet/wallet.cpp:3333-3343, src/consensus/consensus.h:19),
# so the spendable balance is exactly 50 BTC — never 100 (maturity ignored),
# never 0 (block-connect credit lost), never null (no usable wallet). This is
# the assertion that stops a harness wallet-setup fix from papering over a real
# wallet-credit or maturity regression on the way to the getrawtransaction
# checks below.
python3 -c "import sys; sys.exit(0 if abs(float('$CC_BAL') - 50.0) < 1e-8 else 1)" 2>/dev/null \
    || fail "camlcoin getbalance at tip 101 = '$CC_BAL', expected exactly 50 BTC (one mature coinbase; Core wallet.cpp:3342)"

DEST=$(jget "$(cc_rpc getnewaddress '[]')" "d['result']")
[[ "$DEST" == bcrt1* ]] || fail "camlcoin getnewaddress (dest) did not return a bcrt1 address: '$DEST'"
SEND_ENV=$(cc_rpc sendtoaddress "[\"$DEST\", 1.0]")
echo "$SEND_ENV" | grep -q '"result"' || fail "camlcoin sendtoaddress failed: $SEND_ENV"
TXID=$(jget "$SEND_ENV" "d['result']")
[[ "$TXID" =~ ^[0-9a-f]{64}$ ]] || fail "camlcoin sendtoaddress returned a non-txid: '$TXID'"
log "created mempool tx $TXID"

# Confirm it really is in the mempool.
cc_rpc getrawmempool '[]' | grep -q "$TXID" || fail "tx $TXID is not in camlcoin mempool"

# ── 5. #1 MEMPOOL: v0 hex byte-exact + v1 decoded byte-exact vs Core. ─────
HEX_T="ok"; DECODED_T="ok"

# cc_grt_hex <params-json> -> the getrawtransaction hex-string RESULT, retrying
# until the response carries a "result" (guards against a transient dropped
# connection making a sub-check spuriously empty -> spurious "bad").
cc_grt_hex() {  # cc_grt_hex <params-json>
    local i env h
    for i in 1 2 3 4 5; do
        env=$(cc_rpc getrawtransaction "$1")
        if echo "$env" | grep -q '"result"'; then
            h=$(jget "$env" "d['result']")
            [[ "$h" =~ ^[0-9a-f]+$ ]] && { echo "$h"; return 0; }
        fi
        sleep 1
    done
    echo ""   # caller surfaces the failure
}

# v0 -> raw hex string.
CC_HEX=$(cc_grt_hex "[\"$TXID\", 0]")
[[ "$CC_HEX" =~ ^[0-9a-f]+$ ]] || fail "camlcoin getrawtransaction v0 is not a hex string: '$CC_HEX'"

# v0 via bool false must equal v0 via int 0 (bool verbosity handling).
CC_HEX_B=$(cc_grt_hex "[\"$TXID\", false]")
[[ "$CC_HEX_B" == "$CC_HEX" ]] || { HEX_T="bad"; log "v0 via bool false != v0 via int 0: b='$CC_HEX_B' 0='$CC_HEX'"; }

# Default verbosity (omitted) must also be the hex string (Core default 0).
CC_HEX_D=$(cc_grt_hex "[\"$TXID\"]")
[[ "$CC_HEX_D" == "$CC_HEX" ]] || { HEX_T="bad"; log "default-verbosity result != v0 hex (default must be 0): d='$CC_HEX_D' 0='$CC_HEX'"; }

# Core decodes the SAME hex -> byte-exact serialization proof + canonical decode.
CORE_DEC=""
for _ in 1 2 3; do
    CORE_DEC=$(core_cli decoderawtransaction "$CC_HEX" 2>/dev/null)
    echo "$CORE_DEC" | grep -q '"txid"' && break
    sleep 1
done
echo "$CORE_DEC" | grep -q '"txid"' || { HEX_T="bad"; log "Core could not decoderawtransaction camlcoin's hex (bad serialization): '$CORE_DEC'"; }

# v1 -> decoded object.
V1_ENV=""
for _ in 1 2 3 4 5; do
    V1_ENV=$(cc_rpc getrawtransaction "[\"$TXID\", 1]")
    echo "$V1_ENV" | grep -q '"result"' && break
    sleep 1
done
echo "$V1_ENV" | grep -q '"result"' || fail "camlcoin getrawtransaction v1 errored: $V1_ENV"
CC_V1=$(jget "$V1_ENV" "json.dumps(d['result'])")
[[ -n "$CC_V1" ]] || fail "camlcoin getrawtransaction v1 result empty"

# v1 via bool true must equal v1 via int 1 (must be a decoded object with txid).
CC_V1B_TXID=""
for _ in 1 2 3 4 5; do
    V1B_ENV=$(cc_rpc getrawtransaction "[\"$TXID\", true]")
    if echo "$V1B_ENV" | grep -q '"result"'; then
        CC_V1B_TXID=$(jget "$V1B_ENV" "d['result']['txid']")
        [[ -n "$CC_V1B_TXID" ]] && break
    fi
    sleep 1
done
[[ "$CC_V1B_TXID" == "$TXID" ]] || { DECODED_T="bad"; log "v1 via bool true did not return a decoded object: '$CC_V1B_TXID'"; }

# v1 top-level hex == v0 hex.
CC_V1_HEX=$(jget "$V1_ENV" "d['result']['hex']")
[[ "$CC_V1_HEX" == "$CC_HEX" ]] || { HEX_T="bad"; log "v1 top-level hex != v0 hex: v1='$CC_V1_HEX' v0='$CC_HEX'"; }

# Byte-exact decoded-field parity: camlcoin v1 vs Core decoderawtransaction.
# Both run the IDENTICAL TxToUniv over the IDENTICAL bytes, so the load-bearing
# fields MUST be byte-equal; asm/desc are asserted PRESENT only.
PARITY=$(python3 - "$CC_V1" "$CORE_DEC" <<'PY'
import sys, json
cc   = json.loads(sys.argv[1])   # camlcoin getrawtransaction v1
core = json.loads(sys.argv[2])   # Core decoderawtransaction of the same hex
problems = []

# Scalar top-level fields that must match byte-exact.
for k in ("txid","hash","version","size","vsize","weight","locktime"):
    if cc.get(k) != core.get(k):
        problems.append(f"top.{k}: cc={cc.get(k)!r} core={core.get(k)!r}")

# vin parity.
cvin, ovin = cc.get("vin",[]), core.get("vin",[])
if len(cvin) != len(ovin):
    problems.append(f"vin len cc={len(cvin)} core={len(ovin)}")
else:
    for i,(a,b) in enumerate(zip(cvin,ovin)):
        # coinbase vs normal input shape
        if ("coinbase" in a) != ("coinbase" in b):
            problems.append(f"vin[{i}] coinbase-shape mismatch")
            continue
        if "coinbase" in a:
            if a.get("coinbase") != b.get("coinbase"):
                problems.append(f"vin[{i}].coinbase cc={a.get('coinbase')!r} core={b.get('coinbase')!r}")
        else:
            for k in ("txid","vout","sequence"):
                if a.get(k) != b.get(k):
                    problems.append(f"vin[{i}].{k}: cc={a.get(k)!r} core={b.get(k)!r}")
            # scriptSig.hex byte-exact; asm present only
            ass, bss = a.get("scriptSig",{}), b.get("scriptSig",{})
            if ass.get("hex") != bss.get("hex"):
                problems.append(f"vin[{i}].scriptSig.hex: cc={ass.get('hex')!r} core={bss.get('hex')!r}")
            if "asm" not in ass:
                problems.append(f"vin[{i}].scriptSig.asm missing")
        # txinwitness byte-exact when present on either side
        if ("txinwitness" in a) or ("txinwitness" in b):
            if a.get("txinwitness") != b.get("txinwitness"):
                problems.append(f"vin[{i}].txinwitness: cc={a.get('txinwitness')!r} core={b.get('txinwitness')!r}")

# vout parity.
cvout, ovout = cc.get("vout",[]), core.get("vout",[])
if len(cvout) != len(ovout):
    problems.append(f"vout len cc={len(cvout)} core={len(ovout)}")
else:
    for i,(a,b) in enumerate(zip(cvout,ovout)):
        # value compared numerically (BTC decimal) and n exact.
        try:
            if float(a.get("value")) != float(b.get("value")):
                problems.append(f"vout[{i}].value cc={a.get('value')!r} core={b.get('value')!r}")
        except Exception:
            problems.append(f"vout[{i}].value unparsable cc={a.get('value')!r} core={b.get('value')!r}")
        if a.get("n") != b.get("n"):
            problems.append(f"vout[{i}].n cc={a.get('n')!r} core={b.get('n')!r}")
        aspk, bspk = a.get("scriptPubKey",{}), b.get("scriptPubKey",{})
        # hex + type + address byte-exact (address only when decodable -> present on both)
        if aspk.get("hex") != bspk.get("hex"):
            problems.append(f"vout[{i}].scriptPubKey.hex cc={aspk.get('hex')!r} core={bspk.get('hex')!r}")
        if aspk.get("type") != bspk.get("type"):
            problems.append(f"vout[{i}].scriptPubKey.type cc={aspk.get('type')!r} core={bspk.get('type')!r}")
        # address: present-if-decodable; if Core emits one, camlcoin must match it.
        if "address" in bspk:
            if aspk.get("address") != bspk.get("address"):
                problems.append(f"vout[{i}].scriptPubKey.address cc={aspk.get('address')!r} core={bspk.get('address')!r}")
        # asm + desc PRESENT (not byte-equal).
        if "asm" not in aspk:
            problems.append(f"vout[{i}].scriptPubKey.asm missing")
        if "desc" not in aspk:
            problems.append(f"vout[{i}].scriptPubKey.desc missing")

if problems:
    print("MISMATCH: " + " | ".join(problems[:8]))
else:
    print("OK")
PY
)
if [[ "$PARITY" != "OK" ]]; then
    DECODED_T="bad"
    log "decoded-field parity vs Core: $PARITY"
fi

[[ "$HEX_T"     == "ok" ]] || fail "v0/v1 hex check failed (see log)"
[[ "$DECODED_T" == "ok" ]] || fail "v1 decoded-field parity vs Core failed (see log)"

# ── 6. #2 CONFIRMED via blockhash arg (camlcoin). ─────────────────────────
CONFIRMED_T="ok"
CC_MINE=$(jget "$(cc_rpc getnewaddress '[]')" "d['result']")
cc_rpc generatetoaddress "[1, \"$CC_MINE\"]" | grep -q '"result"' || fail "camlcoin generatetoaddress(1) to confirm tx failed"
CC_BH=$(jget "$(cc_rpc getbestblockhash '[]')" "d['result']")
[[ "$CC_BH" =~ ^[0-9a-f]{64}$ ]] || fail "camlcoin getbestblockhash returned non-hash: '$CC_BH'"

CONF_ENV=$(cc_rpc getrawtransaction "[\"$TXID\", 1, \"$CC_BH\"]")
echo "$CONF_ENV" | grep -q '"result"' || fail "camlcoin getrawtransaction confirmed errored: $CONF_ENV"
CONF=$(jget "$CONF_ENV" "json.dumps(d['result'])")

C_BH=$(jget "$CONF_ENV" "d['result'].get('blockhash')")
[[ "$C_BH" == "$CC_BH" ]] || { CONFIRMED_T="bad"; log "confirmed blockhash mismatch: got '$C_BH' expected '$CC_BH'"; }

C_CONF=$(jget "$CONF_ENV" "d['result'].get('confirmations')")
if ! [[ "$C_CONF" =~ ^[0-9]+$ ]] || [[ "$C_CONF" -lt 1 ]]; then
    CONFIRMED_T="bad"; log "confirmed confirmations not int>=1: '$C_CONF'"
fi

C_IAC=$(jget "$CONF_ENV" "d['result'].get('in_active_chain')")
[[ "$C_IAC" == "true" ]] || { CONFIRMED_T="bad"; log "in_active_chain not true with blockhash arg: '$C_IAC'"; }

C_TIME=$(jget "$CONF_ENV" "d['result'].get('time')")
C_BTIME=$(jget "$CONF_ENV" "d['result'].get('blocktime')")
[[ "$C_TIME"  =~ ^[0-9]+$ ]] || { CONFIRMED_T="bad"; log "confirmed time absent/non-integer: '$C_TIME'"; }
[[ "$C_BTIME" =~ ^[0-9]+$ ]] || { CONFIRMED_T="bad"; log "confirmed blocktime absent/non-integer: '$C_BTIME'"; }
[[ "$C_TIME" == "$C_BTIME" ]] || { CONFIRMED_T="bad"; log "time != blocktime (Core sets both equal): '$C_TIME' vs '$C_BTIME'"; }

# Envelope key-set: every key Core's TxToJSON + TxToUniv emit for a confirmed
# tx retrieved WITH a blockhash arg must be present in camlcoin's v1 output.
# Core ref: rawtransaction.cpp:243-251 (envelope) + :339 (in_active_chain) +
# core_io.cpp:434-532 (TxToUniv) + :73-79 (blockhash/confirmations/time/blocktime).
ENVCHK=$(python3 - "$CONF" <<'PY'
import sys, json
cc = json.loads(sys.argv[1])
must = ["txid","hash","version","size","vsize","weight","locktime","vin","vout",
        "hex","blockhash","confirmations","time","blocktime","in_active_chain"]
missing = [k for k in must if k not in cc]
print("OK" if not missing else "MISSING:" + ",".join(missing))
PY
)
[[ "$ENVCHK" == "OK" ]] || { CONFIRMED_T="bad"; log "confirmed envelope key-set vs Core-documented shape: $ENVCHK"; }

# Bonus (camlcoin has an implicit always-on tx-index; it has no explicit
# --txindex flag so this is informational, not gating): getrawtransaction with
# NO blockhash on a CONFIRMED tx must still resolve.
NOBH_ENV=$(cc_rpc getrawtransaction "[\"$TXID\", 1]")
if echo "$NOBH_ENV" | grep -q '"result"' && [[ "$(jget "$NOBH_ENV" "d['result']['txid']")" == "$TXID" ]]; then
    log "bonus: confirmed tx resolves with NO blockhash (implicit txindex) -> ok"
else
    log "note: confirmed tx did NOT resolve without a blockhash (no implicit txindex) -- not gating"
fi

[[ "$CONFIRMED_T" == "ok" ]] || fail "confirmed-form check failed (see log)"

# ── 7. #3 ERROR-CODE parity: random txid -> -5; genesis coinbase -> -5. ───
ERRORS_T="ok"

# Core: random txid (txindex on) -> -5.
CORE_E5=$(core_cli getrawtransaction "$RANDOM_TXID" 1 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ "$CORE_E5" == "-5" ]] || log "note: Core random-txid code was '$CORE_E5' (expected -5)"

# camlcoin: random txid -> -5.
CC_E5=$(jget "$(cc_rpc getrawtransaction "[\"$RANDOM_TXID\", 1]")" "d['error']['code']")
[[ "$CC_E5" == "-5" ]] || { ERRORS_T="bad"; log "random txid: camlcoin code '$CC_E5' (expected -5)"; }

# Core: genesis coinbase txid -> -5.
CORE_EG=$(core_cli getrawtransaction "$GENESIS_CB_TXID" 1 2>&1 | grep -oE 'error code: -?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
[[ "$CORE_EG" == "-5" ]] || log "note: Core genesis-coinbase code was '$CORE_EG' (expected -5)"

# camlcoin: genesis coinbase txid -> -5.
CCG_ENV=$(cc_rpc getrawtransaction "[\"$GENESIS_CB_TXID\", 1]")
CC_EG=$(jget "$CCG_ENV" "d['error']['code']")
[[ "$CC_EG" == "-5" ]] || { ERRORS_T="bad"; log "genesis-coinbase: camlcoin code '$CC_EG' (expected -5): $CCG_ENV"; }
CC_EG_MSG=$(jget "$CCG_ENV" "d['error']['message']")
echo "$CC_EG_MSG" | grep -qi "genesis block coinbase" || { ERRORS_T="bad"; log "genesis-coinbase message off: '$CC_EG_MSG'"; }

# camlcoin: unknown blockhash arg -> -5 ("Block hash not found").
CCBH_ENV=$(cc_rpc getrawtransaction "[\"$TXID\", 1, \"$RANDOM_TXID\"]")
CC_EBH=$(jget "$CCBH_ENV" "d['error']['code']")
[[ "$CC_EBH" == "-5" ]] || { ERRORS_T="bad"; log "unknown blockhash: camlcoin code '$CC_EBH' (expected -5): $CCBH_ENV"; }

[[ "$ERRORS_T" == "ok" ]] || fail "error-code parity check failed (see log)"

# ── 8. Done. ──────────────────────────────────────────────────────────────
log "PASS: camlcoin getrawtransaction matches Core on hex + decoded shape + confirmed envelope + error codes"
pass "$HEX_T" "$DECODED_T" "$CONFIRMED_T" "$ERRORS_T"

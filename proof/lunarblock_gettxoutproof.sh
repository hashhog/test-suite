#!/usr/bin/env bash
#
# lunarblock_gettxoutproof.sh — self-contained gettxoutproof / verifytxoutproof
#   DIFFERENTIAL-REGRESSION test for lunarblock vs. a real Bitcoin Core oracle.
#
# gettxoutproof(["txid",...] (,"blockhash")) returns a SERIALIZED CMerkleBlock as
# HEX:  80-byte block header | nTransactions(uint32 LE) | hash-count(varint) |
#       hashes(32B each) | flag-byte-count(varint) | flag bytes.  Because the
# encoding is fully determined by (the block, the set of matched txids), the SAME
# tx in the SAME block yields a DETERMINISTIC, BYTE-IDENTICAL merkleblock across
# any two correct implementations.
#
# verifytxoutproof("hex") deserializes that merkleblock, re-extracts the matched
# txids from the partial merkle tree, checks the recomputed root against the
# header's merkle root, checks the block is in the active chain, and returns a
# JSON ARRAY of the committed txids (empty array / RPC error if invalid).
#
# Core refs:
#   bitcoin-core/src/rpc/txoutproof.cpp gettxoutproof   (23-127)
#       blockhash supplied + not found    -> RPC -5  "Block not found"
#       txid not in the resolved block    -> RPC -5  "Not all transactions found
#                                                     in specified or retrieved block"
#       no blockhash + tx not locatable   -> RPC -5  "Transaction not yet in block"
#       success                           -> HexStr(CMerkleBlock(block,setTxids))
#   bitcoin-core/src/rpc/txoutproof.cpp verifytxoutproof (129-175)
#       proof not hexadecimal             -> RPC -8  "proof must be hexadecimal ..."
#       proof too short / bad stream      -> RPC -1  "SpanReader::read(): end of data..."
#       root extraction fails             -> []  (empty array, NOT an error)
#       block not in active chain         -> RPC -5  "Block not found in chain"
#       success                           -> ["<txid>", ...]
#   bitcoin-core/src/merkleblock.{h,cpp}  (CMerkleBlock / CPartialMerkleTree wire)
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports, launched -listen=0 (RPC only; the sandbox
#   SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener) and -txindex=1.
#
#   To make the SAME confirmed tx live in the SAME block byte-for-byte on BOTH
#   nodes, Core mines the whole chain to a DETERMINISTIC p2wpkh address, and
#   lunarblock is fed each block via `submitblock` — so both nodes carry an
#   IDENTICAL chain (identical headers, identical coinbase, identical merkle
#   roots).  The proven tx is BLOCK 1's COINBASE: a confirmed, deterministic tx
#   whose merkleblock hex is therefore identical on the two nodes.  (Reuses the
#   launch + Core-oracle + mirror boilerplate from
#   test-suite/scan/lunarblock_scantxoutset.sh, swapping the RPC contract.)
#
# FOUR GATED CHECKS (ALL run on BOTH the impl and Core; NONE optional):
#   (1) proof    : lunarblock gettxoutproof([cb_txid], bh1) returns hex
#                  BYTE-IDENTICAL to Core's gettxoutproof([cb_txid], bh1).
#   (2) verifyslf: lunarblock verifytxoutproof(lb_hex)  == EXACTLY [cb_txid].
#   (3) verifyxr : lunarblock verifytxoutproof(core_hex) == EXACTLY [cb_txid]
#                  (Core's proof verifies on lunarblock — cross-impl acceptance).
#   (4) errors   : gettxoutproof for an unknown txid (in a real block) -> RPC
#                  ERROR on both (Core -5 "Not all transactions found ...");
#                  gettxoutproof with a bogus blockhash -> RPC ERROR on both
#                  (Core -5 "Block not found"); verifytxoutproof of malformed /
#                  garbage hex -> RPC ERROR or [] on both (matches Core).
#                  Each impl error must be a JSON-RPC error; Core's category is
#                  captured + reported.  A genuine divergence (proof hex differs,
#                  or verify returns the wrong txids) is a FAIL, never papered.
#
# STRICT UNIFORM INTERFACE (mirrors scan/lunarblock_scantxoutset.sh):
#   set -uo pipefail, no required args, idempotent, trap cleanup, scratch /tmp
#   datadirs + unique ports, ONE clean summary line on stdout, all noise ->
#   stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTPROOF lunarblock: PASS proof=ok verify-self=ok verify-cross=ok errors=ok
#   FAIL: GETTXOUTPROOF lunarblock: FAIL <short reason>
#   SKIP: if the impl entrypoint/luajit is missing the FAIL reason contains
#         "not found" / "not built" (GAP_RE-compatible) so the runner SKIPs.
#
# Touches ONLY /tmp/proof-lunarblock/ + /tmp/proof-lb-core/ and ports 22325/22345
#   (lunarblock RPC/P2P) + 22327/22347 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node. Never
#   broad-pkills bitcoind by name; only frees its OWN fixed ports / scratch dir.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
LB_DIR="$BASEDIR/lunarblock"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (key/address)

# Deterministic test secrets. Block-1 coinbase pays MINE_ADDR; the 100 maturity
# blocks pay a separate SINK address. Both addresses are derived from fixed keys
# so the entire chain — and thus block-1's header/coinbase/merkle root — is
# byte-identical every run and across both nodes.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
SINK_SECRET="2222222222222222222222222222222222222222222222222222222222222223"

# Needles for the error checks.
UNKNOWN_TXID="00000000000000000000000000000000000000000000000000000000deadbeef"
BOGUS_BLOCKHASH="00000000000000000000000000000000000000000000000000000000cafebabe"
GARBAGE_HEX="deadbeef"          # valid hex, too short to deserialize a merkleblock
NONHEX_GARBAGE="zzzz"           # not hexadecimal at all

LB_DATADIR="/tmp/proof-lunarblock"
LB_RPC=22325
LB_P2P=22345
LB_LOG="$LB_DATADIR/node.log"

CORE_DATADIR="/tmp/proof-lb-core"
CORE_RPC=22327
CORE_P2P=22347
CORE_LOG="$CORE_DATADIR/core.log"

NBLOCKS=101        # 1 coinbase to MINE_ADDR + 100 maturity blocks (to a sink).

LB_PID=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gettxoutproof:lunarblock] $*" >&2; }

# ── Port free helper: kill + POLL until the socket is actually released. ──
free_port() {
    # WAIT-ONLY (port-kill removed: 2026-06-10 fuser incident): waits for OUR
    # just-stopped node to release the port. NEVER kills by port.
    local p="$1"
    for _ in $(seq 1 20); do
        ss -tln 2>/dev/null | grep -qE ":${p} " || return 0
        sleep 1
    done
    return 0
}

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$LB_PID" ]] && kill -0 "$LB_PID" 2>/dev/null; then
        kill -TERM "-${LB_PID}" 2>/dev/null || kill -TERM "$LB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$LB_PID" 2>/dev/null || break; sleep 1; done
        kill -KILL "-${LB_PID}" 2>/dev/null || kill -KILL "$LB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    free_port "$LB_RPC"
    free_port "$LB_P2P"
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$LB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <proof> <verify-self> <verify-cross> <errors>
pass() {
    echo "GETTXOUTPROOF lunarblock: PASS proof=$1 verify-self=$2 verify-cross=$3 errors=$4"
    exit 0
}
fail() {
    echo "GETTXOUTPROOF lunarblock: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "proof-lunarblock" 2>/dev/null || true
free_port "$LB_RPC"
free_port "$LB_P2P"
free_port "$CORE_RPC"
free_port "$CORE_P2P"
if ss -tln 2>/dev/null | grep -qE ":(${LB_RPC}|${LB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${LB_RPC}/${LB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
rm -rf "$LB_DATADIR" "$CORE_DATADIR"
mkdir -p "$LB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
command -v luajit  >/dev/null 2>&1   || fail "luajit not found on PATH"
[[ -f "$LB_DIR/src/main.lua" ]]      || fail "lunarblock entrypoint not found at $LB_DIR/src/main.lua (binary not built)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── Derive the deterministic p2wpkh mining + sink addresses. ──────────────
derive_p2wpkh() {
    python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$1'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))" 2>/dev/null
}
MINE_ADDR=$(derive_p2wpkh "$SECRET")   || fail "could not derive mining address (test_framework import failed)"
[[ "$MINE_ADDR" == bcrt1* ]] || fail "mining address not regtest bech32: '$MINE_ADDR'"
SINK_ADDR=$(derive_p2wpkh "$SINK_SECRET")   || fail "could not derive sink address"
[[ "$SINK_ADDR" == bcrt1* ]] || fail "sink address not regtest bech32: '$SINK_ADDR'"
[[ "$MINE_ADDR" != "$SINK_ADDR" ]] || fail "mine/sink addresses collided"
log "mine addr=$MINE_ADDR  sink addr=$SINK_ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# Tolerant of the bitcoin-cli .cookie read race + heavy concurrent fleet load.
core_cli_retry() {
    local out="" rc=1
    for _ in $(seq 1 20); do
        out=$(core_cli "$@" 2>/dev/null); rc=$?
        [[ $rc -eq 0 && -n "$out" ]] && { echo "$out"; return 0; }
        [[ -n "$CORE_BG" ]] && ! kill -0 "$CORE_BG" 2>/dev/null && return 1   # daemon dead
        sleep 3
    done
    return 1
}
# core_err <cmd...> -> the RPC error code (e.g. -5) on stderr-parse, "?" if none.
core_err() {
    local raw
    raw=$(core_cli "$@" 2>&1 >/dev/null)
    local code
    code=$(echo "$raw" | grep -oE 'code: -?[0-9]+' | grep -oE -- '-?[0-9]+' | head -1)
    [[ -z "$code" ]] && code="?"
    echo "$code"
}

# lb_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
# (lunarblock defaults to an EMPTY rpcpassword on regtest -> no auth header.)
lb_rpc() {
    curl -s --max-time 90 \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$LB_RPC/" 2>/dev/null
}
# lb_result <method> <params> -> the .result as compact JSON / string (or empty),
#   ONLY when there is no .error; prints nothing (and is detectable) on error.
lb_result() {
    lb_rpc "$1" "$2" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("error") is not None: sys.exit(0)
r=d.get("result")
if r is None: sys.exit(0)
print(r if isinstance(r,str) else json.dumps(r))'
}
# lb_err_code <method> <params> -> the JSON-RPC error code, or "__NOERR__".
lb_err_code() {
    lb_rpc "$1" "$2" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print("__PARSEERR__"); sys.exit(0)
e=d.get("error")
if e is None: print("__NOERR__")
elif isinstance(e,dict): print(e.get("code","__NOCODE__"))
else: print("__BADERR__")'
}
# lb_is_empty_array <method> <params> -> "yes" if .result is [] and no error.
lb_is_empty_array() {
    lb_rpc "$1" "$2" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print("no"); sys.exit(0)
print("yes" if d.get("error") is None and isinstance(d.get("result"),list) and len(d["result"])==0 else "no")'
}

# ── 2. Launch the Core regtest oracle (RPC-only, -txindex=1). ─────────────
launch_core_once() {
    free_port "$CORE_RPC"
    free_port "$CORE_P2P"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    # -listen=0: RPC-only — the sandbox SIGKILLs a 0.0.0.0 P2P listener.
    # -txindex=1: gettxoutproof's no-blockhash path needs an index; harmless here.
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -listen=0 -txindex=1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        if core_cli getblockcount >/dev/null 2>&1; then
            core_cli_retry getblockcount >/dev/null && return 0
        fi
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
CORE_OK=0
for attempt in 1 2 3; do
    log "launching Core regtest oracle rpc=:$CORE_RPC p2p=:$CORE_P2P -listen=0 -txindex=1 (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 3. Launch lunarblock on regtest (with --txindex for parity). ──────────
log "launching lunarblock (regtest, --txindex) rpc=:$LB_RPC p2p=:$LB_P2P -> $LB_LOG"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$LB_DATADIR' \
    --port '$LB_P2P' --rpcport '$LB_RPC' --nov2transport --txindex" \
    >"$LB_LOG" 2>&1 &
LB_PID=$!
log "lunarblock pid=$LB_PID"
lb_deadline=$(( $(date +%s) + 120 ))
lb_up=0
while (( $(date +%s) < lb_deadline )); do
    if ! kill -0 "$LB_PID" 2>/dev/null; then
        tail -n 20 "$LB_LOG" >&2 2>/dev/null || true
        fail "lunarblock exited during startup (see $LB_LOG)"
    fi
    r=$(lb_rpc getblockchaininfo '[]')
    if echo "$r" | grep -q '"regtest"'; then lb_up=1; break; fi
    sleep 1
done
[[ "$lb_up" -eq 1 ]] || { tail -n 20 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock RPC never reported chain=regtest within 120s"; }
log "lunarblock RPC ready"

# ── 4. Mine a deterministic chain on Core; mirror it into lunarblock so both
#       carry an IDENTICAL block 1 (header + coinbase + merkle root). ───────
log "mining block 1 coinbase -> $MINE_ADDR on Core"
core_cli_retry generatetoaddress 1 "$MINE_ADDR" >/dev/null || fail "Core generatetoaddress (funding) failed"
log "mining 100 maturity blocks -> $SINK_ADDR on Core"
core_cli_retry generatetoaddress 100 "$SINK_ADDR" >/dev/null || fail "Core generatetoaddress (maturity) failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height $CORE_HEIGHT != $NBLOCKS after mining"

log "mirroring Core's $NBLOCKS blocks into lunarblock via submitblock"
for ((h=1; h<=NBLOCKS; h++)); do
    BH=$(core_cli_retry getblockhash "$h")  || fail "Core getblockhash $h failed"
    RAW=$(core_cli_retry getblock "$BH" 0)  || fail "Core getblock $h (raw) failed"
    SB=$(lb_rpc submitblock "[\"$RAW\"]")
    RES=$(python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
r=d.get("result")
print("" if r is None else r)' <<<"$SB")
    if [[ -n "$RES" && "$RES" != "None" && "$RES" != "duplicate" ]]; then
        log "lunarblock submitblock height=$h rejected: $SB"
        tail -n 40 "$LB_LOG" >&2 2>/dev/null || true
        fail "lunarblock submitblock failed at height $h: '$RES'"
    fi
done
LB_HEIGHT=$(lb_result getblockcount '[]')
[[ "$LB_HEIGHT" == "$NBLOCKS" ]] || { tail -n 40 "$LB_LOG" >&2 2>/dev/null || true; fail "lunarblock height $LB_HEIGHT != $NBLOCKS after mirror (submitblock did not connect chain)"; }

# Both chains must now share the SAME tip hash (identical blocks).
CORE_TIP=$(core_cli_retry getbestblockhash)
LB_TIP=$(lb_result getbestblockhash '[]')
[[ "$CORE_TIP" == "$LB_TIP" ]] || fail "tip mismatch after mirror: core=$CORE_TIP lb=$LB_TIP"
log "both nodes at identical tip $LB_TIP (height $NBLOCKS)"

# Block-1 hash + its coinbase txid: the confirmed, deterministic tx we prove.
BH1=$(core_cli_retry getblockhash 1) || fail "Core getblockhash 1 failed"
CB_TXID=$(core_cli_retry getblock "$BH1" 1 | python3 -c "import sys,json;print(json.load(sys.stdin)['tx'][0])")
[[ "$CB_TXID" =~ ^[0-9a-f]{64}$ ]] || fail "could not extract block-1 coinbase txid (got '$CB_TXID')"
# Sanity: lunarblock must agree on block-1 hash (identical chain assertion).
LB_BH1=$(lb_result getblockhash '[1]')
[[ "$LB_BH1" == "$BH1" ]] || fail "block-1 hash mismatch: core=$BH1 lb=$LB_BH1"
log "proving block-1 coinbase txid=$CB_TXID in block $BH1"

PROOF_T="ok"; VSELF_T="ok"; VCROSS_T="ok"; ERRORS_T="ok"

# ════════════════════════════════════════════════════════════════════════
# CHECK (1) — proof: lunarblock's merkleblock hex BYTE-IDENTICAL to Core's.
# ════════════════════════════════════════════════════════════════════════
CORE_PROOF=$(core_cli_retry gettxoutproof "[\"$CB_TXID\"]" "$BH1") \
    || fail "Core gettxoutproof failed (see $CORE_LOG)"
[[ "$CORE_PROOF" =~ ^[0-9a-fA-F]+$ ]] || fail "Core gettxoutproof returned non-hex: '$CORE_PROOF'"
CORE_PROOF=$(echo "$CORE_PROOF" | tr 'A-F' 'a-f')

LB_PROOF=$(lb_result gettxoutproof "[[\"$CB_TXID\"], \"$BH1\"]")
if [[ -z "$LB_PROOF" ]]; then
    PROOF_RESP=$(lb_rpc gettxoutproof "[[\"$CB_TXID\"], \"$BH1\"]")
    log "lunarblock gettxoutproof errored/empty: $PROOF_RESP"
    PROOF_T="lb-empty-or-error"
elif [[ ! "$LB_PROOF" =~ ^[0-9a-fA-F]+$ ]]; then
    PROOF_T="lb-not-hex"
else
    LB_PROOF=$(echo "$LB_PROOF" | tr 'A-F' 'a-f')
    if [[ "$LB_PROOF" != "$CORE_PROOF" ]]; then
        PROOF_T="hex-differs"
        log "proof hex DIFFERS:"
        log "  core(${#CORE_PROOF}): $CORE_PROOF"
        log "  lb  (${#LB_PROOF}): $LB_PROOF"
    fi
fi
log "proof check: core_len=${#CORE_PROOF} lb_len=${#LB_PROOF} -> $PROOF_T"

# ════════════════════════════════════════════════════════════════════════
# CHECK (2) — verify-self: lunarblock verifytxoutproof(lb_hex) == [cb_txid].
# ════════════════════════════════════════════════════════════════════════
# Use lunarblock's OWN proof if it produced a valid one; otherwise fall back to
# Core's proof so this check is still meaningful and the failure is localized to
# (1).  We require the matched-txid array to be EXACTLY [CB_TXID].
verify_returns_exact_txid() {
    # <json-result-array> <expected-txid> -> "yes"/"no"
    python3 -c "
import sys,json
try: r=json.loads(sys.argv[1])
except Exception: print('no'); sys.exit(0)
print('yes' if r==['$2'] else 'no')" "$1" 2>/dev/null
}
SELF_PROOF="$LB_PROOF"
[[ "$SELF_PROOF" =~ ^[0-9a-f]+$ ]] || SELF_PROOF="$CORE_PROOF"   # fall back if (1) failed
LB_VSELF=$(lb_result verifytxoutproof "[\"$SELF_PROOF\"]")
if [[ -z "$LB_VSELF" ]]; then
    VSELF_T="lb-empty-or-error: $(lb_rpc verifytxoutproof "[\"$SELF_PROOF\"]")"
elif [[ "$(verify_returns_exact_txid "$LB_VSELF" "$CB_TXID")" != "yes" ]]; then
    VSELF_T="not-[txid]:$LB_VSELF"
fi
log "verify-self check: lb verifytxoutproof(self) -> $LB_VSELF -> $VSELF_T"

# ════════════════════════════════════════════════════════════════════════
# CHECK (3) — verify-cross: lunarblock verifytxoutproof(CORE_hex) == [cb_txid].
# ════════════════════════════════════════════════════════════════════════
LB_VCROSS=$(lb_result verifytxoutproof "[\"$CORE_PROOF\"]")
if [[ -z "$LB_VCROSS" ]]; then
    VCROSS_T="lb-empty-or-error: $(lb_rpc verifytxoutproof "[\"$CORE_PROOF\"]")"
elif [[ "$(verify_returns_exact_txid "$LB_VCROSS" "$CB_TXID")" != "yes" ]]; then
    VCROSS_T="not-[txid]:$LB_VCROSS"
fi
log "verify-cross check: lb verifytxoutproof(core_hex) -> $LB_VCROSS -> $VCROSS_T"

# Reciprocal sanity (logged, not gated): Core must verify lunarblock's proof too.
if [[ "$LB_PROOF" =~ ^[0-9a-f]+$ ]]; then
    CORE_VLB=$(core_cli_retry verifytxoutproof "$LB_PROOF" 2>/dev/null)
    CORE_VLB_OK=$(python3 -c "
import sys,json
try: print('yes' if json.loads(sys.argv[1])==['$CB_TXID'] else 'no')
except Exception: print('no')" "$CORE_VLB" 2>/dev/null)
    log "reciprocal (Core verifies lb proof): $CORE_VLB -> $CORE_VLB_OK"
fi

# ════════════════════════════════════════════════════════════════════════
# CHECK (4) — errors: unknown txid / bogus blockhash / garbage hex.
#   Each impl probe must be a JSON-RPC ERROR (or [] for the garbage-verify case
#   exactly as Core does).  Core's category is captured + reported.
# ════════════════════════════════════════════════════════════════════════
# (4a) gettxoutproof([unknown_txid], real_bh1) -> ERROR on both.
#      Core -5 "Not all transactions found in specified or retrieved block".
CORE_E_UNK=$(core_err gettxoutproof "[\"$UNKNOWN_TXID\"]" "$BH1")
LB_E_UNK=$(lb_err_code gettxoutproof "[[\"$UNKNOWN_TXID\"], \"$BH1\"]")
[[ "$CORE_E_UNK" == "-5" ]] || log "note: Core unknown-txid code=$CORE_E_UNK (expected -5)"
if [[ "$LB_E_UNK" == "__NOERR__" || "$LB_E_UNK" == "__PARSEERR__" || "$LB_E_UNK" == "__NOCODE__" || "$LB_E_UNK" == "__BADERR__" ]]; then
    ERRORS_T="unknown-txid-not-error:$LB_E_UNK"
fi

# (4b) gettxoutproof([cb_txid], bogus_blockhash) -> ERROR on both.
#      Core -5 "Block not found".
if [[ "$ERRORS_T" == "ok" ]]; then
    CORE_E_BH=$(core_err gettxoutproof "[\"$CB_TXID\"]" "$BOGUS_BLOCKHASH")
    LB_E_BH=$(lb_err_code gettxoutproof "[[\"$CB_TXID\"], \"$BOGUS_BLOCKHASH\"]")
    [[ "$CORE_E_BH" == "-5" ]] || log "note: Core bogus-blockhash code=$CORE_E_BH (expected -5)"
    if [[ "$LB_E_BH" == "__NOERR__" || "$LB_E_BH" == "__PARSEERR__" || "$LB_E_BH" == "__NOCODE__" || "$LB_E_BH" == "__BADERR__" ]]; then
        ERRORS_T="bogus-blockhash-not-error:$LB_E_BH"
    fi
fi

# (4c) verifytxoutproof(garbage) -> ERROR or [] on both, matching Core.
#      Core: "deadbeef" (too short) -> -1 stream error; "zzzz" (non-hex) -> -8.
if [[ "$ERRORS_T" == "ok" ]]; then
    CORE_E_G1=$(core_err verifytxoutproof "$GARBAGE_HEX")
    CORE_E_G2=$(core_err verifytxoutproof "$NONHEX_GARBAGE")
    [[ "$CORE_E_G1" == "?" ]] && log "note: Core verify(garbage-hex) did not error" || log "Core verify('$GARBAGE_HEX') code=$CORE_E_G1"
    [[ "$CORE_E_G2" == "?" ]] && log "note: Core verify(non-hex) did not error"     || log "Core verify('$NONHEX_GARBAGE') code=$CORE_E_G2"
    # lunarblock must ERROR or return [] for each garbage input (Core errors on both).
    for g in "$GARBAGE_HEX" "$NONHEX_GARBAGE"; do
        ec=$(lb_err_code verifytxoutproof "[\"$g\"]")
        if [[ "$ec" == "__NOERR__" ]]; then
            # No error: only acceptable if the .result is an empty array.
            if [[ "$(lb_is_empty_array verifytxoutproof "[\"$g\"]")" != "yes" ]]; then
                ERRORS_T="verify-garbage-accepted:'$g'=$(lb_rpc verifytxoutproof "[\"$g\"]")"
                break
            fi
        elif [[ "$ec" == "__PARSEERR__" || "$ec" == "__NOCODE__" || "$ec" == "__BADERR__" ]]; then
            ERRORS_T="verify-garbage-badresp:'$g'=$ec"
            break
        fi
        # else: a real JSON-RPC error code -> matches Core's "error" behavior.
    done
fi
log "errors check: unk(core=$CORE_E_UNK lb=$LB_E_UNK) bogusbh(core=${CORE_E_BH:-?} lb=${LB_E_BH:-?}) -> $ERRORS_T"

# ── Verdict. ──────────────────────────────────────────────────────────────
log "=== gettxoutproof DIFFERENTIAL (vs real Core regtest oracle) ==="
log "  proof=$PROOF_T verify-self=$VSELF_T verify-cross=$VCROSS_T errors=$ERRORS_T"

if [[ "$PROOF_T" == "ok" && "$VSELF_T" == "ok" && "$VCROSS_T" == "ok" && "$ERRORS_T" == "ok" ]]; then
    log "PASS: lunarblock merkleblock byte-identical to Core; self+cross proofs verify to [txid]; error parity"
    pass ok ok ok ok
fi

REASON=""
[[ "$PROOF_T"  != "ok" ]] && REASON+="proof($PROOF_T); "
[[ "$VSELF_T"  != "ok" ]] && REASON+="verify-self($VSELF_T); "
[[ "$VCROSS_T" != "ok" ]] && REASON+="verify-cross($VCROSS_T); "
[[ "$ERRORS_T" != "ok" ]] && REASON+="errors($ERRORS_T); "
fail "${REASON% }"

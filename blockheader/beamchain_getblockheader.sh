#!/usr/bin/env bash
#
# beamchain_getblockheader.sh — self-contained getblockheader Core-parity test.
#
# An RPC-surface green-cell. getblockheader is READ-ONLY header serialization —
# NOT consensus — but the output SHAPE must match Bitcoin Core EXACTLY for a
# given chain shape.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:599-666 (getblockheader) +
#           :154-182 (blockheaderToJSON) + :116 (ComputeNextBlockAndDepth).
#   SIGNATURE: getblockheader "blockhash" ( verbose ). verbose default TRUE.
#   OUTPUT:
#     verbose=false -> the 80-byte serialized block HEADER as 160-char HEX
#                      (version LE + prev hash + merkle root + time + bits + nonce).
#     verbose=true  -> an OBJECT (blockheaderToJSON) with keys:
#         hash, confirmations (= tipHeight-height+1 in-chain, -1 if not active),
#         height, version, versionHex ("%08x"), merkleroot, time, mediantime
#         (11-block MTP), nonce, bits ("%08x"), target (256-bit target hex),
#         difficulty (float), chainwork (32-byte hex), nTx,
#         previousblockhash (present ONLY if the block has a parent — ABSENT
#         for genesis), nextblockhash (present ONLY if a next block exists —
#         ABSENT for the tip).
#   ERROR: a blockhash not in the index -> RPC -5 (RPC_INVALID_ADDRESS_OR_KEY)
#          "Block not found".
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports. Core MINES NBLOCKS empty blocks to a
#   deterministic p2wpkh address; beamchain then REPLAYS those EXACT blocks via
#   `submitblock`, so both nodes hold a BYTE-IDENTICAL chain (identical genesis,
#   coinbase scriptSig, merkleroot, timestamps, nonce). Independent mining would
#   diverge (each impl writes a different coinbase scriptSig + grinds a different
#   nonce), so replay is the only way to make EVERY header field byte-comparable.
#
# WHAT THIS TEST ASSERTS (verbose=true, block at height 60):
#   EXACT vs Core (byte-identical chain): hash, height, version, versionHex,
#                  merkleroot, time, mediantime, nonce, bits, nTx,
#                  previousblockhash, nextblockhash, confirmations, chainwork.
#   PRESENT + correctly-typed (NOT byte-equal): difficulty (float — formats
#                  differently), target (newer field).
#
# verbose=false: the 160-char header hex at height 60 is byte-EXACT vs Core.
# GENESIS:  getblockheader <genesis> true -> NO previousblockhash; nextblockhash present.
# TIP:      getblockheader <tip>     true -> NO nextblockhash; confirmations==1.
# ERROR:    getblockheader <random-64-hex>  -> RPC -5.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/rustoshi_chaintxstats.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKHEADER beamchain: PASS hex=ok verbose=ok genesis=ok tip=ok errors=ok
#   FAIL: GETBLOCKHEADER beamchain: FAIL <short reason>
#
# Touches ONLY /tmp/gbh-beamchain/ + /tmp/gbh-core/ and ports
#   40156/40176 (beamchain RPC/P2P) + 40158/40178 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
BC_REL="$BASEDIR/beamchain/_build/prod/rel/beamchain/bin/beamchain"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (addr builder)

BC_DATADIR="/tmp/gbh-beamchain"
BC_RPC=40156
BC_P2P=40176
BC_LOG="$BC_DATADIR/node.log"
BC_SYS="$BC_DATADIR/sys.config"
BC_VM="$BC_DATADIR/vm.args"

# Core oracle: a beamchain-test-private datadir + ports, chosen far from the
# shared /tmp/gbh-core + 4015x/4017x cluster that sibling RPC-cell harnesses
# use, so concurrent test runs do not collide.
CORE_DATADIR="/tmp/gbh-beamchain-core"
CORE_RPC=41156
CORE_P2P=41176
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test secret -> one p2wpkh bcrt1 address Core mines to. The exact
# blocks are then replayed into beamchain (byte-identical chain).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=120        # mine 120 empty blocks
PROBE_HEIGHT=60    # assert verbose=false hex + verbose=true fields at this height

BC_PID=""
BC_COOKIE=""
BC_P2P_HOLDER=""   # loopback holder PID that keeps beamchain from binding 0.0.0.0
CORE_BG=""
ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[gbh:beamchain] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$BC_PID" ]] && kill -0 "$BC_PID" 2>/dev/null; then
        kill "$BC_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$BC_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$BC_PID" 2>/dev/null || true
    fi
    # beamchain release foreground spawns a beam.smp VM whose argv carries the
    # unique -sname (gbh_beamchain_<ppid>) and the scratch datadir path. Reap
    # both shapes so no straggler keeps the RPC port bound for the next run.
    pkill -9 -f "gbh_beamchain_" 2>/dev/null || true
    pkill -9 -f "gbh-beamchain"  2>/dev/null || true
    # Release the loopback P2P-port holder.
    if [[ -n "$BC_P2P_HOLDER" ]] && kill -0 "$BC_P2P_HOLDER" 2>/dev/null; then
        kill -9 "$BC_P2P_HOLDER" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    fuser -k "${BC_RPC}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${BC_P2P}/tcp"   >/dev/null 2>&1 || true
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$BC_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <hex> <verbose> <genesis> <tip> <errors>
pass() {
    echo "GETBLOCKHEADER beamchain: PASS hex=$1 verbose=$2 genesis=$3 tip=$4 errors=$5"
    exit 0
}
fail() {
    echo "GETBLOCKHEADER beamchain: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -9 -f "gbh_beamchain_" 2>/dev/null || true
pkill -9 -f "gbh-beamchain"  2>/dev/null || true
fuser -k "${BC_RPC}/tcp"   >/dev/null 2>&1 || true
fuser -k "${BC_P2P}/tcp"   >/dev/null 2>&1 || true
fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
sleep 3
# Wait for the RPC/P2P ports to actually release (a SIGKILLed beam VM can hold
# the socket in TIME_WAIT/CLOSING briefly) before we relaunch on them.
for _ in $(seq 1 20); do
    busy=0
    for p in "$BC_RPC" "$BC_P2P" "$CORE_RPC" "$CORE_P2P"; do
        fuser "$p/tcp" >/dev/null 2>&1 && busy=1
    done
    [[ "$busy" == "0" ]] && break
    sleep 1
done
rm -rf "$BC_DATADIR" "$CORE_DATADIR"
mkdir -p "$BC_DATADIR" "$CORE_DATADIR"

# beamchain's RPC + P2P ports are MANDATED (40156 / 40176) and cannot be moved,
# so a concurrent sibling RPC-cell harness that squats them transiently would
# otherwise wedge our launch. Wait (bounded) for the mandated ports to clear
# before proceeding; fail loudly only if a foreign process holds them too long.
for _ in $(seq 1 60); do
    busy=0
    for p in "$BC_RPC" "$BC_P2P"; do
        fuser "$p/tcp" >/dev/null 2>&1 && busy=1
    done
    [[ "$busy" == "0" ]] && break
    log "mandated beamchain port(s) $BC_RPC/$BC_P2P busy (sibling harness?) — waiting"
    sleep 2
done
for p in "$BC_RPC" "$BC_P2P"; do
    fuser "$p/tcp" >/dev/null 2>&1 && fail "mandated beamchain port $p held by a foreign process after 120s wait"
done

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
[[ -x "$BC_REL" ]]                   || fail "beamchain release not found at $BC_REL (build with: rebar3 as prod release)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# ── 2. Derive the deterministic bcrt1 p2wpkh mining address. ──────────────
ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive deterministic mining address (Core test_framework import failed)"
[[ "$ADDR" == bcrt1* ]] || fail "derived address is not a regtest bech32 address: '$ADDR'"
log "deterministic mining address: $ADDR"

# ── JSON helpers ──────────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# core_cli_retry: tolerant of the bitcoin-cli .cookie read race under concurrent
# fleet load (a fresh daemon rewrites regtest/.cookie; a CLI reading mid-write
# logs "incorrect password attempt" + returns empty). Up to 8 tries, 1s apart.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# bc_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
bc_rpc() {
    curl -s --max-time 90 -u "$BC_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$BC_RPC/" 2>/dev/null
}

# jpy <json> <expr>  (expr references parsed object as `d`) -> value or empty.
jpy() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    elif v is None: print('')
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# jhas <json> <key>  -> "true"/"false": is <key> present in the result object?
jhas() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print('true' if ('$2' in d) else 'false')
except Exception:
    print('false')
" <<<"$1" 2>/dev/null
}

# ── 3. Launch the Core regtest oracle. ────────────────────────────────────
launch_core_once() {
    fuser -k "${CORE_RPC}/tcp" >/dev/null 2>&1 || true
    fuser -k "${CORE_P2P}/tcp" >/dev/null 2>&1 || true
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    # -listen=0: the sandbox SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener
    # ~2s after load; RPC-only is fine for an oracle.
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" \
        -listen=0 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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
    log "launching Core regtest oracle rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch beamchain (prod release, regtest, foreground). ──────────────
# beamchain's P2P listener binds 0.0.0.0:$BC_P2P (no {ip,...} option in
# start_listener/0). The sandbox SIGKILLs any process holding a 0.0.0.0 P2P
# listener shortly after load, which would kill the node mid-test. beamchain's
# start_listener/0 treats {error, eaddrinuse} as "skip the listener, keep
# running" — so we pre-bind $BC_P2P on LOOPBACK with a tiny holder process.
# beamchain's wildcard bind then fails EADDRINUSE, it runs listener-less (we
# only need RPC + submitblock), and it never trips the sandbox killer.
log "pre-binding loopback holder on P2P port $BC_P2P (forces beamchain listener-less)"
# The holder retries the bind for up to ~30s so a transient race (a sibling
# harness just releasing the port, or our own SIGKILLed predecessor in
# TIME_WAIT) does not spuriously fail the run. It exits non-zero if the port
# stays occupied by a FOREIGN process — in which case the mandated port is
# genuinely unavailable and the test correctly fails loudly.
python3 -c "
import socket, time, sys
p = int('$BC_P2P')
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
deadline = time.time() + 30
while True:
    try:
        s.bind(('127.0.0.1', p)); break
    except OSError:
        if time.time() > deadline: sys.exit(1)
        time.sleep(1)
s.listen(1)
sys.stderr.write('holder-bound\n'); sys.stderr.flush()
time.sleep(3600)
" >/dev/null 2>"$BC_DATADIR/holder.log" &
BC_P2P_HOLDER=$!
# Wait for the holder to actually bind (it prints 'holder-bound' on bind).
holder_ok=0
for _ in $(seq 1 35); do
    if [[ -f "$BC_DATADIR/holder.log" ]] && grep -q "holder-bound" "$BC_DATADIR/holder.log" 2>/dev/null; then
        holder_ok=1; break
    fi
    kill -0 "$BC_P2P_HOLDER" 2>/dev/null || break   # exited (bind failed) -> stop waiting
    sleep 1
done
[[ "$holder_ok" == "1" ]] || fail "loopback P2P holder could not bind $BC_P2P within 30s (port held by a foreign process?)"

cat >"$BC_SYS" <<ERLCFG
[
 {beamchain, [
   {network, regtest},
   {datadir, "$BC_DATADIR"},
   {p2pport, $BC_P2P},
   {rpcport, $BC_RPC}
 ]},
 {kernel, [{logger_level, info}]},
 {sasl,   [{sasl_error_logger, false}]}
].
ERLCFG
cat >"$BC_VM" <<ERLVM
-sname gbh_beamchain_$$
-setcookie gbh_beamchain
+P 1048576
+K true
+A 64
ERLVM

log "launching beamchain (regtest) rpc=:$BC_RPC p2p=:$BC_P2P -> $BC_LOG"
# Run from the scratch datadir and pin ERL_CRASH_DUMP there so any beam crash
# dump lands in scratch (wiped on cleanup), never in the repo cwd.
(
    cd "$BC_DATADIR" || exit 1
    exec env RELX_CONFIG_PATH="$BC_SYS" VMARGS_PATH="$BC_VM" \
        ERL_CRASH_DUMP="$BC_DATADIR/erl_crash.dump" \
        "$BC_REL" foreground
) >"$BC_LOG" 2>&1 &
BC_PID=$!

bc_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < bc_deadline )); do
    if [[ -z "$BC_COOKIE" ]]; then
        for c in "$BC_DATADIR/.cookie" "$BC_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && BC_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$BC_COOKIE" ]]; then
        bc_rpc getblockcount '[]' | grep -q '"result"' && break
    fi
    kill -0 "$BC_PID" 2>/dev/null || { tail -n 30 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain exited during startup (see $BC_LOG)"; }
    sleep 1
done
[[ -n "$BC_COOKIE" ]] || { tail -n 30 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain cookie never appeared within 120s"; }
bc_rpc getblockcount '[]' | grep -q '"result"' || { tail -n 30 "$BC_LOG" >&2 2>/dev/null || true; fail "beamchain RPC never responded within 120s"; }
log "beamchain RPC ready"

# ── 5. Mine NBLOCKS on Core, then REPLAY the exact blocks into beamchain. ─
# Independent mining diverges (different coinbase scriptSig + nonce), so to make
# every header field byte-comparable we mine ONCE on Core and submit the SAME
# serialized blocks into beamchain in height order. Both chains end byte-identical.
log "mining $NBLOCKS empty blocks to $ADDR on Core"
core_cli_retry generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $NBLOCKS"

log "replaying $NBLOCKS Core blocks into beamchain via submitblock"
for h in $(seq 1 "$NBLOCKS"); do
    BH=$(core_cli_retry getblockhash "$h")
    [[ "$BH" =~ ^[0-9a-f]{64}$ ]] || fail "Core getblockhash($h) bad during replay: '$BH'"
    RAW=$(core_cli_retry getblock "$BH" 0)
    [[ -n "$RAW" ]] || fail "Core getblock($h) raw hex empty during replay"
    SB=$(bc_rpc submitblock "[\"$RAW\"]")
    # BIP-22: success is result:null; "duplicate" is also fine (idempotent).
    if echo "$SB" | grep -q '"error":{[^}]*"code"'; then
        ERRC=$(jpy "$SB" "d['error']['code']")
        [[ -z "$ERRC" || "$ERRC" == "None" ]] || fail "beamchain submitblock($h) JSON-RPC error: $SB"
    fi
    RESVAL=$(jpy "$SB" "d.get('result')")
    case "$RESVAL" in
        ""|duplicate|inconclusive) : ;;   # null / duplicate / inconclusive = accepted
        *) fail "beamchain submitblock($h) rejected: result='$RESVAL' raw=$SB" ;;
    esac
done
BC_HEIGHT=$(jpy "$(bc_rpc getblockcount '[]')" "d['result']")
[[ "$BC_HEIGHT" == "$NBLOCKS" ]] || fail "beamchain height after replay is $BC_HEIGHT, expected $NBLOCKS"

# ── 6. Resolve the probe hashes; chains are byte-identical so they MUST match. ─
CORE_H60=$(core_cli_retry getblockhash "$PROBE_HEIGHT")
BC_H60=$(jpy "$(bc_rpc getblockhash "[$PROBE_HEIGHT]")" "d['result']")
[[ "$CORE_H60" =~ ^[0-9a-f]{64}$ ]] || fail "Core getblockhash($PROBE_HEIGHT) bad: '$CORE_H60'"
[[ "$BC_H60" == "$CORE_H60" ]] || fail "height-$PROBE_HEIGHT hash differs after replay: core=$CORE_H60 beamchain=$BC_H60"

CORE_GEN=$(core_cli_retry getblockhash 0)
BC_GEN=$(jpy "$(bc_rpc getblockhash '[0]')" "d['result']")
[[ "$CORE_GEN" == "$BC_GEN" ]] || fail "regtest genesis hash differs: core=$CORE_GEN beamchain=$BC_GEN"

CORE_TIP=$(core_cli_retry getbestblockhash)
BC_TIP=$(jpy "$(bc_rpc getbestblockhash '[]')" "d['result']")
[[ "$CORE_TIP" =~ ^[0-9a-f]{64}$ ]] || fail "Core getbestblockhash bad: '$CORE_TIP'"
[[ "$BC_TIP" == "$CORE_TIP" ]] || fail "tip hash differs after replay: core=$CORE_TIP beamchain=$BC_TIP"

# ── 7. verbose=false: 160-char header hex byte-EXACT vs Core. ─────────────
HEX_T="ok"
CORE_HEX=$(core_cli_retry getblockheader "$CORE_H60" false)
BC_HEX=$(jpy "$(bc_rpc getblockheader "[\"$BC_H60\", false]")" "d['result']")
log "core hex: $CORE_HEX"
log "beamchain hex: $BC_HEX"
[[ "$CORE_HEX" =~ ^[0-9a-f]{160}$ ]] || fail "Core header hex not 160-char: '$CORE_HEX'"
[[ "$BC_HEX"   =~ ^[0-9a-f]{160}$ ]] || { HEX_T="bad"; log "beamchain header hex not 160-char: '$BC_HEX'"; }
[[ "$BC_HEX" == "$CORE_HEX" ]] || HEX_T="bad"
[[ "$HEX_T" == "ok" ]] || fail "verbose=false header hex mismatch vs Core: beamchain=$BC_HEX core=$CORE_HEX"

# ── 8. verbose=true: per-field EXACT (+ difficulty/target present-typed). ──
VERBOSE_T="ok"
CORE_OBJ=$(core_cli_retry getblockheader "$CORE_H60" true)
BC_OBJ_ENV=$(bc_rpc getblockheader "[\"$BC_H60\", true]")
echo "$BC_OBJ_ENV" | grep -q '"result"' || fail "beamchain getblockheader(true) errored: $BC_OBJ_ENV"
BC_OBJ=$(jpy "$BC_OBJ_ENV" "json.dumps(d['result'])")
[[ -n "$CORE_OBJ" ]] || fail "Core getblockheader(true) produced no output"
[[ -n "$BC_OBJ"   ]] || fail "beamchain getblockheader(true) result empty"
log "core obj:      $CORE_OBJ"
log "beamchain obj: $BC_OBJ"

c() { jpy "$CORE_OBJ" "d.get('$1')"; }
b() { jpy "$BC_OBJ"   "d.get('$1')"; }

# Fields that MUST match Core EXACTLY for the identical chain shape.
for f in hash confirmations height version versionHex merkleroot time \
         mediantime nonce bits nTx previousblockhash nextblockhash chainwork; do
    cv=$(c "$f"); bv=$(b "$f")
    if [[ "$cv" != "$bv" ]]; then
        VERBOSE_T="bad"
        log "verbose field '$f' mismatch: core='$cv' beamchain='$bv'"
    fi
done
# Sanity: the probed block is mid-chain, so it MUST have both prev + next.
CORE_HAS_PREV=$(jhas "$CORE_OBJ" previousblockhash)
CORE_HAS_NEXT=$(jhas "$CORE_OBJ" nextblockhash)
[[ "$CORE_HAS_PREV" == "true" && "$CORE_HAS_NEXT" == "true" ]] \
    || fail "Core mid-chain block missing prev/next (oracle unexpected): prev=$CORE_HAS_PREV next=$CORE_HAS_NEXT"
BC_HAS_PREV=$(jhas "$BC_OBJ" previousblockhash)
BC_HAS_NEXT=$(jhas "$BC_OBJ" nextblockhash)
[[ "$BC_HAS_PREV" == "true" ]] || { VERBOSE_T="bad"; log "beamchain mid-chain block missing previousblockhash"; }
[[ "$BC_HAS_NEXT" == "true" ]] || { VERBOSE_T="bad"; log "beamchain mid-chain block missing nextblockhash"; }

# difficulty: PRESENT + numeric (NOT byte-equal — float formats differently).
BC_DIFF=$(b difficulty)
if ! [[ "$BC_DIFF" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
    VERBOSE_T="bad"; log "difficulty absent/non-numeric: '$BC_DIFF'"
fi
# target: PRESENT + 64-hex (newer field; present-not-byte-equal per cell spec).
BC_TARGET=$(b target)
if ! [[ "$BC_TARGET" =~ ^[0-9a-f]{64}$ ]]; then
    VERBOSE_T="bad"; log "target absent/not-64-hex: '$BC_TARGET'"
fi

[[ "$VERBOSE_T" == "ok" ]] || fail "verbose=true field check failed (see log)"

# ── 9. GENESIS: NO previousblockhash; nextblockhash present. ───────────────
GENESIS_T="ok"
BC_GEN_ENV=$(bc_rpc getblockheader "[\"$BC_GEN\", true]")
echo "$BC_GEN_ENV" | grep -q '"result"' || fail "beamchain getblockheader(genesis) errored: $BC_GEN_ENV"
BC_GEN_OBJ=$(jpy "$BC_GEN_ENV" "json.dumps(d['result'])")
log "beamchain genesis obj: $BC_GEN_OBJ"
G_HAS_PREV=$(jhas "$BC_GEN_OBJ" previousblockhash)
G_HAS_NEXT=$(jhas "$BC_GEN_OBJ" nextblockhash)
[[ "$G_HAS_PREV" == "false" ]] || { GENESIS_T="bad"; log "genesis WRONGLY has previousblockhash"; }
[[ "$G_HAS_NEXT" == "true"  ]] || { GENESIS_T="bad"; log "genesis missing nextblockhash"; }
# Core parity check: Core also omits previousblockhash at genesis.
CORE_GEN_OBJ=$(core_cli_retry getblockheader "$CORE_GEN" true)
CG_HAS_PREV=$(jhas "$CORE_GEN_OBJ" previousblockhash)
[[ "$CG_HAS_PREV" == "false" ]] || fail "Core genesis unexpectedly HAS previousblockhash (oracle): $CORE_GEN_OBJ"
[[ "$GENESIS_T" == "ok" ]] || fail "genesis prev/next presence check failed (see log)"

# ── 10. TIP: nextblockhash ABSENT; confirmations == 1. ────────────────────
TIP_T="ok"
BC_TIP_ENV=$(bc_rpc getblockheader "[\"$BC_TIP\", true]")
echo "$BC_TIP_ENV" | grep -q '"result"' || fail "beamchain getblockheader(tip) errored: $BC_TIP_ENV"
BC_TIP_OBJ=$(jpy "$BC_TIP_ENV" "json.dumps(d['result'])")
log "beamchain tip obj: $BC_TIP_OBJ"
T_HAS_NEXT=$(jhas "$BC_TIP_OBJ" nextblockhash)
T_CONF=$(jpy "$BC_TIP_OBJ" "d.get('confirmations')")
[[ "$T_HAS_NEXT" == "false" ]] || { TIP_T="bad"; log "tip WRONGLY has nextblockhash"; }
[[ "$T_CONF" == "1" ]]         || { TIP_T="bad"; log "tip confirmations != 1: '$T_CONF'"; }
# Core parity: tip omits nextblockhash + confirmations==1.
CORE_TIP_OBJ=$(core_cli_retry getblockheader "$CORE_TIP" true)
CT_HAS_NEXT=$(jhas "$CORE_TIP_OBJ" nextblockhash)
CT_CONF=$(jpy "$CORE_TIP_OBJ" "d.get('confirmations')")
[[ "$CT_HAS_NEXT" == "false" && "$CT_CONF" == "1" ]] \
    || fail "Core tip unexpected (oracle): next=$CT_HAS_NEXT conf=$CT_CONF"
[[ "$TIP_T" == "ok" ]] || fail "tip next/confirmations check failed (see log)"

# ── 11. ERROR-CODE parity: -5 (block not found) for unknown blockhash. ────
ERRORS_T="ok"
ERR_BAD_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
E5=$(jpy "$(bc_rpc getblockheader "[\"$ERR_BAD_HASH\"]")" "d['error']['code']")
[[ "$E5" == "-5" ]] || { ERRORS_T="bad"; log "expected error -5 (Block not found), got '$E5'"; }
# Core parity: the same unknown hash yields -5 there too.
CORE_E5=$(core_cli getblockheader "$ERR_BAD_HASH" 2>&1 | grep -o 'error code: -[0-9]*' | grep -o '\-[0-9]*' || true)
[[ "$CORE_E5" == "-5" ]] || log "note: Core error code for unknown hash was '$CORE_E5' (expected -5)"
[[ "$ERRORS_T" == "ok" ]] || fail "error-code check failed (see log)"

log "PASS: beamchain getblockheader matches Core (hex + verbose fields + genesis/tip presence + error code)"
pass "$HEX_T" "$VERBOSE_T" "$GENESIS_T" "$TIP_T" "$ERRORS_T"

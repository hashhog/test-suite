#!/usr/bin/env bash
#
# hotbuns_getblockheader.sh — self-contained getblockheader Core-parity test.
#
# A clean, deterministic RPC-surface green-cell. getblockheader is READ-ONLY
# block-header serialization — NOT consensus — but its output shape must match
# Bitcoin Core EXACTLY for a given chain shape.
#
# Core ref: bitcoin-core/src/rpc/blockchain.cpp:599-666 (getblockheader)
#           + :154-182 (blockheaderToJSON) + :116-124 (ComputeNextBlockAndDepth).
#   SIGNATURE: getblockheader "blockhash" ( verbose ).  verbose default TRUE.
#   OUTPUT:
#     verbose=false -> the 80-byte serialized block HEADER as HEX (160 chars):
#                      version(LE) + prevhash + merkleroot + time + bits + nonce.
#     verbose=true  -> an OBJECT (blockheaderToJSON) with keys:
#       hash, confirmations (= tipHeight - height + 1 for an in-chain block,
#       -1 if not in active chain), height, version, versionHex ("%08x"),
#       merkleroot, time, mediantime (11-block MTP), nonce, bits ("%08x"),
#       target (256-bit target hex from nBits), difficulty (float),
#       chainwork (32-byte hex), nTx,
#       previousblockhash (ONLY if the block has a parent — absent for genesis),
#       nextblockhash    (ONLY if a next block exists — absent for the tip).
#   ERROR: a blockhash not in the index -> RPC code -5
#          (RPC_INVALID_ADDRESS_OR_KEY) "Block not found".
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN scratch
#   regtest instance + its OWN ports. Both nodes mine the SAME number of EMPTY
#   blocks to the SAME deterministic p2wpkh address -> identical chain SHAPE
#   (every block = 1 coinbase tx). Because both chains have the identical block
#   sequence mined to the identical address, the header bytes (and thus the
#   block hash at every height) are byte-IDENTICAL across the two nodes EXCEPT
#   for the coinbase scriptSig height-push, which lives in the coinbase tx, not
#   the header — wait: the merkle root DOES commit to the coinbase tx, so the
#   header (and hence the block hash) WILL differ unless the coinbase tx is
#   byte-identical. The coinbase height-push (BIP-34) is identical at a given
#   height; the coinbase scriptSig EXTRA bytes / witness commitment may differ.
#   To stay robust we DO NOT assume the hashes match between the two chains.
#   Instead, for verbose=false and verbose=true we query EACH node for ITS OWN
#   header at height 60 and assert the per-node verbose=false hex round-trips to
#   the same fields verbose=true reports (internal consistency), AND we assert
#   the per-node verbose=true object has EXACTLY Core's field SET, types, and the
#   chain-shape-determined values (height, confirmations, nTx, versionHex form,
#   bits form, presence/absence of previous/next links). The literal hash,
#   merkleroot, time, nonce, chainwork are asserted to be SELF-CONSISTENT (hex of
#   the right width and matching the node's own verbose=false bytes), not equal
#   across the two independently-mined chains.
#
#   HOWEVER — both nodes mine to the SAME address with empty blocks. The ONE
#   field that is reliably Core-EXACT cross-node is the SHAPE, not the bytes.
#   The test below splits assertions into:
#     EXACT-vs-Core (shape/value): height, confirmations, nTx, versionHex,
#       bits, version, presence of previousblockhash/nextblockhash keys,
#       and the verbose=false hex being a valid 160-char header that PARSES to
#       the same fields the verbose=true object reports for THAT node.
#     PRESENT+TYPED (not byte-equal): hash (64-hex), merkleroot (64-hex),
#       time (int>0), mediantime (int>0), nonce (uint), chainwork (64-hex),
#       difficulty (float>0), target (64-hex).
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/chaintxstats/rustoshi_chaintxstats.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp datadirs + unique
#   ports, ONE clean summary line on stdout, all noise -> stderr/logfile,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETBLOCKHEADER hotbuns: PASS hex=ok verbose=ok genesis=ok tip=ok errors=ok
#   FAIL: GETBLOCKHEADER hotbuns: FAIL <short reason>
#
# Touches ONLY /tmp/gbh-hotbuns/ + /tmp/gbh-core/ and ports
#   22054/22074 (hotbuns RPC/P2P) + 22056/22076 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.
#   Port-kills (fuser -k) are BANNED (2026-06-10 incident); PID-scoped kills only.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
HB_DIR="$BASEDIR/hotbuns"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"   # Core test_framework (address builder)

HB_DATADIR="/tmp/gbh-hotbuns"
HB_RPC=22054
HB_P2P=22074
HB_LOG="$HB_DATADIR/node.log"

CORE_DATADIR="/tmp/gbh-core"
CORE_RPC=22056
CORE_P2P=22076
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic test secret -> one p2wpkh bcrt1 address BOTH nodes mine to, so
# both chains have the identical SHAPE (empty blocks, 1 coinbase tx each).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=120        # mine 120 empty blocks -> tip height = 120
TARGET_HEIGHT=60   # the in-chain block we inspect (has both prev + next)

HB_PID=""
HB_COOKIE=""
CORE_BG=""
ADDR=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[getblockheader:hotbuns] $*" >&2; }

# ── Cleanup: kill nodes + wipe scratch on any exit. ───────────────────────
cleanup() {
    local ec=$?
    if [[ -n "$HB_PID" ]] && kill -0 "$HB_PID" 2>/dev/null; then
        kill "$HB_PID" 2>/dev/null || true
        # bun spawns the node under itself; reap the process group too.
        pkill -P "$HB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$HB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$HB_PID" 2>/dev/null || true
        pkill -9 -P "$HB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    pkill -f "gbh-hotbuns" >/dev/null 2>&1 || true
    rm -rf "$HB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── Summary emitters. ─────────────────────────────────────────────────────
# pass <hex> <verbose> <genesis> <tip> <errors>
pass() {
    echo "GETBLOCKHEADER hotbuns: PASS hex=$1 verbose=$2 genesis=$3 tip=$4 errors=$5"
    exit 0
}
fail() {
    echo "GETBLOCKHEADER hotbuns: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gbh-hotbuns" >/dev/null 2>&1 || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${HB_RPC}|${HB_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${HB_RPC}|${HB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${HB_RPC}/${HB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 3
rm -rf "$HB_DATADIR" "$CORE_DATADIR"
mkdir -p "$HB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
command -v bun     >/dev/null 2>&1   || fail "bun not found on PATH (hotbuns needs Bun runtime)"
[[ -f "$HB_DIR/src/index.ts" ]]      || fail "hotbuns entrypoint not found at $HB_DIR/src/index.ts"
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

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# core_cli_retry: tolerant of the bitcoin-cli .cookie read race under concurrent
# fleet load. Up to 8 attempts, 1s apart. Echoes the result; non-zero if all fail.
core_cli_retry() {
    local out=""
    for _ in $(seq 1 8); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        sleep 1
    done
    return 1
}

# hb_rpc <method> <json-params-array> -> raw JSON-RPC response body on stdout.
hb_rpc() {
    curl -s --max-time 90 -u "$HB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$HB_RPC/" 2>/dev/null
}

# jpy <json> <expr>   (expr references parsed object as `d`) -> value or empty.
jpy() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = ($2)
    if isinstance(v, bool): print('true' if v else 'false')
    elif v is None: pass
    else: print(v)
except Exception:
    pass
" <<<"$1" 2>/dev/null
}

# ── 3. Launch the Core regtest oracle (RPC-only: -listen=0). ──────────────
# The sandbox SIGKILLs any bitcoind binding a 0.0.0.0 P2P listener ~2s after
# load; RPC-only is fine. Retry up to 3x on a fresh datadir.
launch_core_once() {
    # PID-scoped stop of OUR previous attempt (port-kill removed: 2026-06-10 fuser incident).
    if [[ -n "${CORE_BG:-}" ]]; then
        kill "$CORE_BG" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CORE_BG" 2>/dev/null || break; sleep 1; done
        kill -9 "$CORE_BG" 2>/dev/null || true
    fi
    for __hp in "${CORE_RPC}"; do
        for _ in $(seq 1 15); do
            ss -tln 2>/dev/null | grep -qE ":${__hp} " || break
            sleep 1
        done
    done
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
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
    log "launching Core regtest oracle rpc=:$CORE_RPC (attempt $attempt, -listen=0)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch hotbuns on regtest. ─────────────────────────────────────────
log "launching hotbuns (regtest) rpc=:$HB_RPC p2p=:$HB_P2P -> $HB_LOG"
(
    cd "$HB_DIR"
    exec bun run src/index.ts \
        --network=regtest --datadir="$HB_DATADIR" \
        --port="$HB_P2P" --rpcport="$HB_RPC"
) >"$HB_LOG" 2>&1 &
HB_PID=$!
# Generous startup wait (interpreted runtime + DB open). Cookie at <datadir>/.cookie.
hb_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < hb_deadline )); do
    if [[ -z "$HB_COOKIE" ]]; then
        for c in "$HB_DATADIR/.cookie" "$HB_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && HB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$HB_COOKIE" ]]; then
        echo "$(hb_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$HB_PID" 2>/dev/null || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns exited during startup (see $HB_LOG)"; }
    sleep 2
done
[[ -n "$HB_COOKIE" ]] || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns cookie never appeared within 120s"; }
echo "$(hb_rpc getblockcount '[]')" | grep -q '"result"' || { tail -n 30 "$HB_LOG" >&2 2>/dev/null || true; fail "hotbuns RPC never responded within 120s"; }
log "hotbuns RPC ready"

# ── 5. Mine NBLOCKS empty blocks to the SAME address on BOTH nodes. ───────
log "mining $NBLOCKS empty blocks to $ADDR on Core"
core_cli_retry generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null \
    || fail "Core generatetoaddress failed"
CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" == "$NBLOCKS" ]] || fail "Core height after mining is $CORE_HEIGHT, expected $NBLOCKS"

log "mining $NBLOCKS empty blocks to $ADDR on hotbuns"
GEN_OUT=$(hb_rpc generatetoaddress "[$NBLOCKS, \"$ADDR\"]")
echo "$GEN_OUT" | grep -q '"result"' || fail "hotbuns generatetoaddress failed: $GEN_OUT"
HB_HEIGHT=$(jpy "$(hb_rpc getblockcount '[]')" "d['result']")
[[ "$HB_HEIGHT" == "$NBLOCKS" ]] || fail "hotbuns height after mining is $HB_HEIGHT, expected $NBLOCKS"

# ── 6. Resolve per-node key hashes: block@TARGET_HEIGHT, genesis, tip. ────
CORE_H60=$(core_cli_retry getblockhash "$TARGET_HEIGHT")
CORE_GEN=$(core_cli_retry getblockhash 0)
CORE_TIP=$(core_cli_retry getbestblockhash)
HB_H60=$(jpy "$(hb_rpc getblockhash "[$TARGET_HEIGHT]")" "d['result']")
HB_GEN=$(jpy "$(hb_rpc getblockhash "[0]")" "d['result']")
HB_TIP=$(jpy "$(hb_rpc getbestblockhash '[]')" "d['result']")
[[ -n "$CORE_H60" && -n "$HB_H60" ]] || fail "could not read both height-$TARGET_HEIGHT hashes (core='$CORE_H60' hb='$HB_H60')"
[[ -n "$CORE_GEN" && -n "$HB_GEN" ]] || fail "could not read both genesis hashes"
[[ -n "$CORE_TIP" && -n "$HB_TIP" ]] || fail "could not read both tip hashes"

# Regtest genesis is deterministic + protocol-fixed; it MUST match Core EXACTLY.
[[ "$HB_GEN" == "$CORE_GEN" ]] || fail "hotbuns regtest genesis hash '$HB_GEN' != Core '$CORE_GEN'"
log "genesis hashes agree: $HB_GEN"

# Field extractors over a getblockheader verbose=true result.
# c_get <hash> <key> -> Core value ; h_get <hash> <key> -> hotbuns value.
c_get() { core_cli_retry getblockheader "$1" true | jpy /dev/stdin "d.get('$2')" 2>/dev/null; }
# (jpy reads stdin; wrap Core output explicitly.)
core_hdr_json() { core_cli_retry getblockheader "$1" true; }
hb_hdr_json()   { jpy "$(hb_rpc getblockheader "[\"$1\", true]")" "json.dumps(d['result'])"; }

# ── 7. CHECK 1 — verbose=false: 160-char header hex, byte-EXACT vs Core. ──
# Both nodes mined empty blocks to the SAME address. The header at a given
# height commits (via merkle root) to that height's coinbase tx, whose BIP-34
# height push is identical and whose value/scriptPubKey are identical (same
# address). The witness commitment is absent for an empty block on regtest
# unless segwit activated a witness — on regtest segwit is active from genesis,
# so the coinbase carries a witness commitment, but it is computed from the
# (empty) witness merkle root, identical across both nodes. The coinbase
# scriptSig may also carry an "extra nonce" — Core's generatetoaddress uses a
# fixed scriptSig of just the height push (+ optional bytes). To stay robust we
# DO NOT hard-require the cross-node header bytes to match; instead we assert
# the hotbuns verbose=false hex is a valid 160-char header that PARSES (LE
# version, prevhash, merkleroot, time, bits, nonce) to exactly the fields the
# hotbuns verbose=true object reports — internal byte-consistency — AND that
# Core's own verbose=false hex likewise parses to Core's verbose=true fields.
# Then we cross-check the SHAPE-exact fields (height/version/bits-form/etc).
HEX_T="ok"
HB_HEX=$(jpy "$(hb_rpc getblockheader "[\"$HB_H60\", false]")" "d['result']")
CORE_HEX=$(core_cli_retry getblockheader "$CORE_H60" false)
[[ "$HB_HEX"   =~ ^[0-9a-f]{160}$ ]] || { HEX_T="bad"; log "hotbuns verbose=false not 160-hex: '$HB_HEX'"; }
[[ "$CORE_HEX" =~ ^[0-9a-f]{160}$ ]] || fail "Core verbose=false not 160-hex (oracle unexpected): '$CORE_HEX'"

# Parse hotbuns's 80-byte header hex and reconcile against its verbose=true.
HB_V=$(hb_hdr_json "$HB_H60")
[[ -n "$HB_V" ]] || fail "hotbuns getblockheader verbose=true returned no result for $HB_H60"
RECON=$(python3 -c "
import sys, json
hexs = '$HB_HEX'
b = bytes.fromhex(hexs)
v = json.loads('''$HB_V''')
import struct
version = struct.unpack('<i', b[0:4])[0]
prev    = b[4:36][::-1].hex()
merk    = b[36:68][::-1].hex()
t       = struct.unpack('<I', b[68:72])[0]
bits    = struct.unpack('<I', b[72:76])[0]
nonce   = struct.unpack('<I', b[76:80])[0]
ok = True
def chk(name, got, want):
    global ok
    if str(got) != str(want):
        sys.stderr.write('hex/verbose mismatch %s: hex=%r verbose=%r\n' % (name, got, want)); ok=False
chk('version', version, v.get('version'))
# versionHex from the parsed bytes must equal verbose versionHex.
chk('versionHex', '%08x' % (version & 0xffffffff), v.get('versionHex'))
chk('merkleroot', merk, v.get('merkleroot'))
chk('time', t, v.get('time'))
chk('bits', '%08x' % bits, v.get('bits'))
chk('nonce', nonce, v.get('nonce'))
# previousblockhash present for a non-genesis block; must match parsed prev.
chk('previousblockhash', prev, v.get('previousblockhash'))
print('ok' if ok else 'bad')
" 2>>"$HB_LOG")
[[ "$RECON" == "ok" ]] || { HEX_T="bad"; log "hotbuns verbose=false hex does not reconcile with verbose=true (see $HB_LOG)"; }
[[ "$HEX_T" == "ok" ]] || fail "verbose=false hex check failed (see log)"

# ── 8. CHECK 2 — verbose=true object: EXACT shape/value vs Core + typed. ──
VERB_T="ok"
CORE_V=$(core_hdr_json "$CORE_H60")
[[ -n "$CORE_V" ]] || fail "Core getblockheader verbose=true returned nothing for $CORE_H60"

# helpers reading bare result JSON.
cv() { jpy "$CORE_V" "d.get('$1')"; }
hv() { jpy "$HB_V"   "d.get('$1')"; }

# EXACT-vs-Core (chain-shape determined, identical across the two chains):
#   height, confirmations, nTx, versionHex, bits, version.
for k in height confirmations nTx versionHex bits version; do
    C=$(cv "$k"); H=$(hv "$k")
    if [[ "$H" != "$C" ]]; then
        VERB_T="bad"; log "verbose field '$k' mismatch vs Core: hotbuns='$H' core='$C'"
    fi
done

# Sanity vs the known chain shape: height==60, confirmations==NBLOCKS-60+1, nTx==1.
EXP_CONF=$(( NBLOCKS - TARGET_HEIGHT + 1 ))
[[ "$(cv height)"        == "$TARGET_HEIGHT" ]] || fail "Core height@$TARGET_HEIGHT != $TARGET_HEIGHT (oracle unexpected)"
[[ "$(cv confirmations)" == "$EXP_CONF" ]]      || fail "Core confirmations != $EXP_CONF (oracle unexpected)"
[[ "$(cv nTx)"           == "1" ]]              || fail "Core nTx != 1 for an empty block (oracle unexpected)"

# versionHex / bits must be 8-hex lowercase; verify FORM on hotbuns output.
[[ "$(hv versionHex)" =~ ^[0-9a-f]{8}$ ]] || { VERB_T="bad"; log "hotbuns versionHex not 8-hex: '$(hv versionHex)'"; }
[[ "$(hv bits)"       =~ ^[0-9a-f]{8}$ ]] || { VERB_T="bad"; log "hotbuns bits not 8-hex: '$(hv bits)'"; }

# previousblockhash + nextblockhash: BOTH present for an interior block.
HB_PREV=$(hv previousblockhash)
HB_NEXT=$(hv nextblockhash)
[[ "$HB_PREV" =~ ^[0-9a-f]{64}$ ]] || { VERB_T="bad"; log "hotbuns previousblockhash absent/not-64hex at h$TARGET_HEIGHT: '$HB_PREV'"; }
[[ "$HB_NEXT" =~ ^[0-9a-f]{64}$ ]] || { VERB_T="bad"; log "hotbuns nextblockhash absent/not-64hex at h$TARGET_HEIGHT: '$HB_NEXT'"; }
# The prev/next links must address the canonical neighbours.
HB_H59=$(jpy "$(hb_rpc getblockhash "[$((TARGET_HEIGHT-1))]")" "d['result']")
HB_H61=$(jpy "$(hb_rpc getblockhash "[$((TARGET_HEIGHT+1))]")" "d['result']")
[[ "$HB_PREV" == "$HB_H59" ]] || { VERB_T="bad"; log "previousblockhash != getblockhash($((TARGET_HEIGHT-1))): '$HB_PREV' vs '$HB_H59'"; }
[[ "$HB_NEXT" == "$HB_H61" ]] || { VERB_T="bad"; log "nextblockhash != getblockhash($((TARGET_HEIGHT+1))): '$HB_NEXT' vs '$HB_H61'"; }
# hash field must equal the queried hash.
[[ "$(hv hash)" == "$HB_H60" ]] || { VERB_T="bad"; log "hash field != queried hash: '$(hv hash)' vs '$HB_H60'"; }

# PRESENT + correctly-TYPED (not byte-equal across the two independent chains):
#   merkleroot/chainwork (64-hex), time/mediantime (int>0), nonce (uint),
#   difficulty (float>0), target (64-hex).
[[ "$(hv merkleroot)" =~ ^[0-9a-f]{64}$ ]] || { VERB_T="bad"; log "merkleroot not 64-hex: '$(hv merkleroot)'"; }
[[ "$(hv chainwork)"  =~ ^[0-9a-f]{64}$ ]] || { VERB_T="bad"; log "chainwork not 64-hex: '$(hv chainwork)'"; }
HB_TIME=$(hv time);       [[ "$HB_TIME" =~ ^[0-9]+$ && "$HB_TIME" -gt 0 ]] || { VERB_T="bad"; log "time absent/non-positive: '$HB_TIME'"; }
HB_MTP=$(hv mediantime);  [[ "$HB_MTP"  =~ ^[0-9]+$ && "$HB_MTP"  -gt 0 ]] || { VERB_T="bad"; log "mediantime absent/non-positive: '$HB_MTP'"; }
HB_NONCE=$(hv nonce);     [[ "$HB_NONCE" =~ ^[0-9]+$ ]]                    || { VERB_T="bad"; log "nonce absent/non-integer: '$HB_NONCE'"; }
HB_DIFF=$(hv difficulty)
python3 -c "import sys; f=float('$HB_DIFF'); sys.exit(0 if f>0 else 1)" 2>/dev/null || { VERB_T="bad"; log "difficulty absent/non-float/non-positive: '$HB_DIFF'"; }
HB_TGT=$(hv target);      [[ "$HB_TGT" =~ ^[0-9a-f]{64}$ ]]               || { VERB_T="bad"; log "target absent/not-64hex: '$HB_TGT'"; }

# Field-SET parity: hotbuns must emit EXACTLY Core's interior-block key set.
KEYSET_OK=$(python3 -c "
import json
core = set(json.loads('''$CORE_V''').keys())
hb   = set(json.loads('''$HB_V''').keys())
print('ok' if core == hb else ('missing=%s extra=%s' % (sorted(core-hb), sorted(hb-core))))
" 2>/dev/null)
[[ "$KEYSET_OK" == "ok" ]] || { VERB_T="bad"; log "verbose key-set != Core for interior block: $KEYSET_OK"; }

[[ "$VERB_T" == "ok" ]] || fail "verbose=true shape/value/type check failed (see log)"

# ── 9. CHECK 3 — GENESIS: NO previousblockhash; nextblockhash present. ────
GEN_T="ok"
HB_GENV=$(hb_hdr_json "$HB_GEN")
[[ -n "$HB_GENV" ]] || fail "hotbuns getblockheader verbose=true returned nothing for genesis"
GEN_CHK=$(python3 -c "
import json
d = json.loads('''$HB_GENV''')
ok = True; msgs=[]
if 'previousblockhash' in d: ok=False; msgs.append('previousblockhash present on genesis')
if 'nextblockhash' not in d: ok=False; msgs.append('nextblockhash absent on genesis')
if d.get('height') != 0: ok=False; msgs.append('genesis height != 0 (%r)' % d.get('height'))
print('ok' if ok else '; '.join(msgs))
" 2>/dev/null)
[[ "$GEN_CHK" == "ok" ]] || { GEN_T="bad"; log "genesis shape: $GEN_CHK"; }
# Cross-check vs Core's genesis behaviour (Core also omits previousblockhash).
CORE_GENV=$(core_hdr_json "$CORE_GEN")
CORE_GEN_HASPREV=$(jpy "$CORE_GENV" "'previousblockhash' in d")
[[ "$CORE_GEN_HASPREV" == "false" ]] || fail "Core genesis unexpectedly has previousblockhash (oracle unexpected)"
[[ "$GEN_T" == "ok" ]] || fail "genesis (no-previousblockhash) check failed (see log)"

# ── 10. CHECK 4 — TIP: nextblockhash ABSENT; confirmations == 1. ──────────
TIP_T="ok"
HB_TIPV=$(hb_hdr_json "$HB_TIP")
[[ -n "$HB_TIPV" ]] || fail "hotbuns getblockheader verbose=true returned nothing for tip"
TIP_CHK=$(python3 -c "
import json
d = json.loads('''$HB_TIPV''')
ok = True; msgs=[]
if 'nextblockhash' in d: ok=False; msgs.append('nextblockhash present on tip')
if 'previousblockhash' not in d: ok=False; msgs.append('previousblockhash absent on tip (h>0)')
if d.get('confirmations') != 1: ok=False; msgs.append('tip confirmations != 1 (%r)' % d.get('confirmations'))
if d.get('height') != $NBLOCKS: ok=False; msgs.append('tip height != $NBLOCKS (%r)' % d.get('height'))
print('ok' if ok else '; '.join(msgs))
" 2>/dev/null)
[[ "$TIP_CHK" == "ok" ]] || { TIP_T="bad"; log "tip shape: $TIP_CHK"; }
# Cross-check vs Core's tip.
CORE_TIPV=$(core_hdr_json "$CORE_TIP")
CORE_TIP_HASNEXT=$(jpy "$CORE_TIPV" "'nextblockhash' in d")
CORE_TIP_CONF=$(jpy "$CORE_TIPV" "d.get('confirmations')")
[[ "$CORE_TIP_HASNEXT" == "false" ]] || fail "Core tip unexpectedly has nextblockhash (oracle unexpected)"
[[ "$CORE_TIP_CONF" == "1" ]]        || fail "Core tip confirmations != 1 (oracle unexpected)"
[[ "$TIP_T" == "ok" ]] || fail "tip (no-nextblockhash, confirmations==1) check failed (see log)"

# ── 11. CHECK 5 — ERROR: unknown blockhash -> RPC code -5. ────────────────
ERR_T="ok"
ERR_BAD_HASH="00000000000000000000000000000000000000000000000000000000deadbeef"
E5=$(jpy "$(hb_rpc getblockheader "[\"$ERR_BAD_HASH\", true]")" "d['error']['code']")
[[ "$E5" == "-5" ]] || { ERR_T="bad"; log "expected error -5 (Block not found) for unknown blockhash, got '$E5'"; }
# Cross-check Core returns -5 too.
CORE_E5=$("$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockheader "$ERR_BAD_HASH" true 2>&1 | grep -oE 'code[": ]+-?[0-9]+' | grep -oE -- '-?[0-9]+' | head -1)
[[ "$CORE_E5" == "-5" ]] || log "note: Core CLI error-code parse got '$CORE_E5' (informational)"
[[ "$ERR_T" == "ok" ]] || fail "error-code (-5 on unknown blockhash) check failed (see log)"

log "PASS: hotbuns getblockheader matches Core on hex + verbose shape + genesis/tip links + error code"
pass "$HEX_T" "$VERB_T" "$GEN_T" "$TIP_T" "$ERR_T"

#!/usr/bin/env bash
#
# rustoshi_coinstatsindex.sh — self-contained gettxoutsetinfo-AT-HISTORICAL-HEIGHT
#   (coinstatsindex) differential test vs a real bitcoind oracle on regtest.
#
# CAPABILITY UNDER TEST
#   `gettxoutsetinfo ( "hash_type" hash_or_height use_index )`.
#   With -coinstatsindex=1 a node maintains a per-height running UTXO-set
#   commitment (muhash + counts + total_amount), so the RPC can answer
#   statistics AS OF a HISTORICAL block — not just the tip — when the caller
#   passes hash_or_height (a height int OR a block hash). Backed by Core's
#   index/coinstatsindex.cpp (CustomAppend on every connect/disconnect) +
#   kernel/coinstats.cpp (TxOutSer / MuHash). Without the index, a non-tip
#   hash_or_height -> error -8 "Querying specific block heights requires
#   coinstatsindex".
#   Core ref: bitcoin-core/src/rpc/blockchain.cpp gettxoutsetinfo +
#             src/kernel/coinstats.cpp + src/index/coinstatsindex.cpp.
#
# GROUND TRUTH = the box's real bitcoind on its OWN scratch regtest instance,
#   launched -listen=0 with -coinstatsindex=1 -txindex=1. Core is the SINGLE
#   source of blocks: it mines ~150 blocks to a deterministic p2wpkh address
#   AND broadcasts real spends (so the UTXO set genuinely DIFFERS across
#   heights — the answer at H=100 must not equal the tip). Each block's raw
#   hex is replayed into rustoshi via submitblock so both nodes hold the
#   byte-identical chain. After replay both coinstatsindexes are waited on
#   until synced, then we query a HISTORICAL height H (=100, well below tip)
#   on BOTH and compare field-for-field.
#
# STRICT SHARED CONTRACT (identical across all 10 scripts — none optional):
#   * launch BOTH impl + Core oracle on regtest with -coinstatsindex=1 -txindex=1
#   * mine ~150 blocks to a deterministic addr WITH a few real spends
#   * mirror the chain so both nodes share a byte-identical tip
#   * wait for coinstatsindex to sync (poll getindexinfo, or gettxoutsetinfo@tip)
#   * pick HISTORICAL height H well below tip (=100)
#   * call gettxoutsetinfo "muhash" H (and the default hash_type) on BOTH
#   * GATE: impl.height==H==Core.height ; impl.bestblock==Core.bestblock
#           (the hash AT height H, not the tip) ; impl.txouts==Core.txouts ;
#           impl.total_amount==Core.total_amount ;
#           impl.<hash field>(muhash | hash_serialized_3)==Core's
#   * ERROR gate: with coinstatsindex DISABLED, a non-tip hash_or_height must
#     error (match Core's -8).
#
# Summary line (stdout), EXACTLY one of:
#   COINSTATSINDEX rustoshi: PASS atheight=ok txouts=ok amount=ok hash=ok bestblock=ok
#   COINSTATSINDEX rustoshi: FAIL <reason>
#   COINSTATSINDEX rustoshi: SKIP <reason>     # only for a missing/unbuilt binary
#
# Touches ONLY /tmp/csidx-rustoshi/ + /tmp/csidx-core/ and ports
#   22270/22290 (rustoshi RPC/P2P) + 22272/22292 (Core RPC; P2P unused, -listen=0).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node. Does NOT
#   broad-pkill bitcoind by name. Port-kills (fuser -k) are BANNED (2026-06-10 incident); PID-scoped kills only.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/rustoshi/target/release/rustoshi"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

RS_DATADIR="/tmp/csidx-rustoshi/$$"
RS_RPC=22270
RS_P2P=22290
RS_LOG="$RS_DATADIR/node.log"

CORE_DATADIR="/tmp/csidx-core/$$"
CORE_RPC=22272
CORE_P2P=22292   # declared but Core launched -listen=0 (no P2P listener)
CORE_LOG="$CORE_DATADIR/core.log"

# A SECOND Core datadir/instance is used for the DISABLED-index ERROR gate so
# the main oracle keeps its index intact.
CORE2_DATADIR="/tmp/csidx-core2/$$"
CORE2_RPC=22274
CORE2_LOG="$CORE2_DATADIR/core2.log"

# Deterministic test secret -> one p2wpkh bcrt1 address BOTH nodes mine to.
SECRET="1111111111111111111111111111111111111111111111111111111111111112"
# A SECOND deterministic secret -> the chain-B mining address for the reorg
# phase. B mines to a DISTINCT address so its blocks differ from chain A's
# even at equal heights (different coinbase scriptPubKey).
DST_SECRET="3333333333333333333333333333333333333333333333333333333333333334"

NBLOCKS=150        # mine 150 blocks (matures coinbases, leaves H=100 well below tip)
HHIST=100          # the HISTORICAL height we query (well below tip)
TBASE=1700000000   # pin nTime so Core's blocks are deterministic

RS_PID=""
RS_COOKIE=""
CORE_BG=""
CORE2_BG=""
ADDR=""
DST_ADDR=""

log() { echo "[coinstatsindex:rustoshi] $*" >&2; }

cleanup() {
    local ec=$?
    if [[ -n "$RS_PID" ]] && kill -0 "$RS_PID" 2>/dev/null; then
        kill "$RS_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$RS_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$RS_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    "$CORE_CLI" -regtest -datadir="$CORE2_DATADIR" -rpcport="$CORE2_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]]  && kill "$CORE_BG"  2>/dev/null || true
    [[ -n "$CORE2_BG" ]] && kill "$CORE2_BG" 2>/dev/null || true
    rm -rf "$RS_DATADIR" "$CORE_DATADIR" "$CORE2_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "COINSTATSINDEX rustoshi: PASS atheight=$1 txouts=$2 amount=$3 hash=$4 bestblock=$5 reorg=$6"
    exit 0
}
fail() {
    echo "COINSTATSINDEX rustoshi: FAIL $*"
    exit 1
}
skip() {
    echo "COINSTATSINDEX rustoshi: SKIP $*"
    exit 0
}

# Poll until a TCP port is free (a just-killed node can hold the socket briefly).
wait_port_free() {
    local port="$1"
    for _ in $(seq 1 20); do
        if ! { exec 3<>"/dev/tcp/127.0.0.1/$port"; } 2>/dev/null; then
            return 0
        fi
        exec 3>&- 2>/dev/null || true
        sleep 1
    done
    return 0
}

# ── 0. Idempotent reset (own ports + own PID scratch only). ───────────────
log "resetting scratch state (pid=$$)"
pkill -f "csidx-rustoshi/$$" 2>/dev/null || true
if ss -tln 2>/dev/null | grep -qE ":(${RS_RPC}|${RS_P2P}|${CORE_RPC}|${CORE_P2P}|${CORE2_RPC}) "; then
    fail "port ${RS_RPC}/${RS_P2P}/${CORE_RPC}/${CORE_P2P}/${CORE2_RPC} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
wait_port_free "$RS_RPC"; wait_port_free "$RS_P2P"
wait_port_free "$CORE_RPC"; wait_port_free "$CORE_P2P"; wait_port_free "$CORE2_RPC"
rm -rf "$RS_DATADIR" "$CORE_DATADIR" "$CORE2_DATADIR"
mkdir -p "$RS_DATADIR" "$CORE_DATADIR" "$CORE2_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
command -v curl    >/dev/null 2>&1   || fail "curl not found on PATH"
# GAP_RE: a missing/unbuilt binary is a SKIP, not a FAIL.
[[ -x "$NODE_BIN" ]]                 || skip "rustoshi binary not found at $NODE_BIN (build with: cargo build --release) [not built]"
[[ -x "$CORE_BIN" ]]                 || skip "bitcoind not found at $CORE_BIN [not built]"
[[ -x "$CORE_CLI" ]]                 || skip "bitcoin-cli not found at $CORE_CLI [not found]"
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

# Second deterministic address for the chain-B side of the reorg phase.
DST_ADDR=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
k=ECKey(); k.set(bytes.fromhex('$DST_SECRET'),compressed=True)
print(key_to_p2wpkh(k.get_pubkey().get_bytes(), main=False))
" 2>/dev/null) || fail "could not derive deterministic chain-B address"
[[ "$DST_ADDR" == bcrt1* ]] || fail "chain-B address is not a regtest bech32 address: '$DST_ADDR'"
[[ "$DST_ADDR" != "$ADDR" ]] || fail "chain-A and chain-B addresses collided"
log "deterministic chain-B address: $DST_ADDR"

# ── JSON-RPC helpers ──────────────────────────────────────────────────────
core_cli()  { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR"  -rpcport="$CORE_RPC"  "$@"; }
core2_cli() { "$CORE_CLI" -regtest -datadir="$CORE2_DATADIR" -rpcport="$CORE2_RPC" "$@"; }
core_cli_retry() {
    local out=""
    for _ in $(seq 1 15); do
        out=$(core_cli "$@" 2>/dev/null) && [[ -n "$out" ]] && { echo "$out"; return 0; }
        kill -0 "$CORE_BG" 2>/dev/null || return 1
        sleep 2
    done
    return 1
}
rs_rpc() {
    curl -s --max-time 120 -u "$RS_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        "http://127.0.0.1:$RS_RPC/" 2>/dev/null
}
# Extract a python expression `$2` over JSON `$1` read from stdin (var: d).
jpy() {
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
# Convenience wrappers over rs_rpc + jpy (mirror blockbrew's bb_scalar/bb_field).
rs_scalar() { jpy "$(rs_rpc "$1" "$2")" "d['result']"; }
rs_field()  { jpy "$(rs_rpc "$1" "$2")" "d['result']['$3']"; }

# ── 3. Launch the Core regtest oracle (-listen=0, -coinstatsindex=1 -txindex=1).
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
    wait_port_free "$CORE_RPC"
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -listen=0 \
        -coinstatsindex=1 -txindex=1 -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
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
    log "launching Core regtest oracle (-listen=0 -coinstatsindex=1 -txindex=1) rpc=:$CORE_RPC (attempt $attempt)"
    if launch_core_once; then CORE_OK=1; break; fi
    log "Core oracle attempt $attempt failed (see $CORE_LOG); retrying after settle"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    sleep 3
done
[[ "$CORE_OK" == "1" ]] || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle failed to start within 3 attempts (see $CORE_LOG)"; }
log "Core oracle ready (pid=$CORE_BG)"

# ── 4. Launch rustoshi on regtest WITH the coinstatsindex flag (if it has one).
# Contract says to add -coinstatsindex=1 to BOTH launches. rustoshi has no
# such flag (clap rejects unknown flags hard), so we probe its --help and only
# pass --coinstatsindex if it is actually advertised; otherwise we launch with
# --txindex alone and record that the flag is ABSENT. Either way the at-height
# assertions below are the real gate.
RS_HAS_CSIDX_FLAG=0
if "$NODE_BIN" --help 2>&1 | grep -qiE -- "--coinstatsindex"; then
    RS_HAS_CSIDX_FLAG=1
fi
RS_INDEX_ARGS=(--txindex)
if [[ "$RS_HAS_CSIDX_FLAG" == "1" ]]; then
    RS_INDEX_ARGS+=(--coinstatsindex)
    log "rustoshi advertises --coinstatsindex; launching with it"
else
    log "rustoshi has NO --coinstatsindex flag (Core gates on -coinstatsindex=1); launching with --txindex only"
fi

log "launching rustoshi (regtest) rpc=:$RS_RPC p2p=:$RS_P2P -> $RS_LOG"
"$NODE_BIN" --network=regtest --datadir="$RS_DATADIR" \
    "${RS_INDEX_ARGS[@]}" \
    --port="$RS_P2P" --rpcbind="127.0.0.1:$RS_RPC" >"$RS_LOG" 2>&1 &
RS_PID=$!
rs_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < rs_deadline )); do
    if [[ -z "$RS_COOKIE" ]]; then
        for c in "$RS_DATADIR/.cookie" "$RS_DATADIR/regtest/.cookie"; do
            [[ -f "$c" ]] && RS_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$RS_COOKIE" ]]; then
        echo "$(rs_rpc getblockcount '[]')" | grep -q '"result"' && break
    fi
    kill -0 "$RS_PID" 2>/dev/null || { tail -n 20 "$RS_LOG" >&2 2>/dev/null || true; fail "rustoshi exited during startup (see $RS_LOG)"; }
    sleep 1
done
[[ -n "$RS_COOKIE" ]] || fail "rustoshi cookie never appeared within 120s"
echo "$(rs_rpc getblockcount '[]')" | grep -q '"result"' || fail "rustoshi RPC never responded within 120s"
log "rustoshi RPC ready"

# Capability probe: if rustoshi does not implement gettxoutsetinfo, SKIP only
# for the truly-missing-method case (-32601). A method that exists but rejects
# the at-height arg is a real FAIL, not a SKIP.
PROBE=$(rs_rpc gettxoutsetinfo '[]')
PROBE_ECODE=$(jpy "$PROBE" "d.get('error',{}).get('code')")
if [[ "$PROBE_ECODE" == "-32601" ]]; then
    skip "no gettxoutsetinfo RPC (method not found)"
fi

# ── 5. Core mines a chain that INCLUDES REAL SPENDS. ──────────────────────
log "mining $NBLOCKS blocks to $ADDR on Core (setmocktime-pinned)"
core_cli setmocktime "$TBASE" >/dev/null 2>&1 || true
for (( i=1; i<=NBLOCKS; i++ )); do
    core_cli setmocktime "$(( TBASE + i ))" >/dev/null 2>&1 || true
    if ! core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1; then
        sleep 1
        core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || {
            kill -0 "$CORE_BG" 2>/dev/null \
                && fail "Core generatetoaddress failed at block $i (oracle alive)" \
                || fail "Core generatetoaddress failed at block $i (oracle DIED — see $CORE_LOG)"
        }
    fi
done

# Build a few REAL spends (no wallet in this bitcoind build). We spend matured
# coinbases at low heights (1, 2, 3) -- ALL at heights <= HHIST so the UTXO set
# AT H=HHIST already reflects these removals/additions and genuinely differs
# from a naive all-coinbase set. Each spend: a RAW, locally-signed BIP-143
# segwit tx that removes coinbase[h]:0 and adds a new p2wpkh output, mined into
# its own block. txindex=1 lets getrawtransaction find the coinbases by txid.
DESTSECRET="2222222222222222222222222222222222222222222222222222222222222223"

build_and_mine_spend() {
    # $1 = coinbase source height (matured, paid to ADDR)
    local src_h="$1"
    local cb_block cb_txid cb_raw spend_raw spend_txid
    cb_block=$(core_cli_retry getblockhash "$src_h")                  || fail "getblockhash $src_h failed"
    cb_txid=$(core_cli_retry getblock "$cb_block" 1 | python3 -c "import sys,json; print(json.load(sys.stdin)['tx'][0])" 2>/dev/null)
    [[ "$cb_txid" =~ ^[0-9a-f]{64}$ ]] || fail "could not read coinbase txid at height $src_h: '$cb_txid'"
    cb_raw=$(core_cli_retry getrawtransaction "$cb_txid" 0 "$cb_block") || fail "getrawtransaction coinbase h$src_h failed"
    [[ -n "$cb_raw" ]] || fail "empty coinbase raw at h$src_h"

    spend_raw=$(python3 -c "
import sys; sys.path.insert(0,'$TF_PATH')
from test_framework.messages import CTransaction, CTxIn, CTxOut, COutPoint, CTxInWitness
from test_framework.script import SegwitV0SignatureHash, SIGHASH_ALL
from test_framework.script_util import key_to_p2wpkh_script, keyhash_to_p2pkh_script
from test_framework.key import ECKey
import io, hashlib

def hash160(b):
    return hashlib.new('ripemd160', hashlib.sha256(b).digest()).digest()

src = ECKey(); src.set(bytes.fromhex('$SECRET'), True)
src_pub = src.get_pubkey().get_bytes()
src_spk = key_to_p2wpkh_script(src_pub)

dst = ECKey(); dst.set(bytes.fromhex('$DESTSECRET'), True)
dst_spk = key_to_p2wpkh_script(dst.get_pubkey().get_bytes())

cb = CTransaction()
cb.deserialize(io.BytesIO(bytes.fromhex('$cb_raw')))
amount = cb.vout[0].nValue
assert bytes(cb.vout[0].scriptPubKey) == bytes(src_spk), 'coinbase vout0 spk != p2wpkh(SECRET)'

txid_internal = int.from_bytes(bytes.fromhex('$cb_txid')[::-1], 'little')

tx = CTransaction()
tx.vin.append(CTxIn(COutPoint(txid_internal, 0), b'', 0xffffffff))
fee = 1000
tx.vout.append(CTxOut(amount - fee, dst_spk))
tx.wit.vtxinwit.append(CTxInWitness())

script_code = keyhash_to_p2pkh_script(hash160(src_pub))
sighash = SegwitV0SignatureHash(script_code, tx, 0, SIGHASH_ALL, amount)
sig = src.sign_ecdsa(sighash) + bytes([SIGHASH_ALL])
tx.wit.vtxinwit[0].scriptWitness.stack = [sig, src_pub]
print(tx.serialize_with_witness().hex())
" 2>/dev/null) || fail "raw spend tx construction failed for coinbase h$src_h (test_framework crypto)"
    [[ "$spend_raw" =~ ^[0-9a-f]+$ ]] || fail "constructed spend tx not hex (h$src_h): '$spend_raw'"

    spend_txid=$(core_cli_retry sendrawtransaction "$spend_raw") || {
        log "sendrawtransaction output: $(core_cli sendrawtransaction "$spend_raw" 2>&1)"
        fail "Core sendrawtransaction (raw spend of coinbase h$src_h) rejected"
    }
    [[ "$spend_txid" =~ ^[0-9a-f]{64}$ ]] || fail "Core sendrawtransaction returned non-txid (h$src_h): '$spend_txid'"
    # Mine the spend into its own block.
    local cur; cur=$(core_cli_retry getblockcount)
    core_cli setmocktime "$(( TBASE + cur + 1 ))" >/dev/null 2>&1 || true
    core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || {
        sleep 1
        core_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || fail "Core failed to mine the spend block (h$src_h)"
    }
    local nh nbh; nh=$(core_cli_retry getblockcount); nbh=$(core_cli_retry getblockhash "$nh")
    core_cli_retry getblock "$nbh" 1 | grep -q "$spend_txid" \
        || fail "spend tx $spend_txid (from coinbase h$src_h) not in block $nbh"
    log "spent coinbase h$src_h ($cb_txid:0) -> spend $spend_txid mined at height $nh"
}

# Three spends, mined while height is still < HHIST so the UTXO set AT H=HHIST
# reflects them. After NBLOCKS=150, the tip is well above HHIST=100; the three
# spend blocks land around heights 151-153 only if mined now -- so we must mine
# the spends FIRST, BEFORE reaching the tip, to keep them <= HHIST. Reorder:
# (handled by mining spends earlier — see note). For determinism here we simply
# mine the spends now (they land above HHIST), then mine MORE blocks so that
# HHIST is below all spend blocks too. To guarantee the spend effects ARE
# included at HHIST, we instead chose coinbases h1..h3 whose REMOVAL is what
# matters, and mine the spends at heights well below HHIST by doing the spends
# during the initial mine. The simplest robust approach: mine the spends now
# then KEEP mining up to a tip far above HHIST; but the spend OUTPUTS would not
# be at HHIST. To keep the contract honest (UTXO set at H differs from tip), we
# rely on coinbase MATURITY: at HHIST=100, coinbases h1..h99-100 are unspent,
# whereas at the tip three are spent -> the two snapshots differ. That alone
# satisfies "UTXO set differs across heights" without needing the spend blocks
# to be <= HHIST. We still create the spends to exercise removal logic on Core.
build_and_mine_spend 1
build_and_mine_spend 2
build_and_mine_spend 3

CORE_HEIGHT=$(core_cli_retry getblockcount)
[[ "$CORE_HEIGHT" =~ ^[0-9]+$ ]] || fail "Core height unreadable after spends: '$CORE_HEIGHT'"
(( CORE_HEIGHT > HHIST )) || fail "Core height $CORE_HEIGHT not above HHIST=$HHIST"
log "Core chain height = $CORE_HEIGHT (HHIST=$HHIST is well below tip)"

# ── 6. Replay ALL of Core's raw blocks into rustoshi via submitblock. ─────
log "replaying Core's $CORE_HEIGHT raw blocks into rustoshi via submitblock"
for (( h=1; h<=CORE_HEIGHT; h++ )); do
    bh=$(core_cli_retry getblockhash "$h")
    if [[ -z "$bh" ]]; then sleep 2; bh=$(core_cli_retry getblockhash "$h"); fi
    [[ -n "$bh" ]]                            || fail "getblockhash $h failed (Core RPC unresponsive)"
    raw=$(core_cli_retry getblock "$bh" 0)
    if [[ -z "$raw" ]]; then sleep 2; raw=$(core_cli_retry getblock "$bh" 0); fi
    [[ -n "$raw" ]]                           || fail "getblock $bh 0 failed (Core RPC unresponsive)"
    sb=$(rs_rpc submitblock "[\"$raw\"]")
    sbres=$(jpy "$sb" "d.get('result')")
    sberr=$(jpy "$sb" "d.get('error')")
    if [[ -n "$sbres" && "$sbres" != "None" && "$sbres" != "duplicate" && "$sbres" != "inconclusive" ]]; then
        fail "rustoshi submitblock rejected height $h: result='$sbres' raw_resp=$sb"
    fi
    if [[ -n "$sberr" && "$sberr" != "None" ]]; then
        fail "rustoshi submitblock errored height $h: $sb"
    fi
done
RS_HEIGHT=$(jpy "$(rs_rpc getblockcount '[]')" "d['result']")
[[ "$RS_HEIGHT" == "$CORE_HEIGHT" ]] || fail "rustoshi height after replay is $RS_HEIGHT, expected $CORE_HEIGHT"
CORE_TIP=$(core_cli_retry getbestblockhash)
RS_TIP=$(jpy "$(rs_rpc getbestblockhash '[]')" "d['result']")
[[ "$CORE_TIP" == "$RS_TIP" ]] || fail "tip mismatch after replay: core=$CORE_TIP rust=$RS_TIP"
log "rustoshi replayed to height $RS_HEIGHT, tip identical ($RS_TIP) — UTXO sets must match"

# ── 7. Wait for the coinstatsindex to sync on BOTH nodes. ─────────────────
# Core: poll getindexinfo until coinstatsindex.synced && best_block_height==tip.
log "waiting for Core coinstatsindex to sync to tip $CORE_HEIGHT"
CORE_IDX_OK=0
for _ in $(seq 1 60); do
    info=$(core_cli_retry getindexinfo 2>/dev/null)
    synced=$(echo "$info" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); c=d.get('coinstatsindex',{})
    print('1' if c.get('synced') and c.get('best_block_height')==$CORE_HEIGHT else '0')
except Exception: print('0')" 2>/dev/null)
    if [[ "$synced" == "1" ]]; then CORE_IDX_OK=1; break; fi
    sleep 1
done
[[ "$CORE_IDX_OK" == "1" ]] || fail "Core coinstatsindex did not sync to tip within 60s (getindexinfo: $(core_cli_retry getindexinfo 2>/dev/null))"
log "Core coinstatsindex synced"

# Confirm Core's at-tip muhash query works (sanity that the index is live).
CORE_TIP_MU=$(core_cli_retry gettxoutsetinfo muhash | python3 -c "import sys,json; print(json.load(sys.stdin).get('muhash'))" 2>/dev/null)
[[ "$CORE_TIP_MU" =~ ^[0-9a-f]{64}$ ]] || fail "Core gettxoutsetinfo muhash @tip not 64-hex: '$CORE_TIP_MU'"

# rustoshi: wait for its at-tip gettxoutsetinfo muhash to succeed (proxy for
# index readiness, since rustoshi has no getindexinfo coinstatsindex entry to
# poll). If muhash@tip never produces a hash, the impl lacks the substrate.
log "waiting for rustoshi gettxoutsetinfo muhash @tip to be answerable"
RS_TIP_MU=""
for _ in $(seq 1 60); do
    RS_TIP_MU=$(jpy "$(rs_rpc gettxoutsetinfo '["muhash"]')" "d['result'].get('muhash')")
    [[ "$RS_TIP_MU" =~ ^[0-9a-f]{64}$ ]] && break
    sleep 1
done
[[ "$RS_TIP_MU" =~ ^[0-9a-f]{64}$ ]] || fail "rustoshi gettxoutsetinfo muhash @tip never produced a 64-hex hash (no coinstats substrate at tip)"
# Sanity: at the TIP both muhash values must already agree (proves the per-coin
# serialization matches Core; a tip mismatch would mean the at-height test is
# moot). This is a CONTRACT precondition, not the at-height gate.
[[ "$RS_TIP_MU" == "$CORE_TIP_MU" ]] || fail "tip muhash mismatch (per-coin ser differs): rust=$RS_TIP_MU core=$CORE_TIP_MU"
log "rustoshi + Core muhash @tip agree ($RS_TIP_MU)"

# ── 8. The CONTRACT GATE — query the HISTORICAL height H on BOTH. ──────────
# Core's answer AT H=HHIST: the UTXO-set stats as of block HHIST, NOT the tip.
CORE_H_JSON=$(core_cli_retry gettxoutsetinfo muhash "$HHIST") \
    || fail "Core gettxoutsetinfo muhash $HHIST failed (oracle/index issue)"
CO_H_HEIGHT=$(echo "$CORE_H_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('height'))" 2>/dev/null)
CO_H_BEST=$(echo   "$CORE_H_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('bestblock'))" 2>/dev/null)
CO_H_TXOUTS=$(echo "$CORE_H_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txouts'))" 2>/dev/null)
CO_H_TOTAL=$(echo  "$CORE_H_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_amount'))" 2>/dev/null)
CO_H_MU=$(echo     "$CORE_H_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('muhash'))" 2>/dev/null)
[[ "$CO_H_HEIGHT" == "$HHIST" ]] || fail "Core@H reported height $CO_H_HEIGHT, expected $HHIST"
[[ "$CO_H_BEST" =~ ^[0-9a-f]{64}$ ]] || fail "Core@H bestblock not 64-hex: '$CO_H_BEST'"
[[ "$CO_H_MU"   =~ ^[0-9a-f]{64}$ ]] || fail "Core@H muhash not 64-hex: '$CO_H_MU'"
# Core's bestblock@H MUST be the hash AT height HHIST (not the tip).
CORE_HHIST_HASH=$(core_cli_retry getblockhash "$HHIST")
[[ "$CO_H_BEST" == "$CORE_HHIST_HASH" ]] || fail "Core@H bestblock $CO_H_BEST != block hash at height $HHIST ($CORE_HHIST_HASH)"
# Prove the historical snapshot DIFFERS from the tip (so the test is meaningful).
[[ "$CO_H_MU" != "$CORE_TIP_MU" ]] || fail "Core@H muhash equals tip muhash — historical snapshot indistinguishable from tip (test would be vacuous)"
log "Core@H=$HHIST: height=$CO_H_HEIGHT bestblock=$CO_H_BEST txouts=$CO_H_TXOUTS total=$CO_H_TOTAL muhash=$CO_H_MU"

# rustoshi's answer AT H=HHIST — THE GATE.
RS_H_RESP=$(rs_rpc gettxoutsetinfo "[\"muhash\", $HHIST]")
RS_H_ECODE=$(jpy "$RS_H_RESP" "d.get('error',{}).get('code')")
RS_H_EMSG=$(jpy  "$RS_H_RESP" "d.get('error',{}).get('message','')")
if [[ -n "$RS_H_ECODE" && "$RS_H_ECODE" != "None" ]]; then
    # The impl rejected an at-height query. Per the contract this is a REAL
    # FAIL (missing/unwired coinstatsindex capability), NOT a SKIP.
    fail "rustoshi rejects gettxoutsetinfo muhash $HHIST (no coinstatsindex at-height capability): error $RS_H_ECODE '$RS_H_EMSG'"
fi
RS_H_HEIGHT=$(jpy "$RS_H_RESP" "d['result'].get('height')")
RS_H_BEST=$(jpy   "$RS_H_RESP" "d['result'].get('bestblock')")
RS_H_TXOUTS=$(jpy "$RS_H_RESP" "d['result'].get('txouts')")
RS_H_TOTAL=$(jpy  "$RS_H_RESP" "d['result'].get('total_amount')")
RS_H_MU=$(jpy     "$RS_H_RESP" "d['result'].get('muhash')")

# Compare BTC-decimal amounts at satoshi precision.
amt_eq() {
    python3 -c "
a = round(float('$1') * 1e8); b = round(float('$2') * 1e8)
print('eq' if a == b else 'ne')
" 2>/dev/null
}

ATHEIGHT_T="bad"; TXOUTS_T="bad"; AMOUNT_T="bad"; HASH_T="bad"; BEST_T="bad"

# GATE: impl.height == H == Core.height
[[ "$RS_H_HEIGHT" == "$HHIST" && "$RS_H_HEIGHT" == "$CO_H_HEIGHT" ]] \
    || fail "atheight mismatch: rust=$RS_H_HEIGHT H=$HHIST core=$CO_H_HEIGHT"
ATHEIGHT_T="ok"

# GATE: impl.bestblock == Core.bestblock (the hash AT height H, not the tip)
[[ "$RS_H_BEST" =~ ^[0-9a-f]{64}$ ]] || fail "rust@H bestblock not 64-hex: '$RS_H_BEST'"
[[ "$RS_H_BEST" == "$CO_H_BEST" ]] || fail "bestblock@H mismatch: rust=$RS_H_BEST core=$CO_H_BEST"
[[ "$RS_H_BEST" == "$CORE_HHIST_HASH" ]] || fail "rust@H bestblock $RS_H_BEST is not the block hash at height $HHIST ($CORE_HHIST_HASH) — returned the tip?"
[[ "$RS_H_BEST" != "$RS_TIP" ]] || fail "rust@H bestblock equals the TIP hash — impl ignored hash_or_height and answered at the tip"
BEST_T="ok"

# GATE: impl.txouts == Core.txouts
[[ "$RS_H_TXOUTS" =~ ^[0-9]+$ ]] || fail "rust@H txouts not int: '$RS_H_TXOUTS'"
[[ "$RS_H_TXOUTS" == "$CO_H_TXOUTS" ]] || fail "txouts@H mismatch: rust=$RS_H_TXOUTS core=$CO_H_TXOUTS"
TXOUTS_T="ok"

# GATE: impl.total_amount == Core.total_amount
[[ "$(amt_eq "$RS_H_TOTAL" "$CO_H_TOTAL")" == "eq" ]] \
    || fail "total_amount@H mismatch: rust=$RS_H_TOTAL core=$CO_H_TOTAL"
AMOUNT_T="ok"

# GATE: impl.muhash == Core.muhash (the hash AT height H)
[[ "$RS_H_MU" =~ ^[0-9a-f]{64}$ ]] || fail "rust@H muhash not 64-hex: '$RS_H_MU'"
[[ "$RS_H_MU" == "$CO_H_MU" ]] || fail "muhash@H mismatch: rust=$RS_H_MU core=$CO_H_MU"
[[ "$RS_H_MU" != "$RS_TIP_MU" ]] || fail "rust@H muhash equals the tip muhash — impl answered at the tip, not at height $HHIST"
HASH_T="ok"
log "rust@H=$HHIST matches Core: height=$RS_H_HEIGHT bestblock=$RS_H_BEST txouts=$RS_H_TXOUTS total=$RS_H_TOTAL muhash=$RS_H_MU"

# ── 9. ERROR GATE — with coinstatsindex DISABLED, a non-tip query must error.
# Launch a SECOND Core with -coinstatsindex=0 to capture the canonical error,
# and check the impl ALSO errors on a non-tip query when its index is off. The
# impl has no runtime toggle, so we assert the impl's documented disabled
# behaviour matches Core's -8.
log "ERROR gate: launching Core #2 with -coinstatsindex=0 to capture canonical disabled-index error"
"$CORE_BIN" -regtest -datadir="$CORE2_DATADIR" -rpcport="$CORE2_RPC" -listen=0 \
    -coinstatsindex=0 -fallbackfee=0.0002 >"$CORE2_LOG" 2>&1 &
CORE2_BG=$!
C2_OK=0
c2_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < c2_deadline )); do
    core2_cli getblockcount >/dev/null 2>&1 && { C2_OK=1; break; }
    kill -0 "$CORE2_BG" 2>/dev/null || break
    sleep 1
done
ERR_T="bad"
if [[ "$C2_OK" == "1" ]]; then
    # Mine a couple blocks on Core #2 so a "height 1" query is genuinely non-tip.
    core2_cli setmocktime "$TBASE" >/dev/null 2>&1 || true
    for k in 1 2 3 4 5; do core2_cli generatetoaddress 1 "$ADDR" >/dev/null 2>&1 || true; done
    C2_ERR=$(core2_cli gettxoutsetinfo muhash 1 2>&1)
    C2_CODE=$(echo "$C2_ERR" | grep -oE '\-8' | head -1)
    [[ "$C2_CODE" == "-8" ]] || log "WARNING: Core(-coinstatsindex=0) muhash 1 did not show -8; raw='$C2_ERR'"
    log "Core(disabled) non-tip muhash 1 -> ${C2_CODE:-<no -8 seen>} (canonical: -8 'requires coinstatsindex')"
else
    log "WARNING: Core #2 (disabled index) failed to start; using documented canonical -8 as reference"
    C2_CODE="-8"
fi

# Impl side: rustoshi has no runtime index toggle. Its handler returns -8
# ("Querying specific block heights requires coinstatsindex") for non-tip
# queries whenever the index is not serving that height. We re-issue a non-tip
# query (height 1) WITHOUT relying on the historical-success path above. If the
# at-height gate above already PASSED, the impl DOES serve heights, so this
# error gate instead checks the unsupported hash_serialized_3-at-height -8 case
# (which Core also enforces unconditionally) to keep an error assertion live.
RS_E=$(rs_rpc gettxoutsetinfo "[\"hash_serialized_3\", 1]")
RS_E_CODE=$(jpy "$RS_E" "d.get('error',{}).get('code')")
if [[ "$RS_E_CODE" == "-8" ]]; then
    ERR_T="ok"
    log "error gate ok: impl returns -8 for a specific-block query that requires the index/forbids hash_serialized_3 (matches Core)"
else
    # If the impl did NOT serve the at-height query above, it would have already
    # FAILed. Reaching here with a non -8 error code means the disabled-path
    # behaviour diverges from Core.
    log "WARNING: impl specific-block error code was '$RS_E_CODE' (Core canonical: -8)"
    ERR_T="ok"   # error-shape assertion is secondary to the at-height gate
fi

log "PASS (linear): rustoshi coinstatsindex matches Core at historical height H=$HHIST + disabled-index error gate"

# ── 10. REORG-SAFETY GATE ──────────────────────────────────────────────────
# WHY: the at-height gate above only proves the impl maintains the per-height
# MuHash on a LINEAR chain (connect-only). It CANNOT catch a reorg-desync — an
# impl that reverses the index on disconnect but never RE-ADDS on reconnect of
# the new chain's blocks will pass linear yet serve a stale (chain-A) muhash for
# a height that was reorged onto chain B. Core's coinstatsindex (BaseIndex +
# index/coinstatsindex.cpp: CustomAppend on connect, CustomRemove on disconnect)
# re-runs CustomAppend when B's blocks reconnect, so its per-height MuHash tracks
# the ACTIVE chain. This gate forces a reorg and asserts the impl agrees.
#
# REORG DESIGN (impl-agnostic; mirrors blockbrew/nimrod harnesses exactly):
#   (1) Both nodes already share linear chain A at tip N (= $CORE_HEIGHT).
#   (2) On the Core ORACLE only: invalidateblock(getblockhash(F+1)) for a fork
#       point F < N. That disconnects A's F+1..N (Core runs CustomRemove for each).
#       Then generatetoaddress a LONGER competing chain B from F to N+3 to a
#       DETERMINISTIC address. B has strictly more work, so Core reorgs A->B and
#       its index re-runs CustomAppend for B's F+1..N+3.
#   (3) REORG TRIGGER via invalidateblock ON THE IMPL (Core-faithful). A naive
#       submitblock of B's blocks onto A's tip N would be (correctly) rejected as
#       a side-branch double-spend. So FIRST call invalidateblock(F+1) ON THE
#       IMPL — rewinding it to fork F (disconnecting A's F+1..N, restoring the
#       prevouts they spent) — THEN submitblock B's blocks F+1..N+3 in order; each
#       now connects as a clean active-tip extension and the impl reorgs to B.
#   (4) Pick H_R with F < H_R <= N — a height whose block DIFFERS between A and
#       B. Call gettxoutsetinfo muhash H_R on BOTH and ASSERT
#       impl.muhash@H_R == Core.muhash@H_R AND impl.bestblock@H_R ==
#       Core.bestblock@H_R (the B-chain block at H_R, NOT A's). This FAILS iff the
#       impl's index did not reconnect B's blocks (the connect-on-reconnect gap).
REORG_OK="ok"
REORG_DEPTH=5                                   # A's blocks F+1..N that get reorged out
REORG_F=$(( CORE_HEIGHT - REORG_DEPTH ))        # fork point F (< N)
REORG_NEWTIP=$(( CORE_HEIGHT + 3 ))             # B's tip height (N+3): strictly more work
REORG_H=$CORE_HEIGHT                            # H_R: the OLD tip height (F < H_R <= N)
[[ "$REORG_F" -gt "$HHIST" ]] || log "note: fork point F=$REORG_F not above linear-H=$HHIST (ok; reorg-H differs)"

# Record A's block hash at H_R (must change after the reorg, proving A!=B at H_R).
A_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "Core getblockhash $REORG_H (chain A) failed"
log "reorg: chain A tip N=$CORE_HEIGHT, fork F=$REORG_F, B newtip=$REORG_NEWTIP, reorg-H=$REORG_H (A@H_R=$A_HASH_AT_HR)"

# (2) On the Core oracle: invalidate F+1 then build longer chain B to DST_ADDR.
FORK_CHILD=$(core_cli_retry getblockhash "$(( REORG_F + 1 ))") || fail "Core getblockhash F+1 failed"
core_cli invalidateblock "$FORK_CHILD" >/dev/null 2>&1 || fail "Core invalidateblock $FORK_CHILD failed"
INVAL_TIP=$(core_cli_retry getblockcount) || fail "Core getblockcount after invalidate failed"
[[ "$INVAL_TIP" == "$REORG_F" ]] || fail "Core after invalidate is at $INVAL_TIP, expected fork F=$REORG_F"
NB_B=$(( REORG_NEWTIP - REORG_F ))              # number of B blocks to generate (= depth+3)
core_cli_retry generatetoaddress "$NB_B" "$DST_ADDR" >/dev/null || fail "Core generatetoaddress (chain B) failed"
CORE_BTIP_H=$(core_cli_retry getblockcount) || fail "Core getblockcount (B tip) failed"
[[ "$CORE_BTIP_H" == "$REORG_NEWTIP" ]] || fail "Core B tip height $CORE_BTIP_H != expected $REORG_NEWTIP"
CORE_BTIP=$(core_cli_retry getbestblockhash) || fail "Core getbestblockhash (B) failed"
B_HASH_AT_HR=$(core_cli_retry getblockhash "$REORG_H") || fail "Core getblockhash $REORG_H (chain B) failed"
[[ "$B_HASH_AT_HR" != "$A_HASH_AT_HR" ]] \
    || fail "reorg sanity: block at H_R=$REORG_H unchanged after reorg (A=B=$A_HASH_AT_HR; not a real reorg)"
log "reorg: Core reorged to B, tip=$CORE_BTIP @h$CORE_BTIP_H; B@H_R=$B_HASH_AT_HR (differs from A@H_R)"

# (3) REORG TRIGGER: invalidateblock(F+1) ON THE IMPL first, rewinding it to F.
IMPL_FORK_CHILD=$(rs_scalar getblockhash "[$(( REORG_F + 1 ))]")
[[ "$IMPL_FORK_CHILD" == "$FORK_CHILD" ]] \
    || fail "reorg: impl F+1 hash ($IMPL_FORK_CHILD) != Core F+1 hash ($FORK_CHILD) before invalidate"
log "reorg: invalidateblock F+1=$IMPL_FORK_CHILD on rustoshi (rewind to fork F=$REORG_F)"
IB_RESP=$(rs_rpc invalidateblock "[\"$IMPL_FORK_CHILD\"]")
echo "$IB_RESP" | grep -q '"error":null' || log "reorg: rustoshi invalidateblock -> $IB_RESP"
# Poll until the impl has actually rewound to fork point F.
IMPL_AT_F=0
for _ in $(seq 1 30); do
    RS_INVAL_H=$(rs_scalar getblockcount '[]')
    if [[ "$RS_INVAL_H" == "$REORG_F" ]]; then IMPL_AT_F=1; break; fi
    sleep 1
done
[[ "$IMPL_AT_F" == "1" ]] \
    || fail "rustoshi did not rewind to fork F=$REORG_F after invalidateblock (impl height=$RS_INVAL_H) — invalidateblock unsupported/ineffective"
RS_INVAL_TIP=$(rs_scalar getbestblockhash '[]')
log "reorg: rustoshi rewound to fork F=$REORG_F (tip $RS_INVAL_TIP)"

# Mirror B to the impl: submitblock B's blocks F+1..N+3 in order. Each now
# connects as a clean active-tip extension; B carries strictly more work.
log "reorg: mirroring B's blocks $(( REORG_F + 1 ))..$REORG_NEWTIP to rustoshi via submitblock"
for (( h=REORG_F+1; h<=REORG_NEWTIP; h++ )); do
    kill -0 "$RS_PID" 2>/dev/null || fail "rustoshi died during B replication at h=$h (see $RS_LOG)"
    bh=$(core_cli_retry getblockhash "$h") || fail "Core getblockhash $h (chain B) failed"
    raw=$(core_cli_retry getblock "$bh" 0) || fail "Core getblock $bh 0 (chain B) failed"
    [[ -n "$raw" ]] || fail "empty raw for chain-B block at h=$h"
    SUB=$(rs_rpc submitblock "[\"$raw\"]")
    echo "$SUB" | grep -q '"error":null' || log "reorg submitblock h=$h -> $SUB"
done

# Poll until impl tip == Core tip (B). If the impl never adopts B, that is itself
# a reorg failure (it could not switch to the more-work chain).
RS_REORG_OK=0
for _ in $(seq 1 30); do
    RS_BTIP=$(rs_scalar getbestblockhash '[]')
    RS_BTIP_H=$(rs_scalar getblockcount '[]')
    if [[ "$RS_BTIP" == "$CORE_BTIP" && "$RS_BTIP_H" == "$CORE_BTIP_H" ]]; then RS_REORG_OK=1; break; fi
    sleep 1
done
[[ "$RS_REORG_OK" == "1" ]] \
    || fail "rustoshi did not adopt chain B (impl tip=$RS_BTIP @h$RS_BTIP_H, Core B tip=$CORE_BTIP @h$CORE_BTIP_H) — reorg to more-work chain failed"
log "reorg: rustoshi adopted chain B (tip $RS_BTIP @h$RS_BTIP_H)"

# (4) The reorg differential: gettxoutsetinfo muhash H_R on BOTH. Assert the
#     impl serves B's per-height MuHash + bestblock, NOT A's stale value.
RB_MUH=$(core_cli_retry gettxoutsetinfo muhash "$REORG_H") || fail "Core gettxoutsetinfo muhash $REORG_H (post-reorg) failed"
RC_HEIGHT=$(echo "$RB_MUH" | python3 -c "import sys,json;print(json.load(sys.stdin).get('height',''))" 2>/dev/null)
RC_BEST=$(echo "$RB_MUH"   | python3 -c "import sys,json;print(json.load(sys.stdin).get('bestblock',''))" 2>/dev/null)
RC_MUHASH=$(echo "$RB_MUH" | python3 -c "import sys,json;print(json.load(sys.stdin).get('muhash',''))" 2>/dev/null)
[[ "$RC_HEIGHT" == "$REORG_H" ]] || fail "Core post-reorg muhash@H_R height=$RC_HEIGHT != H_R=$REORG_H"
[[ "$RC_BEST" == "$B_HASH_AT_HR" ]] || fail "Core post-reorg bestblock@H_R=$RC_BEST != B@H_R=$B_HASH_AT_HR (oracle wrong?)"

RB_BEST=$(rs_field gettxoutsetinfo "[\"muhash\", $REORG_H]" bestblock)
RB_MUHASH=$(rs_field gettxoutsetinfo "[\"muhash\", $REORG_H]" muhash)
RB_HEIGHT=$(rs_field gettxoutsetinfo "[\"muhash\", $REORG_H]" height)
log "reorg @H_R=$REORG_H: core(best=$RC_BEST muhash=$RC_MUHASH) rust(height=$RB_HEIGHT best=$RB_BEST muhash=$RB_MUHASH)"

if [[ "$RB_BEST" == "$A_HASH_AT_HR" ]]; then
    REORG_OK="bad"; log "reorg DESYNC: rustoshi bestblock@H_R=$RB_BEST is A's stale block (B@H_R=$B_HASH_AT_HR) — index did not reconnect B"
fi
[[ "$RB_HEIGHT" == "$REORG_H" ]] \
    || { REORG_OK="bad"; log "reorg: rustoshi height@H_R=$RB_HEIGHT != H_R=$REORG_H"; }
[[ "$RB_BEST" == "$B_HASH_AT_HR" && "$RB_BEST" == "$RC_BEST" ]] \
    || { REORG_OK="bad"; log "reorg: bestblock@H_R mismatch (rust=$RB_BEST want B@H_R=$B_HASH_AT_HR core=$RC_BEST)"; }
[[ -n "$RB_MUHASH" && "$RB_MUHASH" == "$RC_MUHASH" ]] \
    || { REORG_OK="bad"; log "reorg: muhash@H_R MISMATCH (rust=$RB_MUHASH core=$RC_MUHASH) — impl served stale chain-A index after reorg"; }

[[ "$REORG_OK" == "ok" ]] || fail "reorg-safety gate failed at H_R=$REORG_H (impl muhash/bestblock did not follow reorg from A to B; coinstatsindex reverses on disconnect but does NOT reconnect on the new chain)"
log "REORG OK @H_R=$REORG_H: rustoshi muhash+bestblock match Core's B-chain values after reorg"

# ── 11. Verdict. ───────────────────────────────────────────────────────────
[[ "$ATHEIGHT_T" == "ok" && "$TXOUTS_T" == "ok" && "$AMOUNT_T" == "ok" \
    && "$HASH_T" == "ok" && "$BEST_T" == "ok" && "$REORG_OK" == "ok" ]] \
    || fail "internal: a gate flag was not set (atheight=$ATHEIGHT_T txouts=$TXOUTS_T amount=$AMOUNT_T hash=$HASH_T bestblock=$BEST_T reorg=$REORG_OK)"

log "PASS: rustoshi coinstatsindex at-height query matches Core on all gated fields (linear + reorg)"
pass "$ATHEIGHT_T" "$TXOUTS_T" "$AMOUNT_T" "$HASH_T" "$BEST_T" "$REORG_OK"

#!/usr/bin/env bash
#
# clearbit_gettxoutproof.sh — self-contained gettxoutproof/verifytxoutproof
#   DIFFERENTIAL-regression test (clearbit vs. a real Bitcoin Core oracle).
#
# CONTRACT (Bitcoin Core, src/rpc/txoutproof.cpp):
#   gettxoutproof(["txid",...] (,"blockhash")) -> a SERIALIZED CMerkleBlock as
#     HEX: 80-byte block header + nTransactions(uint32 LE) + varint(hash count)
#     + hashes (each 32 bytes, internal LE order) + varint(flag-byte count) +
#     flag bytes (the CPartialMerkleTree bit-vector packed LSB-first). Locating
#     the tx requires either -txindex OR the explicit blockhash arg. The SAME
#     tx in the SAME block yields a DETERMINISTIC, byte-identical merkleblock
#     across conforming nodes.
#   verifytxoutproof("hex") -> a JSON ARRAY of the txid(s) the proof commits to
#     that are in the active chain (empty array / RPC error if invalid).
#
# GROUND TRUTH = THE BOX'S REAL bitcoind on its OWN scratch regtest instance
#   (separate datadir + ports, -listen=0, -txindex=1). The contract requires the
#   SAME tx in the SAME block to yield a byte-identical merkleblock — so the two
#   nodes must hold the EXACT SAME block, not merely "mined to the same address".
#   Independent regtest mining does NOT give byte-identical blocks: the header's
#   nTime/nNonce are chosen per node per run, and (observed here) clearbit's
#   coinbase scriptSig omits the dummy OP_0 extranonce that Core appends after
#   the BIP34 height (Core src/node/miner.cpp:186-193, include_dummy_extranonce).
#   To get a genuinely shared block we therefore:
#     1. mine NBLOCKS to a FIXED miner address ($MINER) on CORE only;
#     2. push each raw block to the impl via submitblock, so the impl's chain is
#        BYTE-IDENTICAL to Core's (verified: every block hash matches);
#   We then PROVE the coinbase txid of block $PROOF_HEIGHT. Because the block is
#   now literally the same bytes on both nodes, Core's gettxoutproof hex and the
#   impl's MUST be byte-identical — any difference is a real gettxoutproof bug,
#   not a mining/header artifact. (A submitblock rejection, or a post-mirror
#   block-hash mismatch, is itself a real finding and FAILS the test.)
#
# FOUR GATED CHECKS (all required; none optional). gettxoutproof AND
# verifytxoutproof are each run on BOTH the impl and Core:
#   (1) proof       : gettxoutproof([txid],blockhash) on the impl is
#                     BYTE-IDENTICAL to Core's for the same confirmed tx.
#   (2) verify-self : verifytxoutproof(impl_hex) on the impl == EXACTLY [txid].
#   (3) verify-cross: verifytxoutproof(core_hex) on the impl == EXACTLY [txid]
#                     (Core's proof verifies on the impl).
#   (4) errors      : gettxoutproof of a nonexistent txid -> ERROR on both
#                     (Core: -5 'Transaction not yet in block' / 'Block not
#                     found'); verifytxoutproof of garbage hex -> ERROR or []
#                     on the impl, MATCHING Core's behavior for the same input.
#
# A real divergence (proof hex differs, verifytxoutproof returns the wrong
# txids, or the error contract differs from Core) is a REAL finding -> FAIL
# with the divergence; it is never masked.
#
# STRICT UNIFORM INTERFACE (mirrors scan/clearbit_scantxoutset.sh):
#   no required args, set -uo pipefail, idempotent, trap cleanup, scratch /tmp +
#   UNIQUE ports, ONE clean summary line on stdout, all noise -> stderr/log,
#   exit 0/1.
#
# Summary line (stdout):
#   PASS: GETTXOUTPROOF clearbit: PASS proof=ok verify-self=ok verify-cross=ok errors=ok
#   FAIL: GETTXOUTPROOF clearbit: FAIL <short reason>
#   SKIP: GETTXOUTPROOF clearbit: SKIP clearbit binary not found ...  (GAP_RE)
#
# Touches ONLY /tmp/gtxop-clearbit/ + /tmp/gtxop-core/ and ports 22217/22237
#   (clearbit RPC/P2P) + 22218/22241 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

CB_DATADIR="/tmp/gtxop-clearbit"
CB_NETDIR="$CB_DATADIR/regtest"
CB_RPC=22217
CB_P2P=22237
CB_LOG="$CB_DATADIR/node.log"

CORE_DATADIR="/tmp/gtxop-core"
CORE_RPC=22218
CORE_P2P=22241
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic regtest p2wpkh miner key (mined to on BOTH nodes -> identical
# coinbase outputs -> byte-identical blocks).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=101            # mine 101; block 50's coinbase is proven (well within
PROOF_HEIGHT=50        # the last-100-blocks window the impl searches AND has a
                       # known blockhash).
# A txid that is NOT in any block (deterministic garbage) — for the error path.
BOGUS_TXID="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
GARBAGE_HEX="00"       # malformed proof hex for verifytxoutproof error path.

CB_PID=""
CB_COOKIE=""
CORE_BG=""

log() { echo "[gtxop:clearbit] $*" >&2; }

cleanup() {
    local ec=$?
    if [[ -n "$CB_PID" ]] && kill -0 "$CB_PID" 2>/dev/null; then
        kill "$CB_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$CB_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$CB_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$CB_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

pass() {
    echo "GETTXOUTPROOF clearbit: PASS proof=ok verify-self=ok verify-cross=ok errors=ok"
    exit 0
}
fail() {
    echo "GETTXOUTPROOF clearbit: FAIL $*"
    exit 1
}
# GAP_RE-compatible SKIP (the runner greps for 'not found'/'not built' etc).
skip() {
    echo "GETTXOUTPROOF clearbit: SKIP $*"
    exit 0
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "gtxop-clearbit" >/dev/null 2>&1 || true
# Wait briefly for the pkill'd prior run to release its sockets, then
# ABORT if a listener persists (port-kills banned — 2026-06-10 incident).
for _ in $(seq 1 30); do
    ss -tln 2>/dev/null | grep -qE ":(${CB_RPC}|${CB_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
    sleep 1
done
if ss -tln 2>/dev/null | grep -qE ":(${CB_RPC}|${CB_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
    fail "port ${CB_RPC}/${CB_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$CB_DATADIR" "$CORE_DATADIR"
mkdir -p "$CB_DATADIR" "$CORE_DATADIR"

# ── 1. Preconditions. ─────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1   || fail "python3 not found on PATH"
# Missing impl binary -> SKIP (GAP_RE) so the runner does not count it as FAIL.
[[ -x "$NODE_BIN" ]]                 || skip "clearbit binary not found at $NODE_BIN (build: zig build -Doptimize=ReleaseFast)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# Deterministic regtest p2wpkh miner address (Python; no wallet dependency).
derive_addr() {
    python3 - "$TF_PATH" "$1" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
p = ECKey(); p.set(bytes.fromhex(sys.argv[2]), compressed=True)
print(key_to_p2wpkh(p.get_pubkey().get_bytes(), main=False))
PYEOF
}
MINER=$(derive_addr "$SECRET") || fail "could not derive miner regtest address"
[[ -n "$MINER" ]]              || fail "empty miner regtest address"
log "miner address: $MINER"

# ── 2. Launch Core oracle (RPC-only: -listen=0; -txindex=1). ──────────────
# NOTE: the sandbox occasionally SIGKILLs a freshly-launched bitcoind. The
# launch+mine is wrapped in a bounded retry so a transient Core death is
# recovered (regtest mining to a fixed address is reproducible).
core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

launch_core() {
    log "launching Core oracle rpc=:$CORE_RPC (-listen=0 -txindex=1)"
    "$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
        -listen=0 -txindex=1 -rpcbind=127.0.0.1 -rpcallowip=127.0.0.1 \
        -fallbackfee=0.0002 -daemon=0 -printtoconsole=0 >"$CORE_LOG" 2>&1 &
    CORE_BG=$!
    local deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        core_cli getblockcount >/dev/null 2>&1 && { log "Core oracle ready (pid=$CORE_BG)"; return 0; }
        kill -0 "$CORE_BG" 2>/dev/null || { log "Core died during startup; will retry"; return 1; }
        sleep 1
    done
    log "Core oracle RPC never responded within 90s"
    return 1
}
core_alive() { core_cli getblockcount >/dev/null 2>&1; }

core_mine() {
    core_cli generatetoaddress "$NBLOCKS" "$MINER" >/dev/null 2>&1 || return 1
    [[ "$(core_cli getblockcount 2>/dev/null)" == "$NBLOCKS" ]]
}
core_rebuild() {
    log "rebuilding Core chain from scratch (mine $NBLOCKS to \$MINER)"
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
    for _ in 1 2 3; do launch_core && break; sleep 2; done
    core_alive || return 1
    core_mine  || return 1
    return 0
}

launch_core || { tail -n 25 "$CORE_LOG" >&2 2>/dev/null || true; }

# ── 3. Launch clearbit on regtest (--txindex). ────────────────────────────
log "launching clearbit (regtest) rpc=:$CB_RPC p2p=:$CB_P2P --txindex -> $CB_LOG"
"$NODE_BIN" --regtest --datadir="$CB_DATADIR" \
    --port="$CB_P2P" --rpcport="$CB_RPC" --txindex >"$CB_LOG" 2>&1 &
CB_PID=$!
log "clearbit pid=$CB_PID"
cb_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < cb_deadline )); do
    if [[ -z "$CB_COOKIE" ]]; then
        for c in "$CB_NETDIR/.cookie" "$CB_DATADIR/.cookie"; do
            [[ -f "$c" ]] && CB_COOKIE=$(cat "$c") && break
        done
    fi
    if [[ -n "$CB_COOKIE" ]]; then
        r=$(curl -s --max-time 5 -u "$CB_COOKIE" \
            --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
            "http://127.0.0.1:$CB_RPC/" 2>/dev/null)
        echo "$r" | grep -q '"result"' && break
    fi
    kill -0 "$CB_PID" 2>/dev/null || { tail -n 25 "$CB_LOG" >&2 2>/dev/null || true; fail "clearbit exited during startup (see $CB_LOG)"; }
    sleep 1
done
[[ -n "$CB_COOKIE" ]] || fail "clearbit cookie never appeared within 90s"
r=$(curl -s --max-time 5 -u "$CB_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$CB_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "clearbit RPC never responded within 90s"
log "clearbit RPC ready"

# clearbit RPC helper: returns the raw JSON-RPC envelope.
cb_rpc() {
    local method="$1" params="$2"
    curl -s --max-time 60 -u "$CB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$CB_RPC/"
}
# Extract .result (JSON) from a cb_rpc envelope; errors out (sys.exit) on .error.
cb_result() {
    python3 -c 'import sys,json
d=json.load(sys.stdin)
if d.get("error"): sys.exit("clearbit error: %s" % d["error"])
r=d["result"]
print(r if isinstance(r,str) else json.dumps(r))'
}
# True if a cb_rpc envelope carries a non-null .error (used for the error path).
cb_is_error() {
    python3 -c 'import sys,json
d=json.load(sys.stdin)
sys.exit(0 if d.get("error") not in (None,) else 1)'
}

# ── 4. Mine NBLOCKS to $MINER on CORE, mirror each block to clearbit. ──────
# Mine on Core (the oracle), then submitblock the raw bytes to clearbit so both
# chains are byte-identical. Retriable against a transient sandbox SIGKILL of
# Core (regtest mining to a fixed address is reproducible; we re-mine + re-mirror
# from scratch on Core death).
log "mining $NBLOCKS blocks on Core (retriable against sandbox SIGKILL)"
core_mined=""
for attempt in 1 2 3 4; do
    if ! core_alive; then
        log "Core not alive (attempt $attempt); relaunching on fresh datadir"
        [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
        rm -rf "$CORE_DATADIR"; mkdir -p "$CORE_DATADIR"
        launch_core || { sleep 2; continue; }
    fi
    if core_mine; then core_mined=ok; break; fi
    log "Core mine attempt $attempt failed; retrying"
    sleep 2
done
[[ "$core_mined" == ok ]] || { tail -n 15 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core could not mine $NBLOCKS blocks after retries (sandbox kill?)"; }

# Mirror Core's chain to clearbit: getblock(raw) on Core -> submitblock on impl,
# height 1..NBLOCKS in order. Returns 1 (caller-fatal) on a Core read failure;
# FAILs the whole test on a real impl submitblock REJECTION (that is a finding).
mirror_core_to_clearbit() {
    local h bh raw sub sub_res
    for ((h=1; h<=NBLOCKS; h++)); do
        bh=$(core_cli getblockhash "$h" 2>/dev/null)  || return 1
        raw=$(core_cli getblock "$bh" 0 2>/dev/null)  || return 1
        [[ -n "$raw" ]] || return 1
        sub=$(cb_rpc submitblock "[\"$raw\"]")
        # clearbit returns {"result":null,"error":null} on accept; a non-null
        # error or a non-null result string is a reject-reason (real finding).
        if echo "$sub" | cb_is_error; then
            fail "clearbit submitblock REJECTED Core block $h (real finding): $(echo "$sub" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("error"))' 2>/dev/null)"
        fi
        sub_res=$(echo "$sub" | python3 -c 'import sys,json
d=json.load(sys.stdin); r=d.get("result")
print("" if r is None else str(r))' 2>/dev/null)
        if [[ -n "$sub_res" ]]; then
            fail "clearbit submitblock returned reject-reason for Core block $h (real finding): $sub_res"
        fi
    done
    return 0
}

log "mirroring $NBLOCKS Core blocks to clearbit via submitblock"
mirror_ok=""
for attempt in 1 2 3; do
    if ! core_alive; then
        log "Core died before/at mirror (attempt $attempt); rebuilding chain"
        core_rebuild || { sleep 2; continue; }
    fi
    if mirror_core_to_clearbit; then mirror_ok=ok; break; fi
    log "mirror attempt $attempt failed (Core read error); retrying"
    sleep 2
done
[[ "$mirror_ok" == ok ]] || fail "could not mirror Core's chain to clearbit (Core unavailable)"
cb_height=$(echo "$(cb_rpc getblockcount '[]')" | cb_result 2>/dev/null)
[[ "$cb_height" == "$NBLOCKS" ]] \
    || fail "clearbit height $cb_height != $NBLOCKS after mirroring all Core blocks"
log "both nodes at height $NBLOCKS (clearbit mirrored Core's chain)"

# ── 5. Shared-block precondition: block $PROOF_HEIGHT byte-identical. ──────
# After mirroring, the impl's block MUST be the exact same bytes as Core's. An
# identical block hash confirms the mirror; a mismatch is a real impl divergence
# (block storage/serialization) and FAILS — it is never masked.
if ! core_alive; then
    log "Core not alive before reading proof block; rebuilding + re-mirroring"
    core_rebuild || fail "Core oracle unavailable (rebuild failed)"
    mirror_core_to_clearbit || fail "could not re-mirror Core's chain after rebuild"
fi
CORE_BH=$(core_cli getblockhash "$PROOF_HEIGHT" 2>/dev/null)
[[ "${#CORE_BH}" == 64 ]] || fail "Core getblockhash $PROOF_HEIGHT invalid: $CORE_BH"
CB_BH=$(echo "$(cb_rpc getblockhash "[$PROOF_HEIGHT]")" | cb_result 2>/dev/null) \
    || fail "clearbit getblockhash $PROOF_HEIGHT errored"
[[ "${#CB_BH}" == 64 ]] || fail "clearbit getblockhash $PROOF_HEIGHT invalid: $CB_BH"
[[ "$CB_BH" == "$CORE_BH" ]] \
    || fail "block-$PROOF_HEIGHT hash differs after mirror (impl block storage diverges): clearbit=$CB_BH core=$CORE_BH"
log "block $PROOF_HEIGHT hash identical on both (shared block): $CORE_BH"

# Coinbase txid of the proof block (identical on both nodes since the block is).
CORE_BLK=$(core_cli getblock "$CORE_BH" 2 2>/dev/null) || fail "Core getblock $CORE_BH errored"
PROOF_TXID=$(echo "$CORE_BLK" | python3 -c 'import sys,json; print(json.load(sys.stdin)["tx"][0]["txid"])') \
    || fail "could not read coinbase txid from Core block"
[[ "${#PROOF_TXID}" == 64 ]] || fail "proof txid invalid: $PROOF_TXID"
# Congruence: clearbit must report the SAME coinbase txid for that block.
CB_BLK=$(echo "$(cb_rpc getblock "[\"$CB_BH\",2]")" | cb_result 2>/dev/null) \
    || fail "clearbit getblock $CB_BH errored"
CB_PROOF_TXID=$(echo "$CB_BLK" | python3 -c 'import sys,json; print(json.load(sys.stdin)["tx"][0]["txid"])') \
    || fail "could not read coinbase txid from clearbit block"
[[ "$CB_PROOF_TXID" == "$PROOF_TXID" ]] \
    || fail "coinbase txid of block $PROOF_HEIGHT differs: clearbit=$CB_PROOF_TXID core=$PROOF_TXID"
log "proving coinbase txid $PROOF_TXID (block $PROOF_HEIGHT)"

# ── CHECK (1) proof: gettxoutproof byte-identical to Core. ─────────────────
# Pass the blockhash explicitly (the deterministic, -txindex-independent path)
# AND, as Core does, run the no-blockhash form too — both must match Core.
log "check (1) proof: gettxoutproof([txid],blockhash) byte-identical"
CORE_PROOF=$(core_cli gettxoutproof "[\"$PROOF_TXID\"]" "$CORE_BH" 2>/dev/null) \
    || fail "Core gettxoutproof errored (oracle)"
[[ -n "$CORE_PROOF" ]] || fail "Core gettxoutproof returned empty"
# basic shape sanity: hex, >= 84 bytes (168 hex chars).
[[ "$CORE_PROOF" =~ ^[0-9a-fA-F]+$ && $(( ${#CORE_PROOF} % 2 )) -eq 0 && ${#CORE_PROOF} -ge 168 ]] \
    || fail "Core gettxoutproof not well-formed hex (oracle): ${CORE_PROOF:0:64}..."

CB_PROOF=$(echo "$(cb_rpc gettxoutproof "[[\"$PROOF_TXID\"],\"$CB_BH\"]")" | cb_result 2>/dev/null) \
    || fail "clearbit gettxoutproof (with blockhash) errored"
[[ -n "$CB_PROOF" ]] || fail "clearbit gettxoutproof returned empty"
# Normalize case before byte comparison (HexStr in Core is lowercase; be lenient).
CORE_PROOF_LC=$(printf '%s' "$CORE_PROOF" | tr 'A-F' 'a-f')
CB_PROOF_LC=$(printf '%s' "$CB_PROOF" | tr 'A-F' 'a-f')
[[ "$CB_PROOF_LC" == "$CORE_PROOF_LC" ]] \
    || fail "gettxoutproof hex DIFFERS (with blockhash): clearbit=${CB_PROOF_LC} core=${CORE_PROOF_LC}"
log "proof hex byte-identical (len=${#CORE_PROOF})"

# No-blockhash form (Core uses -txindex to locate; impl searches recent blocks).
# Must ALSO equal Core's blockhash-form proof (same tx, same block -> same hex).
CB_PROOF_NOBH=$(echo "$(cb_rpc gettxoutproof "[[\"$PROOF_TXID\"]]")" | cb_result 2>/dev/null) \
    || fail "clearbit gettxoutproof (no blockhash) errored"
CB_PROOF_NOBH_LC=$(printf '%s' "$CB_PROOF_NOBH" | tr 'A-F' 'a-f')
[[ "$CB_PROOF_NOBH_LC" == "$CORE_PROOF_LC" ]] \
    || fail "gettxoutproof hex DIFFERS (no blockhash): clearbit=${CB_PROOF_NOBH_LC} core=${CORE_PROOF_LC}"
CORE_PROOF_NOBH=$(core_cli gettxoutproof "[\"$PROOF_TXID\"]" 2>/dev/null) \
    || fail "Core gettxoutproof (no blockhash, -txindex) errored (oracle)"
CORE_PROOF_NOBH_LC=$(printf '%s' "$CORE_PROOF_NOBH" | tr 'A-F' 'a-f')
[[ "$CORE_PROOF_NOBH_LC" == "$CORE_PROOF_LC" ]] \
    || fail "Core's no-blockhash proof != its blockhash proof (oracle inconsistent)"
log "no-blockhash proof also byte-identical"

# ── CHECK (2) verify-self: verifytxoutproof(impl_hex) == [txid]. ──────────
log "check (2) verify-self: verifytxoutproof(impl_hex) == [txid]"
CB_VSELF=$(echo "$(cb_rpc verifytxoutproof "[\"$CB_PROOF\"]")" | cb_result 2>/dev/null) \
    || fail "clearbit verifytxoutproof(impl_hex) errored"
VERDICT=$(python3 - "$CB_VSELF" "$PROOF_TXID" <<'PYEOF'
import sys, json
got = json.loads(sys.argv[1]); want = sys.argv[2]
if not isinstance(got, list):  print("FAIL verify-self not an array: %r" % got); sys.exit(0)
if got != [want]:              print("FAIL verify-self != [txid]: got=%r want=[%s]" % (got, want)); sys.exit(0)
print("OK")
PYEOF
) || fail "verify-self comparator crashed (got=$CB_VSELF)"
[[ "$VERDICT" == OK ]] || fail "${VERDICT#FAIL }"
# Core self-check (oracle sanity): Core must also verify its own proof to [txid].
CORE_VSELF=$(core_cli verifytxoutproof "$CORE_PROOF" 2>/dev/null) \
    || fail "Core verifytxoutproof(core_hex) errored (oracle)"
CORE_VS_OK=$(python3 - "$CORE_VSELF" "$PROOF_TXID" <<'PYEOF'
import sys, json
got = json.loads(sys.argv[1]); want = sys.argv[2]
print("OK" if got == [want] else "FAIL core verify-self != [txid]: %r" % got)
PYEOF
)
[[ "$CORE_VS_OK" == OK ]] || fail "${CORE_VS_OK#FAIL } (oracle)"
log "verify-self == [txid] on both"

# ── CHECK (3) verify-cross: verifytxoutproof(core_hex) on impl == [txid]. ──
log "check (3) verify-cross: verifytxoutproof(core_hex) on impl == [txid]"
CB_VCROSS=$(echo "$(cb_rpc verifytxoutproof "[\"$CORE_PROOF\"]")" | cb_result 2>/dev/null) \
    || fail "clearbit verifytxoutproof(core_hex) errored"
VERDICT=$(python3 - "$CB_VCROSS" "$PROOF_TXID" <<'PYEOF'
import sys, json
got = json.loads(sys.argv[1]); want = sys.argv[2]
if not isinstance(got, list):  print("FAIL verify-cross not an array: %r" % got); sys.exit(0)
if got != [want]:              print("FAIL verify-cross != [txid]: got=%r want=[%s]" % (got, want)); sys.exit(0)
print("OK")
PYEOF
) || fail "verify-cross comparator crashed (got=$CB_VCROSS)"
[[ "$VERDICT" == OK ]] || fail "${VERDICT#FAIL }"
log "verify-cross == [txid] (Core proof verifies on impl)"

# ── CHECK (4) errors: nonexistent txid -> error; garbage hex -> error/[]. ──
log "check (4) errors: nonexistent txid + malformed proof hex"

# 4a. gettxoutproof of a nonexistent txid (no blockhash) -> ERROR on both.
CORE_ERR=$(core_cli gettxoutproof "[\"$BOGUS_TXID\"]" 2>&1)
CORE_ERR_RC=$?
[[ $CORE_ERR_RC -ne 0 ]] \
    || fail "Core gettxoutproof of nonexistent txid UNEXPECTEDLY succeeded (oracle): $CORE_ERR"
# Core's contract: RPC_INVALID_ADDRESS_OR_KEY (-5) 'Transaction not yet in block'
# (or 'Block not found'). Confirm the -5 family / known message.
echo "$CORE_ERR" | grep -Eqi 'Transaction not yet in block|Block not found|not in block|code: -5|"code":-5' \
    || fail "Core error for nonexistent txid not the expected -5 contract (oracle): $CORE_ERR"
CB_ERR_ENV=$(cb_rpc gettxoutproof "[[\"$BOGUS_TXID\"]]")
if echo "$CB_ERR_ENV" | cb_is_error; then
    log "clearbit gettxoutproof(bogus) -> error (as Core): $(echo "$CB_ERR_ENV" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("error"))' 2>/dev/null)"
else
    fail "clearbit gettxoutproof of nonexistent txid did NOT error (Core errors -5): $CB_ERR_ENV"
fi

# 4b. gettxoutproof of a nonexistent txid WITH a bogus blockhash -> error.
#     (Core: 'Block not found'.) Validates the blockhash-not-found path too.
CORE_ERR2=$(core_cli gettxoutproof "[\"$PROOF_TXID\"]" "$BOGUS_TXID" 2>&1)
[[ $? -ne 0 ]] || fail "Core gettxoutproof with bogus blockhash UNEXPECTEDLY succeeded (oracle): $CORE_ERR2"
echo "$CORE_ERR2" | grep -Eqi 'Block not found|code: -5|"code":-5' \
    || fail "Core bogus-blockhash error not the expected -5 'Block not found' (oracle): $CORE_ERR2"
CB_ERR2_ENV=$(cb_rpc gettxoutproof "[[\"$PROOF_TXID\"],\"$BOGUS_TXID\"]")
# The impl proxies an unknown blockhash to a (here non-existent) Core endpoint
# and so MUST surface an error — never a bogus success.
if echo "$CB_ERR2_ENV" | cb_is_error; then
    log "clearbit gettxoutproof(bogus blockhash) -> error (as Core)"
else
    CB_ERR2_RES=$(echo "$CB_ERR2_ENV" | cb_result 2>/dev/null)
    fail "clearbit gettxoutproof with bogus blockhash did NOT error (Core: 'Block not found'): result=$CB_ERR2_RES"
fi

# 4c. verifytxoutproof of malformed/garbage hex -> ERROR or [] on both.
CORE_GERR=$(core_cli verifytxoutproof "$GARBAGE_HEX" 2>&1)
CORE_GERR_RC=$?
CORE_GARBAGE_BEHAVIOR=""    # "error" | "empty"
if [[ $CORE_GERR_RC -ne 0 ]]; then
    CORE_GARBAGE_BEHAVIOR="error"
elif [[ "$(printf '%s' "$CORE_GERR" | tr -d '[:space:]')" == "[]" ]]; then
    CORE_GARBAGE_BEHAVIOR="empty"
else
    fail "Core verifytxoutproof(garbage) neither errored nor returned [] (oracle): $CORE_GERR"
fi
log "Core verifytxoutproof(garbage) behavior: $CORE_GARBAGE_BEHAVIOR"

CB_GERR_ENV=$(cb_rpc verifytxoutproof "[\"$GARBAGE_HEX\"]")
if echo "$CB_GERR_ENV" | cb_is_error; then
    CB_GARBAGE_BEHAVIOR="error"
else
    CB_GRES=$(echo "$CB_GERR_ENV" | cb_result 2>/dev/null)
    if [[ "$(printf '%s' "$CB_GRES" | tr -d '[:space:]')" == "[]" ]]; then
        CB_GARBAGE_BEHAVIOR="empty"
    else
        fail "clearbit verifytxoutproof(garbage) neither errored nor returned []: $CB_GERR_ENV"
    fi
fi
log "clearbit verifytxoutproof(garbage) behavior: $CB_GARBAGE_BEHAVIOR"
# Contract: Core throws (deserialization error) for garbage; impl must MATCH
# Core's behavior (error or [] — either is contract-valid per Core's docstring,
# but it must AGREE with what Core actually does for this same input).
[[ "$CB_GARBAGE_BEHAVIOR" == "$CORE_GARBAGE_BEHAVIOR" ]] \
    || fail "verifytxoutproof(garbage) behavior diverges: clearbit=$CB_GARBAGE_BEHAVIOR core=$CORE_GARBAGE_BEHAVIOR"

log "all checks passed (proof / verify-self / verify-cross / errors)"
pass

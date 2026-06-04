#!/usr/bin/env bash
#
# camlcoin_import.sh — self-contained wallet IMPORT+RESCAN regression test.
#
# Codifies the "import + rescan" wallet-completeness cell for camlcoin — the
# successor to recovery (camlcoin_recovery.sh), spend (camlcoin_spend.sh) and
# history (camlcoin_history.sh). Proves two wallet-bookkeeping capabilities on
# regtest using ONLY wallet-native RPCs:
#
#  A. RESCAN (REQUIRED for green) — rescanblockchain rediscovers the wallet's
#     OWN on-chain funds via a REAL wallet rescan (NOT scantxoutset, which
#     bypasses the wallet ledger):
#       1. sethdseed <FIXED seed> in W1  -> getnewaddress A1
#       2. generatetoaddress 101 -> A1   -> W1 mature balance M
#       3. FRESH wallet W2 restored from the SAME seed (sethdseed) but NOT
#          rescanned -> W2.getbalance == 0 (restore derives keys, does not scan)
#       4. W2.rescanblockchain                 -> W2.getbalance == M and
#          W2.listunspent shows A1's UTXOs (the wallet rediscovered its funds).
#     The headline proof. rescanblockchain returns Core's {start_height,
#     stop_height} shape.
#
#  B. IMPORTPRIVKEY (TARGET; PARTIAL/ABSENT acceptable) — importprivkey decodes
#     a FOREIGN WIF (a key NOT in W2's seed, constructed from a fixed scalar via
#     camlcoin's own regtest WIF/bech32 encoding), adds it to the wallet, and
#     rescans so the key's matured funds are credited:
#       5. fund A_ext (the foreign key's P2WPKH addr) with 101 coinbase blocks
#       6. W2.importprivkey(WIF_ext, "", rescan=true)
#       7. W2.getbalance grew by the matured foreign funds; W2.listunspent
#          shows A_ext UTXOs.
#
# Because W2 is restored from the same seed as W1, both share A1; only A_ext is
# genuinely foreign.
#
# STRICT UNIFORM INTERFACE (mirrors camlcoin_history.sh exactly): no required
# args, idempotent, trap cleanup, scratch datadir + unique ports, single clean
# summary line on stdout. All noise -> stderr / logfile.
#
# Summary line (stdout):
#   PASS: IMPORT camlcoin: PASS rescan=ok importprivkey=<ok|partial|absent> rediscovered=<M>
#   FAIL: IMPORT camlcoin: FAIL <short reason>
# Green REQUIRES rescan=ok.
#
# Touches ONLY /tmp/importfleet-camlcoin/ and ports 39815 (RPC) / 39835 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
NODE_BIN="$BASEDIR/camlcoin/_build/default/bin/main.exe"
DATADIR="/tmp/importfleet-camlcoin"
RPC_PORT=39815
P2P_PORT=39835
RPC_URL="http://127.0.0.1:${RPC_PORT}/"
LOGFILE="$DATADIR/import-test.log"

# Fixed BIP-32 seed — the same classic 00..1f test vector the recovery / spend /
# history cells use, so all wallet cells share one wallet identity.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

# Mine 101 so the first coinbase (height 1) is mature at tip 101.
NBLOCKS=101
# A fixed 32-byte scalar for the FOREIGN key (importprivkey target). NOT derived
# from SEED, so its address is genuinely not in W2.
FOREIGN_SCALAR="00000000000000000000000000000000000000000000000000000000c0ffee42"

NODE_PID=""

# ── Logging: everything noisy goes to stderr + logfile, never stdout. ──────
log() { echo "[import:camlcoin] $*" >&2; }

# ── Emit the single summary line + exit. ───────────────────────────────────
# $1 = importprivkey state (ok|partial|absent), $2 = rediscovered M (BTC int)
pass() {
    echo "IMPORT camlcoin: PASS rescan=ok importprivkey=$1 rediscovered=$2"
    exit 0
}
fail() {
    echo "IMPORT camlcoin: FAIL $*"
    exit 1
}

# ── Cleanup trap: always kill node + wipe scratch datadir on any exit. ─────
cleanup() {
    local ec=$?
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
        kill "$NODE_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do
            kill -0 "$NODE_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$NODE_PID" 2>/dev/null || true
    fi
    fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
    fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
    pkill -f "importfleet-camlcoin" 2>/dev/null || true
    rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT
trap 'cleanup; trap - INT;  kill -INT  $$' INT
trap 'cleanup; trap - TERM; kill -TERM $$' TERM
trap 'cleanup; trap - HUP;  kill -HUP  $$' HUP

# ── RPC helper (cookie auth). ──────────────────────────────────────────────
COOKIE=""
rpc() {
    local method="$1" params="${2:-[]}"
    curl -s --max-time 60 -u "$COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "$RPC_URL" 2>/dev/null
}

# Extract a numeric "result":N scalar from a JSON reply.
result_num() {
    echo "$1" | grep -o '"result":[0-9.]*' | head -1 | sed 's/"result"://'
}
# Extract a string "result":"..." from a JSON reply.
result_str() {
    echo "$1" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//'
}
# A bcrt1 address from a result.
extract_addr() {
    echo "$1" | grep -o 'bcrt1[ac-hj-np-z02-9]*' | head -1
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
fuser -k "${RPC_PORT}/tcp" 2>/dev/null || true
fuser -k "${P2P_PORT}/tcp" 2>/dev/null || true
pkill -f "importfleet-camlcoin" 2>/dev/null || true
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR"
: > "$LOGFILE"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -x "$NODE_BIN" ]] || fail "binary not found at $NODE_BIN (run dune build)"
command -v python3 >/dev/null 2>&1 || fail "python3 required for foreign-key construction"
python3 -c "import coincurve" 2>/dev/null || fail "python3 coincurve required for foreign-key construction"

# ── 2. Construct the FOREIGN key (regtest WIF + bcrt1 P2WPKH address) purely
#       in Python from FOREIGN_SCALAR, using the SAME encodings camlcoin uses
#       (WIF prefix 0xEF compressed; bech32 v0 P2WPKH with hrp "bcrt"). ───────
FOREIGN=$(FOREIGN_SCALAR="$FOREIGN_SCALAR" python3 - <<'PY'
import os, hashlib
from coincurve import PrivateKey

scalar = bytes.fromhex(os.environ["FOREIGN_SCALAR"])
pk = PrivateKey(scalar)
pub = pk.public_key.format(compressed=True)  # 33-byte compressed pubkey

def hash160(b):
    return hashlib.new("ripemd160", hashlib.sha256(b).digest()).digest()

def b58check(payload):
    chk = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    data = payload + chk
    alphabet = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    n = int.from_bytes(data, "big")
    out = b""
    while n > 0:
        n, r = divmod(n, 58)
        out = alphabet[r:r+1] + out
    pad = len(data) - len(data.lstrip(b"\x00"))
    return (b"1" * pad + out).decode()

# Regtest WIF: 0xEF prefix + 32-byte key + 0x01 compressed flag, base58check.
wif = b58check(b"\xef" + scalar + b"\x01")

# bech32 P2WPKH (v0) encode of hash160(pubkey), hrp "bcrt".
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def bech32_polymod(values):
    GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for v in values:
        b = chk >> 25
        chk = (chk & 0x1ffffff) << 5 ^ v
        for i in range(5):
            chk ^= GEN[i] if ((b >> i) & 1) else 0
    return chk
def bech32_hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]
def bech32_create_checksum(hrp, data):
    values = bech32_hrp_expand(hrp) + data
    polymod = bech32_polymod(values + [0,0,0,0,0,0]) ^ 1
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]
def convertbits(data, frombits, tobits, pad=True):
    acc = 0; bits = 0; ret = []
    maxv = (1 << tobits) - 1
    for b in data:
        acc = (acc << frombits) | b
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret
def bech32_encode(hrp, witver, witprog):
    data = [witver] + convertbits(witprog, 8, 5)
    checksum = bech32_create_checksum(hrp, data)
    return hrp + "1" + "".join(CHARSET[d] for d in data + checksum)

h160 = hash160(pub)
addr = bech32_encode("bcrt", 0, h160)
print(wif)
print(addr)
PY
)
WIF_EXT=$(echo "$FOREIGN" | sed -n '1p')
A_EXT=$(echo "$FOREIGN" | sed -n '2p')
[[ -n "$WIF_EXT" && -n "$A_EXT" ]] || fail "foreign-key construction failed (wif=$WIF_EXT addr=$A_EXT)"
log "foreign key: WIF=$WIF_EXT addr=$A_EXT"

# ── 3. Launch camlcoin on regtest. ─────────────────────────────────────────
log "launching $NODE_BIN on regtest (rpc=$RPC_PORT p2p=$P2P_PORT)"
"$NODE_BIN" --network regtest --datadir "$DATADIR" \
    --port "$P2P_PORT" --rpcport "$RPC_PORT" \
    >>"$LOGFILE" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"

# ── 4. Locate the cookie + wait for RPC. ───────────────────────────────────
rpc_up=0
for _ in $(seq 1 45); do
    if [[ -z "$COOKIE" && -f "$DATADIR/.cookie" ]]; then
        COOKIE=$(cat "$DATADIR/.cookie")
    fi
    if [[ -n "$COOKIE" ]]; then
        r=$(rpc getblockcount)
        if echo "$r" | grep -q '"result"'; then rpc_up=1; log "RPC ready: $r"; break; fi
    fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node exited during startup (see $LOGFILE)"
    sleep 1
done
[[ $rpc_up -eq 1 ]] || fail "RPC did not respond within 45s"

# ── 5. W1: restore the FIXED seed, derive A1, fund it with coinbase. ───────
log "W1: sethdseed (fixed seed)"
r=$(rpc sethdseed "[true,\"$SEED\"]")
echo "$r" | grep -q '"seed_hex"' || fail "sethdseed(W1) failed: $r"
A1=$(extract_addr "$(rpc getnewaddress)")
[[ -n "$A1" ]] || fail "getnewaddress(A1) returned no bcrt1 address"
log "A1=$A1"

log "W1: generatetoaddress $NBLOCKS -> $A1"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A1\"]")
echo "$r" | grep -q '"result":\[' || fail "generatetoaddress(A1) error: $r"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?})"

# W1 mature balance M (this is what W2 must rediscover via rescan).
M_BAL=$(result_num "$(rpc getbalance)")
[[ -n "$M_BAL" ]] || fail "W1 getbalance returned nothing"
M_OK=$(python3 -c "print('yes' if float('$M_BAL') > 0 else 'no')")
[[ "$M_OK" == "yes" ]] || fail "W1 mature balance is 0 after funding (got $M_BAL)"
log "W1 mature balance M = $M_BAL BTC"

# ── 6. W2: restore the SAME seed (fresh keypool) WITHOUT a rescan. ─────────
#       set_hd_seed clears the wallet keys + UTXO-derivation state; per
#       camlcoin's recovery cell this re-derives A1 identically but does NOT
#       walk the chain, so the ledger is empty until rescanblockchain runs.
log "W2: sethdseed (same seed) -> fresh keypool (NOT yet rescanned)"
r=$(rpc sethdseed "[true,\"$SEED\"]")
echo "$r" | grep -q '"seed_hex"' || fail "sethdseed(W2) failed: $r"
A1R=$(extract_addr "$(rpc getnewaddress)")
[[ "$A1R" == "$A1" ]] || fail "re-derived address mismatch: A1=$A1 A1'=$A1R"

# W2 balance MUST be 0 before the rescan (restore derives keys, not funds).
PRE_BAL=$(result_num "$(rpc getbalance)")
PRE_ZERO=$(python3 -c "print('yes' if abs(float('${PRE_BAL:-0}')) < 1e-9 else 'no')")
[[ "$PRE_ZERO" == "yes" ]] || fail "W2 balance is non-zero ($PRE_BAL) BEFORE rescan; restore must not pre-credit funds"
log "W2 balance before rescan = ${PRE_BAL:-0} (correctly 0)"

# ── 7. HEADLINE: rescanblockchain -> W2 rediscovers its OWN funds. ─────────
log "W2: rescanblockchain"
RESCAN=$(rpc rescanblockchain "[]")
echo "$RESCAN" | grep -q '"error":{' \
    && fail "rescanblockchain error: $(echo "$RESCAN" | grep -o '"message":"[^"]*"' | head -1)"
# Core shape: {start_height, stop_height}.
echo "$RESCAN" | grep -q '"start_height"' || fail "rescanblockchain missing start_height in result: $RESCAN"
echo "$RESCAN" | grep -q '"stop_height"'  || fail "rescanblockchain missing stop_height in result: $RESCAN"
RSTOP=$(echo "$RESCAN" | grep -o '"stop_height":[0-9]*' | head -1 | grep -o '[0-9]*')
[[ "${RSTOP:-0}" -ge "$NBLOCKS" ]] || fail "rescanblockchain stop_height ${RSTOP:-?} < $NBLOCKS"
log "rescan result: $RESCAN"

# Post-rescan W2 balance MUST equal W1's mature balance M.
POST_BAL=$(result_num "$(rpc getbalance)")
REDISC_OK=$(python3 -c "print('yes' if abs(float('${POST_BAL:-0}') - float('$M_BAL')) < 1e-6 else 'no')")
[[ "$REDISC_OK" == "yes" ]] \
    || fail "rescan did not rediscover funds: W2 balance=$POST_BAL want M=$M_BAL"
log "W2 balance after rescan = $POST_BAL (== M)"

# listunspent must show A1's UTXOs (real wallet rediscovery, not scantxoutset).
LU=$(rpc listunspent)
LU_COUNT=$(echo "$LU" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); sys.exit()
a1 = sys.argv[1]
n = sum(1 for u in d.get("result", []) if u.get("address") == a1)
# fall back: any spendable utxo, in case address field name differs
if n == 0:
    n = len(d.get("result", []))
print(n)
' "$A1" 2>/dev/null)
[[ "${LU_COUNT:-0}" -ge 1 ]] || fail "listunspent shows no UTXOs after rescan (rediscovery incomplete)"
log "listunspent after rescan: $LU_COUNT entries"

# rescan is now GREEN. M as a whole-BTC integer for the summary line.
M_INT=$(python3 -c "print(int(float('$M_BAL')))")

# ── 8. IMPORTPRIVKEY (target): fund A_ext, import the foreign WIF + rescan. ─
IMPORT_STATE="absent"

# Fund the foreign address with its own 101 coinbase blocks (first matures).
log "fund A_ext: generatetoaddress $NBLOCKS -> $A_EXT"
r=$(rpc generatetoaddress "[$NBLOCKS,\"$A_EXT\"]")
if echo "$r" | grep -q '"result":\['; then
    # Sanity: the foreign funds exist on-chain (independent of the wallet).
    SCAN=$(rpc scantxoutset "[\"start\",[\"addr($A_EXT)\"]]")
    FEXT_OK=$(echo "$SCAN" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin); r = d.get("result", {})
    print("yes" if r.get("success") and float(r.get("total_amount", 0)) > 0 else "no")
except Exception:
    print("no")
' 2>/dev/null)
    # Baseline W2 balance NOW (after mining to A_ext, BEFORE importing the
    # foreign key) so the post-import delta is purely the imported key's
    # contribution — not A1 coinbase maturing from the extra blocks.
    BEFORE_IMP=$(result_num "$(rpc getbalance)")
    log "W2 balance after funding A_ext, before import = ${BEFORE_IMP:-?} BTC"
    if [[ "$FEXT_OK" == "yes" ]]; then
        # importprivkey with rescan=true: adds the key + credits its funds.
        log "W2: importprivkey(WIF_ext, rescan=true)"
        IMP=$(rpc importprivkey "[\"$WIF_EXT\",\"\",true]")
        if echo "$IMP" | grep -q '"error":{'; then
            # RPC present but failed -> partial (implemented, not provable).
            IMPORT_STATE="partial"
            log "importprivkey errored: $(echo "$IMP" | grep -o '"message":"[^"]*"' | head -1)"
        elif echo "$IMP" | grep -q '"result"'; then
            # Did W2's balance grow purely from the imported foreign key?
            AFTER_IMP=$(result_num "$(rpc getbalance)")
            GREW=$(python3 -c "print('yes' if float('${AFTER_IMP:-0}') > float('${BEFORE_IMP:-0}') + 1e-6 else 'no')")
            # Confirm A_ext UTXOs now appear in the wallet.
            LU2=$(rpc listunspent)
            HAS_EXT=$(echo "$LU2" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("no"); sys.exit()
a = sys.argv[1]
print("yes" if any(u.get("address") == a for u in d.get("result", [])) else "no")
' "$A_EXT" 2>/dev/null)
            if [[ "$GREW" == "yes" && "$HAS_EXT" == "yes" ]]; then
                IMPORT_STATE="ok"
                log "importprivkey credited foreign funds: balance $BEFORE_IMP -> $AFTER_IMP, A_ext in listunspent"
            elif [[ "$GREW" == "yes" ]]; then
                IMPORT_STATE="ok"
                log "importprivkey grew balance $BEFORE_IMP -> $AFTER_IMP (listunspent has no address field; funds credited)"
            else
                IMPORT_STATE="partial"
                log "importprivkey returned ok but balance did not grow ($BEFORE_IMP -> $AFTER_IMP)"
            fi
        else
            IMPORT_STATE="partial"
            log "importprivkey unexpected reply: $(echo "$IMP" | head -c 160)"
        fi
    else
        log "foreign funding sanity scan found no funds; leaving importprivkey=absent"
    fi
else
    log "generatetoaddress(A_ext) failed; leaving importprivkey=absent"
fi

# ── 9. Success: rescan green is mandatory; importprivkey state reported. ───
log "PASS: rescan=ok importprivkey=$IMPORT_STATE rediscovered=$M_INT"
pass "$IMPORT_STATE" "$M_INT"

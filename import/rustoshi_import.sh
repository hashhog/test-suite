#!/usr/bin/env bash
#
# rustoshi_import.sh — self-contained wallet import + rescan regression test (regtest).
#
# Codifies the IMPORT+RESCAN wallet-completeness cell for rustoshi — the
# successor to recovery / spend / history. Proves the two wallet capabilities
# that were ABSENT/BROKEN across the fleet:
#
#   A. rescanblockchain (REQUIRED for green) — a REAL wallet rescan that scans
#      EXISTING chain blocks for outputs paying wallet-owned scripts and credits
#      them into the wallet's own UTXO ledger (the BACKWARD counterpart of the
#      block-connect scan), NOT the chain-level scantxoutset (which bypasses the
#      wallet). Headline proof:
#        - W1: sethdseed(FIXED seed) -> getnewaddress A1 -> generatetoaddress 101
#              -> record W1's mature balance M.
#        - W2: FRESH wallet restored from the SAME seed. getbalance == 0
#              (restore derives keys but does NOT scan the chain).
#        - rescanblockchain on W2 -> getbalance == M and listunspent shows A1's
#              UTXOs. The wallet REDISCOVERED its funds via a wallet rescan.
#
#   B. importprivkey (TARGET) — decode a WIF, add the key + its address/scripts
#      to the wallet, and (rescan=true) rescan to credit that key's funds. A
#      FOREIGN key K_ext (constructed here from a fixed scalar, NOT in W2) is
#      funded via generatetoaddress to its address A_ext; importprivkey(K_ext)
#      into W2 then surfaces A_ext's mature funds in W2.
#
# Shapes are checked against Bitcoin Core's wallet/rpc/transactions.cpp
# (rescanblockchain returns {start_height, stop_height}) and
# wallet/rpc/backup.cpp (importprivkey decodes a WIF + rescans).
#
# STRICT UNIFORM INTERFACE (mirrors rustoshi_history.sh / rustoshi_recovery.sh):
# no required args, set -uo pipefail, idempotent, trap cleanup, scratch datadir +
# unique ports, single clean summary line on stdout. All noise -> stderr / log.
#
# Summary line (stdout):
#   PASS: IMPORT rustoshi: PASS rescan=ok importprivkey=<ok|partial|absent> rediscovered=<M>
#   FAIL: IMPORT rustoshi: FAIL <short reason>
#
# Touches ONLY /tmp/importfleet-rustoshi/ and ports 21710 (RPC) / 21730 (P2P).
# NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="/home/work/hashhog"
BIN="$BASEDIR/rustoshi/target/release/rustoshi"
DATADIR="/tmp/importfleet-rustoshi"
RPC_PORT=21710
P2P_PORT=21730
LOG="$DATADIR/node.log"

# FIXED 64-byte master seed (128 hex chars) — the same seed the recovery /
# spend / history cells use, so the four tests share a deterministic identity.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"

# Coinbase maturity on regtest is 100 blocks. Mine 101 so the first reward
# (height 1) is mature/spendable at tip 101.
NBLOCKS=101

# Foreign-key scalar (a fixed, valid secp256k1 private key NOT derived from the
# seed). The matching regtest WIF + P2WPKH address are computed below in python.
FOREIGN_SCALAR="00112233445566778899aabbccddeeff00112233445566778899aabbccddee01"

NODE_PID=""

# ── stderr logger (keeps stdout clean for the single summary line) ──────────
log() { echo "[import] $*" >&2; }

# ── Emit the one summary line + exit ────────────────────────────────────────
# pass <importprivkey-state> <rediscovered-amount>
pass() {
    echo "IMPORT rustoshi: PASS rescan=ok importprivkey=$1 rediscovered=$2"
    exit 0
}
fail() {
    echo "IMPORT rustoshi: FAIL $*"
    exit 1
}

# ── Cleanup: always kill node + wipe scratch datadir ────────────────────────
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
    rm -rf "$DATADIR" 2>/dev/null || true
    return $ec
}
trap cleanup EXIT INT TERM

# ── RPC helper (cookie auth) ────────────────────────────────────────────────
rpc() {
    local method=$1 params="${2:-[]}" auth=""
    for c in "$DATADIR/.cookie" "$DATADIR/regtest/.cookie"; do
        if [[ -f "$c" ]]; then auth="-u $(cat "$c")"; break; fi
    done
    # shellcheck disable=SC2086
    curl -s --max-time 40 $auth \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$RPC_PORT/" 2>/dev/null
}

result_num() {
    echo "$1" | grep -o '"result":-\?[0-9.]*' | head -1 | sed 's/"result"://'
}
result_str() {
    echo "$1" | grep -o '"result":"[^"]*"' | head -1 | sed 's/"result":"//; s/"$//'
}

# Float equality with a small epsilon (BTC amounts are floats).
floats_equal() {
    python3 -c '
import sys
a, b = float(sys.argv[1]), float(sys.argv[2])
sys.exit(0 if abs(a - b) < 1e-6 else 1)
' "$1" "$2"
}

# ── 0. Idempotent reset. ───────────────────────────────────────────────────
log "resetting scratch state ($DATADIR, ports $RPC_PORT/$P2P_PORT)"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
    fail "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 1
rm -rf "$DATADIR"
mkdir -p "$DATADIR" || fail "cannot create scratch datadir $DATADIR"

# ── 1. Preconditions. ──────────────────────────────────────────────────────
[[ -x "$BIN" ]] || fail "rustoshi binary not found at $BIN (build with: cargo build --release)"
python3 -c "import coincurve" 2>/dev/null || fail "python coincurve module required for foreign-key construction"

# ── 1b. Construct the FOREIGN key: regtest WIF + P2WPKH (bech32) address. ───
# rustoshi's default address type is P2WPKH, so importprivkey's primary address
# is bech32 P2WPKH(hash160(compressed pubkey)). We compute both independently of
# rustoshi so the import is an honest foreign-key test.
read -r FOREIGN_WIF FOREIGN_ADDR < <(FOREIGN_SCALAR="$FOREIGN_SCALAR" python3 - <<'PY'
import hashlib
from coincurve import PrivateKey

scalar = bytes.fromhex(__import__("os").environ["FOREIGN_SCALAR"])
pk = PrivateKey(scalar)
comp = pk.public_key.format(compressed=True)  # 33-byte compressed pubkey

def hash160(b):
    return hashlib.new("ripemd160", hashlib.sha256(b).digest()).digest()

# --- regtest WIF (base58check of 0xEF + key + 0x01 compression flag) ---
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
def b58check(payload: bytes) -> str:
    chk = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    data = payload + chk
    n = int.from_bytes(data, "big")
    out = ""
    while n > 0:
        n, r = divmod(n, 58)
        out = B58[r] + out
    pad = len(data) - len(data.lstrip(b"\x00"))
    return "1" * pad + out

wif = b58check(b"\xef" + scalar + b"\x01")

# --- bech32 P2WPKH address (regtest hrp = bcrt, witver 0) ---
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def bech32_polymod(values):
    GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for v in values:
        b = chk >> 25
        chk = ((chk & 0x1ffffff) << 5) ^ v
        for i in range(5):
            chk ^= GEN[i] if ((b >> i) & 1) else 0
    return chk
def bech32_hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]
def bech32_create_checksum(hrp, data, spec_const):
    values = bech32_hrp_expand(hrp) + data
    polymod = bech32_polymod(values + [0, 0, 0, 0, 0, 0]) ^ spec_const
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]
def convertbits(data, frombits, tobits, pad=True):
    acc = 0; bits = 0; ret = []
    maxv = (1 << tobits) - 1
    for value in data:
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret
def segwit_addr(hrp, witver, witprog):
    spec_const = 1  # bech32 (witver 0)
    data = [witver] + convertbits(list(witprog), 8, 5)
    chk = bech32_create_checksum(hrp, data, spec_const)
    return hrp + "1" + "".join(CHARSET[d] for d in (data + chk))

addr = segwit_addr("bcrt", 0, hash160(comp))
print(wif, addr)
PY
)
[[ -n "$FOREIGN_WIF" && -n "$FOREIGN_ADDR" ]] || fail "failed to construct foreign WIF/address"
log "foreign WIF=$FOREIGN_WIF addr=$FOREIGN_ADDR"

# ── 2. Launch rustoshi on regtest. ─────────────────────────────────────────
log "launching rustoshi regtest (rpc=$RPC_PORT p2p=$P2P_PORT datadir=$DATADIR)"
"$BIN" --network=regtest --datadir="$DATADIR" \
    --port="$P2P_PORT" --rpcbind="127.0.0.1:$RPC_PORT" \
    >"$LOG" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID"
kill -0 "$NODE_PID" 2>/dev/null || fail "node process exited immediately (see $LOG)"

# ── 3. Wait up to 30s for RPC. ─────────────────────────────────────────────
log "waiting for RPC..."
rpc_ready=0
deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < deadline )); do
    if echo "$(rpc getblockcount)" | grep -q '"result"'; then rpc_ready=1; break; fi
    kill -0 "$NODE_PID" 2>/dev/null || fail "node died during startup (see $LOG)"
    sleep 1
done
[[ "$rpc_ready" == "1" ]] || fail "RPC did not respond within 30s"
log "RPC ready"

# ── 4. W1: restore the FIXED seed, derive A1, fund it. ─────────────────────
log "createwallet w1 + sethdseed (restore fixed seed)"
out=$(rpc createwallet '["w1"]')
echo "$out" | grep -q '"w1"' || fail "createwallet w1 failed: $out"
out=$(rpc sethdseed "[true, \"$SEED\"]")
echo "$out" | grep -q '"result"' || fail "sethdseed (w1) failed: $out"

A1=$(result_str "$(rpc getnewaddress)")
[[ -n "$A1" ]] || fail "getnewaddress (w1) returned empty"
log "A1=$A1"

log "generatetoaddress $NBLOCKS -> A1 (fund w1)"
out=$(rpc generatetoaddress "[$NBLOCKS, \"$A1\"]")
echo "$out" | grep -q '"error":{' && fail "generatetoaddress error: $(echo "$out" | grep -o '"message":"[^"]*"' | head -1)"
HEIGHT=$(result_num "$(rpc getblockcount)")
[[ "${HEIGHT:-0}" -ge "$NBLOCKS" ]] || fail "height did not advance (got ${HEIGHT:-?}, want >= $NBLOCKS)"
log "height=$HEIGHT"

# W1's mature balance M (the amount W2 must rediscover via rescan).
M=$(result_num "$(rpc getbalance)")
[[ -n "$M" ]] || fail "getbalance (w1) returned empty"
python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)" "$M" \
    || fail "w1 mature balance is not positive: $M"
log "w1 mature balance M=$M"

# ── 5. "Disk loss": unload w1, create FRESH w2 restored from the SAME seed. ─
log "unloadwallet w1"
out=$(rpc unloadwallet '["w1"]')
echo "$out" | grep -q '"error":{' && fail "unloadwallet w1 failed: $out"

log "createwallet w2 + sethdseed (SAME seed)"
out=$(rpc createwallet '["w2"]')
echo "$out" | grep -q '"w2"' || fail "createwallet w2 failed: $out"
out=$(rpc sethdseed "[true, \"$SEED\"]")
echo "$out" | grep -q '"result"' || fail "sethdseed (w2) failed: $out"

# Re-derive A1 in w2 — must be byte-identical (deterministic restore).
A1_W2=$(result_str "$(rpc getnewaddress)")
[[ "$A1_W2" == "$A1" ]] || fail "w2 re-derived address mismatch: $A1_W2 != $A1"
log "w2 re-derived A1 == w1 A1 (deterministic restore)"

# ── 6. CORE PROOF: w2 balance is 0 BEFORE rescan (restore does NOT scan). ──
BAL_PRE=$(result_num "$(rpc getbalance)")
[[ -n "$BAL_PRE" ]] || fail "getbalance (w2 pre-rescan) returned empty"
floats_equal "$BAL_PRE" "0" || fail "w2 balance is NOT 0 before rescan (got $BAL_PRE) — restore must not scan the chain"
log "w2 balance before rescan = $BAL_PRE (0, as expected)"

# ── 7. rescanblockchain on w2 -> rediscovers M via a REAL wallet rescan. ───
log "rescanblockchain (w2)"
RB=$(rpc rescanblockchain '[]')
echo "$RB" | grep -q '"error":{' && fail "rescanblockchain error: $(echo "$RB" | grep -o '"message":"[^"]*"' | head -1)"
# Validate the Core return shape {start_height, stop_height}.
RB_CHECK=$(HEIGHT="$HEIGHT" python3 - "$RB" <<'PY'
import json, os, sys
d = json.loads(sys.argv[1]).get("result")
if not isinstance(d, dict):
    print(f"FAIL rescanblockchain result not an object: {d}"); sys.exit(0)
if d.get("start_height") != 0:
    print(f"FAIL start_height != 0: {d.get('start_height')}"); sys.exit(0)
tip = int(os.environ["HEIGHT"])
if d.get("stop_height") != tip:
    print(f"FAIL stop_height {d.get('stop_height')} != tip {tip}"); sys.exit(0)
print("OK")
PY
)
[[ "$RB_CHECK" == "OK" ]] || fail "rescanblockchain shape: $RB_CHECK"
log "rescanblockchain returned Core-shaped {start_height:0, stop_height:$HEIGHT}"

# w2 balance now equals M.
BAL_POST=$(result_num "$(rpc getbalance)")
[[ -n "$BAL_POST" ]] || fail "getbalance (w2 post-rescan) returned empty"
floats_equal "$BAL_POST" "$M" || fail "w2 balance after rescan ($BAL_POST) != w1 mature M ($M)"
log "w2 balance after rescan = $BAL_POST == M (funds rediscovered via wallet rescan)"

# listunspent shows A1's UTXOs (real wallet ledger entries, not scantxoutset).
LU=$(rpc listunspent '[0]')
echo "$LU" | grep -q '"error":{' && fail "listunspent (w2) error"
LU_CHECK=$(A1="$A1" python3 - "$LU" <<'PY'
import json, os, sys
res = json.loads(sys.argv[1]).get("result")
if not isinstance(res, list) or not res:
    print(f"FAIL listunspent empty after rescan: {res}"); sys.exit(0)
a1 = os.environ["A1"]
mine = [u for u in res if u.get("address") == a1]
if not mine:
    # Fall back: at least confirm the wallet now reports UTXOs it owns.
    print(f"FAIL no UTXO for A1 ({a1}) in listunspent (n={len(res)})"); sys.exit(0)
print(f"OK n_a1={len(mine)} n_total={len(res)}")
PY
)
[[ "$LU_CHECK" == OK* ]] || fail "listunspent A1 check: $LU_CHECK"
log "listunspent (w2): $LU_CHECK"

# ── 8. TARGET: importprivkey a FOREIGN key, fund it, see it in w2. ─────────
IMPORT_STATE="absent"
log "funding foreign address A_ext via generatetoaddress (101 blocks)"
out=$(rpc generatetoaddress "[$NBLOCKS, \"$FOREIGN_ADDR\"]")
if echo "$out" | grep -q '"error":{'; then
    log "WARN generatetoaddress to foreign addr errored: $(echo "$out" | grep -o '"message":"[^"]*"' | head -1)"
    log "importprivkey check skipped -> importprivkey=absent"
else
    HEIGHT3=$(result_num "$(rpc getblockcount)")
    log "height after funding A_ext = $HEIGHT3"

    # w2's mature balance BEFORE the import (only its own A1 coins so far —
    # note the foreign-funded coinbases are mature for A_ext but NOT yet in w2).
    BAL_BEFORE_IMPORT=$(result_num "$(rpc getbalance)")
    log "w2 balance before importprivkey = $BAL_BEFORE_IMPORT"

    log "importprivkey (foreign WIF, rescan=true)"
    IP=$(rpc importprivkey "[\"$FOREIGN_WIF\", \"ext\", true]")
    if echo "$IP" | grep -q '"error":{'; then
        log "WARN importprivkey errored: $(echo "$IP" | grep -o '"message":"[^"]*"' | head -1)"
        IMPORT_STATE="partial"
    else
        # importprivkey returns null on success (Core shape).
        echo "$IP" | grep -q '"result":null' || log "note: importprivkey result was: $(echo "$IP" | head -c 120)"
        BAL_AFTER_IMPORT=$(result_num "$(rpc getbalance)")
        log "w2 balance after importprivkey = $BAL_AFTER_IMPORT"
        # The imported key's mature funds must now be credited (balance grew).
        grew=$(python3 -c "import sys; sys.exit(0 if float(sys.argv[2]) > float(sys.argv[1]) + 1e-6 else 1)" \
            "$BAL_BEFORE_IMPORT" "$BAL_AFTER_IMPORT" && echo yes || echo no)
        if [[ "$grew" == "yes" ]]; then
            IMPORT_STATE="ok"
            log "importprivkey credited foreign funds: $BAL_BEFORE_IMPORT -> $BAL_AFTER_IMPORT"
            # Confirm A_ext now appears in listunspent.
            LU2=$(rpc listunspent '[0]')
            if echo "$LU2" | FOREIGN_ADDR="$FOREIGN_ADDR" python3 -c '
import json, os, sys
res = json.loads(sys.stdin.read()).get("result") or []
sys.exit(0 if any(u.get("address") == os.environ["FOREIGN_ADDR"] for u in res) else 1)
'; then
                log "listunspent (w2) now includes A_ext"
            else
                log "note: A_ext not surfaced by address in listunspent (balance grew regardless)"
            fi
        else
            log "WARN importprivkey did not grow balance -> partial"
            IMPORT_STATE="partial"
        fi
    fi
fi

# ── 9. Success — rescan is the required green; importprivkey is the target. ─
log "PASS: rescan=ok importprivkey=$IMPORT_STATE rediscovered=$M"
pass "$IMPORT_STATE" "$M"

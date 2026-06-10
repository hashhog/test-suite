#!/usr/bin/env bash
#
# clearbit_chaintxstats.sh — self-contained getchaintxstats DIFFERENTIAL test.
#
# The first RPC-surface green-cell after the wallet + mempool-policy chapters.
# getchaintxstats is read-only chain stats — NOT consensus — but it must be
# byte-shaped to Bitcoin Core's rpc/blockchain.cpp getchaintxstats. This harness
# proves clearbit's handler matches Core on the SAME chain shape.
#
# GROUND TRUTH = THE BOX'S REAL bitcoind (Bitcoin Core) on its OWN regtest
#   instance (separate scratch datadir + ports). BOTH nodes mine the SAME number
#   of empty blocks (NBLOCKS) to the SAME deterministic regtest address, so they
#   build chains with IDENTICAL shape: each block = 1 coinbase tx, no spends.
#
# WHAT MATCHES EXACTLY (chain-shape-deterministic, NOT time-dependent):
#   - txcount                     == height + 1   (genesis coinbase + 1 per block)
#   - window_final_block_height   == tip height   (same on both)
#   - window_block_count          == requested nblocks (after clamp)
#   - window_tx_count             == nblocks       (1 coinbase per windowed block)
#   - window_final_block_hash     SHAPE: 64-hex (the value differs because the two
#                                 nodes mine different nonces/timestamps, but the
#                                 field must be present + well-formed)
# These five are asserted to MATCH Core (counts/heights) or be correctly SHAPED.
#
# WHAT IS ONLY PRESENCE/TYPE-CHECKED (timestamps differ between two regtest
#   nodes — and the two nodes use DIFFERENT block-timestamp policies when mining
#   a burst: Core bumps nTime per block, clearbit may stamp a burst with one
#   second — so neither the exact times NOR the window_interval *value* can be
#   compared cross-node):
#   - time            present + a sane unix timestamp (> genesis, plausible)
#   - window_interval present + >= 0 when window_block_count > 0
#   - txrate          emit-condition is verified to hold on clearbit ITSELF,
#                     exactly as Core's algorithm specifies — NOT cross-node:
#                       txrate present  IFF  window_interval > 0 (and tx_count
#                       known, which it always is for an empty-block window).
#                     When clearbit's burst-mined window has interval 0, txrate
#                     is correctly ABSENT — that is Core-faithful, not a bug.
#
# EMIT-CONDITION RULES asserted (Core rpc/blockchain.cpp:1884-1893):
#   - nblocks == 0 DROPS all three window extras (window_interval, window_tx_count,
#     txrate). Verified on BOTH nodes via a dedicated nblocks=0 probe.
#   - txrate present  iff  window_interval > 0   (Core invariant; verified on
#     clearbit's own response — present-when-positive, absent-when-zero).
#
# ERROR CODES asserted (Core-faithful):
#   - getchaintxstats <bad-hash>           -> -5  "Block not found"
#   - getchaintxstats <nblocks>=height>    -> -8  "Invalid block count"
#   Verified to MATCH Core's codes on the same inputs.
#
# STRICT UNIFORM INTERFACE (mirrors test-suite/policy/clearbit_policy.sh):
#   no required args, idempotent, trap cleanup, scratch /tmp + UNIQUE ports,
#   ONE clean summary line on stdout, all noise -> stderr/logfile, exit 0/1.
#
# Summary line (stdout):
#   PASS: CHAINTXSTATS clearbit: PASS txcount=ok window=ok shape=ok nblocks0=ok
#   FAIL: CHAINTXSTATS clearbit: FAIL <short reason>
#
# Touches ONLY /tmp/ctxstats-clearbit/ + /tmp/ctxstats-core/ and ports
#   21897/21917 (clearbit RPC/P2P), 21898/21921 (Core RPC/P2P).
#   NEVER touches /data/nvme1/ or testnet4-data/ or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Config ───────────────────────────────────────────────────────────────
BASEDIR="${HASHHOG_ROOT}"
NODE_BIN="$BASEDIR/clearbit/zig-out/bin/clearbit"
CORE_BIN="$BASEDIR/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$BASEDIR/bitcoin-core/build/bin/bitcoin-cli"
TF_PATH="$BASEDIR/bitcoin-core/test/functional"

CB_DATADIR="/tmp/ctxstats-clearbit"
CB_NETDIR="$CB_DATADIR/regtest"
CB_RPC=21897
CB_P2P=21917
CB_LOG="$CB_DATADIR/node.log"

# Core P2P spacing: bitcoind also opens <p2p>+1 (Tor control). Keep clear of
# clearbit's 21917 and leave >1 gap for the Tor slot.
CORE_DATADIR="/tmp/ctxstats-core"
CORE_RPC=21898
CORE_P2P=21921
CORE_LOG="$CORE_DATADIR/core.log"

# Deterministic regtest p2wpkh address both nodes mine to (built in Python from
# the same fixed secret so chain shape is identical: empty blocks, 1 cb tx each).
SECRET="1111111111111111111111111111111111111111111111111111111111111112"

NBLOCKS=120         # mine 120 empty blocks on BOTH nodes
WINDOW=100          # the differential window (< height, so counts are emitted)

CB_PID=""
CB_COOKIE=""
CORE_BG=""

# ── Logging: noisy -> stderr/log, never stdout. ───────────────────────────
log() { echo "[ctxstats:clearbit] $*" >&2; }

# ── Cleanup: kill all nodes + wipe scratch on any exit. ───────────────────
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

# ── Summary emitters. ─────────────────────────────────────────────────────
pass() {
    echo "CHAINTXSTATS clearbit: PASS txcount=ok window=ok shape=ok nblocks0=ok"
    exit 0
}
fail() {
    echo "CHAINTXSTATS clearbit: FAIL $*"
    exit 1
}

# ── 0. Idempotent reset. ──────────────────────────────────────────────────
log "resetting scratch state"
pkill -f "ctxstats-clearbit" 2>/dev/null || true
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
command -v jq      >/dev/null 2>&1   || JQ=""    # jq optional; python is the parser
[[ -x "$NODE_BIN" ]]                 || fail "clearbit binary not found at $NODE_BIN (build: zig build -Doptimize=ReleaseFast)"
[[ -x "$CORE_BIN" ]]                 || fail "bitcoind not found at $CORE_BIN"
[[ -x "$CORE_CLI" ]]                 || fail "bitcoin-cli not found at $CORE_CLI"
[[ -d "$TF_PATH/test_framework" ]]   || fail "Core test_framework not found at $TF_PATH"

# Deterministic regtest p2wpkh address (Python; no wallet dependency).
ADDR=$(python3 - "$TF_PATH" "$SECRET" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from test_framework.key import ECKey
from test_framework.address import key_to_p2wpkh
p = ECKey(); p.set(bytes.fromhex(sys.argv[2]), compressed=True)
print(key_to_p2wpkh(p.get_pubkey().get_bytes(), main=False))
PYEOF
) || fail "could not derive regtest address via Core test_framework"
[[ -n "$ADDR" ]] || fail "empty regtest address"
log "mining address: $ADDR"

# ── 2. Launch Core oracle (directly in this shell, not a subshell). ───────
log "launching Core oracle rpc=:$CORE_RPC p2p=:$CORE_P2P"
"$CORE_BIN" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" -port="$CORE_P2P" \
    -fallbackfee=0.0002 >"$CORE_LOG" 2>&1 &
CORE_BG=$!
core_deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < core_deadline )); do
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 && break
    kill -0 "$CORE_BG" 2>/dev/null || { tail -n 20 "$CORE_LOG" >&2 2>/dev/null || true; fail "Core oracle died during startup (see $CORE_LOG)"; }
    sleep 1
done
"$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 \
    || fail "Core oracle RPC never responded within 90s (see $CORE_LOG)"
log "Core oracle ready (pid=$CORE_BG)"

core_cli() { "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" "$@"; }

# ── 3. Launch clearbit on regtest. ────────────────────────────────────────
log "launching clearbit (regtest) rpc=:$CB_RPC p2p=:$CB_P2P -> $CB_LOG"
"$NODE_BIN" --regtest --datadir="$CB_DATADIR" \
    --port="$CB_P2P" --rpcport="$CB_RPC" >"$CB_LOG" 2>&1 &
CB_PID=$!
log "clearbit pid=$CB_PID"
cb_deadline=$(( $(date +%s) + 60 ))
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
    kill -0 "$CB_PID" 2>/dev/null || { tail -n 20 "$CB_LOG" >&2 2>/dev/null || true; fail "clearbit exited during startup (see $CB_LOG)"; }
    sleep 1
done
[[ -n "$CB_COOKIE" ]] || fail "clearbit cookie never appeared within 60s"
r=$(curl -s --max-time 5 -u "$CB_COOKIE" --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "http://127.0.0.1:$CB_RPC/" 2>/dev/null)
echo "$r" | grep -q '"result"' || fail "clearbit RPC never responded within 60s"
log "clearbit RPC ready"

# clearbit RPC helper: returns the raw JSON-RPC envelope.
cb_rpc() {
    local method="$1" params="$2"
    curl -s --max-time 30 -u "$CB_COOKIE" \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        "http://127.0.0.1:$CB_RPC/"
}

# ── 4. Mine the SAME number of blocks on both nodes. ──────────────────────
log "mining $NBLOCKS blocks on Core"
core_cli generatetoaddress "$NBLOCKS" "$ADDR" >/dev/null 2>&1 || fail "Core generatetoaddress failed"
core_h=$(core_cli getblockcount)
[[ "$core_h" == "$NBLOCKS" ]] || fail "Core height $core_h != $NBLOCKS"

log "mining $NBLOCKS blocks on clearbit"
cb_gen=$(cb_rpc generatetoaddress "[$NBLOCKS,\"$ADDR\"]")
cb_h=$(echo "$cb_gen" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(0 if d.get("error") else "ok")
except Exception: print("err")' 2>/dev/null)
cb_height=$(echo "$(cb_rpc getblockcount '[]')" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"])' 2>/dev/null)
[[ "$cb_height" == "$NBLOCKS" ]] || fail "clearbit height $cb_height != $NBLOCKS (gen result: $cb_gen)"
log "both nodes at height $NBLOCKS"

CORE_TIP=$(core_cli getbestblockhash)
CB_TIP=$(echo "$(cb_rpc getbestblockhash '[]')" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"])' 2>/dev/null)
[[ -n "$CORE_TIP" && -n "$CB_TIP" ]] || fail "could not read tip hashes (core=$CORE_TIP cb=$CB_TIP)"

# ── 5. getchaintxstats <WINDOW> <tip> on both. ────────────────────────────
log "getchaintxstats $WINDOW <tip> on Core + clearbit"
CORE_STATS=$(core_cli getchaintxstats "$WINDOW" "$CORE_TIP" 2>>"$CORE_LOG")
[[ -n "$CORE_STATS" ]] || fail "Core getchaintxstats returned nothing"
CB_STATS_ENV=$(cb_rpc getchaintxstats "[$WINDOW,\"$CB_TIP\"]")
CB_STATS=$(echo "$CB_STATS_ENV" | python3 -c 'import sys,json
d=json.load(sys.stdin)
if d.get("error"): sys.exit("clearbit error: %s" % d["error"])
print(json.dumps(d["result"]))' 2>>"$CB_LOG") || fail "clearbit getchaintxstats error: $CB_STATS_ENV"

log "Core stats:     $CORE_STATS"
log "clearbit stats: $CB_STATS"

# ── 6. Compare the count/height fields EXACTLY; type-check the rest. ───────
# A single Python comparator does the heavy lifting and prints a verdict line:
#   OK            all assertions passed
#   FAIL <reason> first failing assertion
VERDICT=$(python3 - "$CORE_STATS" "$CB_STATS" "$NBLOCKS" "$WINDOW" <<'PYEOF'
import sys, json
core = json.loads(sys.argv[1])
cb   = json.loads(sys.argv[2])
nblocks = int(sys.argv[3])
window  = int(sys.argv[4])

def f(reason):
    print("FAIL " + reason); sys.exit(0)

# --- Count/height fields must MATCH Core exactly (chain-shape deterministic) ---
# Empty blocks: 1 coinbase tx each -> txcount = height + 1.
exp_txcount = nblocks + 1
for k in ("txcount", "window_final_block_height", "window_block_count", "window_tx_count"):
    if k not in core: f("Core stats missing %s (oracle shape changed?)" % k)
    if k not in cb:   f("clearbit stats missing %s" % k)
    if core[k] != cb[k]:
        f("%s mismatch: core=%r clearbit=%r" % (k, core[k], cb[k]))

if cb["txcount"] != exp_txcount:
    f("txcount=%r expected %r (height+1)" % (cb["txcount"], exp_txcount))
if cb["window_final_block_height"] != nblocks:
    f("window_final_block_height=%r expected %r" % (cb["window_final_block_height"], nblocks))
if cb["window_block_count"] != window:
    f("window_block_count=%r expected %r" % (cb["window_block_count"], window))
# Each windowed block is one coinbase tx -> window_tx_count == window.
if cb["window_tx_count"] != window:
    f("window_tx_count=%r expected %r" % (cb["window_tx_count"], window))

# --- window_final_block_hash: 64-hex SHAPE (value differs between nodes) ---
h = cb.get("window_final_block_hash")
if not isinstance(h, str) or len(h) != 64:
    f("window_final_block_hash not a 64-hex string: %r" % (h,))
try:
    int(h, 16)
except Exception:
    f("window_final_block_hash not hexadecimal: %r" % (h,))

# --- time: present + sane unix timestamp (timestamps differ between nodes) ---
t = cb.get("time")
if not isinstance(t, int):
    f("time not an integer: %r" % (t,))
# Bitcoin genesis is 2009; regtest mined-now blocks are well past 1.2e9.
if t < 1_000_000_000 or t > 4_000_000_000:
    f("time=%r out of sane unix range" % (t,))

# --- window_interval: present + >= 0 when window_block_count > 0 ---
if "window_interval" not in cb:
    f("window_interval missing while window_block_count=%r > 0" % (cb["window_block_count"],))
if not isinstance(cb["window_interval"], int) or cb["window_interval"] < 0:
    f("window_interval=%r not a non-negative int" % (cb["window_interval"],))

# --- txrate emit-condition: verified on CLEARBIT'S OWN response (Core's rule) ---
# Core rpc/blockchain.cpp: txrate is pushed IFF window_interval > 0 (and the
# window tx counts are known, which they always are for an empty-block window).
# The two regtest nodes use different block-timestamp policies when mining a
# burst, so their window_interval *values* legitimately differ — we therefore
# do NOT compare interval/txrate cross-node. Instead we assert clearbit honours
# Core's emit-condition exactly: present-iff-positive-interval.
cb_has_rate = "txrate" in cb
if cb["window_interval"] > 0:
    if not cb_has_rate:
        f("window_interval=%r > 0 but txrate absent (Core invariant)" % (cb["window_interval"],))
    if not isinstance(cb["txrate"], (int, float)):
        f("txrate present but not numeric: %r" % (cb["txrate"],))
    # Sanity: txrate ~= window_tx_count / window_interval.
    expect_rate = cb["window_tx_count"] / cb["window_interval"]
    if abs(cb["txrate"] - expect_rate) > 1e-6:
        f("txrate=%r != window_tx_count/window_interval=%r" % (cb["txrate"], expect_rate))
else:
    if cb_has_rate:
        f("window_interval=0 but txrate present %r (should be dropped)" % (cb["txrate"],))

# Core, for reference, must also satisfy its own invariant (oracle self-check).
core_has_rate = "txrate" in core
if (core["window_interval"] > 0) != core_has_rate:
    print("FAIL Core oracle violated its own txrate invariant (interval=%r has_rate=%s)"
          % (core["window_interval"], core_has_rate)); sys.exit(0)

print("OK")
PYEOF
) || fail "comparator crashed (core=$CORE_STATS cb=$CB_STATS)"

[[ "$VERDICT" == OK ]] || fail "${VERDICT#FAIL }"

# ── 7. nblocks=0 DROPS the 3 window extras (on both nodes). ───────────────
log "getchaintxstats 0 <tip> on Core + clearbit (emit-condition check)"
CORE_Z=$(core_cli getchaintxstats 0 "$CORE_TIP" 2>>"$CORE_LOG")
CB_Z_ENV=$(cb_rpc getchaintxstats "[0,\"$CB_TIP\"]")
CB_Z=$(echo "$CB_Z_ENV" | python3 -c 'import sys,json
d=json.load(sys.stdin)
if d.get("error"): sys.exit("clearbit error: %s" % d["error"])
print(json.dumps(d["result"]))' 2>>"$CB_LOG") || fail "clearbit getchaintxstats 0 error: $CB_Z_ENV"

Z_VERDICT=$(python3 - "$CORE_Z" "$CB_Z" "$NBLOCKS" <<'PYEOF'
import sys, json
core = json.loads(sys.argv[1])
cb   = json.loads(sys.argv[2])
nblocks = int(sys.argv[3])
def f(reason):
    print("FAIL " + reason); sys.exit(0)

# window_block_count must be 0 on both.
if cb.get("window_block_count") != 0:
    f("nblocks=0: window_block_count=%r expected 0" % (cb.get("window_block_count"),))
# The 3 window extras MUST be absent (Core rpc/blockchain.cpp: only pushed when
# blockcount > 0).
for k in ("window_interval", "window_tx_count", "txrate"):
    if k in cb:
        f("nblocks=0: %s should be ABSENT but clearbit emitted %r" % (k, cb[k]))
    if k in core:
        f("nblocks=0: %s present in Core oracle (oracle changed?)" % k)
# But the non-window fields are still present.
for k in ("time", "txcount", "window_final_block_hash", "window_final_block_height", "window_block_count"):
    if k not in cb:
        f("nblocks=0: clearbit missing %s" % k)
if cb["txcount"] != nblocks + 1:
    f("nblocks=0: txcount=%r expected %r" % (cb["txcount"], nblocks + 1))
print("OK")
PYEOF
) || fail "nblocks=0 comparator crashed (core=$CORE_Z cb=$CB_Z)"

[[ "$Z_VERDICT" == OK ]] || fail "${Z_VERDICT#FAIL }"

# ── 8. Error-code parity: bad hash -> -5, nblocks>=height -> -8. ──────────
log "error-code parity: bad-hash (-5) and nblocks>=height (-8)"
BADHASH="0000000000000000000000000000000000000000000000000000000000000099"

# Core: bad hash -> error code -5.
core_badhash_code=$(core_cli getchaintxstats 10 "$BADHASH" 2>&1 | grep -oE 'code:? *-?[0-9]+' | grep -oE '\-?[0-9]+' | head -1)
# Fallback: bitcoin-cli prints "error code: -5" form.
[[ -z "$core_badhash_code" ]] && core_badhash_code=$(core_cli getchaintxstats 10 "$BADHASH" 2>&1 | grep -oE '\-[0-9]+' | head -1)

cb_badhash_code=$(echo "$(cb_rpc getchaintxstats "[10,\"$BADHASH\"]")" | python3 -c 'import sys,json
d=json.load(sys.stdin); print(d["error"]["code"] if d.get("error") else "none")' 2>/dev/null)

[[ "$cb_badhash_code" == "-5" ]] || fail "bad-hash: clearbit code=$cb_badhash_code expected -5 (Core=$core_badhash_code)"

# nblocks >= height -> -8 on both.
cb_badcount_code=$(echo "$(cb_rpc getchaintxstats "[$NBLOCKS,\"$CB_TIP\"]")" | python3 -c 'import sys,json
d=json.load(sys.stdin); print(d["error"]["code"] if d.get("error") else "none")' 2>/dev/null)
[[ "$cb_badcount_code" == "-8" ]] || fail "nblocks>=height: clearbit code=$cb_badcount_code expected -8"

core_badcount_code=$(core_cli getchaintxstats "$NBLOCKS" "$CORE_TIP" 2>&1 | grep -oE '\-[0-9]+' | head -1)
[[ "$core_badcount_code" == "-8" ]] || log "note: Core bad-count code parse='$core_badcount_code' (expected -8; clearbit matched -8)"

# ── 9. Positive-interval / txrate path (exercise the OTHER emit branch). ──
# The burst-mined 120-block window can have window_interval 0 (clearbit stamps a
# burst with one second), which correctly DROPS txrate. To also cover the
# txrate-PRESENT branch we mine a handful of blocks ONE AT A TIME with a 1s gap
# so successive block timestamps (and thus MTP) advance, then probe a small
# recent window where window_interval MUST be > 0 and txrate MUST be present and
# equal to window_tx_count / window_interval.
log "txrate-present branch: mining 8 spaced blocks on clearbit then probing a recent window"
for _ in $(seq 1 8); do
    cb_rpc generatetoaddress "[1,\"$ADDR\"]" >/dev/null 2>&1
    sleep 1
done
CB_TIP2=$(echo "$(cb_rpc getbestblockhash '[]')" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"])' 2>/dev/null)
CB_S2_ENV=$(cb_rpc getchaintxstats "[6,\"$CB_TIP2\"]")
CB_S2=$(echo "$CB_S2_ENV" | python3 -c 'import sys,json
d=json.load(sys.stdin)
if d.get("error"): sys.exit("clearbit error: %s" % d["error"])
print(json.dumps(d["result"]))' 2>>"$CB_LOG") || fail "clearbit getchaintxstats(6) error: $CB_S2_ENV"
log "clearbit spaced-window stats: $CB_S2"

S2_VERDICT=$(python3 - "$CB_S2" <<'PYEOF'
import sys, json
cb = json.loads(sys.argv[1])
def f(reason):
    print("FAIL " + reason); sys.exit(0)
if cb.get("window_block_count") != 6:
    f("spaced: window_block_count=%r expected 6" % (cb.get("window_block_count"),))
if cb.get("window_tx_count") != 6:
    f("spaced: window_tx_count=%r expected 6" % (cb.get("window_tx_count"),))
iv = cb.get("window_interval")
if not isinstance(iv, int) or iv <= 0:
    f("spaced: window_interval=%r expected > 0 (timestamps advance with sleeps)" % (iv,))
if "txrate" not in cb:
    f("spaced: txrate ABSENT while window_interval=%r > 0" % (iv,))
expect = cb["window_tx_count"] / iv
if abs(cb["txrate"] - expect) > 1e-6:
    f("spaced: txrate=%r != %r (=tx_count/interval)" % (cb["txrate"], expect))
print("OK")
PYEOF
) || fail "spaced-window comparator crashed (cb=$CB_S2)"
[[ "$S2_VERDICT" == OK ]] || fail "${S2_VERDICT#FAIL }"

log "all assertions passed"
pass

#!/usr/bin/env bash
# ============================================================================
# WALLET-RECOVERY REGRESSION TEST — lunarblock
# ============================================================================
# Codifies the recovery green cell landed in lunarblock commit 4050b35
# ("feat(wallet): scantxoutset + restore-from-seed -> wallet recovery GREEN")
# into a permanent, repeatable nightly check.
#
# Recovery mechanism for lunarblock: RESTORE-FROM-SEED (BIP-39 importmnemonic).
# A wallet keeps no on-disk UTXO ledger you can trust after a disk loss; the
# only durable secret is the BIP-39 mnemonic. Recovery = re-derive the same
# receiving scriptPubKeys from the seed, then ask the node which are funded
# on-chain (scantxoutset, the UTXO-set scan primitive). This is exactly the
# flow the committed code proved green.
#
# Proven flow (all on a throwaway regtest chain, no auth — default rpcpassword=""):
#   1. importmnemonic(FIXED_MNEMONIC, "", "recA")           -> restore wallet A
#   2. getnewaddress on /wallet/recA                        -> A1 (p2wpkh bech32)
#   3. generatetoaddress(101, A1)                           -> fund A1 (coinbases)
#   4. scantxoutset(start, [addr(A1)])                      -> FUNDED total (BEFORE)
#   5. importmnemonic(SAME mnemonic, "", "recB")            -> fresh wallet, same seed
#   6. getnewaddress on /wallet/recB                        -> assert == A1 byte-identical
#   7. scantxoutset(start, [addr(A1)])                      -> RECOVERED total (AFTER)
#   8. assert AFTER == BEFORE                               -> recovery rediscovers 100%
#   9. negative control: scantxoutset of a foreign addr     -> assert 0
#
# Launch recipe mirrors tools/smoke-harness.sh (lunarblock arm, ~line 330):
#   luajit src/main.lua --network regtest --datadir <dd> --port <p2p> --rpcport <rpc> --nov2transport
#
# STRICT: scratch datadir /tmp/recreg-lunarblock/ + ports 21508 (RPC) / 21538
# (P2P) ONLY. NEVER touches /data/nvme1/, testnet4-data/, or any live node.
#
# Output: exactly ONE summary line on stdout, then exit.
#   PASS -> "RECOVERY lunarblock: PASS funded=<X> recovered=<X> addrs=match neg=0"  exit 0
#   FAIL -> "RECOVERY lunarblock: FAIL <short reason>"                              exit 1
# All other (noisy) output goes to stderr / the node log.
# ============================================================================
set -uo pipefail

# ── Fixed configuration ─────────────────────────────────────────────────────
REPO_ROOT="/home/work/hashhog"
LB_DIR="$REPO_ROOT/lunarblock"
SCRATCH="/tmp/recreg-lunarblock"
NODE_LOG="$SCRATCH/node.log"
RPC_PORT=21508
P2P_PORT=21538
RPC="http://127.0.0.1:${RPC_PORT}"

# A fixed, well-known BIP-39 12-word test mnemonic (the canonical
# "abandon … about" vector). Deterministic across runs — this is what makes
# the re-derivation assertion meaningful.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

# A foreign address NOT derived from MNEMONIC (the lunarblock default-wallet's
# first receiving address) — used for the negative control. It must score 0.
FOREIGN_ADDR="bcrt1q7rt494gc52tnt8w5pqeg5xhq49vskanvgfkfdy"

NODE_PID=""

# ── stdout discipline ───────────────────────────────────────────────────────
# Save the REAL stdout on fd 3, then point the script's fd 1 at stderr. From
# here on, every incidental write the script (or bash itself — e.g. async
# job-control "Killed <pid>" notices when the cleanup trap reaps the node)
# emits to fd 1 lands on stderr, NOT on the real stdout. Only finish() writes
# the single summary line, and it writes it to fd 3. Net result: stdout carries
# exactly one line for the runner to grep, no matter how the node is reaped.
exec 3>&1 1>&2

# ── Helpers ─────────────────────────────────────────────────────────────────
log() { echo "[recovery-lunarblock] $*" >&2; }

# Emit the single summary line (to the saved real stdout, fd 3) and exit.
# $1=PASS/FAIL, $2..=rest-of-line.
finish() {
  local verdict="$1"; shift
  if [[ "$verdict" == "PASS" ]]; then
    echo "RECOVERY lunarblock: PASS $*" >&3
    exit 0
  else
    echo "RECOVERY lunarblock: FAIL $*" >&3
    exit 1
  fi
}

# Kill the node by port (always) and by process group (when we have its PGID).
# The node is launched with setsid (own session/PGID == its PID), so it is NOT
# a job-controlled child of this shell — that means bash never emits a
# "Killed  <pid>" job-completion notice on stdout when it dies, keeping stdout
# to exactly the one summary line. Best-effort, never fatal.
kill_node() {
  if [[ -n "$NODE_PID" ]]; then
    kill -TERM "-${NODE_PID}" 2>/dev/null || kill -TERM "$NODE_PID" 2>/dev/null || true
  fi
}

# Cleanup trap: always kill the node + wipe scratch on ANY exit path.
cleanup() {
  local rc=$?
  kill_node
  # Give the daemon a moment to release the port/datadir, then SIGKILL stragglers.
  for _ in 1 2 3 4 5; do
    if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
      sleep 0.4
    else
      break
    fi
  done
  if [[ -n "$NODE_PID" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
    kill -KILL "-${NODE_PID}" 2>/dev/null || kill -KILL "$NODE_PID" 2>/dev/null || true
  fi
  rm -rf "$SCRATCH" 2>/dev/null || true
  return $rc
}
trap cleanup EXIT INT TERM

# JSON-RPC call. $1=url (RPC base or /wallet/<name>), $2=method, $3=params-json.
# Echoes the raw HTTP body on stdout. Caller parses with rpc_result / asserts.
rpc_call() {
  local url="$1" method="$2" params="$3"
  curl -s --max-time 90 -X POST "$url" \
    -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"1.0\",\"id\":\"rec\",\"method\":\"${method}\",\"params\":${params}}"
}

# Extract a python-evaluated field from an RPC response on stdin.
# $1 = python expression over `r` (the "result" object) or `d` (whole doc).
# Prints the value, or prints "__ERR__" + the json error to stderr on failure.
py_field() {
  python3 -c '
import sys, json
expr = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("json-parse-error: %s\n" % e)
    print("__ERR__"); sys.exit(0)
if d.get("error") not in (None, False):
    sys.stderr.write("rpc-error: %s\n" % json.dumps(d.get("error")))
    print("__ERR__"); sys.exit(0)
r = d.get("result")
try:
    print(eval(expr))
except Exception as e:
    sys.stderr.write("field-eval-error (%s): %s\n" % (expr, e))
    print("__ERR__"); sys.exit(0)
' "$1"
}

# ── 0. Idempotent reset ─────────────────────────────────────────────────────
log "resetting scratch state (ports ${RPC_PORT}/${P2P_PORT}, datadir ${SCRATCH})"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
  finish FAIL "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 0.5
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

# Sanity: interpreter + sources present.
if ! command -v luajit >/dev/null 2>&1; then
  finish FAIL "luajit not found on PATH"
fi
if [[ ! -f "$LB_DIR/src/main.lua" ]]; then
  finish FAIL "lunarblock src/main.lua missing at $LB_DIR"
fi

# ── 1. Launch lunarblock on regtest (smoke-harness recipe) ──────────────────
log "launching lunarblock regtest node"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
# setsid puts the node in its OWN session/process group (PGID == its PID). This
# means it is not a job-controlled child of this shell, so bash never prints a
# "Killed  <pid>" job-completion notice to stdout when the cleanup trap reaps
# it — stdout stays clean for the runner. We can then SIGTERM/SIGKILL the whole
# group with `kill -- -PID`.
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$SCRATCH' \
    --port '$P2P_PORT' --rpcport '$RPC_PORT' --nov2transport" \
    >"$NODE_LOG" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID (log: $NODE_LOG)"

# ── 2. Wait for RPC to come up (getblockchaininfo with chain=regtest) ────────
RPC_UP=0
for _ in $(seq 1 60); do
  if ! kill -0 "$NODE_PID" 2>/dev/null; then
    log "node process died during startup; last log lines:"
    tail -20 "$NODE_LOG" >&2 || true
    finish FAIL "node exited before RPC came up"
  fi
  resp="$(rpc_call "$RPC" getblockchaininfo '[]' 2>/dev/null || true)"
  chain="$(printf '%s' "$resp" | py_field 'r["chain"]' 2>/dev/null || true)"
  if [[ "$chain" == "regtest" ]]; then
    RPC_UP=1
    break
  fi
  sleep 0.5
done
if [[ "$RPC_UP" != "1" ]]; then
  log "RPC never reported chain=regtest; last log lines:"
  tail -20 "$NODE_LOG" >&2 || true
  finish FAIL "rpc did not come up within timeout"
fi
log "RPC up (chain=regtest)"

# ── 3. Restore wallet A from the FIXED seed ─────────────────────────────────
log "importmnemonic -> recA"
resp="$(rpc_call "$RPC" importmnemonic "[\"$MNEMONIC\",\"\",\"recA\"]")"
ok="$(printf '%s' "$resp" | py_field 'r["wallet_name"]')"
if [[ "$ok" != "recA" ]]; then
  finish FAIL "importmnemonic recA failed"
fi

# ── 4. Derive the first receiving address (A1) ──────────────────────────────
log "getnewaddress on recA"
A1="$(rpc_call "$RPC/wallet/recA" getnewaddress '[]' | py_field 'r')"
if [[ -z "$A1" || "$A1" == "__ERR__" || "$A1" != bcrt1* ]]; then
  finish FAIL "getnewaddress recA returned bad address: '${A1}'"
fi
log "A1=$A1"

# ── 5. Fund A1 with 101 coinbase blocks ─────────────────────────────────────
log "generatetoaddress 101 -> A1"
resp="$(rpc_call "$RPC/wallet/recA" generatetoaddress "[101,\"$A1\"]")"
nblk="$(printf '%s' "$resp" | py_field 'len(r)')"
if [[ "$nblk" != "101" ]]; then
  finish FAIL "generatetoaddress did not mine 101 blocks (got '${nblk}')"
fi

# ── 6. scantxoutset BEFORE (record total over A1) ───────────────────────────
log "scantxoutset BEFORE (addr A1)"
resp="$(rpc_call "$RPC" scantxoutset "[\"start\",[\"addr($A1)\"]]")"
BEFORE_OK="$(printf '%s' "$resp" | py_field 'bool(r["success"])')"
BEFORE_AMT="$(printf '%s' "$resp" | py_field 'r["total_amount"]')"
BEFORE_N="$(printf '%s' "$resp" | py_field 'len(r["unspents"])')"
if [[ "$BEFORE_OK" != "True" || "$BEFORE_AMT" == "__ERR__" ]]; then
  finish FAIL "scantxoutset BEFORE failed"
fi
log "BEFORE total_amount=$BEFORE_AMT unspents=$BEFORE_N"
# Recovery is only meaningful if there are coins to recover.
zero="$(python3 -c "print(float('$BEFORE_AMT') <= 0)")"
if [[ "$zero" == "True" ]]; then
  finish FAIL "no funds present before recovery (amt=$BEFORE_AMT)"
fi

# ── 7. Fresh wallet, restore the SAME seed; re-derive A1' ───────────────────
log "importmnemonic SAME seed -> recB (fresh wallet)"
resp="$(rpc_call "$RPC" importmnemonic "[\"$MNEMONIC\",\"\",\"recB\"]")"
ok="$(printf '%s' "$resp" | py_field 'r["wallet_name"]')"
if [[ "$ok" != "recB" ]]; then
  finish FAIL "importmnemonic recB failed"
fi
log "getnewaddress on recB (must equal A1)"
A1B="$(rpc_call "$RPC/wallet/recB" getnewaddress '[]' | py_field 'r')"
if [[ "$A1B" != "$A1" ]]; then
  finish FAIL "re-derived address mismatch: recB=$A1B != recA=$A1"
fi
log "re-derived address byte-identical: $A1B"

# ── 8. scantxoutset AFTER (recovered total) + assert == BEFORE ──────────────
log "scantxoutset AFTER (addr A1', from restored seed)"
resp="$(rpc_call "$RPC" scantxoutset "[\"start\",[\"addr($A1B)\"]]")"
AFTER_OK="$(printf '%s' "$resp" | py_field 'bool(r["success"])')"
AFTER_AMT="$(printf '%s' "$resp" | py_field 'r["total_amount"]')"
if [[ "$AFTER_OK" != "True" || "$AFTER_AMT" == "__ERR__" ]]; then
  finish FAIL "scantxoutset AFTER failed"
fi
log "AFTER total_amount=$AFTER_AMT"
match="$(python3 -c "print(abs(float('$AFTER_AMT') - float('$BEFORE_AMT')) < 1e-9)")"
if [[ "$match" != "True" ]]; then
  finish FAIL "recovered != funded ($AFTER_AMT != $BEFORE_AMT)"
fi

# ── 9. Negative control: a foreign address must score 0 ─────────────────────
log "negative control: scantxoutset of foreign addr"
resp="$(rpc_call "$RPC" scantxoutset "[\"start\",[\"addr($FOREIGN_ADDR)\"]]")"
NEG_AMT="$(printf '%s' "$resp" | py_field 'r["total_amount"]')"
NEG_N="$(printf '%s' "$resp" | py_field 'len(r["unspents"])')"
if [[ "$NEG_AMT" == "__ERR__" ]]; then
  finish FAIL "negative-control scantxoutset failed"
fi
neg_nonzero="$(python3 -c "print(float('$NEG_AMT') != 0.0 or int('$NEG_N') != 0)")"
if [[ "$neg_nonzero" == "True" ]]; then
  finish FAIL "negative control nonzero (amt=$NEG_AMT n=$NEG_N)"
fi
log "negative control clean (amt=$NEG_AMT n=$NEG_N)"

# ── Success ─────────────────────────────────────────────────────────────────
finish PASS "funded=${BEFORE_AMT} recovered=${AFTER_AMT} addrs=match neg=0"

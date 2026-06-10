#!/usr/bin/env bash
# ============================================================================
# WALLET IMPORT + RESCAN REGRESSION TEST — lunarblock
# ============================================================================
# Codifies the IMPORT+RESCAN wallet-completeness cell for lunarblock — the 10th
# (last) impl of this axis. The successor to recovery / spend / history. Proves,
# on a throwaway regtest chain, using ONLY wallet-native RPCs, the two wallet
# capabilities that complete the axis:
#
#   A. RESCAN (REQUIRED for green) — a REAL wallet rescan that scans EXISTING
#      chain blocks for outputs paying wallet-owned scripts and credits them into
#      the wallet's OWN UTXO ledger (the BACKWARD counterpart of the
#      block-connect scan), NOT the chain-level scantxoutset (which bypasses the
#      wallet). Headline proof:
#        - W1: importmnemonic <FIXED mnemonic> -> getnewaddress A1
#              -> generatetoaddress 101 A1 -> record W1's mature balance M.
#        - W2: FRESH wallet restored from the SAME mnemonic. Re-derive A1'
#              (assert == A1: restore is deterministic) and assert
#              W2.getbalance == 0 (restore derives keys but does NOT scan).
#        - rescanblockchain on W2 -> Core shape {start_height, stop_height} ->
#              W2.getbalance == M and W2.listunspent shows A1's UTXOs. The wallet
#              REDISCOVERED its funds via a wallet rescan.
#
#   B. IMPORTPRIVKEY (TARGET; partial/absent acceptable) — decode a FOREIGN WIF,
#      register the key's standard scripts as imported (held apart from the HD
#      keychain), and (rescan=true) rescan to credit that key's funds:
#        - W3: a SECOND wallet from a DIFFERENT mnemonic -> getnewaddress A_ext.
#              dumpprivkey(A_ext) on W3 = WIF_ext (A_ext is foreign to W2).
#        - generatetoaddress 101 A_ext  (fund the foreign key)
#        - importprivkey(WIF_ext, "ext", rescan=true) into W2 -> W2 adopts
#              A_ext's matured funds (balance grows; A_ext UTXO in listunspent).
#
# Shapes/semantics mirror bitcoin-core/src/wallet/rpc/transactions.cpp
# (rescanblockchain -> CWallet::ScanForWalletTransactions; returns
# {start_height, stop_height}) and wallet/rpc/backup.cpp (importprivkey decodes a
# WIF + rescans; dumpprivkey -> EncodeSecret).
#
# Launch recipe mirrors tools/smoke-harness.sh (lunarblock arm) and
# recovery/spend/history cells:
#   luajit src/main.lua --network regtest --datadir <dd> --port <p2p> \
#       --rpcport <rpc> --nov2transport
#
# STRICT UNIFORM INTERFACE (mirrors import/rustoshi_import.sh + spend/
# lunarblock_spend.sh): no required args, set -uo pipefail, idempotent, trap
# cleanup with the saved-fd / stdout discipline lunarblock_spend.sh uses,
# scratch datadir + unique ports, single clean summary line on stdout. All noise
# -> stderr / node log.
#
# Output: exactly ONE summary line on stdout, then exit.
#   PASS -> "IMPORT lunarblock: PASS rescan=ok importprivkey=<ok|partial|absent> rediscovered=<M>"  exit 0
#   FAIL -> "IMPORT lunarblock: FAIL <short reason>"                                                exit 1
# Green REQUIRES rescan=ok.
#
# Touches ONLY /tmp/importfleet-lunarblock/ and ports 21719 (RPC) / 21739 (P2P).
# NEVER touches /data/nvme1/, testnet4-data/, or any live node.
# ============================================================================
set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── Fixed configuration ─────────────────────────────────────────────────────
REPO_ROOT="${HASHHOG_ROOT}"
LB_DIR="$REPO_ROOT/lunarblock"
SCRATCH="/tmp/importfleet-lunarblock"
NODE_LOG="$SCRATCH/node.log"
RPC_PORT=21719
P2P_PORT=21739
RPC="http://127.0.0.1:${RPC_PORT}"

# The canonical "abandon … about" BIP-39 test mnemonic — deterministic across
# runs, same vector recovery/spend/history cells use. W1 + W2 share it.
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
# A DIFFERENT fixed mnemonic for the FOREIGN wallet (W3) whose key we import.
FOREIGN_MNEMONIC="legal winner thank year wave sausage worth useful legal winner thank yellow"

# Coinbase maturity is 100 (spendable at COINBASE_MATURITY+1 = 101 confs). The
# foreign key (A_ext) is funded FIRST with a small batch, then W1 is funded with
# 101 — so at the final tip BOTH A_ext's earliest coinbases and A1's height-1
# coinbase are mature, while the tip stays below the regtest 150-block subsidy
# halving boundary (avoids a node-side miner-template/connect-block subsidy
# divergence at the halving that is orthogonal to this wallet axis).
NBLOCKS=101
NBLOCKS_FOREIGN=20
NODE_PID=""

# ── stdout discipline (mirrors recovery/spend cells) ─────────────────────────
# Save the REAL stdout on fd 3, then point fd 1 at stderr. Only finish() writes
# the single summary line, and it writes to fd 3 — so stdout carries exactly one
# line no matter how the node is reaped.
exec 3>&1 1>&2

log() { echo "[import-lunarblock] $*" >&2; }

finish() {
  local verdict="$1"; shift
  if [[ "$verdict" == "PASS" ]]; then
    echo "IMPORT lunarblock: PASS $*" >&3
    exit 0
  else
    echo "IMPORT lunarblock: FAIL $*" >&3
    exit 1
  fi
}

kill_node() {
  if [[ -n "$NODE_PID" ]]; then
    kill -TERM "-${NODE_PID}" 2>/dev/null || kill -TERM "$NODE_PID" 2>/dev/null || true
  fi
}

cleanup() {
  local rc=$?
  kill_node
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
rpc_call() {
  local url="$1" method="$2" params="$3"
  curl -s --max-time 120 -X POST "$url" \
    -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"1.0\",\"id\":\"import\",\"method\":\"${method}\",\"params\":${params}}"
}

# Extract a python-evaluated field from an RPC response on stdin.
# $1 = python expr over `r` (the "result") or `d` (whole doc). Prints the value,
# or "__ERR__" + json error to stderr on failure.
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

# Float comparison helper. $1 op $2 (op in: lt le gt ge eq) within 1e-6.
fcmp() {
  python3 -c "
import sys
a,op,b=float('$1'),'$2',float('$3')
eps=1e-6
res={'lt':a<b-eps,'le':a<=b+eps,'gt':a>b+eps,'ge':a>=b-eps,'eq':abs(a-b)<eps}[op]
print('True' if res else 'False')"
}

# ── 0. Idempotent reset ─────────────────────────────────────────────────────
log "resetting scratch state (ports ${RPC_PORT}/${P2P_PORT}, datadir ${SCRATCH})"
if ss -tln 2>/dev/null | grep -qE ":(${RPC_PORT}|${P2P_PORT}) "; then
  finish FAIL "port ${RPC_PORT}/${P2P_PORT} already LISTENING — refusing to kill it (fuser-on-port killed mainnet nodes, 2026-06-10 fuser incident)"
fi
sleep 0.5
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

if ! command -v luajit >/dev/null 2>&1; then
  finish FAIL "luajit not found on PATH"
fi
if [[ ! -f "$LB_DIR/src/main.lua" ]]; then
  finish FAIL "lunarblock src/main.lua missing at $LB_DIR"
fi

# ── 1. Launch lunarblock on regtest (smoke-harness recipe) ──────────────────
log "launching lunarblock regtest node"
export LUA_PATH="$LB_DIR/src/?.lua;$LB_DIR/src/?/init.lua;;"
setsid bash -c "cd '$LB_DIR' && exec luajit src/main.lua \
    --network regtest --datadir '$SCRATCH' \
    --port '$P2P_PORT' --rpcport '$RPC_PORT' --nov2transport" \
    >"$NODE_LOG" 2>&1 &
NODE_PID=$!
log "node pid=$NODE_PID (log: $NODE_LOG)"

# ── 2. Wait for RPC (getblockchaininfo chain=regtest) ───────────────────────
RPC_UP=0
for _ in $(seq 1 60); do
  if ! kill -0 "$NODE_PID" 2>/dev/null; then
    log "node died during startup; last log lines:"; tail -20 "$NODE_LOG" >&2 || true
    finish FAIL "node exited before RPC came up"
  fi
  resp="$(rpc_call "$RPC" getblockchaininfo '[]' 2>/dev/null || true)"
  chain="$(printf '%s' "$resp" | py_field 'r["chain"]' 2>/dev/null || true)"
  if [[ "$chain" == "regtest" ]]; then RPC_UP=1; break; fi
  sleep 0.5
done
if [[ "$RPC_UP" != "1" ]]; then
  log "RPC never reported chain=regtest; last log lines:"; tail -20 "$NODE_LOG" >&2 || true
  finish FAIL "rpc did not come up within timeout"
fi
log "RPC up (chain=regtest)"

# ── 3a. FOREIGN key first: derive A_ext + fund it (kept under height 150). ──
# Done BEFORE W1 so both A_ext's and A1's coinbases mature at a tip < 150. A_ext
# / WIF_ext are captured here and reused by import_attempt below.
AEXT=""
WIF_EXT=""
log "importmnemonic FOREIGN seed -> w3"
resp="$(rpc_call "$RPC" importmnemonic "[\"$FOREIGN_MNEMONIC\",\"\",\"w3\"]")"
ok="$(printf '%s' "$resp" | py_field 'r["wallet_name"]')"
if [[ "$ok" == "w3" ]]; then
  AEXT="$(rpc_call "$RPC/wallet/w3" getnewaddress '[]' | py_field 'r')"
  if [[ -n "$AEXT" && "$AEXT" != "__ERR__" && "$AEXT" == bcrt1* ]]; then
    WIF_EXT="$(rpc_call "$RPC/wallet/w3" dumpprivkey "[\"$AEXT\"]" | py_field 'r')"
    log "A_ext=$AEXT (foreign, NOT in w2)"
    resp="$(rpc_call "$RPC/wallet/w3" generatetoaddress "[$NBLOCKS_FOREIGN,\"$AEXT\"]")"
    fblk="$(printf '%s' "$resp" | py_field 'len(r)')"
    if [[ "$fblk" != "$NBLOCKS_FOREIGN" ]]; then
      log "WARN: foreign pre-funding mined '$fblk' != $NBLOCKS_FOREIGN; importprivkey will degrade"
      AEXT=""
    fi
  else
    log "WARN: getnewaddress w3 bad ('$AEXT'); importprivkey will be absent/partial"
    AEXT=""
  fi
else
  log "WARN: importmnemonic w3 failed; importprivkey will be absent/partial"
fi

# ── 3b. W1: restore the FIXED mnemonic, derive A1, fund + mature M. ─────────
log "importmnemonic -> w1"
resp="$(rpc_call "$RPC" importmnemonic "[\"$MNEMONIC\",\"\",\"w1\"]")"
ok="$(printf '%s' "$resp" | py_field 'r["wallet_name"]')"
if [[ "$ok" != "w1" ]]; then finish FAIL "importmnemonic w1 failed"; fi

A1="$(rpc_call "$RPC/wallet/w1" getnewaddress '[]' | py_field 'r')"
if [[ -z "$A1" || "$A1" == "__ERR__" || "$A1" != bcrt1* ]]; then
  finish FAIL "getnewaddress w1 bad addr: '${A1}'"
fi
log "A1=$A1"

log "generatetoaddress $NBLOCKS -> A1 (fund + mature)"
resp="$(rpc_call "$RPC/wallet/w1" generatetoaddress "[$NBLOCKS,\"$A1\"]")"
nblk="$(printf '%s' "$resp" | py_field 'len(r)')"
if [[ "$nblk" != "$NBLOCKS" ]]; then finish FAIL "generatetoaddress did not mine $NBLOCKS (got '${nblk}')"; fi

HEIGHT="$(rpc_call "$RPC" getblockcount '[]' | py_field 'r')"
if [[ "$HEIGHT" == "__ERR__" || "${HEIGHT:-0}" -lt "$NBLOCKS" ]]; then
  finish FAIL "height did not advance (got '${HEIGHT}')"
fi
log "height=$HEIGHT (tip)"

# W1's mature balance M (the amount W2 must rediscover via rescan).
M="$(rpc_call "$RPC/wallet/w1" getbalance '[]' | py_field 'r')"
if [[ "$M" == "__ERR__" ]]; then finish FAIL "getbalance w1 crashed"; fi
if [[ "$(fcmp "$M" gt 0)" != "True" ]]; then finish FAIL "w1 mature balance not positive ($M)"; fi
log "w1 mature balance M=$M"

# ── 4. W2: FRESH wallet, SAME mnemonic -> re-derive A1' (== A1), balance 0. ──
log "importmnemonic SAME seed -> w2 (fresh wallet)"
resp="$(rpc_call "$RPC" importmnemonic "[\"$MNEMONIC\",\"\",\"w2\"]")"
ok="$(printf '%s' "$resp" | py_field 'r["wallet_name"]')"
if [[ "$ok" != "w2" ]]; then finish FAIL "importmnemonic w2 failed"; fi

A1B="$(rpc_call "$RPC/wallet/w2" getnewaddress '[]' | py_field 'r')"
if [[ "$A1B" != "$A1" ]]; then
  finish FAIL "w2 re-derived address mismatch: $A1B != $A1 (restore not deterministic)"
fi
log "w2 re-derived A1' == A1 (deterministic restore)"

# CORE PROOF: w2 balance is 0 BEFORE rescan (restore derives keys, no scan).
BAL_PRE="$(rpc_call "$RPC/wallet/w2" getbalance '[]' | py_field 'r')"
if [[ "$BAL_PRE" == "__ERR__" ]]; then finish FAIL "w2 getbalance (pre-rescan) crashed"; fi
if [[ "$(fcmp "$BAL_PRE" eq 0)" != "True" ]]; then
  finish FAIL "w2 balance NOT 0 before rescan (got $BAL_PRE) — restore must not scan the chain"
fi
log "w2 balance before rescan = $BAL_PRE (0, as expected)"

# ── 5. rescanblockchain on w2 -> rediscovers M via a REAL wallet rescan. ────
log "rescanblockchain (w2)"
RB="$(rpc_call "$RPC/wallet/w2" rescanblockchain '[]')"
if printf '%s' "$RB" | grep -qi 'method not found'; then
  finish FAIL "rescanblockchain RPC missing (this cell requires it)"
fi
RB_CHECK="$(printf '%s' "$RB" | HEIGHT="$HEIGHT" python3 -c '
import os, sys, json
d = json.load(sys.stdin)
if d.get("error") not in (None, False):
    print("ERR:rescanblockchain error: %s" % json.dumps(d.get("error"))); sys.exit(0)
r = d.get("result")
if not isinstance(r, dict):
    print("ERR:result not an object: %s" % r); sys.exit(0)
if "start_height" not in r or "stop_height" not in r:
    print("ERR:missing start_height/stop_height (Core shape)"); sys.exit(0)
try:
    sh=int(r["start_height"]); st=int(r["stop_height"])
except Exception:
    print("ERR:start/stop_height not integers"); sys.exit(0)
if sh != 0:
    print("ERR:default start_height %s != 0" % sh); sys.exit(0)
tip=int(os.environ["HEIGHT"])
if st != tip:
    print("ERR:default stop_height %s != tip %s" % (st, tip)); sys.exit(0)
print("ok")
')"
case "$RB_CHECK" in
  ok) ;;
  ERR:*) finish FAIL "rescanblockchain shape: ${RB_CHECK#ERR:}";;
  *) finish FAIL "rescanblockchain produced no verdict";;
esac
log "rescanblockchain returned Core shape {start_height:0, stop_height:$HEIGHT}"

# w2 balance now equals M (rediscovered via a REAL wallet rescan).
BAL_POST="$(rpc_call "$RPC/wallet/w2" getbalance '[]' | py_field 'r')"
if [[ "$BAL_POST" == "__ERR__" ]]; then finish FAIL "w2 getbalance (post-rescan) crashed"; fi
if [[ "$(fcmp "$BAL_POST" eq "$M")" != "True" ]]; then
  finish FAIL "w2 balance after rescan ($BAL_POST) != w1 mature M ($M)"
fi
log "w2 balance after rescan = $BAL_POST == M (funds rediscovered via wallet rescan)"

# listunspent shows A1's UTXOs (real wallet ledger entries, not scantxoutset).
LU="$(rpc_call "$RPC/wallet/w2" listunspent '[1]')"
LU_CHECK="$(printf '%s' "$LU" | A1="$A1" python3 -c '
import os, sys, json
d = json.load(sys.stdin)
if d.get("error") not in (None, False):
    print("ERR:listunspent error: %s" % json.dumps(d.get("error"))); sys.exit(0)
arr = d.get("result") or []
if not arr:
    print("ERR:listunspent empty after rescan"); sys.exit(0)
a1=os.environ["A1"]
mine=[u for u in arr if u.get("address")==a1]
if not mine:
    print("ERR:no UTXO at A1 in listunspent (n=%d)" % len(arr)); sys.exit(0)
if sum(float(u.get("amount",0)) for u in mine) <= 0:
    print("ERR:A1 UTXOs sum to zero"); sys.exit(0)
print("ok n_a1=%d n_total=%d" % (len(mine), len(arr)))
')"
case "$LU_CHECK" in
  ok*) ;;
  ERR:*) finish FAIL "listunspent A1 check: ${LU_CHECK#ERR:}";;
  *) finish FAIL "listunspent produced no verdict";;
esac
log "w2 listunspent: $LU_CHECK"

# ── 6. IMPORTPRIVKEY (target): adopt a FOREIGN key's funds into w2. ─────────
# Best-effort: rescan is already proven green above, so any failure here only
# downgrades importprivkey=<state> — it never fails the cell.
IMPORT_STATE="absent"
REDISCOVERED="$BAL_POST"

import_attempt() {
  # A_ext + WIF_EXT were derived + funded up front (section 3a), kept under the
  # regtest height-150 halving boundary. If that pre-funding failed, degrade.
  if [[ -z "$AEXT" || -z "$WIF_EXT" || "$WIF_EXT" == "__ERR__" ]]; then
    log "foreign key not available (pre-funding failed) -> importprivkey partial"
    IMPORT_STATE="partial"; return 1
  fi
  if [[ "$AEXT" == "$A1" ]]; then log "A_ext collided with A1"; IMPORT_STATE="partial"; return 1; fi

  # w2 (HD keys + already scanned) must NOT see the foreign A_ext funds yet.
  local W2_PRE
  W2_PRE="$(rpc_call "$RPC/wallet/w2" getbalance '[]' | py_field 'r')"
  log "w2 balance pre-import (HD keys only) = $W2_PRE"

  # importprivkey the foreign key into w2 with rescan=true.
  local IRESP
  IRESP="$(rpc_call "$RPC/wallet/w2" importprivkey "[\"$WIF_EXT\",\"ext\",true]")"
  if printf '%s' "$IRESP" | grep -qi 'method not found'; then
    log "importprivkey absent"; IMPORT_STATE="absent"; return 1
  fi
  if [[ "$(printf '%s' "$IRESP" | py_field 'd.get("error")')" != "None" ]]; then
    log "importprivkey errored: $(printf '%s' "$IRESP" | py_field 'd.get("error")')"
    IMPORT_STATE="partial"; return 1
  fi

  local W2_POST
  W2_POST="$(rpc_call "$RPC/wallet/w2" getbalance '[]' | py_field 'r')"
  log "w2 balance post-import = $W2_POST"

  # Adoption proof: balance grew (foreign mature funds now spendable by w2).
  if [[ "$(fcmp "$W2_POST" gt "$W2_PRE")" != "True" ]]; then
    log "importprivkey did not grow w2 balance ($W2_PRE -> $W2_POST)"
    IMPORT_STATE="partial"; return 1
  fi

  # And listunspent must now contain an A_ext UTXO.
  local LU2 LU2V
  LU2="$(rpc_call "$RPC/wallet/w2" listunspent '[1]')"
  LU2V="$(printf '%s' "$LU2" | AEXT="$AEXT" python3 -c '
import os, sys, json
arr=(json.load(sys.stdin).get("result")) or []
print("yes" if any(u.get("address")==os.environ["AEXT"] for u in arr) else "no")
')"
  if [[ "$LU2V" != "yes" ]]; then
    log "importprivkey credited balance but A_ext UTXO not in listunspent"
    IMPORT_STATE="partial"; return 1
  fi

  REDISCOVERED="$W2_POST"
  IMPORT_STATE="ok"
  log "importprivkey adopted A_ext's funds into w2 ($W2_PRE -> $W2_POST, A_ext UTXO present)"
  return 0
}

import_attempt || log "importprivkey check -> state=$IMPORT_STATE (rescan already green; cell still PASSES)"

# ── 7. Success — rescan is the required green; importprivkey is the target. ─
log "PASS: rescan=ok importprivkey=$IMPORT_STATE rediscovered=$REDISCOVERED"
finish PASS "rescan=ok importprivkey=$IMPORT_STATE rediscovered=$REDISCOVERED"

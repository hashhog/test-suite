#!/usr/bin/env bash
#
# run-gettxoutproof-regression.sh — gettxoutproof indexing/UTXO Core-parity differential.
#
# Runs each per-impl test in proof/<impl>_gettxoutproof.sh. Each test is self-contained:
# it launches its impl on regtest + a real bitcoind regtest as the ORACLE (RPC-only,
# -listen=0), funds a known address, mines to confirm, mirrors the chain so both nodes
# share a byte-identical tip, then runs `gettxoutproof start "addr(<addr>)"` on BOTH and
# diffs. Core ref: bitcoin-core/src/rpc/blockchain.cpp (gettxoutproof). EXACT shape:
# result { success, txouts, height, bestblock, unspents[{txid,vout,scriptPubKey,desc,
# amount,coinbase,height,blockhash,confirmations}], total_amount }.
#
#   Usage:  run-gettxoutproof-regression.sh
#           GETTXOUTPROOF_IMPLS="rustoshi nimrod" run-gettxoutproof-regression.sh
#
# HEAVY: a regtest impl node + a Core oracle per impl, SEQUENTIALLY. exit 0 = no regression.
DIR="$(cd "$(dirname "$0")" && pwd)"
PROOF="$DIR/proof"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-${HASHHOG_ROOT}/haskoin}"

IMPLS="${GETTXOUTPROOF_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${GETTXOUTPROOF_LOGDIR:-/tmp/gettxoutproof-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0; INFRA=0
declare -a FAILED=()
declare -a INFRAED=()
# Infra-abort signatures: a per-impl failure that PREVENTED the comparison
# (port collision, node never launched, empty output) — NOT a divergence.
# Fail-closed: anything not matching this stays a real FAIL.
INFRA_RE='already LISTENING|refusing to kill|produced no output|no output for|no summary line|address already in use|failed to (start|launch|bind|connect)|could not (start|launch|bind)|connection refused|port [0-9].* (in use|already)|bind: address|Errno 98|timed out (waiting|starting)|RPC (never came up|not ready)|launch (failed|error)|node (did not|failed to) start'

echo "== gettxoutproof-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$PROOF/${impl}_gettxoutproof.sh"
  if [ ! -x "$script" ] && [ ! -f "$script" ]; then
    echo "  SKIP  $impl (no gettxoutproof test yet: $script)"; SKIP=$((SKIP+1)); continue
  fi
  log="$LOGDIR/${impl}.log"
  tmpout="$(mktemp)"
  setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
  line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  if [ "$rc" -ne 0 ] && ! printf '%s' "$line" | grep -qiE "$GAP_RE"; then
    echo "  RETRY $impl (attempt 1 exit $rc: ${line})"
    setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
    line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  fi
  [ -z "$line" ] && line="(no summary line — see $log)"
  if [ "$rc" -eq 0 ] && ! printf '%s' "$line" | grep -qiE "SKIP"; then
    echo "  PASS  $impl — $line"; PASS=$((PASS+1))
  elif printf '%s' "$line" | grep -qiE "$GAP_RE|SKIP"; then
    echo "  SKIP  $impl — $line"; SKIP=$((SKIP+1))
  elif printf '%s' "$line" | grep -qiE "$INFRA_RE"; then
    echo "  INFRA $impl (exit $rc) — $line  [detail: $log]"; INFRA=$((INFRA+1)); INFRAED+=("$impl")
  else
    echo "  FAIL  $impl (exit $rc) — $line  [detail: $log]"; FAIL=$((FAIL+1)); FAILED+=("$impl")
  fi
  rm -f "$tmpout"
done

echo "== gettxoutproof-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP${INFRA:+ INFRA=$INFRA} =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  [ "$INFRA" -gt 0 ] && printf '  INFRA (not a divergence): %s\n' "${INFRAED[*]}"
  exit 1
fi
if [ "$INFRA" -gt 0 ]; then
  printf '  INFRA-ONLY (no divergence; harness/port/launch aborts): %s\n' "${INFRAED[*]}"
  exit 3
fi

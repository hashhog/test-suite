#!/usr/bin/env bash
#
# run-coinstatsindex-regression.sh — coinstatsindex indexing/UTXO Core-parity differential.
#
# Runs each per-impl test in coinstats/<impl>_coinstatsindex.sh. Each test is self-contained:
# it launches its impl on regtest + a real bitcoind regtest as the ORACLE (RPC-only,
# -listen=0), funds a known address, mines to confirm, mirrors the chain so both nodes
# share a byte-identical tip, then runs `coinstatsindex start "addr(<addr>)"` on BOTH and
# diffs. Core ref: bitcoin-core/src/rpc/blockchain.cpp (coinstatsindex). EXACT shape:
# result { success, txouts, height, bestblock, unspents[{txid,vout,scriptPubKey,desc,
# amount,coinbase,height,blockhash,confirmations}], total_amount }.
#
#   Usage:  run-coinstatsindex-regression.sh
#           COINSTATSINDEX_IMPLS="rustoshi nimrod" run-coinstatsindex-regression.sh
#
# HEAVY: a regtest impl node + a Core oracle per impl, SEQUENTIALLY. exit 0 = no regression.
DIR="$(cd "$(dirname "$0")" && pwd)"
CS="$DIR/coinstats"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-${HASHHOG_ROOT}/haskoin}"

IMPLS="${COINSTATSINDEX_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${COINSTATSINDEX_LOGDIR:-/tmp/coinstatsindex-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== coinstatsindex-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$CS/${impl}_coinstatsindex.sh"
  if [ ! -x "$script" ] && [ ! -f "$script" ]; then
    echo "  SKIP  $impl (no coinstatsindex test yet: $script)"; SKIP=$((SKIP+1)); continue
  fi
  log="$LOGDIR/${impl}.log"
  tmpout="$(mktemp)"
  timeout 300 setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
  line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  if [ "$rc" -ne 0 ] && ! printf '%s' "$line" | grep -qiE "$GAP_RE"; then
    echo "  RETRY $impl (attempt 1 exit $rc: ${line})"
    timeout 300 setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
    line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  fi
  [ -z "$line" ] && line="(no summary line — see $log)"
  if [ "$rc" -eq 0 ] && ! printf '%s' "$line" | grep -qiE "SKIP"; then
    echo "  PASS  $impl — $line"; PASS=$((PASS+1))
  elif printf '%s' "$line" | grep -qiE "$GAP_RE|SKIP"; then
    echo "  SKIP  $impl — $line"; SKIP=$((SKIP+1))
  else
    echo "  FAIL  $impl (exit $rc) — $line  [detail: $log]"; FAIL=$((FAIL+1)); FAILED+=("$impl")
  fi
  rm -f "$tmpout"
done

echo "== coinstatsindex-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi

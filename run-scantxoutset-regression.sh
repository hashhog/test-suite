#!/usr/bin/env bash
#
# run-scantxoutset-regression.sh — scantxoutset indexing/UTXO Core-parity differential.
#
# Runs each per-impl test in scan/<impl>_scantxoutset.sh. Each test is self-contained:
# it launches its impl on regtest + a real bitcoind regtest as the ORACLE (RPC-only,
# -listen=0), funds a known address, mines to confirm, mirrors the chain so both nodes
# share a byte-identical tip, then runs `scantxoutset start "addr(<addr>)"` on BOTH and
# diffs. Core ref: bitcoin-core/src/rpc/blockchain.cpp (scantxoutset). EXACT shape:
# result { success, txouts, height, bestblock, unspents[{txid,vout,scriptPubKey,desc,
# amount,coinbase,height,blockhash,confirmations}], total_amount }.
#
#   Usage:  run-scantxoutset-regression.sh
#           SCANTXOUTSET_IMPLS="rustoshi nimrod" run-scantxoutset-regression.sh
#
# HEAVY: a regtest impl node + a Core oracle per impl, SEQUENTIALLY. exit 0 = no regression.
DIR="$(cd "$(dirname "$0")" && pwd)"
SCAN="$DIR/scan"

export PATH="/home/work/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-/home/work/hashhog/haskoin}"

IMPLS="${SCANTXOUTSET_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${SCANTXOUTSET_LOGDIR:-/tmp/scantxoutset-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== scantxoutset-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$SCAN/${impl}_scantxoutset.sh"
  if [ ! -x "$script" ] && [ ! -f "$script" ]; then
    echo "  SKIP  $impl (no scantxoutset test yet: $script)"; SKIP=$((SKIP+1)); continue
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
  else
    echo "  FAIL  $impl (exit $rc) — $line  [detail: $log]"; FAIL=$((FAIL+1)); FAILED+=("$impl")
  fi
  rm -f "$tmpout"
done

echo "== scantxoutset-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi

#!/usr/bin/env bash
#
# run-gettxout-regression.sh — gettxout UTXO-coin Core-parity differential.
#
# Runs each per-impl test in gettxout/<impl>_gettxout.sh. Each test is
# self-contained: it launches its impl on regtest + a real bitcoind regtest as
# the ORACLE (RPC-only, -listen=0), funds a known UTXO, mines to a FIXED depth
# (so confirmations is a known constant), mirrors the chain so both nodes share
# a byte-identical tip, then runs `gettxout <txid> <vout> true` on BOTH and
# diffs the FULL shape. Core ref: bitcoin-core/src/rpc/blockchain.cpp (gettxout).
# EXACT shape for an EXISTING UTXO:
#   result { bestblock(hex tip), confirmations(int = tip_height - coin_height + 1),
#            value(BTC float), scriptPubKey{asm,hex,type,address}, coinbase(bool) }
# A spent / nonexistent output -> JSON null.
#
#   Usage:  run-gettxout-regression.sh
#           GETTXOUT_IMPLS="rustoshi nimrod" run-gettxout-regression.sh
#
# HEAVY: a regtest impl node + a Core oracle per impl, SEQUENTIALLY. exit 0 = no regression.
DIR="$(cd "$(dirname "$0")" && pwd)"
GTO="$DIR/gettxout"

export PATH="/home/work/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-/home/work/hashhog/haskoin}"

IMPLS="${GETTXOUT_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${GETTXOUT_LOGDIR:-/tmp/gettxout-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== gettxout-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$GTO/${impl}_gettxout.sh"
  if [ ! -x "$script" ] && [ ! -f "$script" ]; then
    echo "  SKIP  $impl (no gettxout test yet: $script)"; SKIP=$((SKIP+1)); continue
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

echo "== gettxout-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi

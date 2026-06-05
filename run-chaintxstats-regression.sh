#!/usr/bin/env bash
# run-chaintxstats-regression.sh — getchaintxstats RPC-surface Core-parity differential.
#
# Runs each per-impl test in chaintxstats/<impl>_chaintxstats.sh. Each test is
# self-contained: it launches its impl on regtest + a real bitcoind regtest as the
# ORACLE (its own scratch dir + ports), mines the SAME number of empty blocks to the
# SAME deterministic address on both (identical chain shape: every block = 1 coinbase
# tx), then asserts getchaintxstats matches Core:
#
#   EXACT (per chain shape): txcount (=height+1), window_tx_count (=window),
#     window_block_count, window_final_block_height.
#   PRESENT + typed + emit-condition-correct (NOT byte-equal — independent wall-clocks):
#     time (final block RAW nTime), window_interval (>=0, only when window>0),
#     txrate (only when window_interval>0); nblocks=0 drops the 3 window_* extras.
#   ERROR CODES: -5 unknown blockhash; -8 not-in-main-chain / out-of-range nblocks.
#
# Sixth differential axis after recovery/spend/history/import/policy. READ-ONLY chain
# stats — NOT consensus, but must match Core exactly. A FAIL means an impl's
# getchaintxstats diverged from Core for an identical chain shape.
#
# Each test prints exactly ONE summary line — "CHAINTXSTATS <impl>: PASS/FAIL ..." — and
# exits 0 (PASS) / 1 (FAIL). Impls with no test yet, or an unbuilt/stale binary, SKIP.
# A transient startup race (impl daemon + Core oracle racing on a loaded box) retries once.
#
# HEAVY: a regtest impl node + a Core oracle per impl, SEQUENTIALLY. Gated behind a mem
# floor in the nightly guard.
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one impl regressed.
#
#   Usage:  run-chaintxstats-regression.sh
#           CHAINTXSTATS_IMPLS="rustoshi nimrod" run-chaintxstats-regression.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
CTS="$DIR/chaintxstats"

export PATH="/home/work/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-/home/work/hashhog/haskoin}"

IMPLS="${CHAINTXSTATS_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${CHAINTXSTATS_LOGDIR:-/tmp/chaintxstats-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== chaintxstats-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$CTS/${impl}_chaintxstats.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no chaintxstats test yet: $script)"; SKIP=$((SKIP+1)); continue
  fi
  log="$LOGDIR/${impl}.log"
  tmpout="$(mktemp)"
  setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
  line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  # transient startup race (impl daemon + Core oracle racing on a loaded box) -> retry once.
  if [ "$rc" -ne 0 ] && ! printf '%s' "$line" | grep -qiE "$GAP_RE"; then
    echo "  RETRY $impl (attempt 1 exit $rc: ${line})"
    setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
    line="$(tail -n 1 "$tmpout" 2>/dev/null)"
  fi
  [ -z "$line" ] && line="(no summary line — see $log)"
  if [ "$rc" -eq 0 ]; then
    echo "  PASS  $impl — $line"; PASS=$((PASS+1))
  elif printf '%s' "$line" | grep -qiE "$GAP_RE"; then
    echo "  SKIP  $impl (build gap) — $line"; SKIP=$((SKIP+1))
  else
    echo "  FAIL  $impl (exit $rc) — $line  [detail: $log]"; FAIL=$((FAIL+1)); FAILED+=("$impl")
  fi
  rm -f "$tmpout"
done

echo "== chaintxstats-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0

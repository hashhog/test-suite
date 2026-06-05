#!/usr/bin/env bash
# run-getindexinfo-regression.sh — getindexinfo indexing-axis Core-parity differential.
#
# Runs each per-impl test in index/<impl>_getindexinfo.sh. Each test is self-contained:
# it launches its impl on regtest + a real bitcoind regtest as the ORACLE (own scratch +
# ports), started with txindex (and a basic block filter index where the impl runs one),
# mines the SAME number of empty blocks on both, waits for index sync, then asserts
# getindexinfo matches Core:
#
#   SHAPE — a dynamic OBJECT keyed by index name; each value is EXACTLY {synced,
#     best_block_height} (no best_hash / best_block_hash / name-in-value / extra keys).
#     (Key ORDER is not asserted — JSON is parsed by key; impls serialize differently.)
#   HEIGHT — for each index the impl runs, synced==true and best_block_height==tip height.
#   FILTER — getindexinfo "<name>" returns only that key; "no-such-index" returns {}.
#
# Each impl runs whatever index set it actually supports (Core lists only running indexes):
# some emit "txindex", some "basic block filter index", some both — each script configures
# its oracle to match, so the comparison is apples-to-apples per impl.
#
# Seventh differential axis (after recovery/spend/history/import/policy/chaintxstats), the
# first INDEXING-axis cell. READ-ONLY index status — NOT consensus. A FAIL means an impl's
# getindexinfo diverged from Core (wrong shape, wrong height, or a broken filter arg).
#
# Each test prints exactly ONE summary line — "GETINDEXINFO <impl>: PASS/FAIL ..." — and
# exits 0 (PASS) / 1 (FAIL). Impls with no test yet, or an unbuilt/stale binary, SKIP.
# A transient startup race (impl daemon + Core oracle racing on a loaded box) retries once.
#
# HEAVY: a regtest impl node + a Core oracle per impl, SEQUENTIALLY. Gated behind a mem
# floor in the nightly guard.
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one impl regressed.
#
#   Usage:  run-getindexinfo-regression.sh
#           GETINDEXINFO_IMPLS="rustoshi nimrod" run-getindexinfo-regression.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
GII="$DIR/index"

export PATH="/home/work/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-/home/work/hashhog/haskoin}"

IMPLS="${GETINDEXINFO_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${GETINDEXINFO_LOGDIR:-/tmp/getindexinfo-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== getindexinfo-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$GII/${impl}_getindexinfo.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no getindexinfo test yet: $script)"; SKIP=$((SKIP+1)); continue
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

echo "== getindexinfo-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0

#!/usr/bin/env bash
# run-getblockfilter-regression.sh — BIP157/158 compact block filter Core-parity differential.
#
# Runs each per-impl test in blockfilter/<impl>_getblockfilter.sh. Each test is self-
# contained: it shares ONE chain (incl a spend tx) between its impl and a real bitcoind
# regtest ORACLE (own scratch + ports, -listen=0 -blockfilterindex=basic) and asserts
# getblockfilter matches Core BYTE-FOR-BYTE:
#
#   filter -> the BIP158 basic GCS filter hex byte-exact (coinbase-only AND multi-element
#     spend blocks). header -> the BIP157 chained filter header hex byte-exact, verified
#     across consecutive blocks (catches a wrong prev-header link). errors -> -5 unknown
#     filtertype / unknown blockhash.
#
# Twelfth differential axis — the substantive INDEXING capability (SPV-serving filters),
# not just index status. A FAIL means an impl's filters diverge from Core (wrong GCS
# params/encoding, wrong element set, broken header chaining) — i.e. a light client would
# get wrong data.
#
# Each test prints exactly ONE summary line — "GETBLOCKFILTER <impl>: PASS/FAIL/SKIP ..." —
# and exits 0 (PASS) / 1 (FAIL). Impls with no filter index, no test yet, or an unbuilt
# binary SKIP. A transient startup race retries once.
#
# HEAVY: a regtest impl node + a Core oracle per impl, SEQUENTIALLY. Gated behind a mem floor.
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one impl regressed.
#
#   Usage:  run-getblockfilter-regression.sh
#           GBF_IMPLS="rustoshi nimrod" run-getblockfilter-regression.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
GBF="$DIR/blockfilter"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-${HASHHOG_ROOT}/haskoin}"

IMPLS="${GBF_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${GBF_LOGDIR:-/tmp/getblockfilter-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed|no filter index|not enabled'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== getblockfilter-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$GBF/${impl}_getblockfilter.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no getblockfilter test yet: $script)"; SKIP=$((SKIP+1)); continue
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

echo "== getblockfilter-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0

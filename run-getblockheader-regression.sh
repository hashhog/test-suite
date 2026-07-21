#!/usr/bin/env bash
# run-getblockheader-regression.sh — getblockheader RPC-surface Core-parity differential.
#
# Runs each per-impl test in blockheader/<impl>_getblockheader.sh. Each test is self-
# contained: it shares ONE chain between its impl and a real bitcoind regtest ORACLE (Core
# mines, blocks replayed via submitblock, so headers are byte-identical), then asserts
# getblockheader matches Core:
#
#   verbose=false -> the 80-byte serialized header HEX, byte-EXACT (round-trips to the hash).
#   verbose=true  -> blockheaderToJSON: hash, confirmations, height, version, versionHex,
#     merkleroot, time, mediantime, nonce, bits, nTx, previousblockhash, nextblockhash,
#     chainwork ALL exact; difficulty + target present-not-byte-equal.
#   genesis -> no previousblockhash; tip -> no nextblockhash, confirmations==1.
#   error -> an unknown blockhash -> -5 "Block not found".
#
# Eleventh differential axis. READ-ONLY header lookup — NOT consensus. A FAIL means an impl's
# getblockheader diverged from Core (wrong hex, wrong/extra field, wrong confirmations,
# genesis/tip edge wrong, wrong error code).
#
# Each test prints exactly ONE summary line — "GETBLOCKHEADER <impl>: PASS/FAIL ..." — and
# exits 0 (PASS) / 1 (FAIL). Impls with no test yet, or an unbuilt/stale binary, SKIP.
# A transient startup race retries once.
#
# HEAVY: a regtest impl node + a Core oracle per impl, SEQUENTIALLY. Gated behind a mem floor.
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one impl regressed.
#
#   Usage:  run-getblockheader-regression.sh
#           GBH_IMPLS="rustoshi nimrod" run-getblockheader-regression.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
GBH="$DIR/blockheader"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-${HASHHOG_ROOT}/haskoin}"

IMPLS="${GBH_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${GBH_LOGDIR:-/tmp/getblockheader-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0; INFRA=0
declare -a FAILED=()
declare -a INFRAED=()
# Infra-abort signatures: a per-impl failure that PREVENTED the comparison
# (port collision, node never launched, empty output) — NOT a divergence.
# Fail-closed: anything not matching this stays a real FAIL.
INFRA_RE='already LISTENING|refusing to kill|produced no output|no output for|no summary line|address already in use|failed to (start|launch|bind|connect)|could not (start|launch|bind)|connection refused|port [0-9].* (in use|already)|bind: address|Errno 98|timed out (waiting|starting)|RPC (never came up|not ready)|launch (failed|error)|node (did not|failed to) start'

echo "== getblockheader-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$GBH/${impl}_getblockheader.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no getblockheader test yet: $script)"; SKIP=$((SKIP+1)); continue
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
  if [ "$rc" -eq 0 ]; then
    echo "  PASS  $impl — $line"; PASS=$((PASS+1))
  elif printf '%s' "$line" | grep -qiE "$GAP_RE"; then
    echo "  SKIP  $impl (build gap) — $line"; SKIP=$((SKIP+1))
  elif printf '%s' "$line" | grep -qiE "$INFRA_RE"; then
    echo "  INFRA $impl (exit $rc) — $line  [detail: $log]"; INFRA=$((INFRA+1)); INFRAED+=("$impl")
  else
    echo "  FAIL  $impl (exit $rc) — $line  [detail: $log]"; FAIL=$((FAIL+1)); FAILED+=("$impl")
  fi
  rm -f "$tmpout"
done

echo "== getblockheader-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP${INFRA:+ INFRA=$INFRA} =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  [ "$INFRA" -gt 0 ] && printf '  INFRA (not a divergence): %s\n' "${INFRAED[*]}"
  exit 1
fi
if [ "$INFRA" -gt 0 ]; then
  printf '  INFRA-ONLY (no divergence; harness/port/launch aborts): %s\n' "${INFRAED[*]}"
  exit 3
fi
exit 0

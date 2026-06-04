#!/usr/bin/env bash
# run-import-regression.sh — wallet IMPORT+RESCAN differential regression.
#
# Runs each per-impl import/rescan test in import/<impl>_import.sh. Each test is
# self-contained: it launches its impl on regtest in a scratch /tmp/importfleet-<impl>
# datadir, then proves the wallet can rediscover + adopt funds by scanning the chain:
#
#   RESCAN (core): fund a seed wallet W1 -> a FRESH wallet W2 from the SAME seed reports
#     getbalance 0 (restore derives keys but does not scan) -> rescanblockchain on W2 ->
#     W2 rediscovers W1's funds via a REAL wallet rescan (not the scantxoutset shortcut).
#   IMPORTPRIVKEY: fund a FOREIGN key's address -> importprivkey(WIF, rescan) into a
#     wallet -> the wallet adopts the foreign funds.
#
# Fourth wallet axis after recovery + spend + history. rescanblockchain is the backward
# counterpart of the block-connect scan and is what makes recovery honest at the wallet
# layer. A FAIL is a real loss of wallet rescan/import for that impl.
#
# Each test prints exactly ONE summary line — "IMPORT <impl>: PASS/FAIL ..." — and exits
# 0 (PASS) / 1 (FAIL). Impls with no import test yet, or an unbuilt/stale binary, are
# SKIPped (logged, not FAILed) — same philosophy as the sibling runners.
#
# HEAVY: a real regtest node per impl, SEQUENTIALLY. The nightly guard gates this behind
# a mem floor.
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one impl regressed.
#
#   Usage:  run-import-regression.sh
#           IMPORT_IMPLS="rustoshi nimrod" run-import-regression.sh
#           IMPORT_LOGDIR=/path run-import-regression.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
IMP="$DIR/import"

export PATH="/home/work/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-/home/work/hashhog/haskoin}"

IMPLS="${IMPORT_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${IMPORT_LOGDIR:-/tmp/import-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== import-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$IMP/${impl}_import.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no import test yet: $script)"; SKIP=$((SKIP+1)); continue
  fi
  log="$LOGDIR/${impl}.log"
  tmpout="$(mktemp)"
  setsid -w bash "$script" >"$tmpout" 2>"$log"; rc=$?
  line="$(tail -n 1 "$tmpout" 2>/dev/null)"
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

echo "== import-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0

#!/usr/bin/env bash
# run-getrawtransaction-regression.sh — getrawtransaction RPC-surface/indexing Core-parity differential.
#
# Runs each per-impl test in rawtx/<impl>_getrawtransaction.sh. Each test is self-contained:
# it drives its impl on regtest alongside a real bitcoind regtest ORACLE (own scratch +
# ports, -listen=0), then asserts getrawtransaction matches Core:
#
#   verbosity 0  -> the raw tx HEX, byte-EXACT.
#   verbosity 1  -> decoded object: txid/hash/version/size/vsize/weight/locktime, vin
#     {txid,vout,sequence,scriptSig.hex}, vout {value,n,scriptPubKey.hex/.type/.address}, hex,
#     and the confirmed envelope (blockhash/confirmations/time/blocktime, in_active_chain when
#     a blockhash arg was given) — all EXACT; asm/desc present-not-byte-equal.
#   errors -> -5 for the genesis-coinbase txid, an unknown txid, and an unknown blockhash arg.
#
# Ninth differential axis (after recovery/spend/history/import/policy/chaintxstats/getindexinfo/
# getnodeaddresses). READ-ONLY tx lookup — NOT consensus. A FAIL means an impl's
# getrawtransaction diverged from Core (wrong hex, wrong decoded field, missing envelope,
# wrong error).
#
# Each test prints exactly ONE summary line — "GETRAWTRANSACTION <impl>: PASS/FAIL ..." — and
# exits 0 (PASS) / 1 (FAIL). Impls with no test yet, or an unbuilt/stale binary, SKIP.
# A transient startup race (impl daemon + Core oracle racing on a loaded box) retries once.
#
# HEAVY: a regtest impl node + a Core oracle per impl, SEQUENTIALLY. Gated behind a mem
# floor in the nightly guard.
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one impl regressed.
#
#   Usage:  run-getrawtransaction-regression.sh
#           GRT_IMPLS="rustoshi nimrod" run-getrawtransaction-regression.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
GRT="$DIR/rawtx"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-${HASHHOG_ROOT}/haskoin}"

IMPLS="${GRT_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${GRT_LOGDIR:-/tmp/getrawtransaction-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()

echo "== getrawtransaction-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$GRT/${impl}_getrawtransaction.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no getrawtransaction test yet: $script)"; SKIP=$((SKIP+1)); continue
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
  else
    echo "  FAIL  $impl (exit $rc) — $line  [detail: $log]"; FAIL=$((FAIL+1)); FAILED+=("$impl")
  fi
  rm -f "$tmpout"
done

echo "== getrawtransaction-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
if [ "$FAIL" -gt 0 ]; then
  printf '  FAILED: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0

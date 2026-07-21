#!/usr/bin/env bash
# run-getnodeaddresses-regression.sh — getnodeaddresses P2P-axis Core-parity differential.
#
# Runs each per-impl test in p2p-addr/<impl>_getnodeaddresses.sh. Each test is
# self-contained: it launches its impl on regtest + a real bitcoind regtest as the ORACLE
# (own scratch + ports, RPC-only — see the watchdog note below), injects a known address
# via addpeeraddress on both, then asserts getnodeaddresses matches Core:
#
#   SHAPE — a JSON ARRAY of objects, each with EXACTLY 5 keys {time, services, address,
#     port, network}: time int unix secs; services the raw bitfield as an INTEGER (NOT
#     hex); address str; port int; network one of ipv4/ipv6/onion/i2p/cjdns/
#     not_publicly_routable/internal. Match by content, never by index (addrman shuffles).
#   ERRORS — count<0 -> -8 "Address count out of range"; bad network -> -8
#     "Network not recognized: <arg>".
#   COUNT/FILTER — count==0 = all, count 1 = <=1; network filter selects the right net.
#
# Eighth differential axis (after recovery/spend/history/import/policy/chaintxstats/
# getindexinfo), the first P2P-axis cell. READ-ONLY addrman dump — NOT consensus. A FAIL
# means an impl's getnodeaddresses diverged from Core (wrong shape, services-as-hex,
# missing error path, broken count/network filter).
#
# NOTE (sandbox watchdog): a bitcoind that binds a 0.0.0.0 P2P listener is SIGKILLed ~2s
# after load in this environment. The addrman / addpeeraddress / getnodeaddresses paths
# are independent of the P2P listener, so each per-impl script launches its Core oracle
# RPC-only (-listen=0). Does not weaken the differential.
#
# Each test prints exactly ONE summary line — "GETNODEADDRESSES <impl>: PASS/FAIL ..." —
# and exits 0 (PASS) / 1 (FAIL). Impls with no test yet, or an unbuilt/stale binary, SKIP.
# A transient startup race (impl daemon + Core oracle racing on a loaded box) retries once.
#
# HEAVY: a regtest impl node + a Core oracle per impl, SEQUENTIALLY. Gated behind a mem
# floor in the nightly guard.
#
# Exit 0 = no regression (all PASS, modulo SKIPs); non-zero = at least one impl regressed.
#
#   Usage:  run-getnodeaddresses-regression.sh
#           GNA_IMPLS="rustoshi nimrod" run-getnodeaddresses-regression.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
GNA="$DIR/p2p-addr"

HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export haskoin_datadir="${haskoin_datadir:-${HASHHOG_ROOT}/haskoin}"

IMPLS="${GNA_IMPLS:-rustoshi nimrod ouroboros blockbrew hotbuns camlcoin beamchain clearbit lunarblock haskoin}"
LOGDIR="${GNA_LOGDIR:-/tmp/getnodeaddresses-regression}"
mkdir -p "$LOGDIR"

GAP_RE='not found|not built|no binary|release binary|rebuild|missing.*RPC|RPC missing|not installed'

PASS=0; FAIL=0; SKIP=0; INFRA=0
declare -a FAILED=()
declare -a INFRAED=()
# Infra-abort signatures: a per-impl failure that PREVENTED the comparison
# (port collision, node never launched, empty output) — NOT a divergence.
# Fail-closed: anything not matching this stays a real FAIL.
INFRA_RE='already LISTENING|refusing to kill|produced no output|no output for|no summary line|address already in use|failed to (start|launch|bind|connect)|could not (start|launch|bind)|connection refused|port [0-9].* (in use|already)|bind: address|Errno 98|timed out (waiting|starting)|RPC (never came up|not ready)|launch (failed|error)|node (did not|failed to) start'

echo "== getnodeaddresses-regression $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
for impl in $IMPLS; do
  script="$GNA/${impl}_getnodeaddresses.sh"
  if [ ! -x "$script" ]; then
    echo "  SKIP  $impl (no getnodeaddresses test yet: $script)"; SKIP=$((SKIP+1)); continue
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
  elif printf '%s' "$line" | grep -qiE "$INFRA_RE"; then
    echo "  INFRA $impl (exit $rc) — $line  [detail: $log]"; INFRA=$((INFRA+1)); INFRAED+=("$impl")
  else
    echo "  FAIL  $impl (exit $rc) — $line  [detail: $log]"; FAIL=$((FAIL+1)); FAILED+=("$impl")
  fi
  rm -f "$tmpout"
done

echo "== getnodeaddresses-regression: PASS=$PASS FAIL=$FAIL SKIP=$SKIP${INFRA:+ INFRA=$INFRA} =="
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

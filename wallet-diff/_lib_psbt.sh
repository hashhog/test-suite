# _lib_psbt.sh — shared plumbing for walletdiff SLICE 2 (PSBT round-trip
# parity, P2.1/P2.2). Sourced, not run.
#
# Design: CORE-PARITY-AUDIT/_wallet-diff-harness-design-2026-07-20.md sec 5.
# House rule (harness-script-consistency memory): per-impl adapters supply ONLY
# launch/RPC plumbing; every comparison lives in the ONE shared comparator
# (probe_psbt.py). An adapter may not weaken a comparison.
#
# DIFFERENCE from slice 1's _lib.sh: a PSBT round-trip is a single DIFFERENTIAL
# flow (SUT creates a PSBT, Core validates + cross-signs the SAME PSBT, blocks
# copied SUT->Core), so this driver launches BOTH nodes and hands BOTH endpoints
# to ONE probe invocation -- rather than replaying a frozen corpus against each
# node independently.
#
# CRITICAL: the Core oracle MUST be the wallet-enabled build
# (bitcoin-core/build-wallet/bin) -- the plain build/bin has NO wallet RPCs
# (createwallet -> "Method not found"). If build-wallet is absent, SKIP (infra),
# never FAIL.
#
# An adapter (<impl>_walletdiff_psbt.sh) must, before calling walletdiff_psbt_main:
#   - set IMPL, BIN (impl binary path), BUILD_HINT
#   - set IMPL_RPC IMPL_P2P CORE_RPC CORE_P2P (reserved 22150-22199 block)
#   - set IMPL_DATADIR CORE_DATADIR (scratch under /tmp/walletdiff-psbt-*)
#   - set IMPL_COOKIE_CANDIDATES (array of possible cookie paths)
#   - define launch_impl()  — start the node in background, set IMPL_PID
#
# Summary-line contract (stdout, exactly one line; all else stderr):
#   WALLETDIFF-PSBT <impl>: PASS native_p2wpkh=PASS native_p2tr=.. import_spend=..
#   WALLETDIFF-PSBT <impl>: FAIL native_p2wpkh=.. .. first=<..>
#   WALLETDIFF-PSBT <impl>: SKIP <build/RPC gap>          (runner GAP_RE)
#   WALLETDIFF-PSBT <impl>: BLOCKED <infra>               (runner INFRA_RE)
# Exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Wallet-enabled Core; fall back to plain build only to emit a clean SKIP.
CORE_BIN="$HASHHOG_ROOT/bitcoin-core/build-wallet/bin/bitcoind"
CORE_CLI="$HASHHOG_ROOT/bitcoin-core/build-wallet/bin/bitcoin-cli"
VECTORS="$WD_DIR/vectors-address.json"
PROBE="$WD_DIR/probe_psbt.py"
RESULTS_DIR="${WALLETDIFF_RESULTS_DIR:-$HASHHOG_ROOT/test-suite/results}"

IMPL_PID=""
CORE_BG=""

log()  { echo "[walletdiff-psbt:${IMPL:-?}] $*" >&2; }
pass_line()    { echo "WALLETDIFF-PSBT $IMPL: PASS $*"; exit 0; }
fail_line()    { echo "WALLETDIFF-PSBT $IMPL: FAIL $*"; exit 1; }
skip_line()    { echo "WALLETDIFF-PSBT $IMPL: SKIP $*"; exit 0; }
blocked_line() { echo "WALLETDIFF-PSBT $IMPL: BLOCKED $*"; exit 1; }

# ── Cleanup: kill OUR pids only, stop OUR oracle, wipe OUR scratch. ──────────
wd_cleanup() {
    local ec=$?
    if [[ -n "$IMPL_PID" ]] && kill -0 "$IMPL_PID" 2>/dev/null; then
        kill "$IMPL_PID" 2>/dev/null || true
        for _ in $(seq 1 15); do kill -0 "$IMPL_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$IMPL_PID" 2>/dev/null || true
    fi
    "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" stop >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        "$CORE_CLI" -regtest -datadir="$CORE_DATADIR" -rpcport="$CORE_RPC" getblockcount >/dev/null 2>&1 || break
        sleep 1
    done
    [[ -n "$CORE_BG" ]] && kill "$CORE_BG" 2>/dev/null || true
    rm -rf "$IMPL_DATADIR" "$CORE_DATADIR" 2>/dev/null || true
    return $ec
}

# ── Core oracle launcher (lifted from _lib.sh / rbf/rustoshi_rbf.sh:376). ────
# -fallbackfee lets walletcreatefundedpsbt estimate on an empty regtest chain.
launch_core() {
    local dd="$1" rpc="$2" p2p="$3" lf="$4"; shift 4
    local attempt
    for attempt in 1 2 3 4 5; do
        local wait_n=0
        while fuser "${rpc}/tcp" >/dev/null 2>&1 && (( wait_n < 15 )); do
            sleep 1; wait_n=$((wait_n+1))
        done
        "$CORE_BIN" -regtest -datadir="$dd" -rpcport="$rpc" -port="$p2p" -listen=0 \
            -fallbackfee=0.0002 "$@" >"$lf" 2>&1 &
        local bg=$!
        local deadline=$(( $(date +%s) + 120 ))
        while (( $(date +%s) < deadline )); do
            if "$CORE_CLI" -regtest -datadir="$dd" -rpcport="$rpc" getblockcount >/dev/null 2>&1; then
                echo "$bg"; return 0
            fi
            if ! kill -0 "$bg" 2>/dev/null; then
                echo "[launch_core] attempt $attempt: bitcoind exited early; retrying" >&2
                tail -n 5 "$lf" >&2 2>/dev/null || true
                break
            fi
            sleep 1
        done
        kill -0 "$bg" 2>/dev/null && { return 1; }
        sleep 2
    done
    tail -n 20 "$lf" >&2 2>/dev/null || true
    return 1
}

# ── The shared driver. ──────────────────────────────────────────────────────
walletdiff_psbt_main() {
    trap wd_cleanup EXIT INT TERM
    local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
    local impl_log="$IMPL_DATADIR/node.log"
    local core_log="$CORE_DATADIR/core.log"
    local probe_out="$IMPL_DATADIR/probe.out"

    # 0. Port refusal — NEVER kill a listener (2026-06-10 fuser incident).
    for _ in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -qE ":(${IMPL_RPC}|${IMPL_P2P}|${CORE_RPC}|${CORE_P2P}) " || break
        sleep 1
    done
    if ss -tln 2>/dev/null | grep -qE ":(${IMPL_RPC}|${IMPL_P2P}|${CORE_RPC}|${CORE_P2P}) "; then
        fail_line "port ${IMPL_RPC}/${IMPL_P2P}/${CORE_RPC}/${CORE_P2P} already LISTENING — refusing to kill it (2026-06-10 fuser incident)"
    fi
    rm -rf "$IMPL_DATADIR" "$CORE_DATADIR"
    mkdir -p "$IMPL_DATADIR" "$CORE_DATADIR" || fail_line "cannot create scratch datadirs"

    # 1. Preconditions (build gaps are SKIP, not FAIL).
    command -v python3 >/dev/null 2>&1 || skip_line "python3 not found on PATH"
    [[ -x "$BIN" ]]      || skip_line "$IMPL binary not found at $BIN ($BUILD_HINT)"
    [[ -x "$CORE_BIN" ]] || skip_line "wallet-enabled bitcoind not found at $CORE_BIN — build it: cmake -B build-wallet -DENABLE_WALLET=ON && cmake --build build-wallet"
    [[ -x "$CORE_CLI" ]] || skip_line "wallet-enabled bitcoin-cli not found at $CORE_CLI"
    [[ -s "$VECTORS" ]]  || fail_line "frozen corpus missing: $VECTORS"
    [[ -s "$PROBE" ]]    || fail_line "shared comparator missing: $PROBE"

    # 2. Launch the Core oracle (wallet build).
    log "launching wallet-enabled Core oracle rpc=:$CORE_RPC (regtest, -listen=0)"
    CORE_BG=$(launch_core "$CORE_DATADIR" "$CORE_RPC" "$CORE_P2P" "$core_log") \
        || fail_line "Core oracle failed to start within 120s (see $core_log)"
    local core_cookie="$CORE_DATADIR/regtest/.cookie"
    [[ -f "$core_cookie" ]] || fail_line "Core cookie not found at $core_cookie"
    log "Core oracle ready (pid=$CORE_BG)"

    # 3. Launch the SUT (adapter-supplied plumbing).
    log "launching $IMPL (regtest) rpc=:$IMPL_RPC p2p=:$IMPL_P2P"
    launch_impl
    [[ -n "$IMPL_PID" ]] || fail_line "launch_impl did not set IMPL_PID"
    local cookie="" deadline=$(( $(date +%s) + 120 )) c r
    while (( $(date +%s) < deadline )); do
        if [[ -z "$cookie" ]]; then
            for c in "${IMPL_COOKIE_CANDIDATES[@]}"; do
                [[ -f "$c" ]] && cookie="$c" && break
            done
        fi
        if [[ -n "$cookie" ]]; then
            r=$(curl -s --max-time 5 -u "$(cat "$cookie")" \
                --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
                "http://127.0.0.1:$IMPL_RPC/" 2>/dev/null)
            echo "$r" | grep -q '"result"' && break
        fi
        kill -0 "$IMPL_PID" 2>/dev/null || { tail -n 20 "$impl_log" >&2 2>/dev/null || true; fail_line "$IMPL exited during startup (see $impl_log)"; }
        sleep 1
    done
    [[ -n "$cookie" ]] || fail_line "$IMPL cookie never appeared within 120s"
    r=$(curl -s --max-time 5 -u "$(cat "$cookie")" \
        --data-binary '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' \
        "http://127.0.0.1:$IMPL_RPC/" 2>/dev/null)
    echo "$r" | grep -q '"result"' || fail_line "$IMPL RPC never responded within 120s"
    log "$IMPL RPC ready"

    # 4. Run the ONE differential probe against BOTH endpoints.
    mkdir -p "$RESULTS_DIR" 2>/dev/null || true
    local results_json="$RESULTS_DIR/walletdiff-psbt-$IMPL-$ts.json"
    python3 "$PROBE" \
        --core-url "http://127.0.0.1:$CORE_RPC/" --core-cookie "$core_cookie" \
        --impl-url "http://127.0.0.1:$IMPL_RPC/" --impl-cookie "$cookie" \
        --impl "$IMPL" --vectors "$VECTORS" --results-out "$results_json" \
        >"$probe_out" 2>&1
    local prc=$?
    cat "$probe_out" >&2

    # 5. Verdict from the probe's SUMMARY line.
    local summary
    summary="$(grep '^SUMMARY ' "$probe_out" | tail -n 1 | sed 's/^SUMMARY //')"
    case $prc in
        0)  [[ -n "$summary" ]] || fail_line "probe exit 0 but no SUMMARY line (see $probe_out)"
            log "results receipt: $results_json"
            pass_line "$summary" ;;
        1)  [[ -n "$summary" ]] || summary="(no SUMMARY line)"
            log "results receipt: $results_json"
            fail_line "$summary" ;;
        2)  local gap
            gap="$(grep '^RPCGAP ' "$probe_out" | tail -n 1 | sed 's/^RPCGAP //')"
            skip_line "${gap:-required PSBT RPC missing} — rebuild $IMPL ($BUILD_HINT)" ;;
        3)  local infra
            infra="$(grep '^INFRA ' "$probe_out" | tail -n 1 | sed 's/^INFRA //')"
            blocked_line "${infra:-comparator infra error} (see $probe_out)" ;;
        *)  fail_line "comparator infra error (exit $prc, see $probe_out)" ;;
    esac
}

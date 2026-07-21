# _lib.sh — shared plumbing for the wallet-differential harness (sourced, not run).
#
# Design: CORE-PARITY-AUDIT/_wallet-diff-harness-design-2026-07-20.md §5.
# House rule (auto-memory harness-script-consistency): per-impl scripts supply
# ONLY launch/RPC plumbing; every comparison lives in the ONE shared comparator
# (probe_address.py) driven off the ONE frozen corpus (vectors-address.json).
# A per-impl script may not weaken a comparison.
#
# An adapter (<impl>_walletdiff.sh) must, before calling walletdiff_address_main:
#   - set IMPL, BIN (impl binary path), BUILD_HINT (how to build it)
#   - set IMPL_RPC IMPL_P2P CORE_RPC CORE_P2P (from the reserved 22150-22199 block)
#   - set IMPL_DATADIR CORE_DATADIR (scratch under /tmp/walletdiff-*)
#   - set IMPL_COOKIE_CANDIDATES (array of possible cookie paths)
#   - define launch_impl()  — start the node in background, set IMPL_PID
#
# Summary-line contract (stdout, exactly one line; everything else stderr):
#   WALLETDIFF <impl>: PASS addr=8/8 desc=8/8
#   WALLETDIFF <impl>: FAIL addr=x/8 desc=y/8 first=<...>
#   WALLETDIFF <impl>: SKIP <build/RPC gap>            (runner GAP_RE -> SKIP)
#   WALLETDIFF <impl>: BLOCKED oracle drift <...>      (runner INFRA_RE -> INFRA)
# Exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CORE_BIN="$HASHHOG_ROOT/bitcoin-core/build/bin/bitcoind"
CORE_CLI="$HASHHOG_ROOT/bitcoin-core/build/bin/bitcoin-cli"
VECTORS="$WD_DIR/vectors-address.json"
PROBE="$WD_DIR/probe_address.py"
RESULTS_DIR="${WALLETDIFF_RESULTS_DIR:-$HASHHOG_ROOT/test-suite/results}"

IMPL_PID=""
CORE_BG=""

log()  { echo "[walletdiff:${IMPL:-?}] $*" >&2; }
pass_line() { echo "WALLETDIFF $IMPL: PASS $*"; exit 0; }
fail_line() { echo "WALLETDIFF $IMPL: FAIL $*"; exit 1; }
skip_line() { echo "WALLETDIFF $IMPL: SKIP $*"; exit 0; }
blocked_line() { echo "WALLETDIFF $IMPL: BLOCKED $*"; exit 1; }

# ── Cleanup: kill OUR pids only, stop OUR oracle, wipe OUR scratch. ─────────
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

# ── Core oracle launcher (lifted from test-suite/rbf/rustoshi_rbf.sh:376). ──
# Spawns bitcoind, waits for RPC; retries up to 5x on the early-exit port-bind
# race of back-to-back runs. Echoes the bg pid on success.
launch_core() {
    local dd="$1" rpc="$2" p2p="$3" lf="$4"; shift 4
    local attempt
    for attempt in 1 2 3 4 5; do
        local wait_n=0
        while fuser "${rpc}/tcp" >/dev/null 2>&1 && (( wait_n < 15 )); do
            sleep 1; wait_n=$((wait_n+1))
        done
        "$CORE_BIN" -regtest -datadir="$dd" -rpcport="$rpc" -port="$p2p" -listen=0 \
            "$@" >"$lf" 2>&1 &
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
walletdiff_address_main() {
    trap wd_cleanup EXIT INT TERM
    local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
    local impl_log="$IMPL_DATADIR/node.log"
    local core_log="$CORE_DATADIR/core.log"
    local probe_log_oracle="$IMPL_DATADIR/probe-oracle.out"
    local probe_log_impl="$IMPL_DATADIR/probe-impl.out"

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
    [[ -x "$CORE_BIN" ]] || skip_line "bitcoind not found at $CORE_BIN"
    [[ -x "$CORE_CLI" ]] || skip_line "bitcoin-cli not found at $CORE_CLI"
    [[ -s "$VECTORS" ]]  || fail_line "frozen corpus missing: $VECTORS"
    [[ -s "$PROBE" ]]    || fail_line "shared comparator missing: $PROBE"

    # 2. Launch the Core oracle.
    log "launching Core oracle rpc=:$CORE_RPC (regtest, -listen=0)"
    CORE_BG=$(launch_core "$CORE_DATADIR" "$CORE_RPC" "$CORE_P2P" "$core_log") \
        || fail_line "Core oracle failed to start within 120s (see $core_log)"
    local core_cookie="$CORE_DATADIR/regtest/.cookie"
    [[ -f "$core_cookie" ]] || fail_line "Core cookie not found at $core_cookie"
    log "Core oracle ready (pid=$CORE_BG)"

    # 3. Oracle sanity vs the FROZEN corpus. A mismatch here means the LOCAL
    #    Core build drifted from the minted vectors — that is BLOCKED (infra),
    #    never a SUT divergence (design §9).
    log "oracle sanity: replaying corpus against Core, comparing to frozen vectors"
    python3 "$PROBE" --role oracle --impl core --vectors "$VECTORS" \
        --url "http://127.0.0.1:$CORE_RPC/" --cookie-file "$core_cookie" \
        >"$probe_log_oracle" 2>&1
    local orc=$?
    cat "$probe_log_oracle" >&2
    if [[ $orc -ne 0 ]]; then
        # Wording must not trip the runner's GAP_RE (e.g. the token "rebuild").
        blocked_line "oracle drift — local Core no longer matches frozen vectors-address.json (probe exit $orc; re-mint deliberately via mint-vectors.sh after auditing the new Core build)"
    fi
    log "oracle matches frozen vectors"

    # 4. Launch the SUT (adapter-supplied plumbing).
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

    # 5. Replay the SAME corpus against the SUT via the SAME comparator.
    mkdir -p "$RESULTS_DIR" 2>/dev/null || true
    local results_json="$RESULTS_DIR/walletdiff-$IMPL-$ts.json"
    python3 "$PROBE" --role impl --impl "$IMPL" --vectors "$VECTORS" \
        --url "http://127.0.0.1:$IMPL_RPC/" --cookie-file "$cookie" \
        --results-out "$results_json" \
        >"$probe_log_impl" 2>&1
    local prc=$?
    cat "$probe_log_impl" >&2

    # 6. Verdict from the probe's SUMMARY line.
    local summary
    summary="$(grep '^SUMMARY ' "$probe_log_impl" | tail -n 1 | sed 's/^SUMMARY //')"
    case $prc in
        0)  [[ -n "$summary" ]] || fail_line "probe exit 0 but no SUMMARY line (see $probe_log_impl)"
            log "results receipt: $results_json"
            pass_line "$summary" ;;
        1)  [[ -n "$summary" ]] || summary="(no SUMMARY line)"
            log "results receipt: $results_json"
            fail_line "$summary" ;;
        2)  local gap
            gap="$(grep '^RPCGAP ' "$probe_log_impl" | tail -n 1 | sed 's/^RPCGAP //')"
            skip_line "${gap:-required RPC missing} — rebuild $IMPL ($BUILD_HINT)" ;;
        *)  fail_line "comparator infra error (exit $prc, see $probe_log_impl)" ;;
    esac
}

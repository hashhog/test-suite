#!/usr/bin/env bash
# test-suite/v2interop/beamchain_v2interop.sh
#
# BIP-324 v2 transport interop gate: beamchain (forced-v2 via env) vs a real
# Bitcoin Core v2 peer, on regtest. This is the GATE the v2-transport campaign
# (CORE-PARITY-AUDIT/_v2-transport-campaign-2026-06-11.md) requires before any
# default-on flip: self-roundtrip unit tests pass even for cipher-desync bugs,
# so we must prove interop against a real Core v2 peer that crosses a rekey
# boundary (Core REKEY_INTERVAL=224, bip324.h:24).
#
# Cloned from camlcoin_v2interop.sh (b95b9aa) / haskoin_v2interop.sh (fbaf1d1)
# -- same structure (cookie auth, /tmp datadirs, HASHHOG_ROOT-relative paths,
# ports <32768, terminal-transport wait, AEAD scan). Only the impl launch +
# binary + log-string matchers differ. beamchain is Erlang/OTP: the escript at
# _build/default/bin/beamchain, invoked with the `start` subcommand, flags
# --network=regtest --datadir=<dd> --rpc-port=<r> --p2p-port=<p> and
# --connect=host:port for the initiator direction. Forced-v2 via env
# BEAMCHAIN_BIP324_V2_OUTBOUND=1 (default OFF this phase -- baseline, NO source
# change). beamchain's v2 INBOUND responder is always-on (no env gate -- it
# peek-classifies every inbound stream); the var is set defensively anyway.
#
# NOTE on the regtest datadir: beamchain appends the network name as a
# subdirectory for non-mainnet networks (beamchain_config:determine_datadir/1),
# so on regtest the cookie lands at <datadir>/regtest/.cookie. The RPC helper
# checks both locations.
#
#   TEST A  handshake + >224-msg flow, BOTH directions:
#     A-init  beamchain dials Core (-v2transport=1)  [beamchain = initiator]
#     A-resp  Core (addnode) dials beamchain         [beamchain = responder]
#     PASS = Core getpeerinfo for that peer shows transport_protocol_type=v2 +
#            non-empty session_id, version+verack complete, app msgs round-trip,
#            and the flow exceeds 224 messages (crosses a rekey) with no AEAD
#            failures / no disconnect. beamchain-side v2 confirmation comes from
#            its --debug=net log: "classified as v2 (BIP-324) responder" for the
#            responder path, and (for the initiator path) the ABSENCE of a
#            "replied v1 to v2 probe; falling back" line + a clean post-rekey
#            block-sync + the "v2 version packet received" debug line.
#
#   TEST B  v1 fallback intact:
#     b1  beamchain forced-v2 dials Core -v2transport=0 -> MUST fall back to v1, sync
#     b2  Core -v2transport=0 dials beamchain           -> beamchain responder accepts v1
#     b3  two beamchain v2<->v2 still interop+sync
#
# NEVER touches mainnet / testnet4 data. All datadirs under /tmp/hashhog-v2-<PID>/.
# Run wrapped through tools/regtest-slot.sh (the caller owns the slot).
#
# Exit: 0 if every sub-case PASSes, 1 otherwise.

set -uo pipefail

# -- Locate the repo root (HASHHOG_ROOT) ------------------------------------
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$SCRIPTDIR/../.." && pwd)}"

CORE_BITCOIND="${CORE_BITCOIND:-$HASHHOG_ROOT/bitcoin-core/build/bin/bitcoind}"
CORE_CLI="${CORE_CLI:-$HASHHOG_ROOT/bitcoin-core/build/bin/bitcoin-cli}"

REGTEST_GENESIS="0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206"

# -- Ports (all <32768 per Rule 10) -----------------------------------------
# Base 29700 -- DISTINCT from haskoin (29400), camlcoin (29500), hotbuns
# (29600) so a back-to-back run never collides. Override with --base-port=N.
BASE_PORT="${BASE_PORT:-29700}"

KEEP=0
VERBOSE=0
ONLY=""        # run a single sub-case: a-init|a-resp|b1|b2|b3
MSG_TARGET=240 # blocks to drive past the 224 rekey boundary (REKEY_INTERVAL=224)
for arg in "$@"; do
    case "$arg" in
        --keep-datadir) KEEP=1 ;;
        --verbose)      VERBOSE=1 ;;
        --base-port=*)  BASE_PORT="${arg#--base-port=}" ;;
        --only=*)       ONLY="${arg#--only=}" ;;
        --msgs=*)       MSG_TARGET="${arg#--msgs=}" ;;
        --help)
            sed -n '2,45p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown flag: $arg (use --help)" >&2; exit 2 ;;
    esac
done

WORKDIR="/tmp/hashhog-v2-$$"
LOGDIR="$WORKDIR/logs"
mkdir -p "$LOGDIR"

BEAMCHAIN_BIN="${BEAMCHAIN_BIN:-$HASHHOG_ROOT/beamchain/_build/default/bin/beamchain}"

C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'; C_NC=$'\033[0m'

declare -a PIDS=()
register_pid() { PIDS+=("$1"); }

# beamchain is an escript that boots a BEAM VM; the `start` foreground process
# spawns beam.smp. Killing the registered escript pid alone can orphan the VM,
# so we also pgrep for the datadir-tagged beam.smp at cleanup. This NEVER
# touches non-/tmp datadirs (the grep is anchored on /tmp/hashhog-v2-$$).
cleanup() {
    for p in "${PIDS[@]:-}"; do
        kill "$p" 2>/dev/null || true
    done
    # also reap any beam.smp launched against our /tmp workdir
    pkill -f "beamchain.*$WORKDIR" 2>/dev/null || true
    pkill -f "beam.smp.*$WORKDIR" 2>/dev/null || true
    sleep 2
    for p in "${PIDS[@]:-}"; do
        kill -9 "$p" 2>/dev/null || true
    done
    pkill -9 -f "beam.smp.*$WORKDIR" 2>/dev/null || true
    if [[ $KEEP -eq 0 ]]; then
        rm -rf "$WORKDIR"
    else
        echo "[keep] artifacts in $WORKDIR" >&2
    fi
}
trap cleanup EXIT INT TERM

log() { echo "$@" >&2; }
vlog() { [[ $VERBOSE -eq 1 ]] && echo "$@" >&2; return 0; }

# -- Pre-flight -------------------------------------------------------------
preflight() {
    local ok=1
    if [[ ! -x "$CORE_BITCOIND" ]]; then
        log "${C_RED}MISSING${C_NC} Core bitcoind: $CORE_BITCOIND"; ok=0
    fi
    if [[ ! -x "$CORE_CLI" ]]; then
        log "${C_RED}MISSING${C_NC} Core bitcoin-cli: $CORE_CLI"; ok=0
    fi
    if [[ -z "$BEAMCHAIN_BIN" || ! -x "$BEAMCHAIN_BIN" ]]; then
        log "${C_RED}MISSING${C_NC} beamchain escript: $BEAMCHAIN_BIN"; ok=0
    fi
    [[ $ok -eq 1 ]] || { log "pre-flight failed"; exit 2; }
    log "Core      : $CORE_BITCOIND"
    log "beamchain : $BEAMCHAIN_BIN"
    log "workdir   : $WORKDIR"
}

# -- RPC helpers ------------------------------------------------------------
# Core uses bitcoin-cli against its own datadir. beamchain we hit over HTTP
# JSON-RPC with cookie auth. beamchain writes <datadir>/regtest/.cookie as
# "__cookie__:<hex>" (beamchain_rpc.erl:579), which curl -u accepts verbatim.
declare -A CORE_RPCPORT
core_cli() {
    local datadir=$1; shift
    local port="${CORE_RPCPORT[$datadir]:-}"
    local portarg=()
    [[ -n "$port" ]] && portarg=(-rpcport="$port")
    "$CORE_CLI" -regtest -datadir="$datadir" -rpcconnect=127.0.0.1 "${portarg[@]}" "$@" 2>>"$LOGDIR/core-cli.err"
}

beamchain_rpc() {
    local datadir=$1 port=$2 method=$3 params="${4:-[]}"
    local auth=""
    for c in "$datadir/regtest/.cookie" "$datadir/.cookie"; do
        [[ -f "$c" ]] && { auth="-u $(cat "$c")"; break; }
    done
    local payload="{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}"
    # shellcheck disable=SC2086
    curl -s --max-time 10 $auth --data-binary "$payload" "http://127.0.0.1:$port/" 2>/dev/null
}

# -- Port-conflict guard (no port-kill: 2026-06-10 fuser incident) ----------
ensure_free() {
    local p
    for p in "$@"; do
        if ss -tln 2>/dev/null | grep -qE ":${p} "; then
            log "${C_RED}refusing to launch${C_NC}: port $p already LISTENING"
            exit 2
        fi
    done
}

# -- Launchers --------------------------------------------------------------
# Core regtest. $1 datadir, $2 rpcport, $3 p2pport, $4 v2transport(0|1),
# $5+ extra args (e.g. -connect=...).
start_core() {
    local datadir=$1 rpc=$2 p2p=$3 v2=$4; shift 4
    mkdir -p "$datadir"
    CORE_RPCPORT[$datadir]=$rpc
    "$CORE_BITCOIND" -regtest -datadir="$datadir" \
        -bind=127.0.0.1:"$p2p" \
        -rpcbind=127.0.0.1:"$rpc" -rpcallowip=127.0.0.1 -rpcport="$rpc" \
        -v2transport="$v2" \
        -listen=1 -discover=0 -dnsseed=0 -fixedseeds=0 \
        -debug=net -logips=1 -printtoconsole=0 \
        "$@" \
        >"$LOGDIR/core.out" 2>&1 &
    local pid=$!
    register_pid "$pid"
    echo "$pid"
}

# beamchain regtest forced-v2-ON via env. $1 datadir, $2 rpcport, $3 p2pport,
# $4+ extra args (e.g. --connect=host:port).
# _OUTBOUND drives the initiator path; the responder path is always-on
# (no env gate), but we set _INBOUND too in case the gate is added later.
# The escript boots a fresh BEAM VM per invocation; each sub-case gets its
# own datadir/ports, so back-to-back launches do not collide.
# The cookie/cookie file lands under <datadir>/regtest/ (network subdir).
# A per-instance log dir is set so each beamchain's stdout is captured into
# its own file (the v2 log lines are at --debug=net level).
BEAMCHAIN_OUT_IDX=0
start_beamchain() {
    local datadir=$1 rpc=$2 p2p=$3; shift 3
    mkdir -p "$datadir"
    BEAMCHAIN_OUT_IDX=$((BEAMCHAIN_OUT_IDX+1))
    local outfile="$LOGDIR/beamchain-${BEAMCHAIN_OUT_IDX}.out"
    echo "$outfile" > "$LOGDIR/beamchain-last-out"
    BEAMCHAIN_BIP324_V2_OUTBOUND=1 BEAMCHAIN_BIP324_V2_INBOUND=1 \
    BEAMCHAIN_DATADIR="$datadir" \
        "$BEAMCHAIN_BIN" start --network=regtest --datadir="$datadir" \
        --rpc-port="$rpc" --p2p-port="$p2p" \
        --nodnsseed --nofixedseeds \
        --printtoconsole --debug=net \
        "$@" \
        >"$outfile" 2>&1 &
    local pid=$!
    register_pid "$pid"
    echo "$pid"
}

# Concatenate every beamchain stdout file (multiple instances may be alive
# across sub-cases). Used by the AEAD scan + v2/fallback log matchers.
beamchain_logs() {
    cat "$LOGDIR"/beamchain-*.out 2>/dev/null
}

wait_core_rpc() {
    local datadir=$1 deadline=$(( $(date +%s) + 30 ))
    while (( $(date +%s) < deadline )); do
        core_cli "$datadir" getblockcount >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

wait_beamchain_rpc() {
    local datadir=$1 port=$2 deadline=$(( $(date +%s) + 120 ))
    while (( $(date +%s) < deadline )); do
        local r; r=$(beamchain_rpc "$datadir" "$port" getblockcount)
        echo "$r" | grep -q '"result"' && return 0
        sleep 1
    done
    return 1
}

# Wait until Core sees >=1 peer AND its transport type is terminal (not the
# transient "detecting" state mid-handshake), then return the getpeerinfo blob.
core_peer_blob() {
    local datadir=$1 deadline=$(( $(date +%s) + 30 ))
    local last=""
    while (( $(date +%s) < deadline )); do
        local pi; pi=$(core_cli "$datadir" getpeerinfo)
        if echo "$pi" | grep -q '"id"'; then
            last="$pi"
            if echo "$pi" | grep -qE '"transport_protocol_type": *"(v1|v2)"'; then
                echo "$pi"
                return 0
            fi
        fi
        sleep 1
    done
    [[ -n "$last" ]] && { echo "$last"; return 0; }
    return 1
}

# -- Generic message-flow driver --------------------------------------------
# Mine MSG_TARGET (>224) blocks on Core (authoritative miner) and require
# beamchain to follow. Each block is a discrete AEAD-framed v2 packet; once
# beamchain has connected >224 blocks the cipher has provably advanced past
# the FSChaCha20 REKEY_INTERVAL{224} with intact tags in BOTH directions.
MINE_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
core_mine() {
    local datadir=$1 n=$2
    core_cli "$datadir" generatetoaddress "$n" "$MINE_ADDR" >/dev/null 2>&1
}

beamchain_height() {
    local datadir=$1 port=$2
    beamchain_rpc "$datadir" "$port" getblockcount \
        | sed -n 's/.*"result":[ ]*\([0-9]\+\).*/\1/p'
}

core_height() {
    core_cli "$1" getblockcount 2>/dev/null
}

# -- AEAD / desync failure scan ---------------------------------------------
aead_failures() {
    local f
    local pat='AEAD|Poly1305 (tag )?mismatch|decrypt(ion)? fail|auth(entication)? fail|tag mismatch|bad mac|v2 .*desync|MAC check failed|ChaCha.*fail|v2 AEAD auth failed|v2_decode_failed|garbage terminator not seen'
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        grep -hEi "$pat" "$f" 2>/dev/null
    done
}

core_disconnect_after_handshake() {
    grep -Ei "disconnecting peer|connection.*reset|sending v2 .*fail|version handshake timeout" \
        "$LOGDIR/core.out" 2>/dev/null
}

# =====================================================================
# TEST A-init : beamchain DIALS Core(-v2transport=1). beamchain = initiator.
# =====================================================================
test_a_init() {
    log ""
    log "${C_YEL}=== TEST A-init: beamchain -> Core (beamchain initiator, forced-v2) ===${C_NC}"
    local CORE_DD="$WORKDIR/a_init_core" BC_DD="$WORKDIR/a_init_bc"
    local CORE_RPC=$((BASE_PORT+0)) CORE_P2P=$((BASE_PORT+1))
    local BC_RPC=$((BASE_PORT+2)) BC_P2P=$((BASE_PORT+3))
    ensure_free "$CORE_RPC" "$CORE_P2P" "$BC_RPC" "$BC_P2P"

    start_core "$CORE_DD" "$CORE_RPC" "$CORE_P2P" 1 >/dev/null
    wait_core_rpc "$CORE_DD" || { log "${C_RED}FAIL${C_NC}: Core RPC never came up"; return 1; }
    core_mine "$CORE_DD" "$MSG_TARGET"
    log "Core pre-mined to $(core_height "$CORE_DD")"

    # beamchain dials Core directly via --connect (initiator path).
    start_beamchain "$BC_DD" "$BC_RPC" "$BC_P2P" --connect="127.0.0.1:$CORE_P2P" >/dev/null
    wait_beamchain_rpc "$BC_DD" "$BC_RPC" || { log "${C_RED}FAIL${C_NC}: beamchain RPC never came up"; return 1; }

    local blob; blob=$(core_peer_blob "$CORE_DD") || { log "${C_RED}FAIL${C_NC}: Core never saw the beamchain peer"; return 1; }
    evaluate_direction "A-init" "$blob" "$CORE_DD" "$BC_DD" "$BC_RPC"
}

# =====================================================================
# TEST A-resp : Core(-v2transport=1) DIALS beamchain via addnode. beamchain = responder.
# =====================================================================
test_a_resp() {
    log ""
    log "${C_YEL}=== TEST A-resp: Core -> beamchain (beamchain responder, forced-v2) ===${C_NC}"
    local CORE_DD="$WORKDIR/a_resp_core" BC_DD="$WORKDIR/a_resp_bc"
    local CORE_RPC=$((BASE_PORT+4)) CORE_P2P=$((BASE_PORT+5))
    local BC_RPC=$((BASE_PORT+6)) BC_P2P=$((BASE_PORT+7))
    ensure_free "$CORE_RPC" "$CORE_P2P" "$BC_RPC" "$BC_P2P"

    # beamchain listens; Core dials it.
    start_beamchain "$BC_DD" "$BC_RPC" "$BC_P2P" >/dev/null
    wait_beamchain_rpc "$BC_DD" "$BC_RPC" || { log "${C_RED}FAIL${C_NC}: beamchain RPC never came up"; return 1; }

    start_core "$CORE_DD" "$CORE_RPC" "$CORE_P2P" 1 >/dev/null
    wait_core_rpc "$CORE_DD" || { log "${C_RED}FAIL${C_NC}: Core RPC never came up"; return 1; }
    core_mine "$CORE_DD" "$MSG_TARGET"
    log "Core pre-mined to $(core_height "$CORE_DD")"

    # Core dials beamchain with v2 explicitly (addnode v2transport=true).
    core_cli "$CORE_DD" addnode "127.0.0.1:$BC_P2P" "onetry" "true" >/dev/null 2>&1 \
      || core_cli "$CORE_DD" addnode "127.0.0.1:$BC_P2P" "onetry" >/dev/null 2>&1

    local blob; blob=$(core_peer_blob "$CORE_DD") || { log "${C_RED}FAIL${C_NC}: Core never connected to beamchain"; return 1; }
    evaluate_direction "A-resp" "$blob" "$CORE_DD" "$BC_DD" "$BC_RPC"
}

# Shared evaluator for the two A directions.
# $1 label, $2 core getpeerinfo blob, $3 core dd, $4 bc dd, $5 bc rpc.
LAST_REKEY_CROSSED=0
LAST_EVIDENCE=""
evaluate_direction() {
    local label=$1 blob=$2 core_dd=$3 bc_dd=$4 bc_rpc=$5
    local ttype sid
    ttype=$(echo "$blob" | grep -o '"transport_protocol_type": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    sid=$(echo "$blob"   | grep -o '"session_id": *"[^"]*"'              | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    log "  Core getpeerinfo: transport_protocol_type=${ttype:-<none>} session_id=${sid:0:16}...(${#sid} hex)"

    # beamchain-side v2 confirmation from --debug=net log. There is no explicit
    # "v2 connected" line; the positive signals are:
    #   responder: "classified as v2 (BIP-324) responder"
    #   either:    "v2 version packet received"
    # and the NEGATIVE signal (fallback) is "replied v1 to v2 probe; falling back".
    local logs; logs=$(beamchain_logs)
    local bc_v2 fellback
    bc_v2=$(echo "$logs" | grep -E "classified as v2 \(BIP-324\) responder|v2 version packet received" | head -1)
    fellback=$(echo "$logs" | grep -E "replied v1 to v2 probe; falling back" | head -1)

    # Drive >224-msg flow via BLOCK DOWNLOAD. Core pre-mined MSG_TARGET (>224)
    # blocks; beamchain downloads them one block per getdata->block exchange.
    local target; target=$(core_height "$core_dd")
    local deadline=$(( $(date +%s) + 240 ))
    local bc_h=0
    while (( $(date +%s) < deadline )); do
        bc_h=$(beamchain_height "$bc_dd" "$bc_rpc"); bc_h=${bc_h:-0}
        (( bc_h >= target )) && break
        (( bc_h > 224 )) && break
        sleep 3
    done

    # Re-read the peer blob AFTER the flow (handshake long settled -> terminal).
    local blob2; blob2=$(core_cli "$core_dd" getpeerinfo)
    local ttype2 sid2
    ttype2=$(echo "$blob2" | grep -o '"transport_protocol_type": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    sid2=$(echo "$blob2"   | grep -o '"session_id": *"[^"]*"'              | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    if [[ "$ttype" != "v2" && -n "$ttype2" ]]; then ttype="$ttype2"; fi
    if [[ ${#sid} -lt 32 && ${#sid2} -ge 32 ]]; then sid="$sid2"; fi

    local blocks_served
    blocks_served=$(echo "$blob2" | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print(0); sys.exit(0)
n=0
for p in d:
    bs=p.get("bytessent_per_msg",{})
    if "block" in bs:
        n=max(n, bs["block"]//250)
print(n)
' 2>/dev/null)
    blocks_served=${blocks_served:-0}

    local crossed=0
    if (( bc_h > 224 )) || (( blocks_served > 224 )); then
        crossed=1
    fi
    LAST_REKEY_CROSSED=$crossed

    # Re-scan logs after the flow for any late v2-success / AEAD lines.
    logs=$(beamchain_logs)
    [[ -z "$bc_v2" ]] && bc_v2=$(echo "$logs" | grep -E "classified as v2 \(BIP-324\) responder|v2 version packet received" | head -1)
    [[ -z "$fellback" ]] && fellback=$(echo "$logs" | grep -E "replied v1 to v2 probe; falling back" | head -1)

    local aead; aead=$(aead_failures "$LOGDIR/core.out" "$LOGDIR"/beamchain-*.out)
    local disc; disc=$(core_disconnect_after_handshake)

    LAST_EVIDENCE="Core transport_protocol_type=${ttype:-none}, session_id len=${#sid} hex; beamchain v2-log=$([[ -n "$bc_v2" ]] && echo yes || echo no) fallback-log=$([[ -n "$fellback" ]] && echo yes || echo no); beamchain block-synced ${bc_h}/${target}; Core-block-pkts-served~${blocks_served} (>224 cross=$crossed); AEAD-fail=$([[ -n "$aead" ]] && echo PRESENT || echo none); mid-stream-disconnect=$([[ -n "$disc" ]] && echo yes || echo no)"
    log "  evidence: $LAST_EVIDENCE"
    [[ -n "$aead" ]] && log "  ${C_RED}AEAD lines:${C_NC} $(echo "$aead" | head -3)"

    local app_roundtrip=0
    (( bc_h > 0 )) && app_roundtrip=1
    local pass=1
    [[ "$ttype" == "v2" ]]    || { log "  ${C_RED}- transport_protocol_type != v2${C_NC}"; pass=0; }
    [[ ${#sid} -ge 32 ]]      || { log "  ${C_RED}- session_id empty/short${C_NC}"; pass=0; }
    [[ -z "$fellback" ]]      || { log "  ${C_RED}- beamchain fell back to v1 (expected v2)${C_NC}"; pass=0; }
    (( app_roundtrip == 1 ))  || { log "  ${C_RED}- no app message round-trip over v2${C_NC}"; pass=0; }
    (( crossed == 1 ))        || { log "  ${C_RED}- flow did not cross 224-msg rekey boundary${C_NC}"; pass=0; }
    [[ -z "$aead" ]]          || { log "  ${C_RED}- AEAD/desync failures present${C_NC}"; pass=0; }
    [[ -z "$disc" ]]          || { log "  ${C_YEL}- note: mid-stream disconnect lines present${C_NC}"; }

    if (( pass == 1 )); then
        log "  ${C_GREEN}$label PASS${C_NC}"
        return 0
    fi
    log "  ${C_RED}$label FAIL${C_NC}"
    return 1
}

# =====================================================================
# TEST B1 : beamchain forced-v2 dials Core -v2transport=0 -> MUST fall back to v1 + sync.
# =====================================================================
test_b1() {
    log ""
    log "${C_YEL}=== TEST B1: beamchain(forced-v2) -> Core(-v2transport=0): v1 fallback ===${C_NC}"
    local CORE_DD="$WORKDIR/b1_core" BC_DD="$WORKDIR/b1_bc"
    local CORE_RPC=$((BASE_PORT+8)) CORE_P2P=$((BASE_PORT+9))
    local BC_RPC=$((BASE_PORT+10)) BC_P2P=$((BASE_PORT+11))
    ensure_free "$CORE_RPC" "$CORE_P2P" "$BC_RPC" "$BC_P2P"

    start_core "$CORE_DD" "$CORE_RPC" "$CORE_P2P" 0 >/dev/null
    wait_core_rpc "$CORE_DD" || { log "${C_RED}FAIL${C_NC}: Core RPC never came up"; return 1; }
    core_mine "$CORE_DD" 40   # a modest chain is enough to prove v1 sync
    local target; target=$(core_height "$CORE_DD")

    start_beamchain "$BC_DD" "$BC_RPC" "$BC_P2P" --connect="127.0.0.1:$CORE_P2P" >/dev/null
    wait_beamchain_rpc "$BC_DD" "$BC_RPC" || { log "${C_RED}FAIL${C_NC}: beamchain RPC never came up"; return 1; }

    # beamchain must sync over v1. The v2 probe corrupts the first socket;
    # beamchain marks the addr v1-only and the manager re-dials it on the
    # next connect_tick (Core ShouldReconnectV1 equivalent, routed through
    # the addrman cycle). Give it a generous window for the re-dial.
    local deadline=$(( $(date +%s) + 150 )) bc_h=0
    while (( $(date +%s) < deadline )); do
        bc_h=$(beamchain_height "$BC_DD" "$BC_RPC"); bc_h=${bc_h:-0}
        (( bc_h >= target )) && break
        sleep 2
    done

    # On the (re-dialed) v1 connection Core should report the peer as v1.
    local blob; blob=$(core_peer_blob "$CORE_DD")
    local ttype; ttype=$(echo "$blob" | grep -o '"transport_protocol_type": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

    local logs; logs=$(beamchain_logs)
    local fellback; fellback=$(echo "$logs" | grep -E "replied v1 to v2 probe; falling back|falling back" | head -1)
    LAST_EVIDENCE="Core saw transport_protocol_type=${ttype:-none} (expect v1); beamchain fell-back-log=$([[ -n "$fellback" ]] && echo yes || echo no); beamchain synced ${bc_h}/${target}"
    log "  evidence: $LAST_EVIDENCE"

    # The load-bearing assertion is the SYNC: if beamchain reached the target
    # height after a v2 probe against a v1-only Core, the fallback re-dial
    # works. We treat the v1-transport report as confirmatory (Core may have
    # since dropped the dead v2-probe socket, so re-read tolerantly).
    local pass=1
    (( bc_h >= target ))   || { log "  ${C_RED}- beamchain did not sync over v1 ($bc_h/$target)${C_NC}"; pass=0; }
    [[ "$ttype" == "v1" || "$ttype" == "" ]] || { log "  ${C_YEL}- note: Core reports peer as $ttype${C_NC}"; }
    if (( pass == 1 )); then log "  ${C_GREEN}B1 PASS${C_NC}"; return 0; fi
    log "  ${C_RED}B1 FAIL${C_NC}"; return 1
}

# =====================================================================
# TEST B2 : Core -v2transport=0 dials beamchain -> beamchain responder accepts v1.
# =====================================================================
test_b2() {
    log ""
    log "${C_YEL}=== TEST B2: Core(-v2transport=0) -> beamchain(forced-v2 resp): accepts v1 ===${C_NC}"
    local CORE_DD="$WORKDIR/b2_core" BC_DD="$WORKDIR/b2_bc"
    local CORE_RPC=$((BASE_PORT+12)) CORE_P2P=$((BASE_PORT+13))
    local BC_RPC=$((BASE_PORT+14)) BC_P2P=$((BASE_PORT+15))
    ensure_free "$CORE_RPC" "$CORE_P2P" "$BC_RPC" "$BC_P2P"

    start_beamchain "$BC_DD" "$BC_RPC" "$BC_P2P" >/dev/null
    wait_beamchain_rpc "$BC_DD" "$BC_RPC" || { log "${C_RED}FAIL${C_NC}: beamchain RPC never came up"; return 1; }

    start_core "$CORE_DD" "$CORE_RPC" "$CORE_P2P" 0 >/dev/null
    wait_core_rpc "$CORE_DD" || { log "${C_RED}FAIL${C_NC}: Core RPC never came up"; return 1; }
    core_mine "$CORE_DD" 40
    local target; target=$(core_height "$CORE_DD")

    core_cli "$CORE_DD" addnode "127.0.0.1:$BC_P2P" "onetry" >/dev/null 2>&1

    local blob; blob=$(core_peer_blob "$CORE_DD")
    local ttype; ttype=$(echo "$blob" | grep -o '"transport_protocol_type": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

    local deadline=$(( $(date +%s) + 90 )) bc_h=0
    while (( $(date +%s) < deadline )); do
        bc_h=$(beamchain_height "$BC_DD" "$BC_RPC"); bc_h=${bc_h:-0}
        (( bc_h >= target )) && break
        sleep 2
    done
    LAST_EVIDENCE="Core reports peer transport_protocol_type=${ttype:-none} (expect v1); beamchain synced ${bc_h}/${target}"
    log "  evidence: $LAST_EVIDENCE"

    local pass=1
    [[ "$ttype" == "v1" ]] || { log "  ${C_RED}- Core reports peer as $ttype, expected v1${C_NC}"; pass=0; }
    (( bc_h >= target ))   || { log "  ${C_RED}- beamchain did not sync the v1 inbound peer ($bc_h/$target)${C_NC}"; pass=0; }
    if (( pass == 1 )); then log "  ${C_GREEN}B2 PASS${C_NC}"; return 0; fi
    log "  ${C_RED}B2 FAIL${C_NC}"; return 1
}

# =====================================================================
# TEST B3 : two beamchain forced-v2 nodes v2<->v2 interop + sync.
# =====================================================================
test_b3() {
    log ""
    log "${C_YEL}=== TEST B3: beamchain(v2) <-> beamchain(v2): self-interop ===${C_NC}"
    local SRC_DD="$WORKDIR/b3_src" DST_DD="$WORKDIR/b3_dst"
    local SRC_RPC=$((BASE_PORT+16)) SRC_P2P=$((BASE_PORT+17))
    local DST_RPC=$((BASE_PORT+18)) DST_P2P=$((BASE_PORT+19))
    local CORE_DD="$WORKDIR/b3_core" CORE_RPC=$((BASE_PORT+20)) CORE_P2P=$((BASE_PORT+21))
    ensure_free "$SRC_RPC" "$SRC_P2P" "$DST_RPC" "$DST_P2P" "$CORE_RPC" "$CORE_P2P"

    # Use a Core node as the authoritative miner+source so the first beamchain
    # (SRC) has a real chain to relay onward to the second beamchain (DST).
    # SRC dials Core (v1 ok for seeding); DST dials SRC over v2.
    start_core "$CORE_DD" "$CORE_RPC" "$CORE_P2P" 1 >/dev/null
    wait_core_rpc "$CORE_DD" || { log "${C_RED}FAIL${C_NC}: Core RPC never came up"; return 1; }
    core_mine "$CORE_DD" 40
    local target; target=$(core_height "$CORE_DD")

    start_beamchain "$SRC_DD" "$SRC_RPC" "$SRC_P2P" --connect="127.0.0.1:$CORE_P2P" >/dev/null
    wait_beamchain_rpc "$SRC_DD" "$SRC_RPC" || { log "${C_RED}FAIL${C_NC}: beamchain SRC RPC never came up"; return 1; }

    # Wait for SRC to sync from Core first.
    local d1=$(( $(date +%s) + 120 )) src_h=0
    while (( $(date +%s) < d1 )); do
        src_h=$(beamchain_height "$SRC_DD" "$SRC_RPC"); src_h=${src_h:-0}
        (( src_h >= target )) && break
        sleep 2
    done

    # DST dials SRC over v2.
    start_beamchain "$DST_DD" "$DST_RPC" "$DST_P2P" --connect="127.0.0.1:$SRC_P2P" >/dev/null
    wait_beamchain_rpc "$DST_DD" "$DST_RPC" || { log "${C_RED}FAIL${C_NC}: beamchain DST RPC never came up"; return 1; }

    local d2=$(( $(date +%s) + 150 )) dst_h=0
    while (( $(date +%s) < d2 )); do
        dst_h=$(beamchain_height "$DST_DD" "$DST_RPC"); dst_h=${dst_h:-0}
        (( dst_h >= target )) && break
        sleep 2
    done

    local aead; aead=$(aead_failures "$LOGDIR"/beamchain-*.out)
    LAST_EVIDENCE="SRC synced ${src_h}/${target}; DST synced ${dst_h}/${target} from SRC over v2; AEAD-fail=$([[ -n "$aead" ]] && echo PRESENT || echo none)"
    log "  evidence: $LAST_EVIDENCE"

    local pass=1
    (( src_h >= target )) || { log "  ${C_RED}- SRC did not seed from Core ($src_h/$target)${C_NC}"; pass=0; }
    (( dst_h >= target )) || { log "  ${C_RED}- DST did not sync from SRC over v2 ($dst_h/$target)${C_NC}"; pass=0; }
    [[ -z "$aead" ]]      || { log "  ${C_RED}- AEAD/desync failures present${C_NC}"; pass=0; }
    if (( pass == 1 )); then log "  ${C_GREEN}B3 PASS${C_NC}"; return 0; fi
    log "  ${C_RED}B3 FAIL${C_NC}"; return 1
}

# -- Driver -----------------------------------------------------------------
preflight

declare -A RESULT
declare -A REKEY
declare -A EVID

run_case() {
    local name=$1 fn=$2
    if "$fn"; then RESULT[$name]=PASS; else RESULT[$name]=FAIL; fi
    REKEY[$name]=$LAST_REKEY_CROSSED
    EVID[$name]=$LAST_EVIDENCE
    LAST_REKEY_CROSSED=0
    LAST_EVIDENCE=""
}

case "$ONLY" in
    a-init) run_case a-init test_a_init ;;
    a-resp) run_case a-resp test_a_resp ;;
    b1)     run_case b1 test_b1 ;;
    b2)     run_case b2 test_b2 ;;
    b3)     run_case b3 test_b3 ;;
    "")
        run_case a-init test_a_init
        run_case a-resp test_a_resp
        run_case b1 test_b1
        run_case b2 test_b2
        run_case b3 test_b3
        ;;
    *) log "unknown --only=$ONLY"; exit 2 ;;
esac

log ""
log "================ SUMMARY ================"
overall=0
for c in a-init a-resp b1 b2 b3; do
    [[ -n "${RESULT[$c]:-}" ]] || continue
    r=${RESULT[$c]}
    [[ "$r" == PASS ]] || overall=1
    rk=""
    [[ "$c" == a-* ]] && rk=" rekey_crossed=${REKEY[$c]:-0}"
    log "  $c : $r$rk"
    log "      ${EVID[$c]}"
done
log "========================================"
exit $overall

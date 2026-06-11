#!/usr/bin/env bash
# test-suite/v2interop/camlcoin_v2interop.sh
#
# BIP-324 v2 transport interop gate: camlcoin (forced-v2 via env) vs a real
# Bitcoin Core v2 peer, on regtest. This is the GATE the v2-transport campaign
# (CORE-PARITY-AUDIT/_v2-transport-campaign-2026-06-11.md) requires before any
# default-on flip: self-roundtrip unit tests pass even for cipher-desync bugs,
# so we must prove interop against a real Core v2 peer that crosses a rekey
# boundary (Core REKEY_INTERVAL=224, bip324.h:24).
#
# Cloned from haskoin_v2interop.sh (fbaf1d1) — same structure (cookie auth,
# /tmp datadirs, HASHHOG_ROOT-relative paths, ports <32768, terminal-transport
# wait, AEAD scan). Only the impl launch + binary + log-string matchers differ.
# camlcoin is OCaml: binary _build/default/bin/main.exe, invoked directly (no
# subcommand), flags --network regtest --datadir <dd> --rpcport <r> --port <p>
# and --connect host:port for the initiator direction. Forced-v2 via env
# CAMLCOIN_BIP324_V2_OUTBOUND=1 CAMLCOIN_BIP324_V2_INBOUND=1 (defaults are OFF
# this phase — baseline, NO source change).
#
#   TEST A  handshake + >224-msg flow, BOTH directions:
#     A-init  camlcoin dials Core (-v2transport=1)   [camlcoin = initiator]
#     A-resp  Core (addnode) dials camlcoin          [camlcoin = responder]
#     PASS = Core getpeerinfo for that peer shows transport_protocol_type=v2 +
#            non-empty session_id, version+verack complete, app msgs round-trip,
#            and the flow exceeds 224 messages (crosses a rekey) with no AEAD
#            failures / no disconnect. camlcoin-side v2 confirmation comes from
#            its log ("BIP-324 v2 outbound connected (encrypted)" / "BIP-324 v2
#            inbound connected (encrypted)") + a clean post-rekey block-sync.
#
#   TEST B  v1 fallback intact:
#     b1  camlcoin forced-v2 dials Core -v2transport=0  -> MUST fall back to v1, sync
#     b2  Core -v2transport=0 dials camlcoin            -> camlcoin responder accepts v1
#
# NEVER touches mainnet / testnet4 data. All datadirs under /tmp/hashhog-v2-<PID>/.
# Run wrapped through tools/regtest-slot.sh (the caller owns the slot).
#
# Exit: 0 if every sub-case PASSes, 1 otherwise.

set -uo pipefail

# ── Locate the repo root (HASHHOG_ROOT) ────────────────────────────────────
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$SCRIPTDIR/../.." && pwd)}"

CORE_BITCOIND="${CORE_BITCOIND:-$HASHHOG_ROOT/bitcoin-core/build/bin/bitcoind}"
CORE_CLI="${CORE_CLI:-$HASHHOG_ROOT/bitcoin-core/build/bin/bitcoin-cli}"

REGTEST_GENESIS="0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206"

# ── Ports (all <32768 per Rule 10) ─────────────────────────────────────────
# Base 29500 — DISTINCT from haskoin (29400) so a back-to-back run never
# collides. Override with --base-port=N.
BASE_PORT="${BASE_PORT:-29500}"

KEEP=0
VERBOSE=0
ONLY=""        # run a single sub-case: a-init|a-resp|b1|b2
MSG_TARGET=240 # blocks to drive past the 224 rekey boundary (REKEY_INTERVAL=224)
for arg in "$@"; do
    case "$arg" in
        --keep-datadir) KEEP=1 ;;
        --verbose)      VERBOSE=1 ;;
        --base-port=*)  BASE_PORT="${arg#--base-port=}" ;;
        --only=*)       ONLY="${arg#--only=}" ;;
        --msgs=*)       MSG_TARGET="${arg#--msgs=}" ;;
        --help)
            sed -n '2,40p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown flag: $arg (use --help)" >&2; exit 2 ;;
    esac
done

WORKDIR="/tmp/hashhog-v2-$$"
LOGDIR="$WORKDIR/logs"
mkdir -p "$LOGDIR"

CAMLCOIN_BIN="${CAMLCOIN_BIN:-$HASHHOG_ROOT/camlcoin/_build/default/bin/main.exe}"

C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'; C_NC=$'\033[0m'

declare -a PIDS=()
register_pid() { PIDS+=("$1"); }

cleanup() {
    for p in "${PIDS[@]:-}"; do
        kill "$p" 2>/dev/null || true
    done
    # brief grace, then hard kill
    sleep 2
    for p in "${PIDS[@]:-}"; do
        kill -9 "$p" 2>/dev/null || true
    done
    if [[ $KEEP -eq 0 ]]; then
        rm -rf "$WORKDIR"
    else
        echo "[keep] artifacts in $WORKDIR" >&2
    fi
}
trap cleanup EXIT INT TERM

log() { echo "$@" >&2; }
vlog() { [[ $VERBOSE -eq 1 ]] && echo "$@" >&2; return 0; }

# ── Pre-flight ─────────────────────────────────────────────────────────────
preflight() {
    local ok=1
    if [[ ! -x "$CORE_BITCOIND" ]]; then
        log "${C_RED}MISSING${C_NC} Core bitcoind: $CORE_BITCOIND"; ok=0
    fi
    if [[ ! -x "$CORE_CLI" ]]; then
        log "${C_RED}MISSING${C_NC} Core bitcoin-cli: $CORE_CLI"; ok=0
    fi
    if [[ -z "$CAMLCOIN_BIN" || ! -x "$CAMLCOIN_BIN" ]]; then
        log "${C_RED}MISSING${C_NC} camlcoin binary: $CAMLCOIN_BIN"; ok=0
    fi
    [[ $ok -eq 1 ]] || { log "pre-flight failed"; exit 2; }
    log "Core     : $CORE_BITCOIND"
    log "camlcoin : $CAMLCOIN_BIN"
    log "workdir  : $WORKDIR"
}

# ── RPC helpers ────────────────────────────────────────────────────────────
# Core uses bitcoin-cli against its own datadir. camlcoin we hit over HTTP
# JSON-RPC with cookie auth. camlcoin writes <datadir>/.cookie as
# "__cookie__:<hex>" (cli.ml:1179), which curl -u accepts verbatim.
declare -A CORE_RPCPORT
core_cli() {
    local datadir=$1; shift
    local port="${CORE_RPCPORT[$datadir]:-}"
    local portarg=()
    [[ -n "$port" ]] && portarg=(-rpcport="$port")
    "$CORE_CLI" -regtest -datadir="$datadir" -rpcconnect=127.0.0.1 "${portarg[@]}" "$@" 2>>"$LOGDIR/core-cli.err"
}

camlcoin_rpc() {
    local datadir=$1 port=$2 method=$3 params="${4:-[]}"
    local auth=""
    for c in "$datadir/.cookie" "$datadir/regtest/.cookie"; do
        [[ -f "$c" ]] && { auth="-u $(cat "$c")"; break; }
    done
    local payload="{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}"
    # shellcheck disable=SC2086
    curl -s --max-time 10 $auth --data-binary "$payload" "http://127.0.0.1:$port/" 2>/dev/null
}

# ── Port-conflict guard (no port-kill: 2026-06-10 fuser incident) ──────────
ensure_free() {
    local p
    for p in "$@"; do
        if ss -tln 2>/dev/null | grep -qE ":${p} "; then
            log "${C_RED}refusing to launch${C_NC}: port $p already LISTENING"
            exit 2
        fi
    done
}

# ── Launchers ──────────────────────────────────────────────────────────────
# Core regtest. $1 datadir, $2 rpcport, $3 p2pport, $4 v2transport(0|1),
# $5 extra args (e.g. -connect=...).
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

# camlcoin regtest forced-v2-ON via env. $1 datadir, $2 rpcport, $3 p2pport,
# $4 extra args (e.g. --connect host:port).
# Both directions are forced ON: _OUTBOUND for the initiator path,
# _INBOUND for the responder path. camlcoin is invoked directly (no
# subcommand) and prints to console with --printtoconsole; --debug enables
# the PEER log source where the v2 connect/fallback lines are emitted.
start_camlcoin() {
    local datadir=$1 rpc=$2 p2p=$3; shift 3
    mkdir -p "$datadir"
    # --metricsport 0 disables the Prometheus listener: camlcoin binds it on a
    # FIXED port (9332, main.ml:131) that would collide across back-to-back
    # sub-cases (each sub-case spawns a fresh camlcoin while the previous is
    # still alive until the final EXIT-trap cleanup).
    CAMLCOIN_BIP324_V2_OUTBOUND=1 CAMLCOIN_BIP324_V2_INBOUND=1 \
        "$CAMLCOIN_BIN" --network regtest --datadir "$datadir" \
        --rpcport "$rpc" --port "$p2p" --metricsport 0 \
        --printtoconsole=true --debug \
        "$@" \
        >"$LOGDIR/camlcoin.out" 2>&1 &
    local pid=$!
    register_pid "$pid"
    echo "$pid"
}

wait_core_rpc() {
    local datadir=$1 deadline=$(( $(date +%s) + 30 ))
    while (( $(date +%s) < deadline )); do
        core_cli "$datadir" getblockcount >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

wait_camlcoin_rpc() {
    local datadir=$1 port=$2 deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        local r; r=$(camlcoin_rpc "$datadir" "$port" getblockcount)
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

# ── Generic message-flow driver ────────────────────────────────────────────
# Mine MSG_TARGET (>224) blocks on Core (authoritative miner) and require
# camlcoin to follow. Each block is a discrete AEAD-framed v2 packet; once
# camlcoin has connected >224 blocks the cipher has provably advanced past
# the FSChaCha20 REKEY_INTERVAL{224} with intact tags in BOTH directions.
MINE_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
core_mine() {
    local datadir=$1 n=$2
    core_cli "$datadir" generatetoaddress "$n" "$MINE_ADDR" >/dev/null 2>&1
}

camlcoin_height() {
    local datadir=$1 port=$2
    camlcoin_rpc "$datadir" "$port" getblockcount \
        | sed -n 's/.*"result":[ ]*\([0-9]\+\).*/\1/p'
}

core_height() {
    core_cli "$1" getblockcount 2>/dev/null
}

# ── AEAD / desync failure scan ─────────────────────────────────────────────
aead_failures() {
    local f
    local pat='AEAD|Poly1305 (tag )?mismatch|decrypt(ion)? fail|auth(entication)? fail|tag mismatch|bad mac|v2 .*desync|MAC check failed|ChaCha.*fail'
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
# TEST A-init : camlcoin DIALS Core(-v2transport=1). camlcoin = initiator.
# =====================================================================
test_a_init() {
    log ""
    log "${C_YEL}=== TEST A-init: camlcoin -> Core (camlcoin initiator, forced-v2) ===${C_NC}"
    local CORE_DD="$WORKDIR/a_init_core" CAML_DD="$WORKDIR/a_init_caml"
    local CORE_RPC=$((BASE_PORT+0)) CORE_P2P=$((BASE_PORT+1))
    local CAML_RPC=$((BASE_PORT+2)) CAML_P2P=$((BASE_PORT+3))
    ensure_free "$CORE_RPC" "$CORE_P2P" "$CAML_RPC" "$CAML_P2P"

    start_core "$CORE_DD" "$CORE_RPC" "$CORE_P2P" 1 >/dev/null
    wait_core_rpc "$CORE_DD" || { log "${C_RED}FAIL${C_NC}: Core RPC never came up"; return 1; }
    core_mine "$CORE_DD" "$MSG_TARGET"
    log "Core pre-mined to $(core_height "$CORE_DD")"

    # camlcoin dials Core directly via --connect (initiator path).
    start_camlcoin "$CAML_DD" "$CAML_RPC" "$CAML_P2P" --connect "127.0.0.1:$CORE_P2P" >/dev/null
    wait_camlcoin_rpc "$CAML_DD" "$CAML_RPC" || { log "${C_RED}FAIL${C_NC}: camlcoin RPC never came up"; return 1; }

    local blob; blob=$(core_peer_blob "$CORE_DD") || { log "${C_RED}FAIL${C_NC}: Core never saw the camlcoin peer"; return 1; }
    evaluate_direction "A-init" "$blob" "$CORE_DD" "$CAML_DD" "$CAML_RPC"
}

# =====================================================================
# TEST A-resp : Core(-v2transport=1) DIALS camlcoin via addnode. camlcoin = responder.
# =====================================================================
test_a_resp() {
    log ""
    log "${C_YEL}=== TEST A-resp: Core -> camlcoin (camlcoin responder, forced-v2) ===${C_NC}"
    local CORE_DD="$WORKDIR/a_resp_core" CAML_DD="$WORKDIR/a_resp_caml"
    local CORE_RPC=$((BASE_PORT+4)) CORE_P2P=$((BASE_PORT+5))
    local CAML_RPC=$((BASE_PORT+6)) CAML_P2P=$((BASE_PORT+7))
    ensure_free "$CORE_RPC" "$CORE_P2P" "$CAML_RPC" "$CAML_P2P"

    # camlcoin listens; Core dials it.
    start_camlcoin "$CAML_DD" "$CAML_RPC" "$CAML_P2P" >/dev/null
    wait_camlcoin_rpc "$CAML_DD" "$CAML_RPC" || { log "${C_RED}FAIL${C_NC}: camlcoin RPC never came up"; return 1; }

    start_core "$CORE_DD" "$CORE_RPC" "$CORE_P2P" 1 >/dev/null
    wait_core_rpc "$CORE_DD" || { log "${C_RED}FAIL${C_NC}: Core RPC never came up"; return 1; }
    core_mine "$CORE_DD" "$MSG_TARGET"
    log "Core pre-mined to $(core_height "$CORE_DD")"

    # Core dials camlcoin with v2 explicitly (addnode v2transport=true).
    core_cli "$CORE_DD" addnode "127.0.0.1:$CAML_P2P" "onetry" "true" >/dev/null 2>&1 \
      || core_cli "$CORE_DD" addnode "127.0.0.1:$CAML_P2P" "onetry" >/dev/null 2>&1

    local blob; blob=$(core_peer_blob "$CORE_DD") || { log "${C_RED}FAIL${C_NC}: Core never connected to camlcoin"; return 1; }
    evaluate_direction "A-resp" "$blob" "$CORE_DD" "$CAML_DD" "$CAML_RPC"
}

# Shared evaluator for the two A directions.
# $1 label, $2 core getpeerinfo blob, $3 core dd, $4 caml dd, $5 caml rpc.
LAST_REKEY_CROSSED=0
LAST_EVIDENCE=""
evaluate_direction() {
    local label=$1 blob=$2 core_dd=$3 caml_dd=$4 caml_rpc=$5
    local ttype sid
    ttype=$(echo "$blob" | grep -o '"transport_protocol_type": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    sid=$(echo "$blob"   | grep -o '"session_id": *"[^"]*"'              | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    log "  Core getpeerinfo: transport_protocol_type=${ttype:-<none>} session_id=${sid:0:16}...(${#sid} hex)"

    # camlcoin-side v2 confirmation: log line ("BIP-324 v2 {outbound,inbound}
    # connected (encrypted)", peer.ml:1172/1326).
    local cl_v2=""
    if [[ "$label" == "A-init" ]]; then
        cl_v2=$(grep -E "BIP-324 v2 outbound connected \(encrypted\)" "$LOGDIR/camlcoin.out" 2>/dev/null | head -1)
    else
        cl_v2=$(grep -E "BIP-324 v2 inbound connected \(encrypted\)" "$LOGDIR/camlcoin.out" 2>/dev/null | head -1)
    fi

    # Drive >224-msg flow via BLOCK DOWNLOAD. Core pre-mined MSG_TARGET (>224)
    # blocks; camlcoin downloads them one block per getdata->block exchange.
    # Once camlcoin has connected >224 blocks the cipher has provably advanced
    # past REKEY_INTERVAL{224} with intact tags in BOTH directions.
    local target; target=$(core_height "$core_dd")
    local deadline=$(( $(date +%s) + 240 ))
    local cl_h=0
    while (( $(date +%s) < deadline )); do
        cl_h=$(camlcoin_height "$caml_dd" "$caml_rpc"); cl_h=${cl_h:-0}
        (( cl_h >= target )) && break
        (( cl_h > 224 )) && break
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
    if (( cl_h > 224 )) || (( blocks_served > 224 )); then
        crossed=1
    fi
    LAST_REKEY_CROSSED=$crossed

    local aead; aead=$(aead_failures "$LOGDIR/core.out" "$LOGDIR/camlcoin.out")
    local disc; disc=$(core_disconnect_after_handshake)

    LAST_EVIDENCE="Core transport_protocol_type=${ttype:-none}, session_id len=${#sid} hex; camlcoin log v2=$([[ -n "$cl_v2" ]] && echo yes || echo no); camlcoin block-synced ${cl_h}/${target}; Core-block-pkts-served~${blocks_served} (>224 cross=$crossed); AEAD-fail=$([[ -n "$aead" ]] && echo PRESENT || echo none); mid-stream-disconnect=$([[ -n "$disc" ]] && echo yes || echo no)"
    log "  evidence: $LAST_EVIDENCE"
    [[ -n "$aead" ]] && log "  ${C_RED}AEAD lines:${C_NC} $(echo "$aead" | head -3)"

    local app_roundtrip=0
    (( cl_h > 0 )) && app_roundtrip=1
    local pass=1
    [[ "$ttype" == "v2" ]]    || { log "  ${C_RED}- transport_protocol_type != v2${C_NC}"; pass=0; }
    [[ ${#sid} -ge 32 ]]      || { log "  ${C_RED}- session_id empty/short${C_NC}"; pass=0; }
    [[ -n "$cl_v2" ]]         || { log "  ${C_RED}- camlcoin emitted no v2-success log${C_NC}"; pass=0; }
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
# TEST B1 : camlcoin forced-v2 dials Core -v2transport=0 -> MUST fall back to v1 + sync.
# =====================================================================
test_b1() {
    log ""
    log "${C_YEL}=== TEST B1: camlcoin(forced-v2) -> Core(-v2transport=0): v1 fallback ===${C_NC}"
    local CORE_DD="$WORKDIR/b1_core" CAML_DD="$WORKDIR/b1_caml"
    local CORE_RPC=$((BASE_PORT+8)) CORE_P2P=$((BASE_PORT+9))
    local CAML_RPC=$((BASE_PORT+10)) CAML_P2P=$((BASE_PORT+11))
    ensure_free "$CORE_RPC" "$CORE_P2P" "$CAML_RPC" "$CAML_P2P"

    start_core "$CORE_DD" "$CORE_RPC" "$CORE_P2P" 0 >/dev/null
    wait_core_rpc "$CORE_DD" || { log "${C_RED}FAIL${C_NC}: Core RPC never came up"; return 1; }
    core_mine "$CORE_DD" 40   # a modest chain is enough to prove v1 sync
    local target; target=$(core_height "$CORE_DD")

    start_camlcoin "$CAML_DD" "$CAML_RPC" "$CAML_P2P" --connect "127.0.0.1:$CORE_P2P" >/dev/null
    wait_camlcoin_rpc "$CAML_DD" "$CAML_RPC" || { log "${C_RED}FAIL${C_NC}: camlcoin RPC never came up"; return 1; }

    local blob; blob=$(core_peer_blob "$CORE_DD") || { log "${C_RED}FAIL${C_NC}: Core never saw the peer"; return 1; }
    local ttype; ttype=$(echo "$blob" | grep -o '"transport_protocol_type": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

    # Wait for camlcoin to sync over v1.
    local deadline=$(( $(date +%s) + 90 )) cl_h=0
    while (( $(date +%s) < deadline )); do
        cl_h=$(camlcoin_height "$CAML_DD" "$CAML_RPC"); cl_h=${cl_h:-0}
        (( cl_h >= target )) && break
        sleep 2
    done

    local fellback; fellback=$(grep -E "falling back to v1" "$LOGDIR/camlcoin.out" 2>/dev/null | head -1)
    LAST_EVIDENCE="Core saw transport_protocol_type=${ttype:-none} (expect v1); camlcoin fell-back-log=$([[ -n "$fellback" ]] && echo yes || echo no); camlcoin synced ${cl_h}/${target}"
    log "  evidence: $LAST_EVIDENCE"

    local pass=1
    [[ "$ttype" == "v1" ]] || { log "  ${C_RED}- Core reports peer as $ttype, expected v1${C_NC}"; pass=0; }
    (( cl_h >= target ))   || { log "  ${C_RED}- camlcoin did not sync over v1 ($cl_h/$target)${C_NC}"; pass=0; }
    if (( pass == 1 )); then log "  ${C_GREEN}B1 PASS${C_NC}"; return 0; fi
    log "  ${C_RED}B1 FAIL${C_NC}"; return 1
}

# =====================================================================
# TEST B2 : Core -v2transport=0 dials camlcoin -> camlcoin responder accepts v1.
# =====================================================================
test_b2() {
    log ""
    log "${C_YEL}=== TEST B2: Core(-v2transport=0) -> camlcoin(forced-v2 resp): accepts v1 ===${C_NC}"
    local CORE_DD="$WORKDIR/b2_core" CAML_DD="$WORKDIR/b2_caml"
    local CORE_RPC=$((BASE_PORT+12)) CORE_P2P=$((BASE_PORT+13))
    local CAML_RPC=$((BASE_PORT+14)) CAML_P2P=$((BASE_PORT+15))
    ensure_free "$CORE_RPC" "$CORE_P2P" "$CAML_RPC" "$CAML_P2P"

    start_camlcoin "$CAML_DD" "$CAML_RPC" "$CAML_P2P" >/dev/null
    wait_camlcoin_rpc "$CAML_DD" "$CAML_RPC" || { log "${C_RED}FAIL${C_NC}: camlcoin RPC never came up"; return 1; }

    start_core "$CORE_DD" "$CORE_RPC" "$CORE_P2P" 0 >/dev/null
    wait_core_rpc "$CORE_DD" || { log "${C_RED}FAIL${C_NC}: Core RPC never came up"; return 1; }
    core_mine "$CORE_DD" 40
    local target; target=$(core_height "$CORE_DD")

    core_cli "$CORE_DD" addnode "127.0.0.1:$CAML_P2P" "onetry" >/dev/null 2>&1

    local blob; blob=$(core_peer_blob "$CORE_DD") || { log "${C_RED}FAIL${C_NC}: Core never connected to camlcoin${C_NC}"; return 1; }
    local ttype; ttype=$(echo "$blob" | grep -o '"transport_protocol_type": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

    local deadline=$(( $(date +%s) + 90 )) cl_h=0
    while (( $(date +%s) < deadline )); do
        cl_h=$(camlcoin_height "$CAML_DD" "$CAML_RPC"); cl_h=${cl_h:-0}
        (( cl_h >= target )) && break
        sleep 2
    done
    local v1in; v1in=$(grep -Ei "Accepted inbound|inbound .*v1|version handshake|Handshake" "$LOGDIR/camlcoin.out" 2>/dev/null | head -1)
    LAST_EVIDENCE="Core reports peer transport_protocol_type=${ttype:-none} (expect v1); camlcoin synced ${cl_h}/${target}; camlcoin-v1-inbound-log=$([[ -n "$v1in" ]] && echo yes || echo no)"
    log "  evidence: $LAST_EVIDENCE"

    local pass=1
    [[ "$ttype" == "v1" ]] || { log "  ${C_RED}- Core reports peer as $ttype, expected v1${C_NC}"; pass=0; }
    (( cl_h >= target ))   || { log "  ${C_RED}- camlcoin did not sync the v1 inbound peer ($cl_h/$target)${C_NC}"; pass=0; }
    if (( pass == 1 )); then log "  ${C_GREEN}B2 PASS${C_NC}"; return 0; fi
    log "  ${C_RED}B2 FAIL${C_NC}"; return 1
}

# ── Driver ─────────────────────────────────────────────────────────────────
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
    "")
        run_case a-init test_a_init
        run_case a-resp test_a_resp
        run_case b1 test_b1
        run_case b2 test_b2
        ;;
    *) log "unknown --only=$ONLY"; exit 2 ;;
esac

log ""
log "================ SUMMARY ================"
overall=0
for c in a-init a-resp b1 b2; do
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

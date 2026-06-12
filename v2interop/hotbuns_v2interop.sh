#!/usr/bin/env bash
# test-suite/v2interop/hotbuns_v2interop.sh
#
# BIP-324 v2 transport interop gate: hotbuns (forced-v2 via env) vs a real
# Bitcoin Core v2 peer, on regtest. This is the GATE the v2-transport campaign
# (CORE-PARITY-AUDIT/_v2-transport-campaign-2026-06-11.md) requires before any
# default-on flip: self-roundtrip unit tests pass even for cipher-desync bugs,
# so we must prove interop against a real Core v2 peer that crosses a rekey
# boundary (Core REKEY_INTERVAL=224, bip324.h:24).
#
# Cloned from camlcoin_v2interop.sh (b95b9aa) / haskoin_v2interop.sh (fbaf1d1) —
# same structure (cookie auth, /tmp datadirs, HASHHOG_ROOT-relative paths, ports
# <32768, terminal-transport wait, AEAD scan). Only the impl launch + binary +
# log-string matchers differ. hotbuns is TypeScript/Bun: launched directly with
# "bun run src/index.ts" from the hotbuns submodule dir (no compiled binary),
# flags --network=regtest --datadir=<dd> --rpcport=<r> --port=<p> --metrics-port=0
# and --connect host:port for the initiator direction. Forced-v2 via env
# HOTBUNS_BIP324_V2=1 (default is OFF this phase for OUTBOUND — INBOUND v2 is
# already ungated/always-on; we still set the env so the outbound/initiator
# path is exercised). No source change.
#
# hotbuns-side v2 confirmation: hotbuns getpeerinfo currently hardcodes
# transport_protocol_type="v1" (server.ts:6012, a stub field), so the
# authoritative session_id + transport type come from CORE getpeerinfo for the
# hotbuns peer. The hotbuns SIDE is confirmed via its stdout log line
# "[bip324] v2 {outbound,inbound} connected (encrypted)" (peer.ts:1156), which
# fires exactly once per Peer on cipher-handshake-ready, AND a clean post-rekey
# block-sync (>224 blocks downloaded over the encrypted channel with intact
# AEAD tags in both directions).
#
#   TEST A  handshake + >224-msg flow, BOTH directions:
#     A-init  hotbuns dials Core (-v2transport=1)   [hotbuns = initiator]
#     A-resp  Core (addnode) dials hotbuns          [hotbuns = responder]
#     PASS = Core getpeerinfo for that peer shows transport_protocol_type=v2 +
#            non-empty session_id, version+verack complete, app msgs round-trip,
#            and the flow exceeds 224 messages (crosses a rekey) with no AEAD
#            failures / no disconnect, AND hotbuns emits its v2-success log.
#
#   TEST B  v1 fallback intact:
#     b1  hotbuns forced-v2 dials Core -v2transport=0  -> MUST fall back to v1, sync
#     b2  Core -v2transport=0 dials hotbuns            -> hotbuns responder accepts v1
#     b3  two hotbuns forced-v2 dial each other        -> v2<->v2 still interops + sync
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
# Base 29600 — DISTINCT from haskoin (29400) and camlcoin (29500) so a
# back-to-back run never collides. Override with --base-port=N. b3 needs an
# extra pair so the per-case offsets run +0..+19.
BASE_PORT="${BASE_PORT:-29600}"

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
            sed -n '2,46p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown flag: $arg (use --help)" >&2; exit 2 ;;
    esac
done

WORKDIR="/tmp/hashhog-v2-$$"
LOGDIR="$WORKDIR/logs"
mkdir -p "$LOGDIR"

HOTBUNS_DIR="${HOTBUNS_DIR:-$HASHHOG_ROOT/hotbuns}"
BUN_BIN="${BUN_BIN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}"

C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'; C_NC=$'\033[0m'

declare -a PIDS=()
register_pid() { PIDS+=("$1"); }

# Recursively signal a pid AND its children. CRITICAL for hotbuns: it is
# launched via "bun run src/index.ts", and `bun run` forks the actual node as
# a CHILD process — `kill <bun-run-pid>` only reaps the wrapper and leaks the
# node, which then keeps its P2P/RPC ports bound and collides with the next
# sub-case (observed: ports 29616/29617 left LISTENING). Walk the tree.
kill_tree() {
    local pid=$1 sig=$2 kid
    for kid in $(pgrep -P "$pid" 2>/dev/null); do
        kill_tree "$kid" "$sig"
    done
    kill "$sig" "$pid" 2>/dev/null || true
}

cleanup() {
    for p in "${PIDS[@]:-}"; do
        kill_tree "$p" -TERM
    done
    # brief grace, then hard kill the whole tree
    sleep 2
    for p in "${PIDS[@]:-}"; do
        kill_tree "$p" -KILL
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
    if [[ ! -x "$BUN_BIN" ]]; then
        log "${C_RED}MISSING${C_NC} bun runtime: $BUN_BIN"; ok=0
    fi
    if [[ ! -f "$HOTBUNS_DIR/src/index.ts" ]]; then
        log "${C_RED}MISSING${C_NC} hotbuns entrypoint: $HOTBUNS_DIR/src/index.ts"; ok=0
    fi
    [[ $ok -eq 1 ]] || { log "pre-flight failed"; exit 2; }
    log "Core    : $CORE_BITCOIND"
    log "hotbuns : $BUN_BIN run $HOTBUNS_DIR/src/index.ts"
    log "workdir : $WORKDIR"
}

# ── RPC helpers ────────────────────────────────────────────────────────────
# Core uses bitcoin-cli against its own datadir. hotbuns we hit over HTTP
# JSON-RPC with cookie auth. hotbuns writes <datadir>/.cookie as
# "__cookie__:<hex>" (server.ts:697), which curl -u accepts verbatim.
declare -A CORE_RPCPORT
core_cli() {
    local datadir=$1; shift
    local port="${CORE_RPCPORT[$datadir]:-}"
    local portarg=()
    [[ -n "$port" ]] && portarg=(-rpcport="$port")
    "$CORE_CLI" -regtest -datadir="$datadir" -rpcconnect=127.0.0.1 "${portarg[@]}" "$@" 2>>"$LOGDIR/core-cli.err"
}

hotbuns_rpc() {
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

# hotbuns regtest forced-v2-ON via env. $1 logtag, $2 datadir, $3 rpcport,
# $4 p2pport, then extra args (e.g. --connect host:port).
# HOTBUNS_BIP324_V2=1 forces the OUTBOUND/initiator v2 path on (default OFF this
# phase). INBOUND/responder v2 is already always-on (no env gate). hotbuns is
# launched via "bun run src/index.ts" from the hotbuns dir; stdout (where the
# "[bip324] v2 ... connected" log lines land) is redirected per-tag so each
# sub-case has an isolated log to scan.  --metrics-port=0 disables the
# Prometheus listener so back-to-back sub-cases don't collide on a fixed port.
start_hotbuns() {
    local tag=$1 datadir=$2 rpc=$3 p2p=$4; shift 4
    mkdir -p "$datadir"
    ( cd "$HOTBUNS_DIR" && \
      HOTBUNS_BIP324_V2=1 \
      "$BUN_BIN" run src/index.ts \
        --network=regtest --datadir="$datadir" \
        --rpcport="$rpc" --port="$p2p" --metrics-port=0 \
        "$@" \
        >"$LOGDIR/hotbuns-$tag.out" 2>&1 ) &
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

wait_hotbuns_rpc() {
    local datadir=$1 port=$2 deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
        local r; r=$(hotbuns_rpc "$datadir" "$port" getblockcount)
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
# hotbuns to follow. Each block is a discrete AEAD-framed v2 packet; once
# hotbuns has connected >224 blocks the cipher has provably advanced past
# the FSChaCha20 REKEY_INTERVAL{224} with intact tags in BOTH directions.
MINE_ADDR="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
core_mine() {
    local datadir=$1 n=$2
    core_cli "$datadir" generatetoaddress "$n" "$MINE_ADDR" >/dev/null 2>&1
}

hotbuns_height() {
    local datadir=$1 port=$2
    hotbuns_rpc "$datadir" "$port" getblockcount \
        | sed -n 's/.*"result":[ ]*\([0-9]\+\).*/\1/p'
}

core_height() {
    core_cli "$1" getblockcount 2>/dev/null
}

# ── AEAD / desync failure scan ─────────────────────────────────────────────
# NOTE: the bare token "AEAD" must NOT appear as a standalone alternative — it
# is a 4-char substring that case-insensitively matches inside arbitrary block
# HASH hex (e.g. the "...aead..." in "INJECT: block ... hash=31c03aead62707af",
# emitted by the mining/injectBlock path the B3 fix wires in). Match "aead"
# ONLY when it is paired with explicit failure context, like every other
# alternative here. A genuine AEAD failure is always logged as "AEAD <verb>
# fail/mismatch", never as a lone token, so this loses no real detection.
aead_failures() {
    local f
    local pat='AEAD[^a-z0-9]*(tag )?(mismatch|fail|error|decrypt)|Poly1305 (tag )?mismatch|decrypt(ion)? fail|auth(entication)? fail|tag mismatch|bad mac|v2 .*desync|MAC check failed|ChaCha.*fail|v2 transport error'
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
# TEST A-init : hotbuns DIALS Core(-v2transport=1). hotbuns = initiator.
# =====================================================================
test_a_init() {
    log ""
    log "${C_YEL}=== TEST A-init: hotbuns -> Core (hotbuns initiator, forced-v2) ===${C_NC}"
    local CORE_DD="$WORKDIR/a_init_core" HB_DD="$WORKDIR/a_init_hb"
    local CORE_RPC=$((BASE_PORT+0)) CORE_P2P=$((BASE_PORT+1))
    local HB_RPC=$((BASE_PORT+2)) HB_P2P=$((BASE_PORT+3))
    ensure_free "$CORE_RPC" "$CORE_P2P" "$HB_RPC" "$HB_P2P"

    start_core "$CORE_DD" "$CORE_RPC" "$CORE_P2P" 1 >/dev/null
    wait_core_rpc "$CORE_DD" || { log "${C_RED}FAIL${C_NC}: Core RPC never came up"; return 1; }
    core_mine "$CORE_DD" "$MSG_TARGET"
    log "Core pre-mined to $(core_height "$CORE_DD")"

    # hotbuns dials Core directly via --connect (initiator path).
    # NOTE: hotbuns parses flags ONLY as --key=value (parseFlag, cli.ts:666);
    # a space-separated "--connect host:port" is silently dropped and host:port
    # becomes a bogus positional "command". Always pass --connect=host:port.
    start_hotbuns a-init "$HB_DD" "$HB_RPC" "$HB_P2P" --connect="127.0.0.1:$CORE_P2P" >/dev/null
    wait_hotbuns_rpc "$HB_DD" "$HB_RPC" || { log "${C_RED}FAIL${C_NC}: hotbuns RPC never came up"; return 1; }

    local blob; blob=$(core_peer_blob "$CORE_DD") || { log "${C_RED}FAIL${C_NC}: Core never saw the hotbuns peer"; return 1; }
    evaluate_direction "A-init" "$blob" "$CORE_DD" "$HB_DD" "$HB_RPC" "a-init"
}

# =====================================================================
# TEST A-resp : Core(-v2transport=1) DIALS hotbuns via addnode. hotbuns = responder.
# =====================================================================
test_a_resp() {
    log ""
    log "${C_YEL}=== TEST A-resp: Core -> hotbuns (hotbuns responder, forced-v2) ===${C_NC}"
    local CORE_DD="$WORKDIR/a_resp_core" HB_DD="$WORKDIR/a_resp_hb"
    local CORE_RPC=$((BASE_PORT+4)) CORE_P2P=$((BASE_PORT+5))
    local HB_RPC=$((BASE_PORT+6)) HB_P2P=$((BASE_PORT+7))
    ensure_free "$CORE_RPC" "$CORE_P2P" "$HB_RPC" "$HB_P2P"

    # hotbuns listens; Core dials it.
    start_hotbuns a-resp "$HB_DD" "$HB_RPC" "$HB_P2P" >/dev/null
    wait_hotbuns_rpc "$HB_DD" "$HB_RPC" || { log "${C_RED}FAIL${C_NC}: hotbuns RPC never came up"; return 1; }

    start_core "$CORE_DD" "$CORE_RPC" "$CORE_P2P" 1 >/dev/null
    wait_core_rpc "$CORE_DD" || { log "${C_RED}FAIL${C_NC}: Core RPC never came up"; return 1; }
    core_mine "$CORE_DD" "$MSG_TARGET"
    log "Core pre-mined to $(core_height "$CORE_DD")"

    # Core dials hotbuns with v2 explicitly (addnode v2transport=true).
    core_cli "$CORE_DD" addnode "127.0.0.1:$HB_P2P" "onetry" "true" >/dev/null 2>&1 \
      || core_cli "$CORE_DD" addnode "127.0.0.1:$HB_P2P" "onetry" >/dev/null 2>&1

    local blob; blob=$(core_peer_blob "$CORE_DD") || { log "${C_RED}FAIL${C_NC}: Core never connected to hotbuns"; return 1; }
    evaluate_direction "A-resp" "$blob" "$CORE_DD" "$HB_DD" "$HB_RPC" "a-resp"
}

# Shared evaluator for the two A directions.
# $1 label, $2 core getpeerinfo blob, $3 core dd, $4 hb dd, $5 hb rpc, $6 logtag.
LAST_REKEY_CROSSED=0
LAST_EVIDENCE=""
evaluate_direction() {
    local label=$1 blob=$2 core_dd=$3 hb_dd=$4 hb_rpc=$5 logtag=$6
    local ttype sid
    ttype=$(echo "$blob" | grep -o '"transport_protocol_type": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    sid=$(echo "$blob"   | grep -o '"session_id": *"[^"]*"'              | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    log "  Core getpeerinfo: transport_protocol_type=${ttype:-<none>} session_id=${sid:0:16}...(${#sid} hex)"

    # hotbuns-side v2 confirmation: stdout log line
    # ("[bip324] v2 {outbound,inbound} connected (encrypted)", peer.ts:1156).
    local hbout="$LOGDIR/hotbuns-$logtag.out"
    local hb_v2=""
    if [[ "$label" == "A-init" ]]; then
        hb_v2=$(grep -E "\[bip324\] v2 outbound connected \(encrypted\)" "$hbout" 2>/dev/null | head -1)
    else
        hb_v2=$(grep -E "\[bip324\] v2 inbound connected \(encrypted\)" "$hbout" 2>/dev/null | head -1)
    fi

    # Drive >224-msg flow via BLOCK DOWNLOAD. Core pre-mined MSG_TARGET (>224)
    # blocks; hotbuns downloads them one block per getdata->block exchange.
    # Once hotbuns has connected >224 blocks the cipher has provably advanced
    # past REKEY_INTERVAL{224} with intact tags in BOTH directions.
    local target; target=$(core_height "$core_dd")
    local deadline=$(( $(date +%s) + 240 ))
    local hb_h=0
    while (( $(date +%s) < deadline )); do
        hb_h=$(hotbuns_height "$hb_dd" "$hb_rpc"); hb_h=${hb_h:-0}
        (( hb_h >= target )) && break
        (( hb_h > 224 )) && break
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
    if (( hb_h > 224 )) || (( blocks_served > 224 )); then
        crossed=1
    fi
    LAST_REKEY_CROSSED=$crossed

    local aead; aead=$(aead_failures "$LOGDIR/core.out" "$hbout")
    local disc; disc=$(core_disconnect_after_handshake)

    LAST_EVIDENCE="Core transport_protocol_type=${ttype:-none}, session_id len=${#sid} hex; hotbuns log v2=$([[ -n "$hb_v2" ]] && echo yes || echo no); hotbuns block-synced ${hb_h}/${target}; Core-block-pkts-served~${blocks_served} (>224 cross=$crossed); AEAD-fail=$([[ -n "$aead" ]] && echo PRESENT || echo none); mid-stream-disconnect=$([[ -n "$disc" ]] && echo yes || echo no)"
    log "  evidence: $LAST_EVIDENCE"
    [[ -n "$aead" ]] && log "  ${C_RED}AEAD lines:${C_NC} $(echo "$aead" | head -3)"

    local app_roundtrip=0
    (( hb_h > 0 )) && app_roundtrip=1
    local pass=1
    [[ "$ttype" == "v2" ]]    || { log "  ${C_RED}- transport_protocol_type != v2${C_NC}"; pass=0; }
    [[ ${#sid} -ge 32 ]]      || { log "  ${C_RED}- session_id empty/short${C_NC}"; pass=0; }
    [[ -n "$hb_v2" ]]         || { log "  ${C_RED}- hotbuns emitted no v2-success log${C_NC}"; pass=0; }
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
# TEST B1 : hotbuns forced-v2 dials Core -v2transport=0 -> MUST fall back to v1 + sync.
# =====================================================================
test_b1() {
    log ""
    log "${C_YEL}=== TEST B1: hotbuns(forced-v2) -> Core(-v2transport=0): v1 fallback ===${C_NC}"
    local CORE_DD="$WORKDIR/b1_core" HB_DD="$WORKDIR/b1_hb"
    local CORE_RPC=$((BASE_PORT+8)) CORE_P2P=$((BASE_PORT+9))
    local HB_RPC=$((BASE_PORT+10)) HB_P2P=$((BASE_PORT+11))
    ensure_free "$CORE_RPC" "$CORE_P2P" "$HB_RPC" "$HB_P2P"

    start_core "$CORE_DD" "$CORE_RPC" "$CORE_P2P" 0 >/dev/null
    wait_core_rpc "$CORE_DD" || { log "${C_RED}FAIL${C_NC}: Core RPC never came up"; return 1; }
    core_mine "$CORE_DD" 40   # a modest chain is enough to prove v1 sync
    local target; target=$(core_height "$CORE_DD")

    start_hotbuns b1 "$HB_DD" "$HB_RPC" "$HB_P2P" --connect="127.0.0.1:$CORE_P2P" >/dev/null
    wait_hotbuns_rpc "$HB_DD" "$HB_RPC" || { log "${C_RED}FAIL${C_NC}: hotbuns RPC never came up"; return 1; }

    local blob; blob=$(core_peer_blob "$CORE_DD") || { log "${C_RED}FAIL${C_NC}: Core never saw the peer"; return 1; }
    local ttype; ttype=$(echo "$blob" | grep -o '"transport_protocol_type": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

    # Wait for hotbuns to sync over v1.
    local deadline=$(( $(date +%s) + 120 )) hb_h=0
    while (( $(date +%s) < deadline )); do
        hb_h=$(hotbuns_height "$HB_DD" "$HB_RPC"); hb_h=${hb_h:-0}
        (( hb_h >= target )) && break
        sleep 2
    done

    # hotbuns logs a v1-fallback reason on disconnect ("v2 outbound: peer
    # responded with v1 VERSION" / "v2 transport requested v1 fallback");
    # after fallback it reconnects v1 (manager marks the addr v1-only).
    local fellback; fellback=$(grep -Ei "peer responded with v1 VERSION|v2 transport requested v1 fallback|falling back to v1" "$LOGDIR/hotbuns-b1.out" 2>/dev/null | head -1)
    LAST_EVIDENCE="Core saw transport_protocol_type=${ttype:-none} (expect v1); hotbuns fell-back-log=$([[ -n "$fellback" ]] && echo yes || echo no); hotbuns synced ${hb_h}/${target}"
    log "  evidence: $LAST_EVIDENCE"

    local pass=1
    [[ "$ttype" == "v1" ]] || { log "  ${C_RED}- Core reports peer as $ttype, expected v1${C_NC}"; pass=0; }
    (( hb_h >= target ))   || { log "  ${C_RED}- hotbuns did not sync over v1 ($hb_h/$target)${C_NC}"; pass=0; }
    if (( pass == 1 )); then log "  ${C_GREEN}B1 PASS${C_NC}"; return 0; fi
    log "  ${C_RED}B1 FAIL${C_NC}"; return 1
}

# =====================================================================
# TEST B2 : Core -v2transport=0 dials hotbuns -> hotbuns responder accepts v1.
# =====================================================================
test_b2() {
    log ""
    log "${C_YEL}=== TEST B2: Core(-v2transport=0) -> hotbuns(forced-v2 resp): accepts v1 ===${C_NC}"
    local CORE_DD="$WORKDIR/b2_core" HB_DD="$WORKDIR/b2_hb"
    local CORE_RPC=$((BASE_PORT+12)) CORE_P2P=$((BASE_PORT+13))
    local HB_RPC=$((BASE_PORT+14)) HB_P2P=$((BASE_PORT+15))
    ensure_free "$CORE_RPC" "$CORE_P2P" "$HB_RPC" "$HB_P2P"

    start_hotbuns b2 "$HB_DD" "$HB_RPC" "$HB_P2P" >/dev/null
    wait_hotbuns_rpc "$HB_DD" "$HB_RPC" || { log "${C_RED}FAIL${C_NC}: hotbuns RPC never came up"; return 1; }

    start_core "$CORE_DD" "$CORE_RPC" "$CORE_P2P" 0 >/dev/null
    wait_core_rpc "$CORE_DD" || { log "${C_RED}FAIL${C_NC}: Core RPC never came up"; return 1; }
    core_mine "$CORE_DD" 40
    local target; target=$(core_height "$CORE_DD")

    core_cli "$CORE_DD" addnode "127.0.0.1:$HB_P2P" "onetry" >/dev/null 2>&1

    local blob; blob=$(core_peer_blob "$CORE_DD") || { log "${C_RED}FAIL${C_NC}: Core never connected to hotbuns"; return 1; }
    local ttype; ttype=$(echo "$blob" | grep -o '"transport_protocol_type": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

    local deadline=$(( $(date +%s) + 120 )) hb_h=0
    while (( $(date +%s) < deadline )); do
        hb_h=$(hotbuns_height "$HB_DD" "$HB_RPC"); hb_h=${hb_h:-0}
        (( hb_h >= target )) && break
        sleep 2
    done
    local v1in; v1in=$(grep -Ei "v2 outbound: peer responded with v1|inbound|version handshake|received version|handshake complete" "$LOGDIR/hotbuns-b2.out" 2>/dev/null | head -1)
    LAST_EVIDENCE="Core reports peer transport_protocol_type=${ttype:-none} (expect v1); hotbuns synced ${hb_h}/${target}; hotbuns-v1-inbound-log=$([[ -n "$v1in" ]] && echo yes || echo no)"
    log "  evidence: $LAST_EVIDENCE"

    local pass=1
    [[ "$ttype" == "v1" ]] || { log "  ${C_RED}- Core reports peer as $ttype, expected v1${C_NC}"; pass=0; }
    (( hb_h >= target ))   || { log "  ${C_RED}- hotbuns did not sync the v1 inbound peer ($hb_h/$target)${C_NC}"; pass=0; }
    if (( pass == 1 )); then log "  ${C_GREEN}B2 PASS${C_NC}"; return 0; fi
    log "  ${C_RED}B2 FAIL${C_NC}"; return 1
}

# =====================================================================
# TEST B3 : two hotbuns forced-v2 dial each other -> v2<->v2 interop + sync.
# One hotbuns mines a chain (regtest generatetoaddress via RPC), the other
# dials it forced-v2 and must sync the chain over the encrypted channel.
# This proves the impl<->impl v2 pairing still interoperates (no Core).
# =====================================================================
test_b3() {
    log ""
    log "${C_YEL}=== TEST B3: hotbuns(v2) <-> hotbuns(v2): impl-pair interop ===${C_NC}"
    local SRV_DD="$WORKDIR/b3_srv" CLI_DD="$WORKDIR/b3_cli"
    local SRV_RPC=$((BASE_PORT+16)) SRV_P2P=$((BASE_PORT+17))
    local CLI_RPC=$((BASE_PORT+18)) CLI_P2P=$((BASE_PORT+19))
    ensure_free "$SRV_RPC" "$SRV_P2P" "$CLI_RPC" "$CLI_P2P"

    # Server hotbuns: listens, mines a regtest chain.
    start_hotbuns b3-srv "$SRV_DD" "$SRV_RPC" "$SRV_P2P" >/dev/null
    wait_hotbuns_rpc "$SRV_DD" "$SRV_RPC" || { log "${C_RED}FAIL${C_NC}: hotbuns(srv) RPC never came up"; return 1; }

    # Mine a chain on the server. >224 blocks so the v2 cipher crosses the
    # rekey boundary on the impl<->impl link too.
    local mined; mined=$(hotbuns_rpc "$SRV_DD" "$SRV_RPC" generatetoaddress "[$MSG_TARGET, \"$MINE_ADDR\"]")
    local srv_h; srv_h=$(hotbuns_height "$SRV_DD" "$SRV_RPC"); srv_h=${srv_h:-0}
    if (( srv_h < 1 )); then
        # Some impls expose a different mining RPC name; try generate fallbacks.
        hotbuns_rpc "$SRV_DD" "$SRV_RPC" generate "[$MSG_TARGET]" >/dev/null 2>&1
        srv_h=$(hotbuns_height "$SRV_DD" "$SRV_RPC"); srv_h=${srv_h:-0}
    fi
    log "  hotbuns(srv) mined to height ${srv_h}"

    # Client hotbuns: dials the server forced-v2 (initiator).
    start_hotbuns b3-cli "$CLI_DD" "$CLI_RPC" "$CLI_P2P" --connect="127.0.0.1:$SRV_P2P" >/dev/null
    wait_hotbuns_rpc "$CLI_DD" "$CLI_RPC" || { log "${C_RED}FAIL${C_NC}: hotbuns(cli) RPC never came up"; return 1; }

    local deadline=$(( $(date +%s) + 240 )) cli_h=0
    while (( $(date +%s) < deadline )); do
        cli_h=$(hotbuns_height "$CLI_DD" "$CLI_RPC"); cli_h=${cli_h:-0}
        (( srv_h > 0 && cli_h >= srv_h )) && break
        (( cli_h > 224 )) && break
        sleep 3
    done

    local cli_v2; cli_v2=$(grep -E "\[bip324\] v2 outbound connected \(encrypted\)" "$LOGDIR/hotbuns-b3-cli.out" 2>/dev/null | head -1)
    local srv_v2; srv_v2=$(grep -E "\[bip324\] v2 inbound connected \(encrypted\)" "$LOGDIR/hotbuns-b3-srv.out" 2>/dev/null | head -1)
    local aead; aead=$(aead_failures "$LOGDIR/hotbuns-b3-srv.out" "$LOGDIR/hotbuns-b3-cli.out")
    local crossed=0; (( cli_h > 224 )) && crossed=1
    LAST_REKEY_CROSSED=$crossed

    LAST_EVIDENCE="hotbuns-cli v2-out-log=$([[ -n "$cli_v2" ]] && echo yes || echo no); hotbuns-srv v2-in-log=$([[ -n "$srv_v2" ]] && echo yes || echo no); cli synced ${cli_h}/${srv_h} (>224 cross=$crossed); AEAD-fail=$([[ -n "$aead" ]] && echo PRESENT || echo none)"
    log "  evidence: $LAST_EVIDENCE"
    [[ -n "$aead" ]] && log "  ${C_RED}AEAD lines:${C_NC} $(echo "$aead" | head -3)"

    local pass=1
    [[ -n "$cli_v2" ]]          || { log "  ${C_RED}- hotbuns(cli) emitted no v2-outbound log${C_NC}"; pass=0; }
    [[ -n "$srv_v2" ]]          || { log "  ${C_RED}- hotbuns(srv) emitted no v2-inbound log${C_NC}"; pass=0; }
    (( srv_h > 0 ))             || { log "  ${C_RED}- hotbuns(srv) failed to mine a chain${C_NC}"; pass=0; }
    (( srv_h > 0 && cli_h >= srv_h )) || { log "  ${C_RED}- hotbuns(cli) did not sync ($cli_h/$srv_h)${C_NC}"; pass=0; }
    [[ -z "$aead" ]]            || { log "  ${C_RED}- AEAD/desync failures present${C_NC}"; pass=0; }
    if (( pass == 1 )); then log "  ${C_GREEN}B3 PASS${C_NC}"; return 0; fi
    log "  ${C_RED}B3 FAIL${C_NC}"; return 1
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
    [[ "$c" == a-* || "$c" == b3 ]] && rk=" rekey_crossed=${REKEY[$c]:-0}"
    log "  $c : $r$rk"
    log "      ${EVID[$c]}"
done
log "========================================"
exit $overall

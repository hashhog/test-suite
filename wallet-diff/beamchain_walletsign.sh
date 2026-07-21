#!/usr/bin/env bash
#
# beamchain_walletsign.sh — walletdiff SLICE 3 (signing + sighash, incl. taproot,
# P2.1) for beamchain (Erlang escript), differential against a REAL bitcoind
# regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparison logic lives
# in wallet-diff/probe_sign.py. This script just launches beamchain + the Core
# oracle and hands both to the shared driver in wallet-diff/_sign_lib.sh.
#
# Launch shape (start_testnet4.sh:105): `beamchain start --network=regtest
# --datadir=<dd> --p2p-port=<n> --rpc-port=<n>`; cookie at
# <datadir>/regtest/.cookie.
#
# Interface: no args; idempotent; scratch /tmp/walletsign-beamchain* only;
# reserved ports 22164/22165 (Core RPC/P2P) + 22166/22167 (beamchain RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF beamchain: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_sign_lib.sh"

IMPL="beamchain"
BIN="$HASHHOG_ROOT/beamchain/_build/default/bin/beamchain"
BUILD_HINT="build with: ./build-all.sh beamchain"

CORE_RPC=22164
CORE_P2P=22165
IMPL_RPC=22166
IMPL_P2P=22167

IMPL_DATADIR="/tmp/walletsign-beamchain"
CORE_DATADIR="/tmp/walletsign-beamchain-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/regtest/.cookie" "$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" start --network=regtest --datadir="$IMPL_DATADIR" \
        --p2p-port="$IMPL_P2P" --rpc-port="$IMPL_RPC" \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_signing_main

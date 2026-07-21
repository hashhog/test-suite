#!/usr/bin/env bash
#
# beamchain_walletdiff_psbt.sh — walletdiff SLICE 2 (PSBT round-trip parity,
# P2.1/P2.2) for beamchain (Erlang escript), differential against a REAL
# wallet-enabled bitcoind regtest oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_psbt.py. This script just launches beamchain + the Core
# oracle and hands both endpoints to the shared driver in _lib_psbt.sh.
#
# Launch shape (start_testnet4.sh:105): `beamchain start --network=regtest
# --datadir=<dd> --p2p-port=<n> --rpc-port=<n>`; cookie at
# <datadir>/regtest/.cookie.
#
# NOTE on wallet routing: the shared probe uses the base URL "/" with a single
# wallet loaded per phase (single-wallet discipline). beamchain resolves an
# empty wallet-name (base URL) to the sole loaded wallet the same way Core does
# when exactly one wallet is loaded, so the base URL is honoured.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-psbt-beamchain* only;
# reserved ports 22160/22161 (Core RPC/P2P) + 22162/22163 (beamchain RPC/P2P);
# ONE summary line on stdout; exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER
# touches /data/nvme1/, testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib_psbt.sh"

IMPL="beamchain"
BIN="$HASHHOG_ROOT/beamchain/_build/default/bin/beamchain"
BUILD_HINT="build with: ./build-all.sh beamchain"

CORE_RPC=22160
CORE_P2P=22161
IMPL_RPC=22162
IMPL_P2P=22163

IMPL_DATADIR="/tmp/walletdiff-psbt-beamchain"
CORE_DATADIR="/tmp/walletdiff-psbt-beamchain-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/regtest/.cookie" "$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" start --network=regtest --datadir="$IMPL_DATADIR" \
        --p2p-port="$IMPL_P2P" --rpc-port="$IMPL_RPC" \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_psbt_main

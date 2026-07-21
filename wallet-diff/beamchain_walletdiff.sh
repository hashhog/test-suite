#!/usr/bin/env bash
#
# beamchain_walletdiff.sh — walletdiff slice 1 (address-derivation parity, P2.1)
# for beamchain (Erlang escript), differential against a REAL bitcoind regtest
# oracle.
#
# Plumbing ONLY (harness-script-consistency memory): all comparisons live in
# wallet-diff/probe_address.py over wallet-diff/vectors-address.json. This
# script just launches beamchain + the Core oracle and hands both to the shared
# driver in wallet-diff/_lib.sh.
#
# Launch shape (start_testnet4.sh:105): `beamchain start --network=<net>
# --datadir=<dd> --p2p-port=<n> --rpc-port=<n>`. For regtest beamchain appends a
# `regtest/` subdir to the datadir (beamchain_config:determine_datadir/1) and
# writes its cookie at <datadir>/regtest/.cookie.
#
# Interface: no args; idempotent; scratch /tmp/walletdiff-beamchain* only;
# reserved ports 22158/22159 (Core RPC/P2P) + 22178/22179 (beamchain RPC/P2P);
# ONE summary line on stdout ("WALLETDIFF beamchain: PASS|FAIL|SKIP|BLOCKED ...");
# exit 0 = PASS/SKIP, 1 = FAIL/BLOCKED. NEVER touches /data/nvme1/,
# testnet4-data/, or any live node.

set -uo pipefail
HASHHOG_ROOT="${HASHHOG_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

IMPL="beamchain"
BIN="$HASHHOG_ROOT/beamchain/_build/default/bin/beamchain"
BUILD_HINT="build with: ./build-all.sh beamchain"

CORE_RPC=22158
CORE_P2P=22159
IMPL_RPC=22178
IMPL_P2P=22179

IMPL_DATADIR="/tmp/walletdiff-beamchain"
CORE_DATADIR="/tmp/walletdiff-beamchain-core"
IMPL_COOKIE_CANDIDATES=("$IMPL_DATADIR/regtest/.cookie" "$IMPL_DATADIR/.cookie")

launch_impl() {
    "$BIN" start --network=regtest --datadir="$IMPL_DATADIR" \
        --p2p-port="$IMPL_P2P" --rpc-port="$IMPL_RPC" \
        >"$IMPL_DATADIR/node.log" 2>&1 &
    IMPL_PID=$!
}

walletdiff_address_main

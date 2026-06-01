#!/usr/bin/env python3
"""haskoin live-arm P2P block-injection harness (W164 hollow-live-path fix).

WHY THIS EXISTS
---------------
haskoin's live inbound-block arm (``syncMessageHandler``'s ``MBlock`` case,
``haskoin/app/Main.hs:2263``) connects a peer-delivered block by calling ONLY
``connectBlock`` / ``connectBlockAt`` (``Consensus.hs:3130``) inside
``connectLock``.  ``connectBlockAt`` enforces ONLY G1 (prevHash == BestBlock),
G2 (genesis), and G19 (prevout existence) — its own docstring
(``Consensus.hs:3156-3190``) states that bad-cb-amount, script verification,
sigops, merkle, BIP30/34/65/66, witness commitment, etc. live UPSTREAM in
``validateFullBlockIO``, which the live arm does NOT call pre-fix.  THAT IS THE
HOLE: a valid-PoW block whose coinbase overpays the subsidy connects on the
live P2P path even though ``submitblock`` and the VerifyScript shim (both of
which DO call ``validateFullBlockIO``) reject it.

Because ``submitblock`` already rejects pre-fix, testing the fix THROUGH
``submitblock`` (as the existing ``tools/diff-test-corpus/regression`` entries
do) is a misleading NO-OP — it passes pre AND post.  The ONLY path that
exposes the difference is a raw ``block`` message pushed straight into the
live MBlock arm.  This harness does exactly that.

DECISION OBSERVED  (accept vs reject):
  * PRE-FIX  : the bad block CONNECTS  -> getblockcount advances to N+1  (BUG)
  * POST-FIX : validateFullBlockIO returns Left -> connectBlock never runs ->
               getblockcount stays at N                                  (FIXED)

This script is intentionally a STANDALONE, read-only sibling of
``p2p_tests.py`` — it imports the already-present MockPeer / handshake / wire
primitives from there and the block-builder primitives from
``regtest_miner.py``; it does not modify either.

USAGE
-----
    # 1. positive control: prove a VALID crafted block at tip+1 DOES connect
    #    through the same raw push (no fix needed; establishes the pipe works).
    python3 haskoin_live_block_inject.py --vector good

    # 2. the EFFECTIVE signal: the three reject vectors.
    python3 haskoin_live_block_inject.py --vector bad-cb-amount
    python3 haskoin_live_block_inject.py --vector bad-tx-in-block      # script-fail
    python3 haskoin_live_block_inject.py --vector bad-blk-sigops       # sigops

Exit codes:
    0 = block was REJECTED (tip did not advance)  -> EXPECTED on the fixed build
        for the three reject vectors; EXPECTED FAIL for --vector good.
    2 = block was ACCEPTED (tip advanced)         -> the pre-fix false-accept
        for the reject vectors; EXPECTED for --vector good.
    1 = harness error (launch / handshake / priming failure).

Run ``--vector good`` first (exit 2 = accepted = pipe works), then each reject
vector twice — once at the parent SHA (expect exit 2, accepted) and once at the
fix SHA (expect exit 0, rejected).  That pre=accept / post=reject delta is the
EFFECTIVE verdict.  See CORE-PARITY-AUDIT/_haskoin-verify-plan-2026-06-01.md.

DO NOT run this while beamchain's flush is using the box's memory — the haskoin
node it launches is light (single regtest node, no snapshot) but the to-tip
``phaseb-revalidate`` regression guard in the plan is NOT.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import signal
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Wire + handshake primitives (self-contained, no node needed to import).
from p2p_tests import MockPeer, do_handshake  # noqa: E402
from regtest_miner import (  # noqa: E402
    bits_to_target,
    compact_size,
    compute_merkle_root,
    encode_coinbase_height,
    rpc_call,
    sha256d,
)

# --------------------------------------------------------------------------
# Constants — fixed, isolated ports so this never collides with the fleet.
# --------------------------------------------------------------------------
HASHHOG = "/home/work/hashhog"
DATADIR = "/tmp/hashhog-haskoin-inject"
RPC_PORT = 31362
P2P_PORT = 31462
RPC_URL = f"http://127.0.0.1:{RPC_PORT}"
RPC_USER = "test"
RPC_PASS = "test"

REGTEST_BITS_HEX = "207fffff"  # haskoin Consensus.hs:1042 regtest powLimit bits
REGTEST_TARGET = bits_to_target(REGTEST_BITS_HEX)  # trivially easy
SUBSIDY_REGTEST = 50 * 100_000_000  # blockRewardForNet(regtest, low height)
COINBASE_MATURITY = 100  # haskoin Consensus.hs netCoinbaseMaturity (regtest=100)

# Monotonic per-height block timestamps.  haskoin's addHeader enforces the
# BIP-113 median-time-past gate (Consensus.hs:4229-4233): a header is rejected
# "time-too-old" unless its timestamp is STRICTLY GREATER than the MTP of the
# prior 11 blocks.  If every block reused int(time.time()) the second block's
# ts would equal the first's and trip the gate.  We anchor a recent base time
# (regtest genesis is 2011; "now" is far past every ancestor's ts) and use
# BASE_TIME + height, so timestamps increase by 1s per block — strictly above
# MTP — while staying well under now + MAX_FUTURE_BLOCK_TIME (the time-too-new
# gate at :4246).  Anchored once at import so priming + injected blocks share
# the same monotone schedule.
BASE_TIME = int(time.time())


def _block_time(height: int) -> int:
    return BASE_TIME + height

OP_TRUE = b"\x51"
# OP_2 ... OP_16 ... OP_CHECKMULTISIG with a huge nominal pubkey count drives
# sigops cost over the per-block budget; see make_block_bad_sigops below.
OP_CHECKMULTISIG = 0xAE
OP_16 = 0x60

# A script that fails evaluation: OP_RETURN-prefixed (provably unspendable) is
# fine for an OUTPUT, but to fail SCRIPT VERIFICATION we need a non-coinbase tx
# whose INPUT scriptSig does not satisfy the prevout scriptPubKey.  Spending an
# OP_TRUE output with an OP_RETURN scriptSig fails (OP_RETURN aborts).
OP_RETURN = b"\x6a"


def _find_haskoin_bin() -> str | None:
    """Mirror smoke-harness.sh:342 — locate the built haskoin executable."""
    base = os.path.join(HASHHOG, "haskoin", "dist-newstyle")
    if not os.path.isdir(base):
        return None
    for root, _dirs, files in os.walk(base):
        for f in files:
            p = os.path.join(root, f)
            if f == "haskoin" and os.access(p, os.X_OK) and os.path.isfile(p):
                return p
    return None


def _rpc(method: str, params=None):
    return rpc_call(RPC_URL, RPC_USER, RPC_PASS, method, params or [])


def launch_node() -> subprocess.Popen:
    """Launch haskoin on regtest with a FIXED inbound listen port.

    CRITICAL: regtest_group1_test.py uses --listen=False/--port=0, which would
    refuse the inbound dial.  We MUST set --listen=True and a fixed --port so
    MockPeer can connect.  (smoke-harness.sh omits --listen, i.e. defaults to
    True per Main.hs:247, but uses an ephemeral port we couldn't predict.)
    """
    hb = _find_haskoin_bin()
    if hb is None:
        print("ERROR: haskoin binary not found under dist-newstyle/ — build it "
              "first (cabal build all), gated behind beamchain memory.",
              file=sys.stderr)
        sys.exit(1)
    os.makedirs(DATADIR, exist_ok=True)
    log = open(os.path.join(DATADIR, "node.log"), "w")
    proc = subprocess.Popen(
        [
            hb, "--network", "Regtest", "--datadir", DATADIR,
            "node",
            "--rpcport", str(RPC_PORT),
            "--rpcuser=test", "--rpcpassword=test",
            "--listen=True",
            "--port", str(P2P_PORT),
            "--metricsport", "0",   # disable: haskoin's fixed 9332 metrics port
                                    # collides with the live mainnet blockbrew node
            "--printtoconsole",     # force startup logging into node.log for debug
        ],
        stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True,  # own process group for clean teardown
    )
    return proc


def wait_for_rpc(timeout: float = 30.0) -> int:
    """Poll getblockcount until the node answers.  Returns current height."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            res, err = _rpc("getblockcount")
            if err is None and res is not None:
                return int(res)
        except Exception:
            pass  # RPC socket not up yet (connection refused during startup) — keep polling
        time.sleep(0.5)
    print("ERROR: haskoin RPC did not come up in time", file=sys.stderr)
    sys.exit(1)


def _submit_legacy_coinbase_block(prevhash_be: str, height: int):
    """Mine + submit a single coinbase-only block at ``height`` extending
    ``prevhash_be`` via the submitblock RPC.  Uses a LEGACY (non-witness)
    coinbase: haskoin's regtest has segwit active but getblocktemplate emits
    NO ``default_witness_commitment``, so a witness-bearing coinbase with no
    commitment output trips ``checkWitnessMalleation``'s no-commitment branch
    -> ``unexpected-witness`` (Consensus.hs:3059-3064).  A witness-free
    coinbase has no commitment requirement and no witness data, so it
    connects cleanly.  Returns (block_hash_be, cb_txid_be, cb_value).

    The coinbase scriptSig encodes ``height`` (BIP34), which submitblock's
    validateFullBlockIO enforces — encode_coinbase_height handles that.
    """
    cb, cb_txid_le = _build_valid_coinbase(height)
    cb_value = SUBSIDY_REGTEST
    merkle = compute_merkle_root([cb_txid_le])
    version = struct.pack("<i", 0x20000000)
    prev_le = bytes.fromhex(prevhash_be)[::-1]
    bits_le = bytes.fromhex(REGTEST_BITS_HEX)[::-1]
    ts = struct.pack("<I", _block_time(height))  # monotone, > parent MTP
    nonce = 0
    while True:
        header = version + prev_le + merkle + ts + bits_le + struct.pack("<I", nonce)
        block_hash_le = sha256d(header)
        if int.from_bytes(block_hash_le, "little") <= REGTEST_TARGET:
            break
        nonce += 1
    block_hex = (header + compact_size(1) + cb).hex()
    res, serr = _rpc("submitblock", [block_hex])
    if serr or (res not in (None, "")):
        print(f"ERROR: priming submitblock rejected: {serr or res}",
              file=sys.stderr)
        sys.exit(1)
    return block_hash_le[::-1].hex(), cb_txid_le[::-1].hex(), cb_value


def prime_chain(n_blocks: int = 105, immature_depth: int = 3):
    """Mine ``n_blocks`` VALID coinbase-only blocks via submitblock so we have
    (a) a tip height >= 101 and (b) TWO spendable OP_TRUE coinbase UTXOs to
    reference in the injected block's non-coinbase tx (needed to pass G19):
    one MATURE (>= COINBASE_MATURITY=100 deep) and one IMMATURE (a few deep).

    We build the priming blocks ENTIRELY in-harness with a legacy
    (non-witness) coinbase rather than reusing regtest_miner.build_coinbase_tx
    / mine_blocks, because those emit a segwit coinbase that haskoin's regtest
    rejects with ``unexpected-witness`` (segwit active but the template carries
    no witness-commitment, so the witness nonce has nowhere to commit).  Using
    the harness's own _serialize_legacy_tx-based coinbase also means the
    recorded spend_outpoint txid is computed by the SAME serializer the bad/good
    blocks use, so it matches haskoin's stored UTXO byte-for-byte.

    WHY >= 101 BLOCKS (load-bearing, per _coinbase-maturity-gap doc):  the
    injected block lands at tip+1.  For the maturity-fix to leave the `good`
    control + the W164 reject vectors UNCHANGED post-fix, each of those vectors
    must spend a MATURE coinbase (their intended defect — bad value / bad script
    / bad sigops — is then the ONLY reason they reject; maturity does not mask
    it).  A coinbase is mature when (tip+1) - coinHeight >= 100.  Priming 105
    blocks gives a tip of (start + 105); the FIRST primed coinbase is then
    >= 104 deep at injection time -> mature.  The new immature vector instead
    spends a RECENT coinbase (``immature_depth`` from the tip, default 3) which
    is < 100 deep -> immature, so AFTER the fix it (and only it) flips to reject.

    Returns (tip_hash_hex_be, tip_height, mature_outpoint, immature_outpoint)
    where each *_outpoint is (txid_be_hex, vout, value):
      * mature_outpoint   = the FIRST primed block's coinbase (>= 100 deep) —
                            used by good / bad-cb-amount / bad-tx-in-block /
                            bad-blk-sigops so only their intended defect remains.
      * immature_outpoint = a coinbase ``immature_depth`` blocks below the tip
                            (< 100 deep) — used by immature-coinbase-spend so the
                            ONLY defect is maturity.
    """
    tip_hash, err = _rpc("getbestblockhash")
    if err:
        print(f"ERROR: getbestblockhash failed: {err}", file=sys.stderr)
        sys.exit(1)
    height, err = _rpc("getblockcount")
    if err:
        print(f"ERROR: getblockcount failed: {err}", file=sys.stderr)
        sys.exit(1)
    height = int(height)

    # Guarantee enough blocks to produce a mature coinbase plus an immature one
    # at the requested depth below the tip.  Need: first coinbase >= 100 deep at
    # injection (tip+1), and a distinct immature coinbase immature_depth deep.
    min_blocks = COINBASE_MATURITY + immature_depth + 1
    if n_blocks < min_blocks:
        n_blocks = min_blocks

    mature_outpoint = None
    immature_outpoint = None
    # The immature coinbase must sit ``immature_depth`` blocks below the final
    # tip.  With a final tip height of (start_height + n_blocks), the coinbase at
    # height (final_tip - immature_depth + 1) is exactly immature_depth deep when
    # the injected block at (final_tip + 1) validates it:
    #     spend_height - coinHeight = (final_tip + 1) - (final_tip - immature_depth + 1)
    #                               = immature_depth   ( < 100 -> immature ).
    final_tip = height + n_blocks
    immature_cb_height = final_tip - immature_depth + 1
    for _ in range(n_blocks):
        next_height = height + 1
        bhash_be, cb_txid_be, cb_value = _submit_legacy_coinbase_block(
            tip_hash, next_height)
        if mature_outpoint is None:
            # FIRST primed block's coinbase -> deepest -> mature at injection.
            mature_outpoint = (cb_txid_be, 0, cb_value)
        if next_height == immature_cb_height:
            # A recent coinbase -> immature_depth deep at injection -> immature.
            immature_outpoint = (cb_txid_be, 0, cb_value)
        tip_hash, height = bhash_be, next_height

    return tip_hash, height, mature_outpoint, immature_outpoint


# --------------------------------------------------------------------------
# Block builders — one valid-PoW block per vector.
# --------------------------------------------------------------------------
def _serialize_legacy_tx(version, inputs, outputs, locktime=0) -> bytes:
    """Non-witness tx serialization.

    inputs : list of (prev_txid_be_hex, vout, script_sig_bytes, sequence)
    outputs: list of (value_sats, script_pubkey_bytes)
    """
    tx = struct.pack("<i", version)
    tx += compact_size(len(inputs))
    for prev_txid_be, vout, ssig, seq in inputs:
        tx += bytes.fromhex(prev_txid_be)[::-1]  # prevout txid LE
        tx += struct.pack("<I", vout)
        tx += compact_size(len(ssig)) + ssig
        tx += struct.pack("<I", seq)
    tx += compact_size(len(outputs))
    for value, spk in outputs:
        tx += struct.pack("<q", value)
        tx += compact_size(len(spk)) + spk
    tx += struct.pack("<I", locktime)
    return tx


def _build_overpaying_coinbase(height: int, extra_sats: int):
    """A coinbase whose single OP_TRUE output value = subsidy + extra_sats.

    Returns (coinbase_serialized_bytes, coinbase_txid_le).  We deliberately use
    a LEGACY (non-witness) coinbase here so the block has no witness commitment
    requirement to satisfy and merkle math stays simple; regtest accepts a
    no-witness block.  (For bad-cb-amount the witness commitment is irrelevant —
    validateFullBlock rejects on value before/independently of it.)
    """
    ssig = encode_coinbase_height(height)
    if len(ssig) < 2:
        ssig += b"\x00"
    value = SUBSIDY_REGTEST + extra_sats
    cb = _serialize_legacy_tx(
        version=2,
        inputs=[("00" * 32, 0xFFFFFFFF, ssig, 0xFFFFFFFF)],
        outputs=[(value, OP_TRUE)],
    )
    return cb, sha256d(cb)


def _build_valid_coinbase(height: int):
    cb, txid = _build_overpaying_coinbase(height, 0)
    return cb, txid


def _assemble_block(prevhash_be: str, height: int, txs: list[bytes]) -> bytes:
    """Brute-force a valid regtest-PoW header over the given tx list and return
    the full serialized block (header || varint(ntx) || tx bytes...).

    ``height`` selects the block timestamp via _block_time so the injected
    block's ts is strictly greater than the primed tip's MTP — otherwise the
    live arm's addHeader rejects it "time-too-old" (Consensus.hs:4229) and the
    test would mis-report a REJECT for reasons unrelated to the gate under
    test."""
    txids_le = [sha256d(tx) for tx in txs]
    merkle = compute_merkle_root(txids_le)
    version = struct.pack("<i", 0x20000000)
    prev_le = bytes.fromhex(prevhash_be)[::-1]
    bits_le = bytes.fromhex(REGTEST_BITS_HEX)[::-1]
    ts = struct.pack("<I", _block_time(height))
    nonce = 0
    while True:
        header = version + prev_le + merkle + ts + bits_le + struct.pack("<I", nonce)
        if int.from_bytes(sha256d(header), "little") <= REGTEST_TARGET:
            break
        nonce += 1
    block = header + compact_size(len(txs))
    for tx in txs:
        block += tx
    return block


def make_block_good(prevhash_be, height, spend_outpoint) -> bytes:
    """POSITIVE CONTROL: a fully valid block at tip+1 (correct subsidy, valid
    spend).  Should connect on BOTH builds (pre and post).  Proves the raw
    'block' push pipe works before we trust a 'rejected' result."""
    prev_txid, vout, prev_value = spend_outpoint
    cb, _ = _build_valid_coinbase(height)
    # A non-coinbase tx spending the OP_TRUE coinbase output -> OP_TRUE, fee 0.
    tx1 = _serialize_legacy_tx(
        version=2,
        inputs=[(prev_txid, vout, b"", 0xFFFFFFFF)],  # OP_TRUE needs empty ssig
        outputs=[(prev_value, OP_TRUE)],
    )
    return _assemble_block(prevhash_be, height, [cb, tx1])


def make_block_bad_cb_amount(prevhash_be, height, spend_outpoint) -> bytes:
    """REJECT VECTOR 1 (bad-cb-amount): coinbase overpays by +100 BTC.

    Includes one valid non-coinbase spend so G19 passes; only the COINBASE
    value is wrong, so validateFullBlock's value check rejects.  This is the
    primary EFFECTIVE signal in the VALIDATED-fix doc test plan (step 1)."""
    prev_txid, vout, prev_value = spend_outpoint
    cb, _ = _build_overpaying_coinbase(height, extra_sats=100 * 100_000_000)
    tx1 = _serialize_legacy_tx(
        version=2,
        inputs=[(prev_txid, vout, b"", 0xFFFFFFFF)],
        outputs=[(prev_value, OP_TRUE)],
    )
    return _assemble_block(prevhash_be, height, [cb, tx1])


def make_block_bad_tx_script(prevhash_be, height, spend_outpoint) -> bytes:
    """REJECT VECTOR 2 (block-script-verify-flag-failed): the non-coinbase tx
    spends the OP_TRUE coinbase output with a scriptSig of OP_RETURN, which
    aborts script evaluation.  Coinbase value is CORRECT, so the ONLY defect is
    script verification — which connectBlock(connectBlockAt) never runs."""
    prev_txid, vout, prev_value = spend_outpoint
    cb, _ = _build_valid_coinbase(height)
    tx1 = _serialize_legacy_tx(
        version=2,
        # scriptSig = OP_RETURN -> evaluation aborts -> script verify fails.
        inputs=[(prev_txid, vout, OP_RETURN, 0xFFFFFFFF)],
        outputs=[(prev_value, OP_TRUE)],
    )
    return _assemble_block(prevhash_be, height, [cb, tx1])


def make_block_bad_sigops(prevhash_be, height, spend_outpoint) -> bytes:
    """REJECT VECTOR 3 (bad-blk-sigops): the non-coinbase tx output carries a
    bare-CHECKMULTISIG scriptPubKey with the max nominal pubkey count (20),
    repeated enough times that the block's accurate sigops cost exceeds the
    per-block budget (MAX_BLOCK_SIGOPS_COST = 80000).  A bare CHECKMULTISIG
    without a preceding push counts as 20 sigops (the legacy fallback).  We
    place MANY such outputs.  Coinbase value + the spend are otherwise valid;
    only the sigops budget is violated.

    NOTE: a bare CHECKMULTISIG output spending nothing is fine for the SIGOPS
    accounting (Core counts scriptPubKey sigops of all outputs); we do not need
    these outputs to be spendable.  Values sum to <= prev_value so value
    conservation holds.
    """
    prev_txid, vout, prev_value = spend_outpoint
    cb, _ = _build_valid_coinbase(height)
    # Each bare OP_CHECKMULTISIG scriptPubKey = 20 legacy sigops * 4 (cost) = 80.
    # 80000 budget / 80 = 1000 outputs to exceed; use 1100 to be safe.
    bare_cms = bytes([OP_CHECKMULTISIG])
    n_outputs = 1100
    per = max(1, prev_value // (n_outputs + 1))
    outputs = [(per, bare_cms) for _ in range(n_outputs)]
    tx1 = _serialize_legacy_tx(
        version=2,
        inputs=[(prev_txid, vout, b"", 0xFFFFFFFF)],
        outputs=outputs,
    )
    return _assemble_block(prevhash_be, height, [cb, tx1])


def make_block_immature_coinbase_spend(prevhash_be, height, spend_outpoint) -> bytes:
    """REJECT VECTOR 4 (bad-txns-premature-spend-of-coinbase): the non-coinbase
    tx spends an IMMATURE coinbase output — one only a few blocks deep (3 by
    default), far short of COINBASE_MATURITY=100.  Coinbase value is CORRECT and
    the input script is empty (OP_TRUE prevout, satisfied trivially), so the
    block is otherwise fully valid — the ONLY defect is coinbase maturity.

    Unlike the good / bad-* vectors (which spend the MATURE primed coinbase so
    only their intended defect remains), this one is deliberately wired by
    main() to the IMMATURE outpoint recorded by prime_chain.

    Maturity is checked in validateFullBlock (Consensus.hs section 0a, applied
    fix); the live-arm connectBlock(connectBlockAt) never ran it pre-fix, and the
    TxOut-only utxoMap at Consensus.hs:2504 discards the per-coin height/coinbase
    metadata the check needs.

    Expected: PRE-FIX  -> ACCEPTED (tip advances) = the maturity false-accept.
              POST-FIX -> REJECTED (tip stays)    = validateFullBlock now runs
                          the maturity loop (section 0a).
    Bitcoin Core verdict on the equivalent block: reject
    bad-txns-premature-spend-of-coinbase (consensus/tx_verify.cpp:179,
    validation.cpp:2535 connect-path, no +1).
    """
    prev_txid, vout, prev_value = spend_outpoint
    cb, _ = _build_valid_coinbase(height)
    tx1 = _serialize_legacy_tx(
        version=2,
        inputs=[(prev_txid, vout, b"", 0xFFFFFFFF)],  # OP_TRUE: empty scriptSig
        outputs=[(prev_value, OP_TRUE)],
    )
    return _assemble_block(prevhash_be, height, [cb, tx1])


VECTORS = {
    "good": make_block_good,
    "bad-cb-amount": make_block_bad_cb_amount,
    "bad-tx-in-block": make_block_bad_tx_script,
    "bad-blk-sigops": make_block_bad_sigops,
    "immature-coinbase-spend": make_block_immature_coinbase_spend,  # NEW
}

# Vectors that must spend a MATURE coinbase so the maturity fix leaves them
# unchanged (their intended defect — or, for `good`, nothing — is the only
# reason they accept/reject).  The maturity vector alone spends the immature
# coinbase.  main() uses this set to pick which recorded outpoint to feed each
# builder.
IMMATURE_VECTORS = {"immature-coinbase-spend"}


# --------------------------------------------------------------------------
# Injection
# --------------------------------------------------------------------------
async def inject(block_bytes: bytes, settle: float = 3.0):
    peer = MockPeer("127.0.0.1", P2P_PORT)
    await peer.connect(timeout=10.0)
    try:
        if not await do_handshake(peer):
            print("ERROR: handshake with haskoin failed", file=sys.stderr)
            sys.exit(1)
        await peer.send("block", block_bytes)
        await asyncio.sleep(settle)
    finally:
        await peer.disconnect()


def teardown(proc: subprocess.Popen):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception:
        pass
    try:
        proc.wait(timeout=15)
    except Exception:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--vector", required=True, choices=sorted(VECTORS),
                    help="which block to inject")
    ap.add_argument("--prime", type=int, default=105,
                    help="number of valid blocks to mine before injecting "
                         "(>= 101 so a MATURE coinbase exists; clamped up "
                         "internally if too low)")
    ap.add_argument("--immature-depth", type=int, default=3,
                    help="depth (< 100) of the coinbase the immature-coinbase-"
                         "spend vector references")
    ap.add_argument("--keep-datadir", action="store_true")
    args = ap.parse_args()

    proc = launch_node()
    rc = 1
    try:
        wait_for_rpc()
        tip_hash, tip_height, mature_outpoint, immature_outpoint = prime_chain(
            args.prime, args.immature_depth)
        # Mature coinbase is the FIRST primed block's, at height 1 (node starts
        # at genesis=0), so its depth at injection (tip+1) == tip_height.
        mature_depth = tip_height
        print(f"[prime] tip={tip_hash[:16]}... height={tip_height}\n"
              f"        mature_outpoint=({mature_outpoint[0][:16]}...,"
              f"{mature_outpoint[1]},{mature_outpoint[2]} sats) "
              f"depth={mature_depth} (>= {COINBASE_MATURITY} -> mature)\n"
              f"        immature_outpoint=({immature_outpoint[0][:16]}...,"
              f"{immature_outpoint[1]},{immature_outpoint[2]} sats) "
              f"depth={args.immature_depth} (< {COINBASE_MATURITY} -> immature)")

        # Maturity vector spends the IMMATURE coinbase (its only defect is
        # maturity); every other vector spends the MATURE coinbase so the
        # maturity fix leaves it unchanged.
        spend_outpoint = (immature_outpoint if args.vector in IMMATURE_VECTORS
                          else mature_outpoint)
        builder = VECTORS[args.vector]
        block = builder(tip_hash, tip_height + 1, spend_outpoint)
        print(f"[inject] vector={args.vector} size={len(block)} bytes "
              f"at height {tip_height + 1} "
              f"(spends {'immature' if args.vector in IMMATURE_VECTORS else 'mature'} "
              f"coinbase {spend_outpoint[0][:16]}...)")

        asyncio.run(inject(block))

        new_height, err = _rpc("getblockcount")
        if err:
            print(f"ERROR: post-inject getblockcount failed: {err}", file=sys.stderr)
            sys.exit(1)
        new_height = int(new_height)

        accepted = new_height == tip_height + 1
        if accepted:
            print(f"RESULT: ACCEPTED  (tip {tip_height} -> {new_height})")
            if args.vector == "good":
                print("  => positive control OK: the raw 'block' push connects.")
            else:
                print("  => PRE-FIX false-accept (this is the BUG the fix closes).")
            rc = 2
        else:
            print(f"RESULT: REJECTED  (tip stayed at {tip_height})")
            if args.vector == "good":
                print("  => UNEXPECTED: a VALID block was rejected — pipe/positive "
                      "control broken; fix the harness before trusting rejects.")
            else:
                print("  => POST-FIX: validateFullBlockIO rejected on the live arm.")
            rc = 0
    finally:
        teardown(proc)
        if not args.keep_datadir:
            import shutil
            shutil.rmtree(DATADIR, ignore_errors=True)
    sys.exit(rc)


if __name__ == "__main__":
    main()

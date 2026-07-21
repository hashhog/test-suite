#!/usr/bin/env python3
"""probe_sign.py — the ONE shared comparator for walletdiff SLICE 3 (signing +
sighash correctness, incl. TAPROOT key-path). Design mirrors probe_address.py.

Per the harness-script-consistency memory, ALL comparison logic lives HERE; the
per-impl shell adapters (<impl>_walletsign.sh) supply only launch/RPC plumbing
and may not weaken a comparison. This probe talks to BOTH endpoints:
  * the SUT (flagship) wallet RPC — creates a wallet, obtains a receive address
    per address type, mines coinbases to those addresses, and signs a spend of
    each via signrawtransactionwithwallet (the wallet's own sign path).
  * a REAL bitcoind regtest ORACLE — receives the SUT's blocks via submitblock
    (so it shares the exact chainstate incl. the funding coinbases), then acts
    as the ground truth: testmempoolaccept on the SUT-signed tx. Core ACCEPTING
    the spend is the authoritative proof the signature + sighash are consensus
    valid (BIP-143 for segwit-v0 p2wpkh, BIP-341 Schnorr key-path for taproot).

Why Core-as-validator and not a second sighash implementation: re-deriving the
sighash in Python would just be another thing that can carry the same bug. Core
is the oracle. A spend Core accepts is valid; a spend Core rejects is not, and
the reject-reason distinguishes wrong-sighash from wrong-signature.

Funding design (self-contained, no P2P, deterministic):
  1. SUT createwallet; get a p2wpkh addr and (if supported) a p2tr addr.
     Address type is CONFIRMED via Core validateaddress witness_version
     (0 = p2wpkh, 1 = p2tr) — if the SUT ignores the requested type and hands
     back a v0 address for a bech32m request, taproot receive is UNAVAILABLE
     and reported precisely (missing-tr-receive, not a wrong signature).
  2. SUT mines ONE coinbase to each funding address, then 101 padding blocks
     (regtest COINBASE_MATURITY=100) so every funding coinbase is spendable.
     Coinbase-only blocks carry no witness data -> no BIP-141 commitment needed
     -> Core accepts them verbatim via submitblock.
  3. Replay every SUT block into Core (getblock verbosity 0 -> submitblock).
     Core and SUT best-hash must match afterwards (also a free consensus check).
  4. Per funding type: build an unsigned 1-in/1-out spend of that coinbase in
     PYTHON (isolating the SIGNING as the thing under test), sign it on the SUT
     via signrawtransactionwithwallet, assert complete=true, then Core
     testmempoolaccept(maxfeerate=0) MUST return allowed=true.

Exit codes (consumed by _sign_lib.sh -> runner):
  0 every attempted type produced a Core-ACCEPTED spend AND taproot was among
    them (full taproot-inclusive pass).
  1 a funding-relevant failure: any type Core-REJECTED (wrong sighash/sig),
    SIGN-INCOMPLETE on an owned UTXO, coinbase did not pay the address, OR
    taproot receive UNAVAILABLE (cannot obtain a spendable bech32m address).
    All of these mean "cannot produce a Core-accepted taproot/spend" and are
    funding-blocking — surfaced RED, never a silent green.
  2 a required RPC is missing on the SUT (build/RPC gap) -> runner SKIP.
  3 infra: Core rejected a replayed block, chain divergence after replay, or an
    RPC transport failure -> runner INFRA (comparison neither proven nor
    disproven).

Output (stdout): one "PROBE <type> <verdict>[ <detail>]" line per address type,
a final "SUMMARY sign=x/n accept=y/n [type=verdict ...]" line, plus
"RPCGAP <detail>" / "INFRA <detail>" markers. --results-out writes a JSON
receipt (mirrors probe_address.py / results/crash-recovery.json precedent).
"""
import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.request

METHOD_NOT_FOUND = -32601
FEE_SATS = 10_000            # generous fee; testmempoolaccept run with maxfeerate=0
PADDING_BLOCKS = 101         # > COINBASE_MATURITY(100) so funding coinbases mature
SEQ_RBF = 0xFFFFFFFD


class RpcGap(Exception):
    pass


class RpcInfra(Exception):
    pass


def make_rpc(url, cookie, label):
    auth = "Basic " + base64.b64encode(cookie.encode()).decode()
    counter = [0]

    def rpc(method, params):
        counter[0] += 1
        body = json.dumps(
            {"jsonrpc": "1.0", "id": counter[0], "method": method, "params": params}
        ).encode()
        req = urllib.request.Request(
            url, data=body,
            headers={"Authorization": auth, "Content-Type": "application/json"},
        )
        last = None
        for _ in range(3):
            try:
                with urllib.request.urlopen(req, timeout=120) as r:
                    d = json.loads(r.read())
                return d.get("result"), d.get("error")
            except urllib.error.HTTPError as e:
                try:
                    d = json.loads(e.read())
                    return d.get("result"), d.get("error")
                except Exception:
                    last = e
            except Exception as e:
                last = e
            time.sleep(1)
        raise RpcInfra(f"{label}:{method}: transport failure after 3 attempts: {last}")

    return rpc


def err_is_method_missing(err):
    if not isinstance(err, dict):
        return False
    if err.get("code") == METHOD_NOT_FOUND:
        return True
    return "method not found" in str(err.get("message", "")).lower()


# ── minimal legacy (no-witness) tx serialization — the unsigned spend the SUT
#    wallet will sign. Built here so the SIGNING is the only thing under test. ──
def _varint(n):
    if n < 0xFD:
        return n.to_bytes(1, "little")
    if n <= 0xFFFF:
        return b"\xfd" + n.to_bytes(2, "little")
    if n <= 0xFFFFFFFF:
        return b"\xfe" + n.to_bytes(4, "little")
    return b"\xff" + n.to_bytes(8, "little")


def build_unsigned_spend(prev_txid_be, prev_vout, out_value_sat, out_spk_hex):
    txid_le = bytes.fromhex(prev_txid_be)[::-1]   # RPC txids are display/big-endian
    spk = bytes.fromhex(out_spk_hex)
    tx = b""
    tx += (2).to_bytes(4, "little")                      # version
    tx += _varint(1)                                     # vin count
    tx += txid_le + prev_vout.to_bytes(4, "little")      # outpoint
    tx += _varint(0)                                     # empty scriptSig (unsigned)
    tx += SEQ_RBF.to_bytes(4, "little")                  # sequence
    tx += _varint(1)                                     # vout count
    tx += out_value_sat.to_bytes(8, "little") + _varint(len(spk)) + spk
    tx += (0).to_bytes(4, "little")                      # locktime
    return tx.hex()


def core_validate(core, addr):
    """Return (isvalid, witness_version_or_None, scriptPubKey_hex) via Core."""
    res, err = core("validateaddress", [addr])
    if err is not None:
        raise RpcInfra(f"core validateaddress errored: {err}")
    res = res or {}
    wv = res.get("witness_version")
    return bool(res.get("isvalid")), wv, res.get("scriptPubKey")


def get_receive_address(impl, core, want_type):
    """Obtain a SUT receive address of want_type ('p2wpkh'|'p2tr'), CONFIRMED by
    Core's witness_version. Returns (addr, spk) or raises RpcGap for a missing
    getnewaddress. Returns (None, None) when the SUT cannot produce that type."""
    req = "bech32" if want_type == "p2wpkh" else "bech32m"
    want_wv = 0 if want_type == "p2wpkh" else 1
    res, err = impl("getnewaddress", ["", req])
    if err is not None:
        if err_is_method_missing(err):
            raise RpcGap("getnewaddress RPC missing")
        # Some impls reject an unknown address-type outright — that's "no support".
        return None, None
    addr = res
    if not isinstance(addr, str) or not addr:
        return None, None
    isvalid, wv, spk = core_validate(core, addr)
    if not isvalid or wv != want_wv:
        # SUT handed back a different type than requested (e.g. ignored bech32m
        # and returned a v0 address): the requested receive type is unavailable.
        return None, None
    return addr, spk


def replay_chain_into_core(impl, core):
    """getblock(verbosity=0) every SUT block -> Core submitblock. Raises
    RpcInfra if Core rejects a block or the chains diverge afterwards."""
    cnt, err = impl("getblockcount", [])
    if err is not None:
        raise RpcInfra(f"impl getblockcount errored: {err}")
    for h in range(1, int(cnt) + 1):
        bh, e1 = impl("getblockhash", [h])
        if e1 is not None:
            raise RpcInfra(f"impl getblockhash({h}) errored: {e1}")
        raw, e2 = impl("getblock", [bh, 0])
        if e2 is not None:
            raise RpcInfra(f"impl getblock({h},0) errored: {e2}")
        if not isinstance(raw, str):
            raise RpcInfra(f"impl getblock({h},0) not raw hex: {type(raw).__name__}")
        sres, serr = core("submitblock", [raw])
        if serr is not None:
            raise RpcInfra(f"core submitblock(height {h}) rpc error: {serr}")
        # submitblock returns null on success, else a reject-reason string.
        if sres not in (None, "", "duplicate", "inconclusive"):
            raise RpcInfra(f"core REJECTED impl block at height {h}: {sres!r} "
                           f"(cannot establish shared chainstate for validation)")
    itip, _ = impl("getbestblockhash", [])
    ctip, _ = core("getbestblockhash", [])
    if itip != ctip:
        raise RpcInfra(f"chain divergence after replay: impl tip={itip} core tip={ctip}")
    return itip


def locate_coinbase_utxo(core, block_hash, spk_hex):
    """On Core (post-replay), find the coinbase output paying spk_hex.
    Returns (txid, vout, amount_sats) or (None,None,None)."""
    blk, err = core("getblock", [block_hash, 2])
    if err is not None:
        raise RpcInfra(f"core getblock({block_hash},2) errored: {err}")
    cb = (blk or {}).get("tx", [{}])[0]
    txid = cb.get("txid")
    for vout in cb.get("vout", []):
        if (vout.get("scriptPubKey") or {}).get("hex") == spk_hex:
            n = vout.get("n")
            amt = int(round(float(vout.get("value")) * 1e8))
            # confirm unspent + mature in Core's UTXO set
            u, uerr = core("gettxout", [txid, n])
            if uerr is not None or u is None:
                return None, None, None
            return txid, n, amt
    return None, None, None


def probe_type(impl, core, want_type, dest_spk):
    """Full fund->sign->validate for one address type. Returns a verdict dict:
       verdict in {ACCEPT, REJECT, SIGN-INCOMPLETE, FUND-FAILED, NO-RECEIVE}."""
    addr, spk = get_receive_address(impl, core, want_type)
    if addr is None:
        return {"type": want_type, "verdict": "NO-RECEIVE",
                "detail": f"SUT cannot produce a spendable {want_type} receive "
                          f"address (requested {'bech32' if want_type=='p2wpkh' else 'bech32m'})"}

    # Mine one coinbase to this address (funding), record the block.
    bh, err = impl("generatetoaddress", [1, addr])
    if err is not None:
        if err_is_method_missing(err):
            raise RpcGap("generatetoaddress RPC missing")
        return {"type": want_type, "verdict": "FUND-FAILED",
                "detail": f"generatetoaddress errored: {err}"}
    block_hash = bh[0] if isinstance(bh, list) and bh else bh
    return {"type": want_type, "verdict": "_FUNDED", "addr": addr, "spk": spk,
            "block_hash": block_hash}


def sign_and_validate(impl, core, ent, dest_spk):
    """After chain replay: locate the coinbase, sign on SUT, validate on Core."""
    want_type = ent["type"]
    txid, vout, amt = locate_coinbase_utxo(core, ent["block_hash"], ent["spk"])
    if txid is None:
        return {"type": want_type, "verdict": "FUND-FAILED",
                "detail": f"coinbase in {ent['block_hash'][:16]}.. did not pay the "
                          f"requested {want_type} address / not in Core UTXO set"}

    unsigned = build_unsigned_spend(txid, vout, amt - FEE_SATS, dest_spk)
    res, err = impl("signrawtransactionwithwallet", [unsigned])
    if err is not None:
        if err_is_method_missing(err):
            raise RpcGap("signrawtransactionwithwallet RPC missing")
        return {"type": want_type, "verdict": "SIGN-INCOMPLETE",
                "detail": f"signrawtransactionwithwallet errored: {err}"}
    res = res or {}
    signed_hex = res.get("hex")
    complete = res.get("complete")
    if not complete or not signed_hex:
        errs = res.get("errors")
        return {"type": want_type, "verdict": "SIGN-INCOMPLETE",
                "detail": f"complete={complete!r} (wallet could not sign the "
                          f"{want_type} UTXO it owns); errors={errs}"}

    # Core is the oracle: does it accept the SUT-produced signature?
    tma, terr = core("testmempoolaccept", [[signed_hex], 0])
    if terr is not None:
        raise RpcInfra(f"core testmempoolaccept errored: {terr}")
    entry = tma[0] if isinstance(tma, list) and tma else {}
    if entry.get("allowed") is True:
        return {"type": want_type, "verdict": "ACCEPT",
                "detail": f"vsize={entry.get('vsize')}", "signed_len": len(signed_hex)}
    reason = entry.get("reject-reason") or entry.get("reject_reason") or entry
    return {"type": want_type, "verdict": "REJECT",
            "detail": f"Core rejected SUT {want_type} signature: {reason} "
                      f"(wrong sighash or invalid signature — funding-critical)"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--impl", required=True)
    ap.add_argument("--impl-url", required=True)
    ap.add_argument("--impl-cookie-file", required=True)
    ap.add_argument("--core-url", required=True)
    ap.add_argument("--core-cookie-file", required=True)
    ap.add_argument("--results-out")
    args = ap.parse_args()

    with open(args.impl_cookie_file) as f:
        impl_cookie = f.read().strip()
    with open(args.core_cookie_file) as f:
        core_cookie = f.read().strip()
    impl = make_rpc(args.impl_url, impl_cookie, "impl")
    core = make_rpc(args.core_url, core_cookie, "core")

    types = ["p2wpkh", "p2tr"]
    verdicts = []
    try:
        # 0. Fresh wallet on the SUT.
        _, cerr = impl("createwallet", [args.impl])
        if cerr is not None and not err_is_method_missing(cerr):
            # Some SUTs auto-load a default wallet / disallow named creates; try
            # continuing (getnewaddress will fail loudly if there is no wallet).
            pass
        if cerr is not None and err_is_method_missing(cerr):
            print("RPCGAP createwallet RPC missing")
            sys.exit(2)

        # 1. Fund each supported type (mine coinbase to a confirmed address).
        funded = []
        for t in types:
            v = probe_type(impl, core, t, None)
            if v["verdict"] == "_FUNDED":
                funded.append(v)
            else:
                verdicts.append(v)

        # 2. Pad to maturity, then replay the whole chain into Core.
        pad_addr = funded[0]["addr"] if funded else None
        if pad_addr is None:
            # No fundable address at all -> nothing to sign. Still emit verdicts.
            pass
        else:
            _, e = impl("generatetoaddress", [PADDING_BLOCKS, pad_addr])
            if e is not None:
                raise RpcInfra(f"impl padding generatetoaddress errored: {e}")
            replay_chain_into_core(impl, core)

            # 3. Destination spk = the p2wpkh receive spk (pay back to wallet).
            dest_spk = next((f["spk"] for f in funded if f["type"] == "p2wpkh"),
                            funded[0]["spk"])

            # 4. Sign + Core-validate each funded type.
            for ent in funded:
                verdicts.append(sign_and_validate(impl, core, ent, dest_spk))
    except RpcGap as e:
        print(f"RPCGAP {e}")
        sys.exit(2)
    except RpcInfra as e:
        print(f"INFRA {e}")
        sys.exit(3)

    # Order verdicts p2wpkh then p2tr for a stable summary.
    order = {"p2wpkh": 0, "p2tr": 1}
    verdicts.sort(key=lambda v: order.get(v["type"], 9))
    for v in verdicts:
        line = f"PROBE {v['type']} {v['verdict']}"
        if v.get("detail"):
            line += f" {v['detail']}"
        print(line)

    n_types = len(types)
    n_sign = sum(1 for v in verdicts if v["verdict"] in ("ACCEPT", "REJECT"))
    n_accept = sum(1 for v in verdicts if v["verdict"] == "ACCEPT")
    per = " ".join(f"{v['type']}={v['verdict']}" for v in verdicts)

    if args.results_out:
        receipt = {
            "suite": "walletdiff-signing",
            "impl": args.impl,
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "types_attempted": n_types,
            "signed": n_sign, "accepted": n_accept,
            "verdicts": verdicts,
        }
        try:
            with open(args.results_out, "w") as f:
                json.dump(receipt, f, indent=1)
        except OSError:
            pass

    summary = f"sign={n_sign}/{n_types} accept={n_accept}/{n_types} [{per}]"
    print(f"SUMMARY {summary}")

    # Verdict policy: full green ONLY when every type Core-accepted (incl. taproot).
    ok = (len(verdicts) == n_types
          and all(v["verdict"] == "ACCEPT" for v in verdicts))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

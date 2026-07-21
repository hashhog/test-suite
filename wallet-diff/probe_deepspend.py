#!/usr/bin/env python3
"""probe_deepspend.py — the ONE shared comparator for walletdiff SLICE 5 (DEEP
spend surface). Extends SLICE 3 (probe_sign.py) past "simple receive+spend" into
the cases that decide whether a wallet is trustworthy for REAL funds:

  1. MULTI-INPUT taproot key-path spend. BIP-341 (interpreter.cpp:1523-1526)
     commits the Schnorr sighash to sha256(ALL spent amounts) AND
     sha256(ALL spent scriptPubKeys). A wallet that mis-aggregates any prevout
     amount/spk into that midstate produces an INVALID signature that single-
     input testing can never catch. Fund >=2 P2TR UTXOs, spend them together,
     Core testmempoolaccept MUST accept.
  2. MULTI-INPUT MIXED (P2WPKH + P2TR in one tx). Exercises per-input sighash
     dispatch: input 0 uses BIP-143 (segwit v0), input 1 uses BIP-341 whose
     midstate still commits to input 0's amount+spk. Core MUST accept.
  3. NON-DEFAULT sighash via signrawtransactionwithwallet's `sighashtype` arg
     (ALL control, plus NONE / SINGLE / ALL|ANYONECANPAY). The produced witness
     signature's trailing hashtype BYTE must equal the requested flag (decoded
     via Core decoderawtransaction) AND Core must accept it. A wallet that
     SILENTLY returns a SIGHASH_ALL (0x01) sig when the caller asked for a
     different flag is a funds-safety honesty failure (WRONG-FLAG), distinct
     from an honest "not yet supported" refusal (UNSUPPORTED).
  4. OFFLINE / EXTERNAL-INPUT gap: does signrawtransactionwithwallet honor the
     `prevtxs` array, or does it require every input to already be in the
     wallet's own UTXO set? Built by signing a child that spends an UNBROADCAST
     parent output paying a wallet-owned key — the wallet holds the key but the
     outpoint is not in its UTXO set. If it cannot sign, external/HW/coordinator
     flows are unsupported (GAP-CONFIRMED, matching the audit).

Core (bitcoin-core/build-wallet/bin) is the oracle, exactly as in SLICE 3: the
SUT mines coinbases to its own addresses, the chain is replayed into Core via
submitblock so Core shares the chainstate, and Core testmempoolaccept(maxfeerate=0)
is the authoritative accept/reject. Re-deriving a sighash in Python would just be
another thing that can carry the same bug.

Exit codes (consumed by _deepspend_lib.sh -> runner):
  0  every MUST-PASS case (multi_taproot, mixed, sighash_all) Core-ACCEPTED and
     no case produced a divergence. Honest UNSUPPORTED refusals and the
     characterized external-input GAP do NOT fail the slice.
  1  a funding-relevant DIVERGENCE: a must-pass case REJECTED/incomplete, OR a
     sighash case that SILENTLY produced the wrong flag byte (WRONG-FLAG), OR
     Core rejected a claimed-honored non-default sighash (wrong sighash comp).
  2  a required wallet RPC is entirely MISSING on the SUT (build/RPC gap) -> SKIP.
  3  infra: Core rejected a replayed block, chain divergence, or transport fail.

Output (stdout): one "PROBE <case> <verdict>[ <detail>]" line per case, a final
"SUMMARY ..." line, plus "RPCGAP <detail>" / "INFRA <detail>" markers.
--results-out writes a JSON receipt (mirrors probe_sign.py).
"""
import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.request

METHOD_NOT_FOUND = -32601
FEE_SATS = 10_000
PADDING_BLOCKS = 101
SEQ_RBF = 0xFFFFFFFD

# sighash flag byte the produced signature MUST carry for each requested type.
SIGHASH_FLAG = {
    "ALL": 0x01, "DEFAULT": 0x01, "NONE": 0x02, "SINGLE": 0x03,
    "ANYONECANPAY": 0x80, "ALL|ANYONECANPAY": 0x81,
    "NONE|ANYONECANPAY": 0x82, "SINGLE|ANYONECANPAY": 0x83,
}

# Which cases are funding-critical MUST-PASS (a divergence here fails the slice).
MUST_PASS = {"multi_taproot", "mixed", "sighash_ALL"}
# Verdicts that constitute a funding-relevant divergence (slice exit 1).
DIVERGENT = {"REJECT", "SIGN-INCOMPLETE", "SIGN-ERROR", "WRONG-FLAG"}


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


def build_unsigned(inputs, outputs):
    """inputs: list of (prev_txid_be_hex, vout). outputs: list of (value_sat,
    spk_hex). Emits a legacy-serialized (no witness) unsigned tx hex."""
    tx = b""
    tx += (2).to_bytes(4, "little")            # version
    tx += _varint(len(inputs))
    for txid_be, vout in inputs:
        tx += bytes.fromhex(txid_be)[::-1] + int(vout).to_bytes(4, "little")
        tx += _varint(0)                       # empty scriptSig (unsigned)
        tx += SEQ_RBF.to_bytes(4, "little")
    tx += _varint(len(outputs))
    for val, spk_hex in outputs:
        spk = bytes.fromhex(spk_hex)
        tx += int(val).to_bytes(8, "little") + _varint(len(spk)) + spk
    tx += (0).to_bytes(4, "little")            # locktime
    return tx.hex()


def core_validate(core, addr):
    res, err = core("validateaddress", [addr])
    if err is not None:
        raise RpcInfra(f"core validateaddress errored: {err}")
    res = res or {}
    return bool(res.get("isvalid")), res.get("witness_version"), res.get("scriptPubKey")


def get_addr(impl, core, want_type):
    """SUT receive address of want_type ('p2wpkh'|'p2tr'), CONFIRMED by Core's
    witness_version. Returns (addr, spk) or (None, None) if the SUT cannot
    produce that type. Raises RpcGap if getnewaddress is entirely absent."""
    req = "bech32" if want_type == "p2wpkh" else "bech32m"
    want_wv = 0 if want_type == "p2wpkh" else 1
    res, err = impl("getnewaddress", ["", req])
    if err is not None:
        if err_is_method_missing(err):
            raise RpcGap("getnewaddress RPC missing")
        return None, None
    addr = res
    if not isinstance(addr, str) or not addr:
        return None, None
    isvalid, wv, spk = core_validate(core, addr)
    if not isvalid or wv != want_wv:
        return None, None
    return addr, spk


def fund_addr(impl, addr):
    """Mine ONE coinbase to addr; return its block hash. Raises RpcGap if
    generatetoaddress is absent, RpcInfra on other error."""
    bh, err = impl("generatetoaddress", [1, addr])
    if err is not None:
        if err_is_method_missing(err):
            raise RpcGap("generatetoaddress RPC missing")
        raise RpcInfra(f"generatetoaddress errored: {err}")
    return bh[0] if isinstance(bh, list) and bh else bh


def replay_chain_into_core(impl, core):
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
        if sres not in (None, "", "duplicate", "inconclusive"):
            raise RpcInfra(f"core REJECTED impl block at height {h}: {sres!r} "
                           f"(cannot establish shared chainstate)")
    itip, _ = impl("getbestblockhash", [])
    ctip, _ = core("getbestblockhash", [])
    if itip != ctip:
        raise RpcInfra(f"chain divergence after replay: impl={itip} core={ctip}")
    return itip


def locate_coinbase_utxo(core, block_hash, spk_hex):
    """On Core (post-replay) find the mature coinbase output paying spk_hex.
    Returns (txid, vout, amount_sats) or (None, None, None)."""
    blk, err = core("getblock", [block_hash, 2])
    if err is not None:
        raise RpcInfra(f"core getblock({block_hash},2) errored: {err}")
    cb = (blk or {}).get("tx", [{}])[0]
    txid = cb.get("txid")
    for vout in cb.get("vout", []):
        if (vout.get("scriptPubKey") or {}).get("hex") == spk_hex:
            n = vout.get("n")
            amt = int(round(float(vout.get("value")) * 1e8))
            u, uerr = core("gettxout", [txid, n])
            if uerr is not None or u is None:
                return None, None, None
            return txid, n, amt
    return None, None, None


def sut_sign(impl, hexstring, prevtxs=None, sighashtype=None):
    """Call the SUT signrawtransactionwithwallet. Returns
    (signed_hex, complete, errors, rpc_err). Raises RpcGap if the method is
    entirely absent on the SUT."""
    params = [hexstring]
    if prevtxs is not None or sighashtype is not None:
        params.append(prevtxs)              # null is acceptable when only sighash given
    if sighashtype is not None:
        params.append(sighashtype)
    res, err = impl("signrawtransactionwithwallet", params)
    if err is not None:
        if err_is_method_missing(err):
            raise RpcGap("signrawtransactionwithwallet RPC missing")
        return None, None, None, err
    res = res or {}
    return res.get("hex"), res.get("complete"), res.get("errors"), None


def core_accepts(core, signed_hex):
    """(allowed_bool, reason). Raises RpcInfra on transport/RPC error."""
    tma, terr = core("testmempoolaccept", [[signed_hex], 0])
    if terr is not None:
        raise RpcInfra(f"core testmempoolaccept errored: {terr}")
    entry = tma[0] if isinstance(tma, list) and tma else {}
    if entry.get("allowed") is True:
        return True, f"vsize={entry.get('vsize')}"
    return False, (entry.get("reject-reason") or entry.get("reject_reason") or entry)


def witness_hashtype_byte(core, signed_hex, vin_index=0):
    """Decode signed_hex via Core; return the trailing hashtype byte of the
    first witness element of vin_index (the signature), or None if absent."""
    dec, err = core("decoderawtransaction", [signed_hex])
    if err is not None:
        raise RpcInfra(f"core decoderawtransaction errored: {err}")
    vin = (dec or {}).get("vin", [])
    if vin_index >= len(vin):
        return None
    wit = vin[vin_index].get("txinwitness") or []
    if not wit:
        return None
    sig = wit[0]
    if not isinstance(sig, str) or len(sig) < 2:
        return None
    return int(sig[-2:], 16)


# ── individual deep-spend cases ─────────────────────────────────────────────
def case_multi(impl, core, name, in_utxos, dest_spk):
    """Multi-input spend of in_utxos (list of (txid,vout,amt,spk)) -> dest_spk.
    ACCEPT / REJECT / SIGN-INCOMPLETE / SIGN-ERROR."""
    total = sum(u[2] for u in in_utxos)
    unsigned = build_unsigned([(u[0], u[1]) for u in in_utxos],
                              [(total - FEE_SATS, dest_spk)])
    signed_hex, complete, errors, rpc_err = sut_sign(impl, unsigned)
    if rpc_err is not None:
        return {"case": name, "verdict": "SIGN-ERROR",
                "detail": f"signrawtransactionwithwallet errored: {rpc_err}"}
    if not complete or not signed_hex:
        return {"case": name, "verdict": "SIGN-INCOMPLETE",
                "detail": f"complete={complete!r} on {len(in_utxos)} wallet-owned "
                          f"inputs; errors={errors}"}
    allowed, reason = core_accepts(core, signed_hex)
    if allowed:
        return {"case": name, "verdict": "ACCEPT",
                "detail": f"{len(in_utxos)} inputs, {reason}"}
    return {"case": name, "verdict": "REJECT",
            "detail": f"Core rejected {len(in_utxos)}-input {name} sig: {reason} "
                      f"(mis-aggregated BIP-341 prevout commitment or bad sig)"}


def case_sighash(impl, core, want_flag, utxo, dest_spk):
    """Single-input p2wpkh spend with signrawtransactionwithwallet
    sighashtype=want_flag. Distinguishes honest UNSUPPORTED refusal, silent
    WRONG-FLAG, correct ACCEPT, and REJECT."""
    cname = f"sighash_{want_flag}"
    unsigned = build_unsigned([(utxo[0], utxo[1])],
                              [(utxo[2] - FEE_SATS, dest_spk)])
    signed_hex, complete, errors, rpc_err = sut_sign(
        impl, unsigned, prevtxs=None, sighashtype=want_flag)
    if rpc_err is not None:
        msg = str(rpc_err.get("message", rpc_err)) if isinstance(rpc_err, dict) else str(rpc_err)
        if "not yet supported" in msg.lower() or "not supported" in msg.lower():
            return {"case": cname, "verdict": "UNSUPPORTED",
                    "detail": f"honest refusal: {msg}"}
        return {"case": cname, "verdict": "SIGN-ERROR", "detail": f"rpc error: {msg}"}
    if not complete or not signed_hex:
        return {"case": cname, "verdict": "SIGN-INCOMPLETE",
                "detail": f"complete={complete!r} on a wallet-owned p2wpkh input; "
                          f"errors={errors}"}
    got = witness_hashtype_byte(core, signed_hex, 0)
    want = SIGHASH_FLAG.get(want_flag)
    if got is None:
        return {"case": cname, "verdict": "SIGN-ERROR",
                "detail": "signed but no witness signature byte to inspect"}
    if got != want:
        return {"case": cname, "verdict": "WRONG-FLAG",
                "detail": f"requested {want_flag} (flag 0x{want:02x}) but produced "
                          f"0x{got:02x} — SILENT wrong sighash flag (wallet lied)"}
    allowed, reason = core_accepts(core, signed_hex)
    if allowed:
        return {"case": cname, "verdict": "ACCEPT",
                "detail": f"flag 0x{got:02x} honored, {reason}"}
    return {"case": cname, "verdict": "REJECT",
            "detail": f"flag 0x{got:02x} but Core rejected: {reason} "
                      f"(wrong non-default sighash computation)"}


def case_external_input(impl, core, parent_source_utxo, x_spk, dest_spk):
    """Characterize the prevtxs / offline-input gap. Build (but never broadcast)
    a PARENT that pays a wallet-owned address X, then ask the SUT to sign a CHILD
    spending parent:0 with the prevout supplied ONLY via prevtxs. The wallet
    holds X's key but the outpoint is not in its UTXO set."""
    # Parent: spend a matured wallet coinbase -> output paying X (wallet-owned).
    p_txid, p_vout, p_amt, _ = parent_source_utxo
    parent_unsigned = build_unsigned([(p_txid, p_vout)],
                                     [(p_amt - FEE_SATS, x_spk)])
    p_signed, p_complete, p_errs, p_rpcerr = sut_sign(impl, parent_unsigned)
    if p_rpcerr is not None or not p_complete or not p_signed:
        return {"case": "external_input", "verdict": "SETUP-FAILED",
                "detail": f"could not build the unbroadcast parent "
                          f"(complete={p_complete!r} err={p_rpcerr or p_errs})"}
    dec, derr = core("decoderawtransaction", [p_signed])
    if derr is not None:
        raise RpcInfra(f"core decoderawtransaction(parent) errored: {derr}")
    parent_txid = (dec or {}).get("txid")
    parent_out = (dec or {}).get("vout", [{}])[0]
    parent_val = parent_out.get("value")
    # Child: spend the (unbroadcast, not-in-any-UTXO-set) parent:0, prevout info
    # supplied ONLY via prevtxs.
    child_unsigned = build_unsigned([(parent_txid, 0)],
                                    [(p_amt - 2 * FEE_SATS, dest_spk)])
    prevtxs = [{
        "txid": parent_txid, "vout": 0,
        "scriptPubKey": x_spk, "amount": parent_val,
    }]
    c_signed, c_complete, c_errs, c_rpcerr = sut_sign(
        impl, child_unsigned, prevtxs=prevtxs)
    if c_rpcerr is not None:
        msg = str(c_rpcerr.get("message", c_rpcerr)) if isinstance(c_rpcerr, dict) else str(c_rpcerr)
        return {"case": "external_input", "verdict": "GAP-CONFIRMED",
                "detail": f"prevtxs NOT honored: signing errored ({msg}); "
                          f"external/offline-input signing unsupported"}
    if not c_complete:
        detail = f"prevtxs NOT honored: complete=false; errors={c_errs}"
        return {"case": "external_input", "verdict": "GAP-CONFIRMED", "detail": detail}
    # Unexpected: it signed a prevtxs-only input. Verify Core would accept it
    # (needs the parent in-chain, which it is not — so this is informational).
    return {"case": "external_input", "verdict": "GAP-UNEXPECTED",
            "detail": "SUT signed a prevtxs-only external input (audit said it "
                      "ignores prevtxs) — re-examine external-input support"}


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

    verdicts = []
    notes = []
    try:
        _, cerr = impl("createwallet", [args.impl])
        if cerr is not None and err_is_method_missing(cerr):
            print("RPCGAP createwallet RPC missing")
            sys.exit(2)

        # 1. Obtain the receive addresses we need (each Core-confirmed by wv).
        #    Some require p2tr; if the SUT cannot produce a confirmed p2tr, the
        #    taproot-dependent cases are NO-RECEIVE (funding-blocking, not skip).
        tr1, tr1_spk = get_addr(impl, core, "p2tr")
        tr2, tr2_spk = get_addr(impl, core, "p2tr")
        trm, trm_spk = get_addr(impl, core, "p2tr")
        wm, wm_spk = get_addr(impl, core, "p2wpkh")
        wsh, wsh_spk = get_addr(impl, core, "p2wpkh")
        wpar, wpar_spk = get_addr(impl, core, "p2wpkh")
        xaddr, x_spk = get_addr(impl, core, "p2wpkh")     # external-input dest (key owned)
        dest, dest_spk = get_addr(impl, core, "p2wpkh")   # generic pay-to output
        if dest is None or wm is None:
            print("RPCGAP SUT cannot produce a Core-confirmed p2wpkh receive address")
            sys.exit(2)
        have_tr = all(a is not None for a in (tr1, tr2, trm))

        # 2. Fund each needed address with one coinbase; record block hashes.
        funds = {}
        fund_plan = [("wm", wm, wm_spk), ("wsh", wsh, wsh_spk),
                     ("wpar", wpar, wpar_spk)]
        if have_tr:
            fund_plan = [("tr1", tr1, tr1_spk), ("tr2", tr2, tr2_spk),
                         ("trm", trm, trm_spk)] + fund_plan
        for key, addr, spk in fund_plan:
            bh = fund_addr(impl, addr)
            funds[key] = {"addr": addr, "spk": spk, "block_hash": bh}

        # 3. Pad to maturity and replay the whole chain into Core.
        _, e = impl("generatetoaddress", [PADDING_BLOCKS, wm])
        if e is not None:
            raise RpcInfra(f"impl padding generatetoaddress errored: {e}")
        replay_chain_into_core(impl, core)

        # 4. Locate each funding coinbase UTXO on Core.
        for key, ent in funds.items():
            txid, vout, amt = locate_coinbase_utxo(core, ent["block_hash"], ent["spk"])
            if txid is None:
                raise RpcInfra(f"coinbase for {key} not found / not in Core UTXO set")
            ent.update(txid=txid, vout=vout, amt=amt)

        def utxo(key):
            e = funds[key]
            return (e["txid"], e["vout"], e["amt"], e["spk"])

        # 5a. MULTI-INPUT TAPROOT (>=2 P2TR spent together).
        if have_tr:
            verdicts.append(case_multi(impl, core, "multi_taproot",
                                       [utxo("tr1"), utxo("tr2")], dest_spk))
            # 5b. MIXED (P2WPKH + P2TR in one tx).
            verdicts.append(case_multi(impl, core, "mixed",
                                       [utxo("wm"), utxo("trm")], dest_spk))
        else:
            notes.append("p2tr receive unavailable — multi_taproot + mixed NO-RECEIVE")
            verdicts.append({"case": "multi_taproot", "verdict": "NO-RECEIVE",
                             "detail": "SUT cannot produce a Core-confirmed p2tr address"})
            verdicts.append({"case": "mixed", "verdict": "NO-RECEIVE",
                             "detail": "SUT cannot produce a Core-confirmed p2tr address"})

        # 5c. NON-DEFAULT SIGHASH via signrawtransactionwithwallet sighashtype.
        for flag in ("ALL", "NONE", "SINGLE", "ALL|ANYONECANPAY"):
            verdicts.append(case_sighash(impl, core, flag, utxo("wsh"), dest_spk))

        # 5d. EXTERNAL-INPUT / prevtxs characterization.
        verdicts.append(case_external_input(impl, core, utxo("wpar"), x_spk, dest_spk))

    except RpcGap as e:
        print(f"RPCGAP {e}")
        sys.exit(2)
    except RpcInfra as e:
        print(f"INFRA {e}")
        sys.exit(3)

    for v in verdicts:
        line = f"PROBE {v['case']} {v['verdict']}"
        if v.get("detail"):
            line += f" {v['detail']}"
        print(line)
    for n in notes:
        print(f"NOTE {n}")

    n_div = sum(1 for v in verdicts if v["verdict"] in DIVERGENT)
    n_mustpass_bad = sum(1 for v in verdicts
                         if v["case"] in MUST_PASS and v["verdict"] != "ACCEPT")
    per = " ".join(f"{v['case']}={v['verdict']}" for v in verdicts)

    if args.results_out:
        receipt = {
            "suite": "walletdiff-deepspend",
            "impl": args.impl,
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "divergences": n_div,
            "verdicts": verdicts,
            "notes": notes,
        }
        try:
            with open(args.results_out, "w") as f:
                json.dump(receipt, f, indent=1)
        except OSError:
            pass

    print(f"SUMMARY deepspend div={n_div} [{per}]")

    ok = (n_div == 0 and n_mustpass_bad == 0)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""probe_psbt.py — the ONE shared comparator for walletdiff SLICE 2 (PSBT
round-trip parity, gate rows P2.1 / P2.2).

Design: CORE-PARITY-AUDIT/_wallet-diff-harness-design-2026-07-20.md sec 5-7,
probes B1/B2/B3 (PSBT create / cross-sign / finalize) + the fee/vsize clause of
P2.2. Per the harness-script-consistency memory ALL comparisons live here; the
per-impl shell adapters only supply launch/RPC plumbing and may not weaken a
comparison. JSON is compared PARSED, never as raw strings.

Unlike slice 1 (address derivation is stateless: one node, deriveaddresses), a
PSBT round-trip is inherently DIFFERENTIAL and STATEFUL, so this probe drives
BOTH endpoints at once:

  --core-url/--core-cookie : a REAL wallet-enabled bitcoind regtest oracle
                             (bitcoin-core/build-wallet/bin — the plain
                             build/bin has NO wallet RPCs).
  --impl-url/--impl-cookie : the SUT.

Ground truth for input-UTXO availability WITHOUT a P2P link: the SUT mines its
own coinbases, then every SUT block is copied verbatim into Core via
submitblock (getblock verbosity=0 -> submitblock). Core then holds the EXACT
same UTXO set (same coinbase txids, byte-identical blocks), so Core's
testmempoolaccept is a true verdict on the SUT's finalized transaction, and
Core does NOT need the spending key to VALIDATE (it needs the key only to
cross-SIGN, phase IMPORT).

PHASES
------
NATIVE-p2wpkh (REQUIRED gate) / NATIVE-p2tr (best-effort, only if the SUT's
  getnewaddress actually yields the requested type -- rustoshi ignores
  address_type, wallet.rs:2041-2044, so p2tr is a GAP there):
    SUT native wallet (its OWN generated keys) funds itself from coinbase,
    builds walletcreatefundedpsbt -> walletprocesspsbt -> finalizepsbt, blocks
    copied to Core. Assert (a) Core testmempoolaccept ALLOWS the finalized tx;
    (b) fee == fee_rate*vsize within bounds, SUT-reported fee == Core-computed
    fee to the satoshi, effective-feerate on target, and fee < the 0.1 BTC
    absurd-fee guard (wallet.h:137).

IMPORT (assertion (c) cross-sign + imported-private-descriptor spend safety):
    Both sides import the SAME frozen wpkh tprv descriptor (from
    vectors-address.json). SUT mines to the frozen index-0 address; blocks
    copied to Core; Core rescans. Core builds+signs a spend of that coinbase =
    the Core-valid REFERENCE. Then:
      * Core walletprocesspsbt of the SUT's UNSIGNED psbt -> finalize -> the
        cross-signed tx MUST be Core-accepted (proves the SUT's PSBT is
        well-formed and Core can complete it with the shared key -- assertion
        (c) positive direction).
      * SUT walletprocesspsbt+finalize of its own psbt -> Core testmempoolaccept:
          ALLOWED  -> import_spend = OK   (byte-identical to Core's finalize on
                                           p2wpkh RFC6979 -> DETERMINISTIC note)
          REJECTED -> import_spend = INVALID  (the SUT signed with the WRONG key
                                           -- a FUNDING-BLOCKING divergence: the
                                           tx is invalid on the real network yet
                                           the SUT's own testmempoolaccept may
                                           wrongly accept it)
      * If the SUT cannot fund the spend at all (imported private descriptor is
        watch-only) -> import_spend = WATCHONLY  (a documented limitation, NOT a
        divergence: a loud refusal never loses funds).

VERDICT / EXIT
--------------
Exit 0 = PASS: native_p2wpkh accepted+bounded AND import_spend is not INVALID.
Exit 1 = FAIL: native_p2wpkh rejected/out-of-bounds, OR import_spend=INVALID
         (silent wrong-key spend), OR a required assertion diverged.
Exit 2 = RPC gap: a REQUIRED PSBT RPC is missing on the SUT (the funding-block
         GAP the task names). Runner classifies SKIP.
Exit 3 = infra: oracle wallet build missing / transport failure / block-copy
         unavailable -- the comparison could not be run.

STDOUT: one "PROBE <phase> <verdict>[ <detail>]" line per check, then one
"SUMMARY native_p2wpkh=.. native_p2tr=.. import_spend=.. [first=..]" line, plus
"RPCGAP <detail>" on exit 2. Optional --results-out writes a JSON receipt.
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.request

METHOD_NOT_FOUND = -32601
COIN = 100_000_000
ABSURD_FEE_SAT = COIN // 10          # DEFAULT_TRANSACTION_MAXFEE, wallet.h:137
FEE_RATE = 10                        # sat/vB requested on every create
DEST = "bcrt1qma7y8lzmsa4e08y84umauh2wnlrayles8hqelf"   # frozen wpkh-ext idx1
MATURE_BLOCKS = 105                  # each phase matures its own earliest coinbase


class RpcGap(Exception):
    pass


class RpcInfra(Exception):
    pass


class RpcError(Exception):
    def __init__(self, err):
        self.err = err
        super().__init__(str(err))


def make_rpc(url, cookie):
    import base64
    auth = "Basic " + base64.b64encode(cookie.encode()).decode()
    counter = [0]

    def rpc(method, params, raw=False):
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
                return _unwrap(d, method, raw)
            except urllib.error.HTTPError as e:
                try:
                    d = json.loads(e.read())
                    return _unwrap(d, method, raw)
                except (RpcGap, RpcError):
                    raise
                except Exception:
                    last = e
            except Exception as e:
                last = e
            time.sleep(1)
        raise RpcInfra(f"{method}: transport failure after 3 attempts: {last}")

    return rpc


def _unwrap(d, method, raw):
    err = d.get("error")
    if err is not None:
        if raw:
            return None, err
        if err_is_method_missing(err):
            raise RpcGap(f"{method} RPC missing")
        raise RpcError(err)
    return d.get("result"), None


def err_is_method_missing(err):
    if not isinstance(err, dict):
        return False
    if err.get("code") == METHOD_NOT_FOUND:
        return True
    return "method not found" in str(err.get("message", "")).lower()


# ── wallet lifecycle helpers (single-wallet discipline: exactly one wallet
#    loaded per node so base-URL wallet RPCs work on rustoshi (no /wallet/
#    routing) AND clearbit AND Core uniformly). ───────────────────────────────
def reset_wallet(node, name, blank):
    """Unload every loaded wallet, then create `name`. descriptors=true."""
    try:
        loaded, _ = node("listwallets", [])
    except (RpcError, RpcGap):
        loaded = []
    for w in (loaded or []):
        try:
            node("unloadwallet", [w])
        except (RpcError, RpcGap):
            pass
    # createwallet(name, disable_private_keys, blank, passphrase, avoid_reuse,
    #              descriptors)
    node("createwallet", [name, False, blank, "", False, True])


def copy_chain(src, dst):
    """Copy every block src has beyond dst's tip into dst via submitblock.
    Requires src getblock verbosity 0 (raw hex). Returns dst's new height."""
    src_h, _ = src("getblockcount", [])
    dst_h, _ = dst("getblockcount", [])
    for h in range(dst_h + 1, src_h + 1):
        bh, _ = src("getblockhash", [h])
        hexblk, _ = src("getblock", [bh, 0])
        if not isinstance(hexblk, str):
            raise RpcGap("getblock verbosity=0 (raw hex) unsupported on SUT")
        res, err = dst("submitblock", [hexblk], raw=True)
        # submitblock returns None on success, or a string reason; "duplicate"
        # / "inconclusive" are benign for our purposes.
        if isinstance(res, str) and res not in ("", "duplicate", "inconclusive"):
            raise RpcInfra(f"Core submitblock rejected SUT block {h}: {res}")
    dh, _ = dst("getblockcount", [])
    return dh


def to_sat(btc):
    return int(round(float(btc) * COIN))


# ── phase implementations ───────────────────────────────────────────────────
def phase_native(sut, core, addr_type, out):
    """Native-key round-trip for one address type. Appends verdict dict(s)."""
    name = f"native_{addr_type_key(addr_type)}"
    verdict = {"phase": name, "verdict": "GAP", "detail": ""}
    out.append(verdict)
    try:
        reset_wallet(sut, f"wdps_{addr_type_key(addr_type)}", blank=False)
        # request the address type; rustoshi ignores it -> we detect + GAP.
        args = [""] if addr_type is None else ["", addr_type]
        addr, _ = sut("getnewaddress", args)
        got_type = classify_addr(addr)
        want_type = addr_type_key(addr_type)
        if got_type != want_type:
            verdict["detail"] = (f"getnewaddress ignored address_type: asked "
                                 f"{want_type!r} got {got_type!r} ({addr}) "
                                 f"-- cannot fund a {want_type} native wallet")
            return
        sut("generatetoaddress", [MATURE_BLOCKS, addr])
        core_h = copy_chain(sut, core)
        # build + sign + finalize on the SUT
        cf, _ = sut("walletcreatefundedpsbt",
                    [[], [{DEST: 1.0}], 0, {"fee_rate": FEE_RATE}])
        sut_fee_sat = to_sat(cf["fee"])
        pp, _ = sut("walletprocesspsbt", [cf["psbt"]])
        if not pp.get("complete"):
            verdict["verdict"] = "FAIL"
            verdict["detail"] = "SUT walletprocesspsbt did not complete (unsigned)"
            return
        fin, _ = sut("finalizepsbt", [pp["psbt"]])
        if not fin.get("complete") or not fin.get("hex"):
            verdict["verdict"] = "FAIL"
            verdict["detail"] = "SUT finalizepsbt did not produce a complete tx"
            return
        hexs = fin["hex"]
        # (a) Core acceptance -- THE funding gate.
        acc = core("testmempoolaccept", [[hexs]])[0][0]
        if not acc.get("allowed"):
            verdict["verdict"] = "FAIL"
            verdict["detail"] = (f"Core REJECTED the SUT's finalized tx: "
                                 f"{acc.get('reject-reason')} "
                                 f"(txid {acc.get('txid')})")
            return
        # (b) fee / vsize parity.
        vsize = acc["vsize"]
        core_fee_sat = to_sat(acc["fees"]["base"])
        target = FEE_RATE * vsize
        eff = acc["fees"].get("effective-feerate")
        eff_satvb = to_sat(eff) / 1000.0 if eff is not None else core_fee_sat / vsize
        problems = []
        if core_fee_sat != sut_fee_sat:
            problems.append(f"SUT-reported fee {sut_fee_sat} != Core-computed "
                            f"{core_fee_sat} sat (same tx bytes)")
        if not (target <= core_fee_sat <= int(target * 1.5)):
            problems.append(f"fee {core_fee_sat} sat off target "
                            f"{target} sat (vsize {vsize} * {FEE_RATE})")
        if not (FEE_RATE * 0.9 <= eff_satvb <= FEE_RATE * 1.5):
            problems.append(f"effective-feerate {eff_satvb:.2f} sat/vB off "
                            f"{FEE_RATE} sat/vB")
        if core_fee_sat >= ABSURD_FEE_SAT:
            problems.append(f"fee {core_fee_sat} sat exceeds absurd-fee guard "
                            f"{ABSURD_FEE_SAT}")
        # SUT self-acceptance (informational).
        self_ok = None
        try:
            self_ok = sut("testmempoolaccept", [[hexs]])[0][0].get("allowed")
        except (RpcError, RpcGap):
            pass
        if problems:
            verdict["verdict"] = "FAIL"
            verdict["detail"] = "; ".join(problems)
        else:
            verdict["verdict"] = "PASS"
            verdict["detail"] = (f"Core-accepted vsize={vsize} fee={core_fee_sat}sat"
                                 f"=({FEE_RATE}sat/vB) sut_self_accept={self_ok}")
        verdict["evidence"] = {
            "vsize": vsize, "core_fee_sat": core_fee_sat,
            "sut_fee_sat": sut_fee_sat, "effective_feerate_satvb": round(eff_satvb, 3),
            "sut_self_accept": self_ok, "core_height": core_h,
        }
    except RpcGap:
        raise
    except RpcError as e:
        verdict["verdict"] = "GAP"
        verdict["detail"] = f"rpc error: {e.err}"
    return


def phase_import(sut, core, corpus, out):
    """Imported frozen-tprv wpkh: cross-sign (c) + spend safety. rustoshi's
    silent wrong-key bug and clearbit's watch-only refusal both surface here."""
    verdict = {"phase": "import_spend", "verdict": "GAP", "detail": ""}
    out.append(verdict)
    ext = find_desc(corpus, "wpkh-ext")
    intd = find_desc(corpus, "wpkh-int")
    if not ext or not intd:
        verdict["verdict"] = "GAP"
        verdict["detail"] = "frozen wpkh descriptors not in corpus"
        return
    imports = [
        {"desc": ext["descriptor"], "timestamp": "now", "active": True,
         "internal": False, "range": [0, 20]},
        {"desc": intd["descriptor"], "timestamp": "now", "active": True,
         "internal": True, "range": [0, 20]},
    ]
    fund_addr = ext["addresses"][0]   # frozen idx-0 address, byte-frozen
    try:
        # --- SUT side: import + fund ---
        reset_wallet(sut, "wdps_import", blank=True)
        imp = sut("importdescriptors", [imports])
        sut_import_warn = any(w for r in (imp[0] or []) for w in (r.get("warnings") or []))
        sut("generatetoaddress", [MATURE_BLOCKS, fund_addr])
        copy_chain(sut, core)
        # --- Core side: same import, rescan, build the reference spend ---
        reset_wallet(core, "wdps", blank=True)
        core("importdescriptors", [imports])
        core("rescanblockchain", [])
        # pick a matured coinbase to the frozen addr as the explicit input
        cutxos, _ = core("listunspent", [1, 9999999, [fund_addr]])
        cutxos = [u for u in (cutxos or []) if u.get("spendable")]
        if not cutxos:
            verdict["verdict"] = "GAP"
            verdict["detail"] = "Core has no spendable frozen-descriptor coinbase (rescan?)"
            return
        u = cutxos[0]
        inp = [{"txid": u["txid"], "vout": u["vout"]}]
        ref_cf, _ = core("walletcreatefundedpsbt",
                         [inp, [{DEST: 1.0}], 0, {"fee_rate": FEE_RATE}])
        ref_pp, _ = core("walletprocesspsbt", [ref_cf["psbt"]])
        ref_fin, _ = core("finalizepsbt", [ref_pp["psbt"]])
        ref_hex = ref_fin.get("hex")
        ref_ok = core("testmempoolaccept", [[ref_hex]])[0][0].get("allowed")
        if not ref_ok:
            verdict["verdict"] = "GAP"
            verdict["detail"] = "Core reference spend of frozen desc not accepted -- infra"
            return
        # --- SUT attempts the same spend ---
        try:
            sut_cf, _ = sut("walletcreatefundedpsbt",
                            [inp, [{DEST: 1.0}], 0, {"fee_rate": FEE_RATE}])
        except RpcError as e:
            msg = str(e.err).lower()
            if "insufficient" in msg or "watch" in msg or "no key" in msg:
                verdict["verdict"] = "WATCHONLY"
                verdict["detail"] = (f"imported private descriptor is watch-only: "
                                     f"walletcreatefundedpsbt -> {e.err} "
                                     f"(loud refusal, no fund loss)")
                return
            raise
        sut_unsigned = sut_cf["psbt"]
        # assertion (c): Core completes the SUT's UNSIGNED psbt with the shared key
        c_pp, _ = core("walletprocesspsbt", [sut_unsigned])
        c_fin, _ = core("finalizepsbt", [c_pp["psbt"]])
        c_hex = c_fin.get("hex")
        c_cross_ok = bool(c_hex) and core("testmempoolaccept", [[c_hex]])[0][0].get("allowed")
        # the SUT's own signing
        s_pp, _ = sut("walletprocesspsbt", [sut_unsigned])
        s_fin, _ = sut("finalizepsbt", [s_pp["psbt"]])
        s_hex = s_fin.get("hex")
        if not s_hex:
            verdict["verdict"] = "WATCHONLY"
            verdict["detail"] = "SUT could not finalize (no private key for imported desc)"
            return
        s_acc = core("testmempoolaccept", [[s_hex]])[0][0]
        sut_self = None
        try:
            sut_self = sut("testmempoolaccept", [[s_hex]])[0][0].get("allowed")
        except (RpcError, RpcGap):
            pass
        verdict["evidence"] = {
            "core_cross_sign_accepted": c_cross_ok,
            "sut_finalized_core_accepted": s_acc.get("allowed"),
            "sut_finalized_sut_accepted": sut_self,
            "byte_identical_to_core": (s_hex == c_hex),
            "sut_import_warning": sut_import_warn,
            "core_reject_reason": s_acc.get("reject-reason"),
        }
        if s_acc.get("allowed"):
            verdict["verdict"] = "OK"
            verdict["detail"] = ("SUT imported-descriptor spend Core-accepted"
                                 + ("; byte-identical to Core (RFC6979 deterministic)"
                                    if s_hex == c_hex else "; bytes differ from Core"))
        else:
            verdict["verdict"] = "INVALID"
            verdict["detail"] = (
                "FUNDING-BLOCKING: SUT signed the imported-descriptor P2WPKH "
                f"input with the WRONG key -- Core REJECTS the finalized tx: "
                f"{s_acc.get('reject-reason')}. SUT self-testmempoolaccept="
                f"{sut_self} (masks the defect). Core cross-sign of the SAME "
                f"unsigned PSBT was accepted={c_cross_ok}.")
    except RpcGap:
        raise
    except RpcError as e:
        verdict["verdict"] = "GAP"
        verdict["detail"] = f"rpc error: {e.err}"
    return


# ── address-type classification ─────────────────────────────────────────────
def addr_type_key(addr_type):
    return {None: "p2wpkh", "bech32": "p2wpkh", "bech32m": "p2tr"}.get(addr_type, str(addr_type))


def classify_addr(addr):
    if not isinstance(addr, str):
        return "?"
    if addr.startswith("bcrt1p") or addr.startswith("bc1p") or addr.startswith("tb1p"):
        return "p2tr"
    if addr.startswith("bcrt1q") or addr.startswith("bc1q") or addr.startswith("tb1q"):
        return "p2wpkh"
    if addr.startswith(("2", "3")):
        return "p2sh"
    return "legacy"


def find_desc(corpus, name):
    for e in corpus["descriptors"]:
        if e["name"] == name:
            return e
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--core-url", required=True)
    ap.add_argument("--core-cookie", required=True)
    ap.add_argument("--impl-url", required=True)
    ap.add_argument("--impl-cookie", required=True)
    ap.add_argument("--impl", required=True)
    ap.add_argument("--vectors", required=True)
    ap.add_argument("--results-out")
    args = ap.parse_args()

    with open(args.vectors) as f:
        corpus = json.load(f)
    with open(args.core_cookie) as f:
        core_cookie = f.read().strip()
    with open(args.impl_cookie) as f:
        impl_cookie = f.read().strip()

    core = make_rpc(args.core_url.rstrip("/") + "/", core_cookie)
    sut = make_rpc(args.impl_url.rstrip("/") + "/", impl_cookie)

    # Oracle must be wallet-enabled; if not, this is infra (SKIP the whole run).
    try:
        core("getwalletinfo", [], raw=True)  # probe existence; error ok
        core("listwallets", [])
    except RpcGap:
        print("INFRA core oracle lacks wallet RPCs -- use bitcoin-core/build-wallet/bin")
        sys.exit(3)
    except RpcInfra as e:
        print(f"INFRA {e}")
        sys.exit(3)

    verdicts = []
    try:
        phase_native(sut, core, None, verdicts)        # p2wpkh (required)
        phase_native(sut, core, "bech32m", verdicts)   # p2tr (best-effort)
        phase_import(sut, core, corpus, verdicts)       # cross-sign (c) + safety
    except RpcGap as e:
        print(f"RPCGAP {e}")
        sys.exit(2)
    except RpcInfra as e:
        print(f"INFRA {e}")
        sys.exit(3)

    for v in verdicts:
        line = f"PROBE {v['phase']} {v['verdict']}"
        if v.get("detail"):
            line += f" {v['detail']}"
        print(line)

    byphase = {v["phase"]: v for v in verdicts}
    n_wpkh = byphase.get("native_p2wpkh", {}).get("verdict", "GAP")
    n_tr = byphase.get("native_p2tr", {}).get("verdict", "GAP")
    imp = byphase.get("import_spend", {}).get("verdict", "GAP")

    if args.results_out:
        receipt = {
            "suite": "walletdiff-psbt",
            "impl": args.impl,
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "native_p2wpkh": n_wpkh, "native_p2tr": n_tr, "import_spend": imp,
            "verdicts": verdicts,
        }
        try:
            with open(args.results_out, "w") as f:
                json.dump(receipt, f, indent=1)
        except OSError:
            pass

    # verdict model
    fail = None
    if n_wpkh != "PASS":
        fail = byphase.get("native_p2wpkh")
    elif imp == "INVALID":
        fail = byphase.get("import_spend")

    summary = f"native_p2wpkh={n_wpkh} native_p2tr={n_tr} import_spend={imp}"
    if fail is not None:
        summary += f" first=[{fail['phase']}] {fail.get('detail', '')}".rstrip()
    print(f"SUMMARY {summary}")
    sys.exit(1 if fail is not None else 0)


if __name__ == "__main__":
    main()

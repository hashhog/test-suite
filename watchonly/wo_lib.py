#!/usr/bin/env python3
# wo_lib.py — shared engine for the WATCH-ONLY import differential family
# (test-suite/watchonly/<impl>_watchonly.sh). Two subcommands:
#
#   keys  --addr-kind p2wpkh|p2pkh
#       Construct the test's EXTERNAL keys fully offline (no node involved):
#       A (addr() descriptor target), B (pre-import-funding rescan target),
#       W (pubkey-descriptor target: wpkh() for p2wpkh, pkh() for p2pkh),
#       M (miner / maturity key, never imported), P (private-key-negative
#       WIF), L1/L2 (legacy informational probes). Emits one JSON doc with
#       addresses, scriptPubKey hex and CHECKSUMMED descriptors. Checksum
#       algorithm is byte-identical to bitcoin-core/test/functional/
#       test_framework/descriptors.py (the reference for src/script/
#       descriptor.cpp).
#
#   check --impl X --base-url U [--cookie F]... --routing path|global
#         --keys keys.json [--watch-wallet wo] [--fallback-wallet w1]
#         [--unload w1] [--expect 150.0]
#       Run the Core-faithful watch-only sequence against an already-BOOTED,
#       already-FUNDED impl and print EXACTLY ONE verdict line on stdout
#       ("PASS ..." / "FAIL ..."), exit 0/1. All diagnostics -> stderr.
#
# CORE v31.99 GROUND TRUTH the checks encode (empirically confirmed
# 2026-06-09 against a wallet-enabled build of the oracle source — the
# shipped oracle binary itself is ENABLE_WALLET=OFF, so this is a
# wallet-family substrate: assertions against Core's source-verified shapes,
# no oracle process):
#   * importdescriptors is the ONLY watch-only import path (src/wallet/rpc/
#     backup.cpp:302); importaddress/importpubkey/importmulti are REMOVED ->
#     -32601 (wallet.cpp:904-960; server.cpp:499). Legacy probes here are
#     INFORMATIONAL ONLY: -32601 is the Core-faithful answer, success is a
#     pre-v29 extension surface (no parity credit, no penalty).
#   * createwallet {wallet_name, disable_private_keys:true, blank:true} ->
#     {"name":...}; legacy (descriptors=false) wallets cannot be created at
#     all (wallet.cpp:403-404).
#   * importdescriptors result: array, SAME LENGTH as the request, each
#     element {"success":true}. Missing checksum -> per-element
#     success:false + error{code:-5,"Missing checksum"}. Private-key
#     descriptor into a disable_private_keys wallet -> error{code:-4}
#     (backup.cpp:224-226).
#   * timestamp:0 (clamped to 1, backup.cpp:376,390) rescans from genesis:
#     funding that PRE-DATES the import MUST be credited (backup.cpp:
#     398-409). "now" is NOT usable as a negative control (tip-MTP minus the
#     7200s TIMESTAMP_WINDOW, chain.h:37, wallet.cpp:1827,1834).
#   * getaddressinfo -> ismine:true; solvable:false for addr(); iswatchonly
#     is DEPRECATED + ALWAYS false (addresses.cpp:383,478) so it is never
#     asserted true here.
#   * getbalances has ONLY a "mine" section on v31.99 — watched funds land
#     in mine.trusted (coins.cpp:401-455). We also accept a legacy-style
#     watchonly.trusted or a plain getbalance, and sats-denominated balances
#     (beamchain), recording WHICH path matched.
#   * listunspent watch-only entries: spendable:true (descriptor ISMINE),
#     solvable:false. Some impls carry no "address" field (camlcoin) ->
#     scriptPubKey-hex fallback, then total-amount fallback.
#   * nonspend: watched funds must NOT be spendable — sendtoaddress on the
#     watch wallet must error (Core: -4, private keys disabled); ANY error
#     satisfies the check, a returned txid fails it.
#
# VERDICT-LINE SANITIZATION (load-bearing): run-watchonly-regression.sh
# classifies a non-zero arm by regexing its LAST stdout line against
# GAP_RE='not found|not built|no binary|release binary|rebuild|not installed|cannot boot'.
# A missing watch-only RPC must classify FAIL, never SKIP, so this engine
# rewrites any GAP_RE vocabulary leaking in from impl error strings (e.g.
# "Method not found" -> "Method-absent") before printing the line.

import argparse
import base64
import hashlib
import json
import re
import sys
import time
import urllib.error
import urllib.request

# ── offline encodings ───────────────────────────────────────────────────────

def hash160(b):
    return hashlib.new("ripemd160", hashlib.sha256(b).digest()).digest()

B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

def b58check(payload: bytes) -> str:
    chk = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    data = payload + chk
    n = int.from_bytes(data, "big")
    out = ""
    while n > 0:
        n, r = divmod(n, 58)
        out = B58[r] + out
    pad = len(data) - len(data.lstrip(b"\x00"))
    return "1" * pad + out

BECH = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

def _bech32_polymod(values):
    GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for v in values:
        b = chk >> 25
        chk = ((chk & 0x1ffffff) << 5) ^ v
        for i in range(5):
            chk ^= GEN[i] if ((b >> i) & 1) else 0
    return chk

def _bech32_hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]

def _convertbits(data, frombits, tobits, pad=True):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    for value in data:
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret

def segwit_addr(hrp, witver, witprog):
    data = [witver] + _convertbits(list(witprog), 8, 5)
    values = _bech32_hrp_expand(hrp) + data
    polymod = _bech32_polymod(values + [0, 0, 0, 0, 0, 0]) ^ 1  # bech32 (v0)
    chk = [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]
    return hrp + "1" + "".join(BECH[d] for d in (data + chk))

# ── descriptor checksum (== bitcoin-core test_framework/descriptors.py) ────

INPUT_CHARSET = ("0123456789()[],'/*abcdefgh@:$%{}IJKLMNOPQRSTUVWXYZ&+-.;<=>?"
                 "!^_|~ijklmnopqrstuvwxyzABCDEFGH`#\"\\ ")
CHECKSUM_CHARSET = BECH
GENERATOR = [0xf5dee51989, 0xa9fdca3312, 0x1bab10e32d, 0x3706b1677a, 0x644d626ffd]

def _descsum_polymod(symbols):
    chk = 1
    for value in symbols:
        top = chk >> 35
        chk = (chk & 0x7ffffffff) << 5 ^ value
        for i in range(5):
            chk ^= GENERATOR[i] if ((top >> i) & 1) else 0
    return chk

def _descsum_expand(s):
    groups = []
    symbols = []
    for c in s:
        if c not in INPUT_CHARSET:
            return None
        v = INPUT_CHARSET.find(c)
        symbols.append(v & 31)
        groups.append(v >> 5)
        if len(groups) == 3:
            symbols.append(groups[0] * 9 + groups[1] * 3 + groups[2])
            groups = []
    if len(groups) == 1:
        symbols.append(groups[0])
    elif len(groups) == 2:
        symbols.append(groups[0] * 3 + groups[1])
    return symbols

def descsum_create(s):
    symbols = _descsum_expand(s) + [0, 0, 0, 0, 0, 0, 0, 0]
    checksum = _descsum_polymod(symbols) ^ 1
    return s + "#" + "".join(
        CHECKSUM_CHARSET[(checksum >> (5 * (7 - i))) & 31] for i in range(8))

# ── fixed external scalars (valid secp256k1, deterministic across runs) ────

SCALARS = {
    "A":  "00112233445566778899aabbccddeeff00112233445566778899aabbccdd1a01",
    "B":  "00112233445566778899aabbccddeeff00112233445566778899aabbccdd2b02",
    "W":  "00112233445566778899aabbccddeeff00112233445566778899aabbccdd3c03",
    "P":  "00112233445566778899aabbccddeeff00112233445566778899aabbccdd4d04",
    "M":  "00112233445566778899aabbccddeeff00112233445566778899aabbccdd5e05",
    "L1": "00112233445566778899aabbccddeeff00112233445566778899aabbccdd6f06",
    "L2": "00112233445566778899aabbccddeeff00112233445566778899aabbccdd7a07",
}

def cmd_keys(a):
    from coincurve import PrivateKey
    kind = a.addr_kind
    out = {"kind": kind}
    for nm, sc in SCALARS.items():
        raw = bytes.fromhex(sc)
        pub = PrivateKey(raw).public_key.format(compressed=True)
        h = hash160(pub)
        if kind == "p2wpkh":
            addr = segwit_addr("bcrt", 0, h)
            spk = "0014" + h.hex()
        else:
            addr = b58check(b"\x6f" + h)          # regtest/testnet P2PKH
            spk = "76a914" + h.hex() + "88ac"
        out[nm] = {"addr": addr, "spk": spk, "pub": pub.hex()}
    wif_p = b58check(b"\xef" + bytes.fromhex(SCALARS["P"]) + b"\x01")
    out["P"]["wif"] = wif_p
    pub_fn = "wpkh" if kind == "p2wpkh" else "pkh"
    out["desc"] = {
        "A": descsum_create("addr(%s)" % out["A"]["addr"]),
        "B": descsum_create("addr(%s)" % out["B"]["addr"]),
        "W": descsum_create("%s(%s)" % (pub_fn, out["W"]["pub"])),
        "A_nochk": "addr(%s)" % out["A"]["addr"],
        "PRIV": descsum_create("%s(%s)" % (pub_fn, wif_p)),
    }
    print(json.dumps(out))
    return 0

# ── verdict-line sanitization (GAP_RE collision guard) ─────────────────────

GAPWORDS = [
    (r"not\s+found", "absent"),
    (r"not\s+built", "unbuilt"),
    (r"no\s+binary", "no-bin"),
    (r"release\s+binary", "release-bin"),
    (r"rebuild", "re-build"),
    (r"not\s+installed", "uninstalled"),
    (r"cannot\s+boot", "cant-boot"),
]

def sanitize(line):
    for pat, rep in GAPWORDS:
        line = re.sub(pat, rep, line, flags=re.I)
    return line

def compact(msg, n=70):
    s = re.sub(r"\s+", "-", str(msg)).replace('"', "")
    return s[:n]

# ── JSON-RPC client (cookie auth optional; content-type auto-fallback) ─────

class Rpc:
    def __init__(self, base, cookies, routing, timeout):
        self.base = base.rstrip("/")
        self.auth = None
        for c in cookies:
            try:
                with open(c) as fh:
                    self.auth = base64.b64encode(fh.read().strip().encode()).decode()
                break
            except OSError:
                continue
        self.routing = routing
        self.timeout = timeout
        self.ct = "application/json"

    def call(self, method, params, wallet=None):
        url = self.base + "/"
        if self.routing == "path" and wallet:
            url = "%s/wallet/%s" % (self.base, wallet)
        body = json.dumps({"jsonrpc": "1.0", "id": "wo", "method": method,
                           "params": params}).encode()
        for attempt in (0, 1):
            req = urllib.request.Request(url, data=body,
                                         headers={"Content-Type": self.ct})
            if self.auth:
                req.add_header("Authorization", "Basic " + self.auth)
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    raw = resp.read()
            except urllib.error.HTTPError as e:
                raw = e.read()
                if e.code == 415 and attempt == 0:
                    self.ct = "text/plain"
                    continue
            except Exception as e:  # transport-level
                return {"error": {"code": "transport", "message": str(e)}}
            try:
                return json.loads(raw.decode(errors="replace"))
            except Exception:
                if attempt == 0 and not raw:
                    self.ct = "text/plain"
                    continue
                return {"error": {"code": "badjson",
                                  "message": raw[:120].decode(errors="replace")
                                  if raw else "empty-reply"}}
        return {"error": {"code": "transport", "message": "unreached"}}

MISSING_RE = re.compile(
    r"method not found|unknown method|not implemented|unknown command|"
    r"no such method|unsupported method", re.I)

def err_of(rep):
    e = rep.get("error") if isinstance(rep, dict) else {"code": "badreply",
                                                        "message": str(rep)[:80]}
    if e in (None, False):
        return None
    if isinstance(e, dict):
        return e
    return {"code": None, "message": str(e)}

def is_missing(rep):
    e = err_of(rep)
    if not e:
        return False
    if e.get("code") == -32601:
        return True
    return bool(MISSING_RE.search(str(e.get("message", ""))))

def norm_amt(x):
    """BTC float; auto-normalize sats-denominated impls (>=1e5 => /1e8)."""
    try:
        v = float(x)
    except (TypeError, ValueError):
        return None
    if abs(v) >= 1e5:
        v = v / 1e8
    return v

# ── the Core-faithful watch-only sequence ───────────────────────────────────

def cmd_check(a):
    with open(a.keys) as fh:
        keys = json.load(fh)
    rpc = Rpc(a.base_url, a.cookie or [], a.routing, a.timeout)

    def log(*x):
        print("[wo:%s]" % a.impl, *x, file=sys.stderr)

    tags = {}
    info = {}

    # 1. watch wallet: Core shape first, then fallbacks (dpk = info tag only).
    created = False
    dpk_claimed = False
    wname = a.watch_wallet
    attempts = [
        ("named", {"wallet_name": wname, "disable_private_keys": True,
                   "blank": True}, True),
        ("pos3", [wname, True, True], True),
        ("pos1", [wname], False),
    ]
    for label, params, claims in attempts:
        rep = rpc.call("createwallet", params, wallet=None)
        e = err_of(rep)
        if e is None:
            created = True
            dpk_claimed = claims
            log("createwallet(%s) ok -> %s" % (label,
                                               compact(json.dumps(rep.get("result")), 100)))
            break
        log("createwallet(%s) rejected: code=%s msg=%s"
            % (label, e.get("code"), compact(e.get("message"))))
    if created:
        watch = wname
        if a.unload:
            rep = rpc.call("unloadwallet", [a.unload], wallet=None)
            log("unloadwallet(%s) -> err=%s" % (a.unload, err_of(rep)))
        gw = rpc.call("getwalletinfo", [], wallet=watch)
        res = gw.get("result") if not err_of(gw) else None
        pk = res.get("private_keys_enabled") if isinstance(res, dict) else None
        if dpk_claimed:
            if pk is False:
                tags["dpk"] = "ok"
            elif pk is True:
                tags["dpk"] = "ignored"  # arg accepted but not honored
            else:
                tags["dpk"] = "ok-unverified"
        else:
            tags["dpk"] = "absent"
        log("getwalletinfo(private_keys_enabled)=%s -> dpk=%s" % (pk, tags["dpk"]))
    else:
        watch = a.fallback_wallet or None
        tags["dpk"] = "unavailable"
        log("no watch wallet creatable; falling back to %s" % (watch or "<global>"))

    def wcall(m, p):
        return rpc.call(m, p, wallet=watch)

    def impdesc(reqs):
        return wcall("importdescriptors", [reqs])

    d = keys["desc"]

    # 2. CORE IMPORT: addr(A) + pubkey descriptor W, timestamp:0 (rescan).
    rep = impdesc([{"desc": d["A"], "timestamp": 0, "label": "wo"},
                   {"desc": d["W"], "timestamp": 0}])
    if is_missing(rep):
        tags["impdesc"] = "missing"
    else:
        e = err_of(rep)
        if e:
            tags["impdesc"] = "bad(rpc-error:%s:%s)" % (e.get("code"),
                                                        compact(e.get("message"), 40))
        else:
            res = rep.get("result")
            if not isinstance(res, list):
                tags["impdesc"] = "bad(result-not-array:%s)" % compact(res, 40)
            elif len(res) != 2:
                tags["impdesc"] = "bad(array-len:%d!=2)" % len(res)
            else:
                bad = None
                for i, el in enumerate(res):
                    if not (isinstance(el, dict) and el.get("success") is True):
                        ee = el.get("error") if isinstance(el, dict) else None
                        det = "elem%d:success=%s" % (
                            i, el.get("success") if isinstance(el, dict) else compact(el, 30))
                        if isinstance(ee, dict):
                            det += ",err=%s:%s" % (ee.get("code"),
                                                   compact(ee.get("message"), 40))
                        bad = "bad(%s)" % det
                        break
                tags["impdesc"] = bad or "ok"
    log("importdescriptors(addr+pub) -> %s; raw=%s"
        % (tags["impdesc"], compact(json.dumps(rep), 200)))
    have_impdesc = tags["impdesc"] != "missing"

    # 3. NEGATIVE: missing checksum -> per-element success:false, error -5.
    #    Uses the PUBKEY descriptor stripped of its checksum (not addr()):
    #    pubkey descriptors are the most widely parseable, so a -5 here is
    #    about the checksum, not about an impl's address parser.
    if have_impdesc:
        w_nochk = d["W"].rsplit("#", 1)[0]
        rep = impdesc([{"desc": w_nochk, "timestamp": 0}])
        e = err_of(rep)
        res = rep.get("result")
        if e is not None:
            tags["chksum"] = "bad(top-level-error:%s)" % e.get("code")
        elif (isinstance(res, list) and len(res) == 1 and isinstance(res[0], dict)
              and res[0].get("success") is False):
            ee = res[0].get("error") or {}
            # Core: {-5, "Missing checksum"}. Require BOTH the code and a
            # checksum-mentioning message — a -5 for an unrelated parse
            # failure (e.g. an addr() parser that chokes on the address
            # itself) must not pass as checksum enforcement.
            if ee.get("code") == -5 and "checksum" in str(ee.get("message", "")).lower():
                tags["chksum"] = "ok"
            elif ee.get("code") == -5:
                tags["chksum"] = "bad(code=-5-but-msg=%s)" % compact(
                    ee.get("message"), 40)
            else:
                tags["chksum"] = "bad(code=%s)" % ee.get("code")
        elif (isinstance(res, list) and res and isinstance(res[0], dict)
              and res[0].get("success") is True):
            tags["chksum"] = "bad(accepted-unchecksummed)"
        else:
            tags["chksum"] = "bad(shape:%s)" % compact(res, 40)
        log("chksum-negative -> %s; raw=%s" % (tags["chksum"],
                                               compact(json.dumps(rep), 200)))
    else:
        tags["chksum"] = "untested"

    # 4. NEGATIVE: private-key descriptor into a dpk wallet -> error -4.
    if have_impdesc and tags["dpk"] in ("ok", "ok-unverified"):
        rep = impdesc([{"desc": d["PRIV"], "timestamp": 0}])
        e = err_of(rep)
        res = rep.get("result")
        if e is not None:
            tags["privneg"] = "bad(top-level-error:%s)" % e.get("code")
        elif isinstance(res, list) and len(res) == 1 and isinstance(res[0], dict):
            el = res[0]
            ee = el.get("error") or {}
            if el.get("success") is False and ee.get("code") == -4:
                tags["privneg"] = "ok"
            elif el.get("success") is True:
                tags["privneg"] = "bad(accepted-privkey-into-dpk-wallet)"
            else:
                tags["privneg"] = "bad(code=%s)" % ee.get("code")
        else:
            tags["privneg"] = "bad(shape:%s)" % compact(res, 40)
        log("privkey-negative -> %s; raw=%s" % (tags["privneg"],
                                                compact(json.dumps(rep), 200)))
    elif have_impdesc:
        tags["privneg"] = "na(no-dpk-wallet)"
    else:
        tags["privneg"] = "untested"

    # 5. import B with timestamp:0 — funding PRE-DATES this import, so the
    #    import's own rescan must credit it (the load-bearing rescan proof).
    b_ok = False
    if have_impdesc:
        rep = impdesc([{"desc": d["B"], "timestamp": 0}])
        e = err_of(rep)
        res = rep.get("result")
        b_ok = (e is None and isinstance(res, list) and len(res) == 1
                and isinstance(res[0], dict) and res[0].get("success") is True)
        log("importdescriptors(B,ts=0) ok=%s; raw=%s" % (b_ok,
                                                         compact(json.dumps(rep), 200)))

    expect_each = a.expect / 3.0
    want_total = a.expect if b_ok else a.expect - expect_each

    # 6a. listunspent: A/B/W each 1 mature coinbase of 50 (pre-import funded).
    # Core's importdescriptors BLOCKS until its rescan completes; an impl that
    # rescans asynchronously gets a short grace window (4 polls / 2s apart)
    # before a miss is declared, so "rescan-miss" means the funds never came.
    if not have_impdesc:
        tags["rescan"] = "untested"
    elif not b_ok:
        tags["rescan"] = "bad(import-B-failed)"
    else:
        for poll in range(4):
            if poll:
                time.sleep(2)
            rep = wcall("listunspent", [])
            if is_missing(rep):
                tags["rescan"] = "bad(listunspent-rpc-missing)"
                break
            if err_of(rep):
                tags["rescan"] = "bad(listunspent-error:%s)" % err_of(rep).get("code")
                break
            res = rep.get("result") or []

            def find(k):
                hits = []
                for u in res:
                    if not isinstance(u, dict):
                        continue
                    if u.get("address") == k["addr"]:
                        hits.append(u)
                        continue
                    spk = (u.get("scriptPubKey") or u.get("script_pubkey")
                           or u.get("scriptpubkey"))
                    if isinstance(spk, dict):
                        spk = spk.get("hex")
                    if isinstance(spk, str) and spk.lower() == k["spk"].lower():
                        hits.append(u)
                return hits

            def amt_of(u):
                v = norm_amt(u.get("amount", u.get("value")))
                return v if v is not None else 0.0

            missing = []
            for nm in ("A", "B", "W"):
                hits = find(keys[nm])
                amt = sum(amt_of(u) for u in hits)
                log("listunspent(poll %d) %s: %d utxo, %.8f BTC (spendable=%s "
                    "solvable=%s)" % (poll, nm, len(hits), amt,
                                      hits[0].get("spendable") if hits else "-",
                                      hits[0].get("solvable") if hits else "-"))
                if not hits or abs(amt - expect_each) > 1e-6:
                    missing.append("%s=%dutxo/%.8f" % (nm, len(hits), amt))
            if not missing:
                tags["rescan"] = "ok"
                break
            total = sum(amt_of(u) for u in res if isinstance(u, dict))
            if abs(total - want_total) < 1e-6 and len(res) >= 3:
                tags["rescan"] = "ok(total-match-no-addr-field)"
                break
            tags["rescan"] = "miss(%s;total=%.8f/n=%d)" % (
                ";".join(missing), total, len(res))
        log("rescan/listunspent -> %s" % tags["rescan"])

    # 6b. balance: mine.trusted (v31.99) / watchonly.trusted (legacy shape) /
    #     getbalance — record which path matched; sats auto-normalized.
    if have_impdesc:
        watched = None
        path = None
        rep = wcall("getbalances", [])
        if not err_of(rep) and isinstance(rep.get("result"), dict):
            res = rep["result"]
            mine = res.get("mine") if isinstance(res.get("mine"), dict) else {}
            wsec = res.get("watchonly") if isinstance(res.get("watchonly"), dict) else {}
            for pth, v in (("mine.trusted", mine.get("trusted")),
                           ("watchonly.trusted", wsec.get("trusted"))):
                nv = norm_amt(v)
                if nv is not None and abs(nv - want_total) < 1e-6:
                    watched, path = nv, pth
                    break
            if path is None:
                log("getbalances did not show watched funds: %s"
                    % compact(json.dumps(res), 160))
        else:
            log("getbalances unusable: %s" % compact(json.dumps(rep), 120))
        if path is None:
            rep2 = wcall("getbalance", [])
            nv = norm_amt(rep2.get("result")) if not err_of(rep2) else None
            if nv is not None and abs(nv - want_total) < 1e-6:
                watched, path = nv, "getbalance"
            elif nv is not None:
                watched = nv
        if path:
            tags["balance"] = "ok(%s)" % path
        else:
            tags["balance"] = "bad(watched=%s;want=%.8f)" % (
                "%.8f" % watched if watched is not None else "unreadable",
                want_total)
        info["watched"] = "%.8f" % watched if watched is not None else "unknown"
        log("balance -> %s" % tags["balance"])
    else:
        tags["balance"] = "untested"
        info["watched"] = "untested"

    # 6c. getaddressinfo A -> ismine:true (iswatchonly NEVER asserted true:
    #     deprecated, hardcoded false in Core — addresses.cpp:383,478).
    if have_impdesc:
        rep = wcall("getaddressinfo", [keys["A"]["addr"]])
        if is_missing(rep):
            tags["addrinfo"] = "missing"
        elif err_of(rep):
            tags["addrinfo"] = "bad(error:%s)" % err_of(rep).get("code")
        else:
            res = rep.get("result") or {}
            if isinstance(res, dict) and res.get("ismine") is True:
                tags["addrinfo"] = "ok"
                log("getaddressinfo A: ismine=true solvable=%s iswatchonly=%s "
                    "parent_desc=%s" % (res.get("solvable"), res.get("iswatchonly"),
                                        compact(res.get("parent_desc"), 60)))
            else:
                tags["addrinfo"] = "bad(ismine=%s)" % (
                    res.get("ismine") if isinstance(res, dict) else compact(res, 30))
        log("addrinfo -> %s" % tags["addrinfo"])
    else:
        tags["addrinfo"] = "untested"

    # 7. nonspend: the defining watch-only property.
    if have_impdesc:
        rep = wcall("sendtoaddress", [keys["M"]["addr"], 1.0])
        if is_missing(rep):
            tags["nonspend"] = "na(sendtoaddress-absent)"
        elif err_of(rep):
            tags["nonspend"] = "ok"
            log("sendtoaddress correctly refused: code=%s msg=%s"
                % (err_of(rep).get("code"), compact(err_of(rep).get("message"), 80)))
        else:
            res = rep.get("result")
            if res:
                tags["nonspend"] = "bad(spent-watchonly:%s)" % compact(res, 20)
            else:
                tags["nonspend"] = "bad(returned-success-null)"
        log("nonspend -> %s" % tags["nonspend"])
    else:
        tags["nonspend"] = "untested"

    # 8. LEGACY INFORMATIONAL PROBE (always, last — so an extension impl's
    #    importaddress rescan can't contaminate the graded checks above).
    #    -32601 == Core v31.99-faithful; success == pre-v29 extension surface.
    def legacy_probe(method, params):
        rep = wcall(method, params)
        if is_missing(rep):
            return "-32601-core-faithful"
        e = err_of(rep)
        if e:
            return "err%s" % e.get("code")
        return "extension-ok"

    ia = legacy_probe("importaddress", [keys["L1"]["addr"], "legacy", False])
    ip = legacy_probe("importpubkey", [keys["L2"]["pub"], "legacy", False])
    log("legacy probes: importaddress=%s importpubkey=%s" % (ia, ip))

    # ── verdict ──
    graded = ["impdesc", "chksum", "privneg", "rescan", "balance", "addrinfo",
              "nonspend"]

    def tag_ok(v):
        return (v == "ok" or v.startswith("ok(") or v.startswith("ok-")
                or v == "na" or v.startswith("na("))

    first_bad = None
    for g in graded:
        v = tags.get(g, "untested")
        if v == "untested":
            continue  # only happens when impdesc already failed first
        if not tag_ok(v):
            first_bad = g
            break
    if first_bad is None and tags["impdesc"] != "ok":
        first_bad = "impdesc"

    tagstr = " ".join("%s=%s" % (k, tags[k]) for k in
                      ["impdesc", "chksum", "privneg", "rescan", "balance",
                       "addrinfo", "nonspend", "dpk"])
    legstr = "legacy[ia=%s,ip=%s]" % (ia, ip)
    wstr = "watched=%s" % info.get("watched", "?")
    if first_bad is None:
        line = "PASS %s %s %s" % (tagstr, wstr, legstr)
        code = 0
    else:
        line = "FAIL first-divergence:%s=%s | %s %s %s" % (
            first_bad, tags[first_bad], tagstr, wstr, legstr)
        code = 1
    print(sanitize(line))
    return code

def main():
    p = argparse.ArgumentParser(description="watch-only family shared engine")
    sub = p.add_subparsers(dest="cmd", required=True)
    k = sub.add_parser("keys")
    k.add_argument("--addr-kind", choices=["p2wpkh", "p2pkh"], default="p2wpkh")
    c = sub.add_parser("check")
    c.add_argument("--impl", required=True)
    c.add_argument("--base-url", required=True)
    c.add_argument("--cookie", action="append", default=[])
    c.add_argument("--routing", choices=["path", "global"], required=True)
    c.add_argument("--keys", required=True)
    c.add_argument("--watch-wallet", default="wo")
    c.add_argument("--fallback-wallet", default="")
    c.add_argument("--unload", default="")
    c.add_argument("--expect", type=float, default=150.0)
    c.add_argument("--timeout", type=float, default=60.0)
    a = p.parse_args()
    if a.cmd == "keys":
        sys.exit(cmd_keys(a))
    sys.exit(cmd_check(a))

if __name__ == "__main__":
    main()

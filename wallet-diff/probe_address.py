#!/usr/bin/env python3
"""probe_address.py — the ONE shared comparator for walletdiff slice 1 (A1+A2).

Design: CORE-PARITY-AUDIT/_wallet-diff-harness-design-2026-07-20.md §5-§7.
Per the harness-script-consistency memory, ALL comparisons live here; the
per-impl shell adapters only supply launch/RPC plumbing and may not weaken a
comparison. JSON is compared PARSED, never as raw strings (fleet-wire-key-order
memory: rustoshi/beamchain alphabetize keys vs Core pushKV order).

Probes, per frozen-corpus descriptor entry (vectors-address.json):
  A2 desc-<name>: getdescriptorinfo(descriptor-with-checksum)
       -> result["checksum"] must equal the frozen checksum byte-exactly.
          (Core semantics: the checksum of the descriptor AS GIVEN.)
  A1 addr-<name>: deriveaddresses(descriptor-with-checksum, [begin,end])
       -> address list must equal the frozen list byte-exactly, INCLUDING
          length (Core range notation is [begin,end] INCLUSIVE).
A1/A2 admit no allowance tier: byte-exact or DIVERGED (design §7 — address
mismatch is fund-loss class).

Roles:
  --role oracle : replay against the local Core build; ANY mismatch is
                  ORACLE-DRIFT (exit 3) — the local Core no longer matches the
                  frozen mint, which is BLOCKED infra, never a SUT verdict.
  --role impl   : replay against the SUT; divergences -> exit 1.

Exit codes: 0 all PASS; 1 divergence; 2 required RPC missing (build/RPC gap,
runner classifies SKIP); 3 infra (oracle drift / RPC transport failure).

Output (stdout): one "PROBE <kind> <name> <verdict>[ <detail>]" line per probe,
one final "SUMMARY addr=x/na desc=y/nd[ first=...]" line, plus "RPCGAP <detail>"
/ "ORACLE-DRIFT <detail>" markers. Optional --results-out writes the per-run
JSON receipt (design §7, mirrors results/crash-recovery.json precedent).
"""
import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.request

METHOD_NOT_FOUND = -32601


class RpcGap(Exception):
    pass


class RpcInfra(Exception):
    pass


def make_rpc(url, cookie):
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
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    d = json.loads(r.read())
                return d.get("result"), d.get("error")
            except urllib.error.HTTPError as e:
                # Core answers RPC errors with HTTP 4xx/5xx + a JSON body.
                try:
                    d = json.loads(e.read())
                    return d.get("result"), d.get("error")
                except Exception:
                    last = e
            except Exception as e:  # transport trouble — retry briefly
                last = e
            time.sleep(1)
        raise RpcInfra(f"{method}: transport failure after 3 attempts: {last}")

    return rpc


def err_is_method_missing(err):
    if not isinstance(err, dict):
        return False
    if err.get("code") == METHOD_NOT_FOUND:
        return True
    return "method not found" in str(err.get("message", "")).lower()


def probe_entry(rpc, entry):
    """Run A2+A1 for one corpus entry. Returns list of verdict dicts."""
    name = entry["name"]
    desc = entry["descriptor"]
    out = []

    # A2 — getdescriptorinfo checksum (of the descriptor AS GIVEN, Core semantics).
    res, err = rpc("getdescriptorinfo", [desc])
    if err is not None:
        if err_is_method_missing(err):
            raise RpcGap("getdescriptorinfo RPC missing")
        out.append({"kind": "desc", "name": name, "verdict": "DIVERGED",
                    "detail": f"rpc error: {err}"})
    else:
        got = (res or {}).get("checksum")
        if got == entry["checksum"]:
            out.append({"kind": "desc", "name": name, "verdict": "PASS"})
        else:
            out.append({"kind": "desc", "name": name, "verdict": "DIVERGED",
                        "detail": f"checksum got={got!r} expected={entry['checksum']!r}"})

    # A1 — deriveaddresses byte-exact list (fund-loss class; no allowance tier).
    res, err = rpc("deriveaddresses", [desc, entry["range"]])
    if err is not None:
        if err_is_method_missing(err):
            raise RpcGap("deriveaddresses RPC missing")
        out.append({"kind": "addr", "name": name, "verdict": "DIVERGED",
                    "detail": f"rpc error: {err}"})
        return out
    exp = entry["addresses"]
    if not isinstance(res, list):
        out.append({"kind": "addr", "name": name, "verdict": "DIVERGED",
                    "detail": f"non-list result: {type(res).__name__}"})
    elif res == exp:
        out.append({"kind": "addr", "name": name, "verdict": "PASS"})
    else:
        if len(res) != len(exp):
            detail = (f"count got={len(res)} expected={len(exp)} "
                      f"(range {entry['range']} is INCLUSIVE in Core)")
            # Pin down the classic off-by-one: same prefix, tail missing.
            if res == exp[: len(res)]:
                detail += f"; got list is an exact PREFIX — missing tail starts at index {len(res)}: {exp[len(res)]}"
        else:
            i = next(i for i, (a, b) in enumerate(zip(res, exp)) if a != b)
            detail = f"first mismatch at index {i}: got={res[i]} expected={exp[i]}"
        out.append({"kind": "addr", "name": name, "verdict": "DIVERGED", "detail": detail})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--cookie-file", required=True)
    ap.add_argument("--vectors", required=True)
    ap.add_argument("--role", choices=["oracle", "impl"], required=True)
    ap.add_argument("--impl", required=True)
    ap.add_argument("--results-out")
    args = ap.parse_args()

    with open(args.vectors) as f:
        corpus = json.load(f)
    with open(args.cookie_file) as f:
        cookie = f.read().strip()
    rpc = make_rpc(args.url, cookie)

    verdicts = []
    try:
        for entry in corpus["descriptors"]:
            verdicts.extend(probe_entry(rpc, entry))
    except RpcGap as e:
        print(f"RPCGAP {e}")
        sys.exit(2)
    except RpcInfra as e:
        print(f"INFRA {e}")
        sys.exit(3)

    for v in verdicts:
        line = f"PROBE {v['kind']} {v['name']} {v['verdict']}"
        if v.get("detail"):
            line += f" {v['detail']}"
        print(line)

    kinds = {"addr": [0, 0], "desc": [0, 0]}  # [pass, total]
    first = None
    for v in verdicts:
        kinds[v["kind"]][1] += 1
        if v["verdict"] == "PASS":
            kinds[v["kind"]][0] += 1
        elif first is None:
            first = v
    n_addrs = sum(len(e["addresses"]) for e in corpus["descriptors"])

    if args.results_out:
        receipt = {
            "suite": corpus["suite"],
            "impl": args.impl,
            "role": args.role,
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "vectors_minted": corpus.get("minted"),
            "addr_pass": kinds["addr"][0], "addr_total": kinds["addr"][1],
            "desc_pass": kinds["desc"][0], "desc_total": kinds["desc"][1],
            "addresses_in_corpus": n_addrs,
            "verdicts": verdicts,
        }
        with open(args.results_out, "w") as f:
            json.dump(receipt, f, indent=1)

    summary = (f"addr={kinds['addr'][0]}/{kinds['addr'][1]} "
               f"desc={kinds['desc'][0]}/{kinds['desc'][1]}")
    if first is not None:
        summary += f" first=[{first['kind']} {first['name']}] {first.get('detail', '')}".rstrip()

    if first is None:
        print(f"SUMMARY {summary}")
        sys.exit(0)
    if args.role == "oracle":
        print(f"ORACLE-DRIFT {summary}")
        sys.exit(3)
    print(f"SUMMARY {summary}")
    sys.exit(1)


if __name__ == "__main__":
    main()

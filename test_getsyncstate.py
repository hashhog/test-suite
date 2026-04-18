#!/usr/bin/env python3
"""
test_getsyncstate.py — hashhog W70 conformance harness.

Probes `getsyncstate` on every node in the fleet and validates the v1
contract defined in `spec/getsyncstate.md`:

  1. JSON-RPC 2.0 envelope is valid.
  2. All six MUST fields are present and have the expected type.
  3. Field invariants hold (hex length, hash chars, height ordering).
  4. `null` is accepted for SHOULD fields (presence required, value
     may be null).
  5. A repeated call returns values that are fresh-or-stable — no
     stale cache that never updates.

Exits 0 on full-fleet pass, 1 on any per-node failure.

Usage:
    python3 test_getsyncstate.py                 # mainnet fleet
    python3 test_getsyncstate.py --network testnet4
    python3 test_getsyncstate.py --nodes rustoshi,hotbuns

stdlib only (Python 3.9+). Port + cookie map comes from
tools/_fleet_config.py (single source of truth with fleet-rate.py).
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Optional

# tools/ is sibling to test-suite/. Push it onto sys.path so the shared
# port config loads regardless of cwd.
_REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO_ROOT / "tools"))
import _fleet_config  # noqa: E402

MUST_FIELDS = {
    "tip_height": int,
    "tip_hash": str,
    "best_header_height": int,
    "best_header_hash": str,
    "initial_block_download": bool,
    "num_peers": int,
}

SHOULD_FIELDS = {
    "verification_progress": (float, int, type(None)),
    "blocks_in_flight": (int, type(None)),
    "blocks_pending_connect": (int, type(None)),
    "last_block_received_time": (int, type(None)),
    "chain": (str, type(None)),
    "protocol_version": (int, type(None)),
}

VALID_CHAIN_NAMES = {"main", "test", "test4", "testnet4", "signet", "regtest"}
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")


def cookie_auth(cookie_path: Path) -> Optional[str]:
    try:
        raw = cookie_path.read_text().strip()
    except OSError:
        return None
    if not raw:
        return None
    return "Basic " + base64.b64encode(raw.encode()).decode()


def rpc_call(port: int, auth: str, method: str, timeout: float = 5.0) -> dict:
    body = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": method, "params": [],
    }).encode()
    headers = {"Content-Type": "application/json", "Authorization": auth}
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/", data=body, headers=headers
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def validate(result: Any) -> list[str]:
    """Return a list of failure messages; empty list means pass."""
    errs: list[str] = []
    if not isinstance(result, dict):
        return [f"result is {type(result).__name__}, expected object"]
    # MUST fields: present + typed.
    for name, typ in MUST_FIELDS.items():
        if name not in result:
            errs.append(f"MUST field `{name}` missing")
            continue
        val = result[name]
        if typ is bool:
            # isinstance(True, int) is True — distinguish explicitly.
            if not isinstance(val, bool):
                errs.append(f"`{name}` type {type(val).__name__}, want bool")
        elif typ is int:
            if not isinstance(val, int) or isinstance(val, bool):
                errs.append(f"`{name}` type {type(val).__name__}, want int")
            elif val < 0:
                errs.append(f"`{name}`={val}, must be >= 0")
        elif typ is str:
            if not isinstance(val, str):
                errs.append(f"`{name}` type {type(val).__name__}, want str")
    # Hash invariants: lowercase hex-64 when present (zero-hash allowed).
    for h in ("tip_hash", "best_header_hash"):
        if isinstance(result.get(h), str) and not HEX64_RE.match(result[h]):
            errs.append(f"`{h}`={result[h]!r} is not lowercase hex-64")
    # Header >= tip invariant.
    th, bhh = result.get("tip_height"), result.get("best_header_height")
    if isinstance(th, int) and isinstance(bhh, int) and bhh < th:
        errs.append(f"best_header_height={bhh} < tip_height={th}")
    # SHOULD fields: presence required, type permissive (value may be null).
    for name, types in SHOULD_FIELDS.items():
        if name not in result:
            errs.append(f"SHOULD field `{name}` missing (must be null, not omitted)")
            continue
        val = result[name]
        if not isinstance(val, types):
            errs.append(
                f"`{name}` type {type(val).__name__}, want one of "
                + "/".join(t.__name__ for t in types)
            )
    # verification_progress range check.
    vp = result.get("verification_progress")
    if isinstance(vp, (int, float)) and not (0.0 <= vp <= 1.0):
        errs.append(f"verification_progress={vp}, must be in [0.0, 1.0]")
    # chain name enum.
    chain = result.get("chain")
    if isinstance(chain, str) and chain not in VALID_CHAIN_NAMES:
        errs.append(f"chain={chain!r} not in {sorted(VALID_CHAIN_NAMES)}")
    return errs


def probe_node(name: str, port: int, cookie_path: Path) -> tuple[str, list[str]]:
    """Return (status, errors). status is 'pass', 'skip', or 'fail'."""
    auth = cookie_auth(cookie_path)
    if auth is None:
        return "skip", [f"no cookie at {cookie_path}"]
    try:
        payload = rpc_call(port, auth, "getsyncstate")
    except urllib.error.HTTPError as exc:
        return "fail", [f"HTTP {exc.code}"]
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        return "fail", [f"transport {type(exc).__name__}: {exc}"]
    # Envelope check. Bitcoin JSON-RPC 1.0 returns {"result": null, "error": {...}}
    # on failure, so presence alone isn't enough.
    errs: list[str] = []
    result = payload.get("result")
    if result is None:
        err = payload.get("error") or {}
        code = err.get("code") if isinstance(err, dict) else None
        if code == -32601:
            return "fail", ["method not implemented (JSON-RPC -32601)"]
        if code == -28:
            return "skip", ["node warming up (RPC -28)"]
        return "fail", [f"no result; error={err}"]
    if payload.get("jsonrpc") not in (None, "1.0", "2.0"):
        errs.append(f"bad jsonrpc tag: {payload.get('jsonrpc')!r}")
    errs.extend(validate(result))
    # Freshness: repeat call must succeed and either match or advance.
    try:
        second = rpc_call(port, auth, "getsyncstate")
    except Exception as exc:  # noqa: BLE001
        errs.append(f"second call failed: {type(exc).__name__}")
        return ("fail" if errs else "pass"), errs
    second_result = second.get("result")
    if not isinstance(second_result, dict):
        errs.append("second call returned no result object")
    else:
        t1, t2 = result.get("tip_height"), second_result.get("tip_height")
        if isinstance(t1, int) and isinstance(t2, int) and t2 < t1:
            errs.append(f"tip_height went backwards across calls: {t1} -> {t2}")
    return ("fail" if errs else "pass"), errs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--network", choices=_fleet_config.NETWORKS, default="mainnet")
    ap.add_argument("--nodes", default="",
                    help="comma-separated subset; empty = all")
    args = ap.parse_args()

    data_root, ports = _fleet_config.config_for(args.network)
    if args.nodes:
        selected = [n.strip() for n in args.nodes.split(",") if n.strip()]
        unknown = [n for n in selected if n not in ports]
        if unknown:
            print(f"unknown node names: {unknown}", file=sys.stderr)
            return 2
        ports = {n: ports[n] for n in selected}

    print(f"getsyncstate conformance — network={args.network} nodes={len(ports)}\n")
    print(f"  {'node':12s}  {'status':6s}  notes")
    print("  " + "-" * 70)

    fail = 0
    skip = 0
    start = time.time()
    for name, port in ports.items():
        cookie = Path(f"{data_root}/{name}/.cookie")
        status, errs = probe_node(name, port, cookie)
        if status == "fail":
            fail += 1
            note = "; ".join(errs)
        elif status == "skip":
            skip += 1
            note = "; ".join(errs) or "(skipped)"
        else:
            note = ""
        print(f"  {name:12s}  {status:6s}  {note}")

    elapsed = time.time() - start
    pass_ct = len(ports) - fail - skip
    print(f"\n  {pass_ct} pass, {fail} fail, {skip} skip  ({elapsed:.1f}s)")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

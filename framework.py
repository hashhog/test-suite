#!/usr/bin/env python3
"""Test framework for comparing Bitcoin full node RPC implementations."""

import json
import time
import http.client
import base64
import os
import sys
from dataclasses import dataclass, field
from typing import Any, Optional


# ---------------------------------------------------------------------------
# RPCClient
# ---------------------------------------------------------------------------

class RPCError(Exception):
    def __init__(self, code, message):
        self.code = code
        self.message = message
        super().__init__(f"RPC error {code}: {message}")


class RPCClient:
    """JSON-RPC client with cookie authentication."""

    def __init__(self, name: str, host: str, port: int, cookie_path: str,
                 timeout: float = 30.0):
        self.name = name
        self.host = host
        self.port = port
        self.cookie_path = cookie_path
        self.timeout = timeout
        self._cookie_cache = None
        self._cookie_mtime = 0
        self._id_counter = 0

    def _read_cookie(self) -> str:
        try:
            mtime = os.path.getmtime(self.cookie_path)
            if self._cookie_cache is None or mtime != self._cookie_mtime:
                with open(self.cookie_path, "r") as f:
                    self._cookie_cache = f.read().strip()
                self._cookie_mtime = mtime
            return self._cookie_cache
        except FileNotFoundError:
            raise RuntimeError(f"Cookie file not found: {self.cookie_path}")

    def _auth_header(self) -> str:
        cookie = self._read_cookie()
        # Cookie format is "user:password" — use the whole string
        encoded = base64.b64encode(cookie.encode()).decode()
        return f"Basic {encoded}"

    def call(self, method: str, *params) -> Any:
        """Make an RPC call and return the result. Raises on error."""
        self._id_counter += 1
        payload = json.dumps({
            "jsonrpc": "2.0",
            "id": self._id_counter,
            "method": method,
            "params": list(params),
        })

        conn = http.client.HTTPConnection(self.host, self.port,
                                          timeout=self.timeout)
        try:
            conn.request("POST", "/", payload, {
                "Content-Type": "application/json",
                "Authorization": self._auth_header(),
            })
            resp = conn.getresponse()
            body = resp.read().decode()
        finally:
            conn.close()

        data = json.loads(body)
        if data.get("error"):
            err = data["error"]
            raise RPCError(err.get("code", -1), err.get("message", str(err)))
        return data.get("result")

    def call_safe(self, method: str, *params) -> Optional[Any]:
        """Make an RPC call, return None on any error."""
        try:
            return self.call(method, *params)
        except Exception:
            return None

    def __repr__(self):
        return f"RPCClient({self.name}, port={self.port})"


# ---------------------------------------------------------------------------
# NodeRegistry
# ---------------------------------------------------------------------------

NODE_CONFIGS = {
    "core":       {"port": 8332,  "cookie": "/data/nvme1/hashhog-mainnet/bitcoin-core/.cookie"},
    "haskoin":    {"port": 8354,  "cookie": "/data/nvme1/hashhog-mainnet/haskoin/.cookie"},
    "rustoshi":   {"port": 8350,  "cookie": "/data/nvme1/hashhog-mainnet/rustoshi/.cookie"},
    "nimrod":     {"port": 8353,  "cookie": "/data/nvme1/hashhog-mainnet/nimrod/mainnet/.cookie"},
    "beamchain":  {"port": 48348, "cookie": "/data/nvme1/hashhog-mainnet/beamchain/.cookie"},
    "hotbuns":    {"port": 8351,  "cookie": "/data/nvme1/hashhog-mainnet/hotbuns/.cookie"},
    "clearbit":   {"port": 8356,  "cookie": "/data/nvme1/hashhog-mainnet/clearbit/.cookie"},
    "blockbrew":  {"port": 8355,  "cookie": "/data/nvme1/hashhog-mainnet/blockbrew/.cookie"},
    "lunarblock": {"port": 8358,  "cookie": "/data/nvme1/hashhog-mainnet/lunarblock/.cookie"},
    "ouroboros":  {"port": 8359,  "cookie": "/data/nvme1/hashhog-mainnet/ouroboros/.cookie"},
    "camlcoin":   {"port": 8357,  "cookie": "/data/nvme1/hashhog-mainnet/camlcoin/.cookie"},
}


class NodeRegistry:
    """Registry of all node RPC clients."""

    def __init__(self, host: str = "127.0.0.1"):
        self.host = host
        self._clients: dict[str, RPCClient] = {}
        for name, cfg in NODE_CONFIGS.items():
            self._clients[name] = RPCClient(
                name=name,
                host=host,
                port=cfg["port"],
                cookie_path=cfg["cookie"],
            )

    def get_node(self, name: str) -> RPCClient:
        return self._clients[name]

    def get_reference(self) -> RPCClient:
        return self._clients["core"]

    def get_available_nodes(self) -> list[RPCClient]:
        """Return nodes that respond to getblockchaininfo."""
        available = []
        for client in self._clients.values():
            try:
                client.call("getblockchaininfo")
                available.append(client)
            except Exception:
                pass
        return available

    def get_at_tip_nodes(self, tolerance: int = 10) -> list[RPCClient]:
        """Return nodes within `tolerance` blocks of Core's height."""
        ref = self.get_reference()
        try:
            ref_info = ref.call("getblockchaininfo")
            ref_height = ref_info["blocks"]
        except Exception:
            return []

        at_tip = []
        for client in self._clients.values():
            try:
                info = client.call("getblockchaininfo")
                height = info.get("blocks", 0)
                if abs(height - ref_height) <= tolerance:
                    at_tip.append(client)
            except Exception:
                pass
        return at_tip


# ---------------------------------------------------------------------------
# ComparisonEngine
# ---------------------------------------------------------------------------

@dataclass
class NodeResult:
    node: str
    passed: bool
    result: Any = None
    error: Optional[str] = None
    diffs: dict = field(default_factory=dict)


@dataclass
class ComparisonResult:
    method: str
    params: list
    reference_result: Any = None
    reference_error: Optional[str] = None
    node_results: list[NodeResult] = field(default_factory=list)

    @property
    def all_passed(self) -> bool:
        return all(nr.passed for nr in self.node_results if nr.node != "core")


class ComparisonEngine:
    """Compare RPC responses across nodes against Core."""

    def __init__(self, registry: NodeRegistry):
        self.registry = registry

    def compare_all(self, method: str, *params,
                    fields: Optional[list[str]] = None,
                    tolerance: Optional[dict[str, float]] = None,
                    nodes: Optional[list[RPCClient]] = None) -> ComparisonResult:
        """Call all at-tip nodes, compare results vs Core.

        Args:
            fields: If set, only compare these top-level keys.
            tolerance: Dict mapping field name to allowed numeric difference.
            nodes: If provided, use these nodes instead of get_at_tip_nodes().
        """
        tolerance = tolerance or {}
        cr = ComparisonResult(method=method, params=list(params))

        # Get reference result
        ref = self.registry.get_reference()
        try:
            cr.reference_result = ref.call(method, *params)
        except Exception as e:
            cr.reference_error = str(e)
            return cr

        # Get target nodes
        target_nodes = nodes if nodes is not None else self.registry.get_at_tip_nodes()

        for client in target_nodes:
            if client.name == "core":
                cr.node_results.append(NodeResult(node="core", passed=True,
                                                  result=cr.reference_result))
                continue

            nr = NodeResult(node=client.name, passed=True)
            try:
                nr.result = client.call(method, *params)
            except Exception as e:
                nr.passed = False
                nr.error = str(e)
                cr.node_results.append(nr)
                continue

            # Compare
            ref_val = cr.reference_result
            node_val = nr.result

            if isinstance(ref_val, dict) and isinstance(node_val, dict):
                keys = fields if fields else list(ref_val.keys())
                for k in keys:
                    if k not in ref_val:
                        continue
                    rv = ref_val.get(k)
                    nv = node_val.get(k)
                    if k in tolerance and isinstance(rv, (int, float)) and isinstance(nv, (int, float)):
                        if abs(rv - nv) > tolerance[k]:
                            nr.diffs[k] = {"expected": rv, "got": nv}
                            nr.passed = False
                    elif rv != nv:
                        nr.diffs[k] = {"expected": rv, "got": nv}
                        nr.passed = False
            elif ref_val != node_val:
                nr.diffs["value"] = {"expected": ref_val, "got": node_val}
                nr.passed = False

            cr.node_results.append(nr)

        return cr


# ---------------------------------------------------------------------------
# TestRunner
# ---------------------------------------------------------------------------

@dataclass
class TestResult:
    name: str
    passed: bool
    details: list  # list of ComparisonResult-like dicts
    error: Optional[str] = None
    duration: float = 0.0


class TestRunner:
    """Execute tests, collect results, output JSON + summary."""

    def __init__(self, registry: NodeRegistry):
        self.registry = registry
        self.engine = ComparisonEngine(registry)
        self.results: list[TestResult] = []

    def run_test(self, name: str, fn):
        """Run a single test function. fn(engine, registry) -> list[ComparisonResult]."""
        print(f"  Running: {name} ...", end=" ", flush=True)
        t0 = time.time()
        try:
            comparisons = fn(self.engine, self.registry)
            passed = all(c.all_passed for c in comparisons)
            details = [self._comparison_to_dict(c) for c in comparisons]
            tr = TestResult(name=name, passed=passed, details=details,
                            duration=time.time() - t0)
        except Exception as e:
            tr = TestResult(name=name, passed=False, details=[],
                            error=str(e), duration=time.time() - t0)
        self.results.append(tr)
        status = "PASS" if tr.passed else "FAIL"
        print(f"{status} ({tr.duration:.1f}s)")
        return tr

    def _comparison_to_dict(self, cr: ComparisonResult) -> dict:
        return {
            "method": cr.method,
            "params": cr.params,
            "reference_error": cr.reference_error,
            "node_results": [
                {
                    "node": nr.node,
                    "passed": nr.passed,
                    "error": nr.error,
                    "diffs": nr.diffs,
                }
                for nr in cr.node_results
            ],
        }

    def to_json(self) -> dict:
        return {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "total_tests": len(self.results),
            "passed": sum(1 for r in self.results if r.passed),
            "failed": sum(1 for r in self.results if not r.passed),
            "tests": [
                {
                    "name": r.name,
                    "passed": r.passed,
                    "error": r.error,
                    "duration": round(r.duration, 2),
                    "details": r.details,
                }
                for r in self.results
            ],
        }

    def summary(self) -> str:
        lines = []
        lines.append("=" * 72)
        lines.append("RPC Conformance Test Results")
        lines.append("=" * 72)
        lines.append(f"Timestamp: {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}")
        lines.append("")

        # Collect all nodes that appeared
        all_nodes = set()
        for r in self.results:
            for d in r.details:
                for nr in d.get("node_results", []):
                    if nr["node"] != "core":
                        all_nodes.add(nr["node"])
        all_nodes = sorted(all_nodes)

        # Per-test summary
        lines.append(f"{'Test':<35} {'Result':<8} {'Time':>6}")
        lines.append("-" * 52)
        for r in self.results:
            status = "PASS" if r.passed else "FAIL"
            lines.append(f"{r.name:<35} {status:<8} {r.duration:>5.1f}s")
            if r.error:
                lines.append(f"  ERROR: {r.error}")
        lines.append("-" * 52)
        total = len(self.results)
        passed = sum(1 for r in self.results if r.passed)
        lines.append(f"Total: {passed}/{total} passed")
        lines.append("")

        # Per-node summary
        node_pass = {n: 0 for n in all_nodes}
        node_fail = {n: 0 for n in all_nodes}
        node_errors = {n: [] for n in all_nodes}

        for r in self.results:
            for d in r.details:
                for nr in d.get("node_results", []):
                    n = nr["node"]
                    if n == "core":
                        continue
                    if nr["passed"]:
                        node_pass[n] += 1
                    else:
                        node_fail[n] += 1
                        if nr["error"]:
                            node_errors[n].append(f"{r.name}: {nr['error'][:80]}")
                        elif nr["diffs"]:
                            diff_keys = list(nr["diffs"].keys())[:3]
                            node_errors[n].append(
                                f"{r.name}/{d['method']}: diff in {diff_keys}")

        lines.append(f"{'Node':<15} {'Pass':>6} {'Fail':>6} {'Total':>6}")
        lines.append("-" * 36)
        for n in all_nodes:
            t = node_pass[n] + node_fail[n]
            lines.append(f"{n:<15} {node_pass[n]:>6} {node_fail[n]:>6} {t:>6}")
        lines.append("")

        # Failures detail
        any_failures = any(errs for errs in node_errors.values())
        if any_failures:
            lines.append("Failure Details:")
            lines.append("-" * 72)
            for n in all_nodes:
                if node_errors[n]:
                    lines.append(f"  {n}:")
                    for e in node_errors[n][:10]:
                        lines.append(f"    - {e}")
            lines.append("")

        lines.append("=" * 72)
        return "\n".join(lines)

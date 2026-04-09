#!/usr/bin/env python3
"""Fleet monitor — health-check all 11 Bitcoin nodes (Core + 10 implementations).

Designed to run via cron every 5 minutes:
  */5 * * * * cd ~/hashhog/test-suite && python3 fleet_monitor.py

Outputs:
  results/fleet-status.json   — full snapshot each run
  results/fleet-alerts.log    — append-only alert log
"""

import json
import os
import subprocess
import sys
import time

# Reuse RPCClient and NODE_CONFIGS from the shared framework
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from framework import RPCClient, NODE_CONFIGS

RESULTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
STATUS_FILE = os.path.join(RESULTS_DIR, "fleet-status.json")
ALERTS_FILE = os.path.join(RESULTS_DIR, "fleet-alerts.log")
TIP_TOLERANCE = 3  # blocks behind Core before alerting


def get_rss_kb(name: str) -> int | None:
    """Return RSS in KB for a node process, or None if not found."""
    # Map node names to likely process identifiers
    search_terms = {
        "core": "bitcoind",
        "rustoshi": "rustoshi",
        "blockbrew": "blockbrew",
        "clearbit": "clearbit",
        "nimrod": "nimrod",
        "camlcoin": "main.exe",
        "beamchain": "beam.smp",
        "hotbuns": "bun",
        "ouroboros": "ouroboros",
        "lunarblock": "luajit",
        "haskoin": "haskoin",
    }
    term = search_terms.get(name, name)
    try:
        # Use pgrep + ps to find RSS
        result = subprocess.run(
            ["pgrep", "-f", term],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return None
        pids = result.stdout.strip().split("\n")
        # Get RSS for the main process (largest RSS)
        max_rss = 0
        for pid in pids:
            pid = pid.strip()
            if not pid:
                continue
            try:
                with open(f"/proc/{pid}/status") as f:
                    for line in f:
                        if line.startswith("VmRSS:"):
                            rss = int(line.split()[1])  # already in kB
                            max_rss = max(max_rss, rss)
                            break
            except (FileNotFoundError, PermissionError, ValueError):
                continue
        return max_rss if max_rss > 0 else None
    except Exception:
        return None


def check_node(name: str, cfg: dict) -> dict:
    """Probe a single node. Returns a status dict."""
    client = RPCClient(
        name=name, host="127.0.0.1",
        port=cfg["port"], cookie_path=cfg["cookie"],
        timeout=10.0,
    )
    status = {
        "name": name,
        "port": cfg["port"],
        "rpc_ok": False,
        "height": None,
        "best_hash": None,
        "peers": None,
        "rss_kb": None,
        "ibd": None,
        "error": None,
    }

    # RPC health
    try:
        info = client.call("getblockchaininfo")
        status["rpc_ok"] = True
        status["height"] = info.get("blocks", info.get("height"))
        status["best_hash"] = info.get("bestblockhash")
        status["ibd"] = info.get("initialblockdownload", False)
    except Exception as e:
        status["error"] = str(e)[:200]
        # Still try to get RSS even if RPC is down
        status["rss_kb"] = get_rss_kb(name)
        return status

    # Peer count
    try:
        net_info = client.call("getnetworkinfo")
        status["peers"] = net_info.get("connections", net_info.get("peers"))
    except Exception:
        # Some impls may not have getnetworkinfo; try getpeerinfo
        try:
            peers = client.call("getpeerinfo")
            if isinstance(peers, list):
                status["peers"] = len(peers)
        except Exception:
            pass

    # RSS
    status["rss_kb"] = get_rss_kb(name)

    return status


def load_previous_status() -> dict | None:
    """Load the previous fleet-status.json for IBD progress comparison."""
    try:
        with open(STATUS_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def run_monitor():
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"Fleet monitor run: {ts}")

    # Load previous for IBD progress comparison
    prev = load_previous_status()
    prev_heights = {}
    if prev and "nodes" in prev:
        for ns in prev["nodes"]:
            prev_heights[ns["name"]] = ns.get("height")

    # Check all nodes
    nodes = []
    for name, cfg in NODE_CONFIGS.items():
        print(f"  Checking {name}...", end=" ", flush=True)
        status = check_node(name, cfg)
        nodes.append(status)
        if status["rpc_ok"]:
            h = status["height"]
            rss_mb = f"{status['rss_kb'] / 1024:.0f}MB" if status["rss_kb"] else "?"
            print(f"height={h} peers={status['peers']} rss={rss_mb}")
        else:
            print(f"DOWN ({status['error'][:60] if status['error'] else 'unknown'})")

    # Find Core height as reference
    core_height = None
    for ns in nodes:
        if ns["name"] == "core" and ns["rpc_ok"]:
            core_height = ns["height"]
            break

    # Generate alerts
    alerts = []

    for ns in nodes:
        name = ns["name"]

        # Alert: node down
        if not ns["rpc_ok"]:
            alerts.append(f"DOWN: {name} — RPC not responding")
            continue

        # Alert: at-tip node falling behind Core
        if core_height is not None and not ns.get("ibd"):
            behind = core_height - (ns["height"] or 0)
            if behind > TIP_TOLERANCE:
                alerts.append(
                    f"BEHIND: {name} at {ns['height']}, "
                    f"Core at {core_height} (behind by {behind})"
                )

        # Alert: IBD node not making progress
        if ns.get("ibd") and name in prev_heights:
            prev_h = prev_heights[name]
            cur_h = ns["height"]
            if prev_h is not None and cur_h is not None and cur_h <= prev_h:
                alerts.append(
                    f"STALLED: {name} IBD stuck at {cur_h} "
                    f"(was {prev_h} last check)"
                )

        # Alert: zero peers
        if ns.get("peers") == 0:
            alerts.append(f"NO_PEERS: {name} has 0 peer connections")

    # Build output
    result = {
        "timestamp": ts,
        "core_height": core_height,
        "node_count": len(nodes),
        "rpc_ok_count": sum(1 for n in nodes if n["rpc_ok"]),
        "alert_count": len(alerts),
        "alerts": alerts,
        "nodes": nodes,
    }

    # Write status JSON
    os.makedirs(RESULTS_DIR, exist_ok=True)
    with open(STATUS_FILE, "w") as f:
        json.dump(result, f, indent=2)
    print(f"\nStatus written to {STATUS_FILE}")

    # Append alerts
    if alerts:
        with open(ALERTS_FILE, "a") as f:
            for a in alerts:
                f.write(f"{ts} {a}\n")
        print(f"Alerts ({len(alerts)}):")
        for a in alerts:
            print(f"  {a}")
    else:
        print("No alerts.")

    # Summary
    print(f"\nSummary: {result['rpc_ok_count']}/{result['node_count']} nodes responding, "
          f"Core height={core_height}")

    return result


if __name__ == "__main__":
    run_monitor()

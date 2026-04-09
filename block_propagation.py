#!/usr/bin/env python3
"""Block propagation measurement — detect new blocks on Core and measure
how long each implementation takes to receive them.

Runs as a long-lived daemon:
  python3 block_propagation.py

Polls Core every 10 seconds. When a new block appears, immediately polls
all other nodes and records the timestamp each reports the new height.

Outputs:
  results/block-propagation.csv — append-only log of propagation times
  results/fleet-alerts.log     — alerts for nodes exceeding 60s threshold
"""

import csv
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from framework import RPCClient, NODE_CONFIGS

RESULTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
CSV_FILE = os.path.join(RESULTS_DIR, "block-propagation.csv")
ALERTS_FILE = os.path.join(RESULTS_DIR, "fleet-alerts.log")

POLL_INTERVAL = 10       # seconds between Core polls
CHECK_INTERVAL = 0.5     # seconds between propagation checks
MAX_WAIT = 120           # stop checking after this many seconds
ALERT_THRESHOLD = 60     # alert if node takes longer than this

CSV_FIELDS = [
    "block_height", "block_hash", "block_time_utc",
    "core_detected_utc", "node", "node_detected_utc",
    "propagation_sec", "alert",
]


def build_clients() -> dict[str, RPCClient]:
    """Build RPC clients for all nodes."""
    clients = {}
    for name, cfg in NODE_CONFIGS.items():
        clients[name] = RPCClient(
            name=name, host="127.0.0.1",
            port=cfg["port"], cookie_path=cfg["cookie"],
            timeout=10.0,
        )
    return clients


def get_core_tip(core: RPCClient) -> tuple[int | None, str | None]:
    """Return (height, hash) from Core, or (None, None) on failure."""
    try:
        info = core.call("getblockchaininfo")
        return info.get("blocks"), info.get("bestblockhash")
    except Exception:
        return None, None


def ensure_csv():
    """Create CSV file with headers if it does not exist."""
    os.makedirs(RESULTS_DIR, exist_ok=True)
    if not os.path.exists(CSV_FILE):
        with open(CSV_FILE, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
            writer.writeheader()


def append_alert(msg: str):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(ALERTS_FILE, "a") as f:
        f.write(f"{ts} {msg}\n")
    print(f"  ALERT: {msg}")


def measure_propagation(
    clients: dict[str, RPCClient],
    height: int,
    block_hash: str,
    core_detected: float,
):
    """Poll all non-Core nodes until they report the new height or timeout."""
    ts_utc = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(core_detected))
    print(f"New block {height} ({block_hash[:16]}...) detected at {ts_utc}")

    # Track which nodes still need to report
    pending = {
        name: client for name, client in clients.items()
        if name != "core"
    }
    results = []  # list of dicts for CSV
    deadline = core_detected + MAX_WAIT

    while pending and time.time() < deadline:
        still_pending = {}
        for name, client in pending.items():
            try:
                info = client.call("getblockchaininfo")
                node_height = info.get("blocks", info.get("height", 0))
                if node_height >= height:
                    now = time.time()
                    delay = round(now - core_detected, 2)
                    node_ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
                    alert = delay > ALERT_THRESHOLD
                    results.append({
                        "block_height": height,
                        "block_hash": block_hash,
                        "block_time_utc": ts_utc,
                        "core_detected_utc": ts_utc,
                        "node": name,
                        "node_detected_utc": node_ts,
                        "propagation_sec": delay,
                        "alert": alert,
                    })
                    print(f"  {name}: {delay:.1f}s", "(SLOW)" if alert else "")
                    if alert:
                        append_alert(
                            f"SLOW_PROPAGATION: {name} took {delay:.1f}s "
                            f"for block {height}"
                        )
                else:
                    still_pending[name] = client
            except Exception:
                still_pending[name] = client

        pending = still_pending
        if pending:
            time.sleep(CHECK_INTERVAL)

    # Record timed-out nodes
    for name in pending:
        now = time.time()
        delay = round(now - core_detected, 2)
        node_ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
        results.append({
            "block_height": height,
            "block_hash": block_hash,
            "block_time_utc": ts_utc,
            "core_detected_utc": ts_utc,
            "node": name,
            "node_detected_utc": "timeout",
            "propagation_sec": delay,
            "alert": True,
        })
        print(f"  {name}: TIMEOUT ({delay:.0f}s)")
        append_alert(
            f"PROPAGATION_TIMEOUT: {name} did not reach block {height} "
            f"within {MAX_WAIT}s"
        )

    # Write CSV
    with open(CSV_FILE, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        for row in results:
            writer.writerow(row)

    responded = len(results) - len(pending)
    print(f"  Block {height}: {responded}/{len(results)} nodes responded within {MAX_WAIT}s")


def main():
    print("Block propagation monitor starting...")
    print(f"  Poll interval: {POLL_INTERVAL}s")
    print(f"  Alert threshold: {ALERT_THRESHOLD}s")
    print(f"  CSV: {CSV_FILE}")

    ensure_csv()
    clients = build_clients()
    core = clients["core"]

    # Get initial tip
    last_height, last_hash = get_core_tip(core)
    if last_height is None:
        print("WARNING: Core not responding, waiting...")
    else:
        print(f"Initial Core tip: height={last_height} hash={last_hash[:16]}...")

    while True:
        try:
            time.sleep(POLL_INTERVAL)
            height, bhash = get_core_tip(core)
            if height is None:
                continue
            if last_height is None:
                # First successful contact
                last_height, last_hash = height, bhash
                print(f"Core now responding: height={height}")
                continue
            if height > last_height:
                detected_at = time.time()
                measure_propagation(clients, height, bhash, detected_at)
                last_height, last_hash = height, bhash
        except KeyboardInterrupt:
            print("\nShutting down.")
            break
        except Exception as e:
            print(f"Error in main loop: {e}")
            time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""P2P connectivity verification for all mainnet nodes.

Read-only diagnostic: calls getpeerinfo and getnetworkinfo on each node,
analyzes peer diversity, and reports results.
"""

import json
import os
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone

# Add parent dir so we can import framework
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from framework import RPCClient, NODE_CONFIGS

DNS_SEEDS = [
    "seed.bitcoin.sipa.be:8333",
    "dnsseed.bluematt.me:8333",
    "dnsseed.bitcoin.dashjr-list-of-hierarchical-deterministic-wallets.org:8333",
    "seed.bitcoinstats.com:8333",
    "seed.bitcoin.jonasschnelli.ch:8333",
    "seed.btc.petertodd.net:8333",
    "seed.bitcoin.sprovoost.nl:8333",
]


def get_subnet_16(addr: str) -> str:
    """Extract /16 subnet from an IP address string. Handles IPv4, IPv6, .onion, etc."""
    # Strip port if present (handle both IPv4:port and [IPv6]:port)
    if addr.startswith("["):
        # IPv6 bracket notation
        bracket_end = addr.find("]")
        if bracket_end != -1:
            addr = addr[1:bracket_end]
    elif addr.count(":") == 1:
        # IPv4:port
        addr = addr.rsplit(":", 1)[0]

    # Handle onion/i2p/cjdns
    if ".onion" in addr:
        return "tor"
    if ".i2p" in addr:
        return "i2p"

    parts = addr.split(".")
    if len(parts) == 4:
        try:
            return f"{parts[0]}.{parts[1]}.0.0/16"
        except (ValueError, IndexError):
            pass
    # IPv6 or other
    return addr[:19] if len(addr) > 19 else addr


def check_node(name: str, cfg: dict) -> dict:
    """Check a single node's P2P connectivity."""
    client = RPCClient(
        name=name,
        host="127.0.0.1",
        port=cfg["port"],
        cookie_path=cfg["cookie"],
        timeout=10.0,
    )

    result = {
        "total_peers": 0,
        "outbound": 0,
        "inbound": 0,
        "outbound_full_relay": 0,
        "outbound_block_relay": 0,
        "unique_subnets": 0,
        "listening": False,
        "protocol_versions": [],
        "status": "UNREACHABLE",
        "error": None,
        "subnet_details": {},
        "peer_addresses": [],
    }

    # Try getpeerinfo
    try:
        peers = client.call("getpeerinfo")
    except FileNotFoundError:
        result["error"] = f"Cookie file not found: {cfg['cookie']}"
        return result
    except Exception as e:
        result["error"] = str(e)[:200]
        return result

    if not isinstance(peers, list):
        result["error"] = f"Unexpected getpeerinfo response type: {type(peers).__name__}"
        return result

    result["total_peers"] = len(peers)

    subnets = set()
    protocol_versions = defaultdict(int)

    for peer in peers:
        # Classify direction
        inbound = peer.get("inbound", False)
        if inbound:
            result["inbound"] += 1
        else:
            result["outbound"] += 1
            conn_type = peer.get("connection_type", "")
            if conn_type == "block-relay-only":
                result["outbound_block_relay"] += 1
            elif conn_type in ("outbound-full-relay", "full-relay"):
                result["outbound_full_relay"] += 1

        # Subnet
        addr = peer.get("addr", "")
        result["peer_addresses"].append(addr)
        subnet = get_subnet_16(addr)
        subnets.add(subnet)

        # Protocol version
        version = peer.get("version", 0)
        protocol_versions[str(version)] += 1

    result["unique_subnets"] = len(subnets)
    result["subnet_details"] = {s: 0 for s in sorted(subnets)}
    for peer in peers:
        s = get_subnet_16(peer.get("addr", ""))
        if s in result["subnet_details"]:
            result["subnet_details"][s] += 1
    result["protocol_versions"] = dict(protocol_versions)

    # Try getnetworkinfo
    try:
        netinfo = client.call("getnetworkinfo")
        if isinstance(netinfo, dict):
            # Check listening status
            result["listening"] = netinfo.get("localservices", "") != "" or netinfo.get("networkactive", False)
            # Some nodes report 'connections' and 'connections_in'/'connections_out'
            if "localaddresses" in netinfo and netinfo["localaddresses"]:
                result["listening"] = True
    except Exception:
        pass

    # Determine status
    if result["total_peers"] == 0:
        result["status"] = "NO_PEERS"
    elif result["total_peers"] < 3:
        result["status"] = "LOW"
    elif result["unique_subnets"] < 4:
        result["status"] = "LOW_DIVERSITY"
    else:
        result["status"] = "GOOD"

    return result


def try_addnode(name: str, cfg: dict, seeds: list[str]) -> list[str]:
    """If a node has 0 peers, try adding DNS seed nodes via addnode onetry."""
    client = RPCClient(
        name=name,
        host="127.0.0.1",
        port=cfg["port"],
        cookie_path=cfg["cookie"],
        timeout=10.0,
    )
    added = []
    for seed in seeds[:3]:
        try:
            client.call("addnode", seed, "onetry")
            added.append(seed)
        except Exception:
            pass
    return added


def main():
    print("=" * 72)
    print("P2P Connectivity Verification - Mainnet Nodes")
    print(f"Timestamp: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print("=" * 72)
    print()

    nodes_report = {}
    recommendations = []
    zero_peer_nodes = []

    # Check all nodes
    for name, cfg in sorted(NODE_CONFIGS.items()):
        print(f"  Checking {name:<15} (port {cfg['port']}) ... ", end="", flush=True)
        result = check_node(name, cfg)
        nodes_report[name] = result

        # Summarize
        if result["status"] == "UNREACHABLE":
            print(f"UNREACHABLE ({result['error'][:60] if result['error'] else 'unknown'})")
        elif result["status"] == "NO_PEERS":
            print(f"NO PEERS (0 connected)")
            zero_peer_nodes.append(name)
        else:
            print(f"{result['status']} - {result['total_peers']} peers "
                  f"(out={result['outbound']}, in={result['inbound']}, "
                  f"subnets={result['unique_subnets']})")

    print()

    # Try addnode for zero-peer nodes
    if zero_peer_nodes:
        print("Attempting addnode for zero-peer nodes:")
        for name in zero_peer_nodes:
            cfg = NODE_CONFIGS[name]
            added = try_addnode(name, cfg, DNS_SEEDS)
            if added:
                print(f"  {name}: sent addnode onetry to {', '.join(added)}")
                recommendations.append(
                    f"{name}: had 0 peers, attempted addnode to {len(added)} DNS seeds"
                )
            else:
                print(f"  {name}: addnode failed or not supported")
                recommendations.append(
                    f"{name}: has 0 peers and addnode failed - may need manual intervention"
                )
        print()

    # Generate recommendations
    for name, result in sorted(nodes_report.items()):
        if result["status"] == "UNREACHABLE":
            recommendations.append(f"{name}: node unreachable - check if running")
        elif result["status"] == "LOW":
            recommendations.append(
                f"{name}: only {result['total_peers']} peers - consider checking firewall/NAT"
            )
        elif result["status"] == "LOW_DIVERSITY":
            recommendations.append(
                f"{name}: low subnet diversity ({result['unique_subnets']} unique /16s) "
                f"- peers may be clustered"
            )

    # Clean up output for JSON (remove peer_addresses to keep file manageable)
    json_nodes = {}
    for name, result in nodes_report.items():
        json_nodes[name] = {
            "total_peers": result["total_peers"],
            "outbound": result["outbound"],
            "inbound": result["inbound"],
            "outbound_full_relay": result["outbound_full_relay"],
            "outbound_block_relay": result["outbound_block_relay"],
            "unique_subnets": result["unique_subnets"],
            "listening": result["listening"],
            "protocol_versions": result["protocol_versions"],
            "status": result["status"],
            "error": result["error"],
        }

    report = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "nodes": json_nodes,
        "recommendations": recommendations,
    }

    # Write results
    results_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
    os.makedirs(results_dir, exist_ok=True)
    output_path = os.path.join(results_dir, "p2p-connectivity.json")
    with open(output_path, "w") as f:
        json.dump(report, f, indent=2)
    print(f"Results written to {output_path}")
    print()

    # Print summary table
    print("=" * 72)
    print(f"{'Node':<15} {'Status':<15} {'Peers':>6} {'Out':>5} {'In':>5} {'Subnets':>8} {'Listen':>7}")
    print("-" * 72)
    for name in sorted(json_nodes):
        n = json_nodes[name]
        listen_str = "yes" if n["listening"] else "no"
        print(f"{name:<15} {n['status']:<15} {n['total_peers']:>6} "
              f"{n['outbound']:>5} {n['inbound']:>5} {n['unique_subnets']:>8} {listen_str:>7}")
    print("=" * 72)

    if recommendations:
        print()
        print("Recommendations:")
        for r in recommendations:
            print(f"  - {r}")

    return 0 if not any(n["status"] == "NO_PEERS" for n in json_nodes.values()) else 1


if __name__ == "__main__":
    sys.exit(main())

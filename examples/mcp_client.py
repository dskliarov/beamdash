#!/usr/bin/env python3
"""Sample client for beamdash's MCP server.

Start beamdash (`mix phx.server`) and connect it to a node first, then run:

    python3 examples/mcp_client.py                 # list the tools and show node_info
    python3 examples/mcp_client.py list_processes '{"limit": 5}'
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

PROTOCOL_VERSION = "2025-06-18"


def send(url, message):
    headers = {"content-type": "application/json", "MCP-Protocol-Version": PROTOCOL_VERSION}
    request = urllib.request.Request(url, json.dumps(message).encode(), headers, method="POST")
    with urllib.request.urlopen(request) as response:
        body = response.read()
    return json.loads(body) if body else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tool", nargs="?", default="node_info", help="tool to call (default: node_info)")
    parser.add_argument("arguments", nargs="?", default="{}", help="tool arguments as a JSON object")
    parser.add_argument("--url", default="http://127.0.0.1:4000/mcp", help="beamdash MCP endpoint")
    args = parser.parse_args()

    try:
        arguments = json.loads(args.arguments)
    except json.JSONDecodeError as error:
        sys.exit(f"arguments must be a JSON object: {error}")
    if not isinstance(arguments, dict):
        sys.exit("arguments must be a JSON object")

    try:
        send(args.url, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": PROTOCOL_VERSION, "capabilities": {},
                                   "clientInfo": {"name": "beamdash-sample", "version": "0.1"}}})
        send(args.url, {"jsonrpc": "2.0", "method": "notifications/initialized"})

        tools = send(args.url, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        names = [tool["name"] for tool in tools["result"]["tools"]]
        print("tools:", ", ".join(names))

        reply = send(args.url, {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                "params": {"name": args.tool, "arguments": arguments}})
    except urllib.error.HTTPError as error:
        sys.exit(f"server refused the request: HTTP {error.code} {error.reason}")
    except urllib.error.URLError as error:
        sys.exit(f"cannot reach {args.url}: {error.reason}")

    if "error" in reply:
        sys.exit(f"JSON-RPC error {reply['error']['code']}: {reply['error']['message']}")

    result = reply["result"]
    text = result["content"][0]["text"]
    if result.get("isError"):
        sys.exit(f"tool error: {text}")
    print(json.dumps(json.loads(text), indent=2))


if __name__ == "__main__":
    main()

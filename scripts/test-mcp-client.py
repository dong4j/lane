#!/usr/bin/env python3
"""Exercise the copied Generic config with the official SDK and loopback fixtures."""

from datetime import timedelta
import json
from pathlib import Path
import sys
from urllib.request import ProxyHandler, build_opener

import anyio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.types import Implementation


async def call(session, tool, arguments=None):
    """Require MCP's structured result from the packaged helper."""
    result = await session.call_tool(tool, arguments or {})
    if result.isError or result.structuredContent is None:
        raise RuntimeError(f"{tool}: {result.content}")
    return result.structuredContent


def read_forwarded_service(address):
    """Ignore system HTTP proxies while checking the known fixture listener."""
    opener = build_opener(ProxyHandler({}))
    with opener.open(f"http://{address}/mcp-sdk", timeout=4) as response:
        return response.read()


async def check(server, expected_address, client_name, external):
    """Use independent stdio sessions even though they share one copied configuration."""
    async with stdio_client(server) as (reader, writer):
        async with ClientSession(
            reader, writer, read_timeout_seconds=timedelta(seconds=10),
            client_info=Implementation(name=client_name, version="1.0"),
        ) as session:
            await session.initialize()
            tools = await session.list_tools()
            assert {tool.name for tool in tools.tools} == {"lane_list", "lane_request", "lane_status", "lane_release"}
            listing = await call(session, "lane_list", {"include_external": True} if external else {})
            assert listing["can_request"]
            request = {"idempotency_key": client_name, "purpose": "Verify Generic MCP setup"}
            if external:
                assert any(route["listen_address"] == expected_address for route in listing["external"])
                request.update(kind="external", external_address=expected_address)
            else:
                assert "external" not in listing
                rule = next(rule for rule in listing["rules"] if rule["listen_address"] == expected_address)
                request.update(kind="shared", rule_id=rule["id"])

            lease = (await call(session, "lane_request", request))["lease"]
            lookup = {"lease_id": lease["id"]}
            try:
                with anyio.fail_after(15):
                    while lease["state"] in {"connecting", "reconnecting"}:
                        await anyio.sleep(0.05)
                        lease = (await call(session, "lane_status", lookup))["lease"]
                assert lease["state"] == "ready", lease
                assert lease["address"] == expected_address
                assert await anyio.to_thread.run_sync(read_forwarded_service, expected_address) == b"lane-fixture"
            finally:
                released = (await call(session, "lane_release", lookup))["lease"]
                assert released["state"] == "released"
            if external:
                assert await anyio.to_thread.run_sync(read_forwarded_service, expected_address) == b"lane-fixture"


async def main(recipe):
    """Use the UI's executable and arguments, with only fixture addresses as targets."""
    setup = json.loads(recipe.read_text())["mcpServers"]["lane"]
    fixture = json.loads(recipe.with_name("manifest.json").read_text())
    server = StdioServerParameters(command=setup["command"], args=setup["args"])
    with anyio.fail_after(40):
        await check(server, f"127.0.0.1:{int(fixture['localPort'])}", "Lane SDK fixture", external=False)
        await check(server, f"127.0.0.1:{int(fixture['externalPorts'][1])}", "Lane external SDK fixture", external=True)
    print("Generic MCP: two clients listed, connected, used and released loopback forwards.")


if __name__ == "__main__":
    anyio.run(main, Path(sys.argv[1]))

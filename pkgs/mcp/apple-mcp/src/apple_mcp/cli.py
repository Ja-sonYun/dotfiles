import asyncio
import json
import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import timedelta
from pathlib import Path
from typing import Any

import httpx
import uvicorn
from mcp import ClientSession, types
from mcp.client.streamable_http import streamable_http_client
from mcp.server.lowlevel import Server
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.routing import Route
from starlette.types import Receive, Scope, Send

BACKENDS = {
    "calendar": "http://127.0.0.1:7363/mcp",
    "reminders": "http://127.0.0.1:7362/mcp",
}


@asynccontextmanager
async def connect(backend: str) -> AsyncIterator[ClientSession]:
    headers = {}
    if backend == "reminders":
        token = (
            await asyncio.to_thread(Path(os.environ["APPLE_MCP_TOKEN_FILE"]).read_text)
        ).strip()
        if not token:
            raise ValueError("Reminders authentication key is empty")
        headers["Authorization"] = f"Bearer {token}"
    async with (
        httpx.AsyncClient(
            headers=headers, timeout=httpx.Timeout(150, connect=10), trust_env=False
        ) as client,
        streamable_http_client(BACKENDS[backend], http_client=client) as (
            reader,
            writer,
            _,
        ),
        ClientSession(
            reader, writer, read_timeout_seconds=timedelta(seconds=150)
        ) as session,
    ):
        await session.initialize()
        yield session


async def list_tools() -> list[types.Tool]:
    tools = []
    for backend in BACKENDS:
        async with connect(backend) as session:
            cursor = None
            while True:
                page = await session.list_tools(
                    params=types.PaginatedRequestParams(cursor=cursor)
                )
                tools.extend(
                    tool.model_copy(update={"name": f"{backend}_{tool.name}"})
                    for tool in page.tools
                )
                cursor = page.nextCursor
                if cursor is None:
                    break
    return tools


async def call_tool(name: str, arguments: dict[str, Any]) -> types.CallToolResult:
    backend, separator, tool = name.partition("_")
    if not separator or backend not in BACKENDS or not tool:
        return types.CallToolResult(
            isError=True,
            content=[types.TextContent(type="text", text="Unknown Apple tool")],
        )
    async with connect(backend) as session:
        return await session.call_tool(tool, arguments)


class HttpEndpoint:
    def __init__(self, manager: StreamableHTTPSessionManager) -> None:
        self.manager = manager

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        await self.manager.handle_request(scope, receive, send)


def main() -> None:
    server = Server("apple")
    server.list_tools()(list_tools)
    server.call_tool()(call_tool)
    manager = StreamableHTTPSessionManager(
        server,
        json_response=True,
        stateless=True,
        security_settings=TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=["127.0.0.1:*", "localhost:*"]
            + json.loads(os.environ.get("APPLE_MCP_ALLOWED_HOSTS", "[]")),
            allowed_origins=json.loads(
                os.environ.get("APPLE_MCP_ALLOWED_ORIGINS", "[]")
            ),
        ),
    )
    app = Starlette(
        routes=[Route("/mcp", endpoint=HttpEndpoint(manager))],
        lifespan=lambda app: manager.run(),
    )
    uvicorn.run(app, host="127.0.0.1", port=7364, log_level="warning")

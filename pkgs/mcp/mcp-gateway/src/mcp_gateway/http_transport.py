from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Unpack

from fastmcp.client.transports.base import (
    ClientTransport,
    SessionKwargs,
    TransportOptions,
)
from mcp import ClientSession
from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client
from pydantic import SecretStr


class HttpTransport(ClientTransport):
    def __init__(
        self, url: str, token: SecretStr | None, max_sse_event_size: int
    ) -> None:
        self.url = url
        self.token = token
        self.max_sse_event_size = max_sse_event_size

    @asynccontextmanager
    async def connect_session(
        self,
        *,
        transport_options: TransportOptions | None = None,
        **session_kwargs: Unpack[SessionKwargs],
    ) -> AsyncIterator[ClientSession]:
        options = transport_options or TransportOptions()
        headers = (
            {"Authorization": f"Bearer {self.token.get_secret_value()}"}
            if self.token is not None
            else {}
        )
        async with (
            create_mcp_http_client(headers=headers) as http_client,
            streamable_http_client(
                self.url,
                http_client=http_client,
                max_sse_event_size=self.max_sse_event_size,
            ) as (read_stream, write_stream),
            options.session_class(
                read_stream, write_stream, **session_kwargs
            ) as session,
        ):
            yield session

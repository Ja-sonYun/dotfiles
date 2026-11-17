import argparse
import json
import os
import secrets
import tempfile
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Unpack

from cryptography.fernet import Fernet
from dotenv import dotenv_values
from fastmcp import FastMCP
from fastmcp.client.transports import ClientTransport, StdioTransport
from fastmcp.client.transports.base import SessionKwargs, TransportOptions
from fastmcp.server import create_proxy
from fastmcp.server.auth import AccessToken, AuthContext, TokenVerifier
from fastmcp.server.auth.providers.google import GoogleProvider
from fastmcp.server.middleware import AuthMiddleware
from key_value.aio.stores.disk import DiskStore
from key_value.aio.wrappers.encryption import FernetEncryptionWrapper
from mcp import ClientSession
from pydantic import SecretStr, ValidationError

from mcp_gateway.config import BearerAuth, GatewayConfig, HttpBackend
from mcp_gateway.http_transport import HttpTransport


def read_secret(path: Path) -> SecretStr:
    value = path.read_text().strip()
    if not value:
        raise ValueError(f"Secret file is empty: {path}")
    return SecretStr(value)


class FreshStdioTransport(StdioTransport):
    @asynccontextmanager
    async def connect_session(
        self,
        *,
        transport_options: TransportOptions | None = None,
        **session_kwargs: Unpack[SessionKwargs],
    ) -> AsyncIterator[ClientSession]:
        transport = StdioTransport(
            command=self.command,
            args=self.args,
            env=self.env,
            cwd=self.cwd,
            keep_alive=False,
            log_file=self.log_file,
        )
        async with transport.connect_session(
            transport_options=transport_options, **session_kwargs
        ) as session:
            yield session


class BearerTokenVerifier(TokenVerifier):
    def __init__(self, token_file: Path) -> None:
        super().__init__()
        self.expected_token = read_secret(token_file)

    async def verify_token(self, token: str) -> AccessToken | None:
        if not secrets.compare_digest(token, self.expected_token.get_secret_value()):
            return None
        return AccessToken(token=token, client_id="gateway", scopes=[])


def create_server(settings: GatewayConfig) -> FastMCP:
    authentication = settings.auth
    if isinstance(authentication, BearerAuth):
        server = FastMCP(
            settings.name,
            auth=BearerTokenVerifier(authentication.token_file),
            list_page_size=settings.list_page_size,
        )
    else:
        credentials = dotenv_values(authentication.credentials_file)
        client_id = credentials.get(authentication.client_id_key)
        client_secret = credentials.get(authentication.client_secret_key)
        if not client_id or not client_secret:
            raise ValueError("Google OAuth credentials are missing or empty")
        owner_sub = authentication.owner_sub

        state = authentication.state_dir
        state.mkdir(parents=True, exist_ok=True, mode=0o700)
        key_file = state / "keys.json"
        if not key_file.exists():
            keys = {
                "storage_key": Fernet.generate_key().decode(),
                "jwt_signing_key": secrets.token_urlsafe(48),
            }
            with tempfile.NamedTemporaryFile(
                mode="w", dir=state, delete=False
            ) as output:
                json.dump(keys, output)
                temporary_path = output.name
            os.replace(temporary_path, key_file)
        keys = json.loads(key_file.read_text())

        def owner_only(context: AuthContext) -> bool:
            token = context.token
            return token is not None and token.claims.get("sub") == owner_sub

        storage = FernetEncryptionWrapper(
            key_value=DiskStore(directory=str(state / "oauth")),
            fernet=Fernet(keys["storage_key"].encode()),
        )
        auth = GoogleProvider(
            client_id=client_id,
            client_secret=client_secret,
            base_url=str(authentication.base_url),
            jwt_signing_key=keys["jwt_signing_key"],
            client_storage=storage,
        )
        server = FastMCP(
            settings.name, auth=auth, list_page_size=settings.list_page_size
        )
        server.add_middleware(AuthMiddleware(auth=owner_only))

    for backend in settings.backends:
        transport: ClientTransport
        if isinstance(backend, HttpBackend):
            transport = HttpTransport(
                str(backend.url),
                read_secret(backend.bearer_token_file)
                if backend.bearer_token_file is not None
                else None,
                backend.max_sse_event_size,
            )
        else:
            environment = backend.env | {
                name: read_secret(path).get_secret_value()
                for name, path in backend.env_files.items()
            }
            transport = FreshStdioTransport(
                command=backend.command,
                args=backend.args,
                env=environment,
            )
        server.mount(
            create_proxy(transport, mode=backend.mode), namespace=backend.namespace
        )

    return server


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()

    os.umask(0o077)
    try:
        settings = GatewayConfig.model_validate_json(args.config.read_text())
    except ValidationError as error:
        parser.error(str(error))

    server = create_server(settings)
    server.run(
        transport="http",
        host=settings.listen.host,
        port=settings.listen.port,
        json_response=False,
        stateless_http=False,
    )

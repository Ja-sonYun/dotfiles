import argparse
import json
import logging
import os
import secrets
import tempfile
from pathlib import Path

from cryptography.fernet import Fernet
from dotenv import dotenv_values
from fastmcp import Client, FastMCP
from fastmcp.client.transports import StdioTransport
from fastmcp.server import create_proxy
from fastmcp.server.auth import AuthContext
from fastmcp.server.auth.providers.google import GoogleProvider
from fastmcp.server.middleware import AuthMiddleware
from key_value.aio.stores.disk import DiskStore
from key_value.aio.wrappers.encryption import FernetEncryptionWrapper


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--credentials", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--owner-sub", default="")
    parser.add_argument("--firecrawl-key", type=Path, required=True)
    parser.add_argument("--n8n-url", type=Path, required=True)
    parser.add_argument("--n8n-key", type=Path, required=True)
    args = parser.parse_args()

    os.umask(0o077)
    credentials = dotenv_values(args.credentials)
    owner_sub = args.owner_sub

    args.state.mkdir(parents=True, exist_ok=True, mode=0o700)
    key_file = args.state / "keys.json"
    if not key_file.exists():
        keys = {
            "storage_key": Fernet.generate_key().decode(),
            "jwt_signing_key": secrets.token_urlsafe(48),
        }
        with tempfile.NamedTemporaryFile(
            mode="w", dir=args.state, delete=False
        ) as output:
            json.dump(keys, output)
            temporary_path = output.name
        os.replace(temporary_path, key_file)
    keys = json.loads(key_file.read_text())

    def owner_only(context: AuthContext) -> bool:
        token = context.token
        if token is None:
            return False
        if not owner_sub:
            logging.getLogger(__name__).warning(
                "MCP access denied during setup: Google email=%r sub=%r",
                token.claims.get("email"),
                token.claims.get("sub"),
            )
            return False
        return token.claims.get("sub") == owner_sub

    storage = FernetEncryptionWrapper(
        key_value=DiskStore(directory=str(args.state / "oauth")),
        fernet=Fernet(keys["storage_key"].encode()),
    )
    auth = GoogleProvider(
        client_id=credentials["CADDY_SECURITY_GOOGLE_CLIENT_ID"],
        client_secret=credentials["CADDY_SECURITY_GOOGLE_CLIENT_SECRET"],
        base_url="https://mcp.test0.zip",
        jwt_signing_key=keys["jwt_signing_key"],
        client_storage=storage,
    )
    server = FastMCP("Internal MCP", auth=auth)
    server.add_middleware(AuthMiddleware(auth=owner_only))

    server.mount(create_proxy("http://127.0.0.1:7364/mcp"), namespace="apple")
    server.mount(
        create_proxy(
            Client(
                StdioTransport(
                    command="firecrawl-mcp",
                    args=[],
                    env={
                        "FIRECRAWL_API_URL": "https://fc.test0.zip",
                        "FIRECRAWL_API_KEY": args.firecrawl_key.read_text().strip(),
                    },
                )
            )
        ),
        namespace="firecrawl",
    )
    server.mount(
        create_proxy(
            Client(
                StdioTransport(
                    command="n8n-mcp",
                    args=[],
                    env={
                        "N8N_API_URL": args.n8n_url.read_text().strip(),
                        "N8N_API_KEY": args.n8n_key.read_text().strip(),
                        "MCP_MODE": "stdio",
                    },
                )
            )
        ),
        namespace="n8n_personal",
    )

    server.run(transport="http", host="127.0.0.1", port=7365)

# Internal MCP gateway

The Mac server exposes Apple, Firecrawl, and personal n8n through
`https://mcp.test0.zip/mcp`. Work n8n remains a separate client-side MCP.

## Google OAuth setup

Add `https://mcp.test0.zip/auth/callback` to the existing Google OAuth web
client's authorized redirect URIs. Keep the Caddy callback registered.
The gateway reads `CADDY_SECURITY_GOOGLE_CLIENT_ID` and
`CADDY_SECURITY_GOOGLE_CLIENT_SECRET` from the existing agenix-managed Caddy
environment file. It does not use the Caddy JWT signing key.

Initially, `services.mcp-gateway.ownerSub` is empty and all MCP access is
denied. Connect the `infra` MCP and complete Google login. Find your account's
`email` and `sub` in `~/Library/Logs/mcp-gateway.log` on the server, then set
`services.mcp-gateway.ownerSub` to that `sub` in the server host configuration
and activate it. Do not select an identity belonging to another login.

The gateway creates signing and encryption keys at first startup and stores
them with its encrypted OAuth state under
`~/Library/Application Support/mcp-gateway`. Disabling the service preserves
this state. Deleting it invalidates existing client sessions.

Google login and a public callback require the edge route, DNS, FRP, and Mac
service to be deployed. Code changes alone do not register the Google callback.

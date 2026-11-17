{ uv }:
uv.asPackage {
  name = "mcp-gateway";
  root = ./.;
  entrypoint = "mcp_gateway.cli:main";
}

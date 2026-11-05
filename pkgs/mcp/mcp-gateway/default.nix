{
  uv,
  firecrawl-mcp,
  n8n-mcp,
}:
uv.asPackage {
  name = "mcp-gateway";
  root = ./.;
  entrypoint = "mcp_gateway.cli:main";
  runtimeInputs = [
    firecrawl-mcp
    n8n-mcp
  ];
}

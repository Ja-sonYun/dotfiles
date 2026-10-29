{ uv, ... }:
(uv.asPackage {
  name = "antigravity-mcp";
  root = ./.;
  entrypoint = "antigravity_mcp.cli:main";
}).overrideAttrs
  {
    meta = {
      description = "Call Antigravity CLI through MCP";
      mainProgram = "antigravity-mcp";
      platforms = [ "aarch64-darwin" ];
    };
  }

{ lib, uv }:
(uv.asPackage {
  name = "calendar-mcp";
  root = ./.;
  entrypoint = "calendar_mcp.cli:main";
}).overrideAttrs
  {
    meta = {
      description = "HTTP MCP interface for Apple Calendar";
      mainProgram = "calendar-mcp";
      platforms = lib.platforms.darwin;
    };
  }

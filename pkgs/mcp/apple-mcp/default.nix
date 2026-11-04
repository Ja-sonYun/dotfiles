{ lib, uv }:
(uv.asPackage {
  name = "apple-mcp";
  root = ./.;
  entrypoint = "apple_mcp.cli:main";
}).overrideAttrs
  {
    meta = {
      description = "Combined Calendar and Reminders MCP gateway";
      mainProgram = "apple-mcp";
      platforms = lib.platforms.darwin;
    };
  }

{
  lib,
  notifycmd,
  uv,
}:
(uv.asPackage {
  name = "notify-mcp";
  root = ./.;
  entrypoint = "notify_mcp.cli:main";
  runtimeInputs = [ notifycmd ];
}).overrideAttrs
  {
    meta = {
      description = "Send AI agent progress notifications to the desktop";
      mainProgram = "notify-mcp";
      platforms = lib.platforms.darwin;
    };
  }

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents.extensions.notification;
  package = pkgs.callPackage ./package.nix { };
  block = {
    hooks = [
      {
        type = "command";
        command = lib.getExe package;
        timeout = 5;
      }
    ];
  };
in
{
  options.programs.ai-agents.extensions.notification = {
    enable = lib.mkEnableOption "AI agent desktop notifications";
    mcp.enable = lib.mkEnableOption "AI agent progress notification MCP server";
    sendCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = lib.getExe pkgs.notifycmd;
      description = "Command accepting a desktop-notification JSON argument.";
    };
  };

  config = lib.mkIf config.programs.ai-agents.enable (
    lib.mkMerge [
      (lib.mkIf cfg.enable {
        programs.ai-agents.hooks = {
          Stop = [ block ];
          Notification = map (matcher: block // { inherit matcher; }) [
            "permission_prompt"
            "elicitation_dialog|idle_prompt"
          ];
        };
      })
      (lib.mkIf cfg.mcp.enable {
        assertions = [
          {
            assertion = pkgs.stdenv.isDarwin;
            message = "The notification MCP server requires macOS.";
          }
        ];
        programs.ai-agents.mcp.servers.notify.command = lib.getExe pkgs.notify-mcp;
      })
    ]
  );
}

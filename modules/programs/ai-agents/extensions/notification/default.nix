{
  config,
  lib,
  pkgs,
  ...
}:
let
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
  options.programs.ai-agents.extensions.notification.enable =
    lib.mkEnableOption "AI agent desktop notifications";

  config =
    lib.mkIf
      (config.programs.ai-agents.enable && config.programs.ai-agents.extensions.notification.enable)
      {
        programs.ai-agents.hooks = {
          Stop = [ block ];
          Notification = map (matcher: block // { inherit matcher; }) [
            "permission_prompt"
            "elicitation_dialog|idle_prompt"
          ];
        };
      };
}

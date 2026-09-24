{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents.extensions.formatLint;
in
{
  options.programs.ai-agents.extensions.formatLint = {
    enable = lib.mkEnableOption "post-edit formatting and lint feedback";
    package = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
      default = pkgs.callPackage ./package.nix { };
      description = "Formatter and lint executable used by the post-edit hook.";
    };
  };

  config = lib.mkIf (config.programs.ai-agents.enable && cfg.enable) {
    programs.ai-agents.hooks.PostToolUse = [
      {
        hooks = [
          {
            type = "command";
            command = lib.getExe cfg.package;
            timeout = 130;
          }
        ];
      }
    ];
  };
}

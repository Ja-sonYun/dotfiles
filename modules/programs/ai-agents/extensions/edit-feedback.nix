{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.ai-agents.extensions;
  block = command: timeout: {
    hooks = [
      {
        type = "command";
        inherit command timeout;
      }
    ];
  };
in
{
  config = lib.mkIf config.programs.ai-agents.enable {
    programs.ai-agents.hooks =
      if cfg.rules.enable then
        lib.mapAttrs
          (event: timeout: [
            (block (
              cfg.rules.hookCommand
              + lib.optionalString (event == "PostToolUse" && cfg.formatLint.enable) (
                " "
                + lib.escapeShellArgs [
                  "--post-edit-command"
                  (lib.getExe cfg.formatLint.package)
                ]
              )
            ) timeout)
          ])
          {
            SessionStart = 5;
            PreToolUse = 40;
            PostToolUse = 160;
            SessionEnd = 3;
          }
      else
        lib.optionalAttrs cfg.formatLint.enable {
          PostToolUse = [ (block (lib.getExe cfg.formatLint.package) 130) ];
        };
  };
}

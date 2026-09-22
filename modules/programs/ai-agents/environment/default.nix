{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.ai-agents;
in
{
  options.programs.ai-agents.extraPath = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [ ];
    description = "Packages added to the PATH of every enabled AI agent.";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf config.programs.codex.enable {
        programs.codex.extraPath = cfg.extraPath;
      })

      (lib.mkIf config.programs.claude-code.enable {
        programs.claude-code.extraPath = cfg.extraPath;
      })

      (lib.mkIf config.programs.pi.enable {
        programs.pi.extraPath = cfg.extraPath;
      })
    ]
  );
}

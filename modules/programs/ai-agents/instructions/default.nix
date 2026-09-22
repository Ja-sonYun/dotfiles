{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.ai-agents;
in
{
  options.programs.ai-agents = {
    context = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
    };

    customInstructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Custom instructions shared by enabled AI agents.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf config.programs.codex.enable {
        programs.codex = lib.mkMerge [
          (lib.mkIf (cfg.context != null) {
            inherit (cfg) context;
          })
          (lib.mkIf (cfg.customInstructions != "") {
            customInstructions = lib.mkBefore cfg.customInstructions;
          })
        ];
      })

      (lib.mkIf config.programs.claude-code.enable {
        programs.claude-code = lib.mkMerge [
          (lib.mkIf (cfg.context != null) {
            inherit (cfg) context;
          })
          (lib.mkIf (cfg.customInstructions != "") {
            customInstructions = lib.mkBefore cfg.customInstructions;
          })
        ];
      })

      (lib.mkIf config.programs.pi.enable {
        programs.pi = lib.mkMerge [
          (lib.mkIf (cfg.context != null) {
            inherit (cfg) context;
          })
          (lib.mkIf (cfg.customInstructions != "") {
            customInstructions = lib.mkBefore cfg.customInstructions;
          })
        ];
      })
    ]
  );
}

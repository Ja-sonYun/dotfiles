{
  lib,
  ...
}:
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
}

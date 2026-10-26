{
  lib,
  ...
}:
{
  options.programs.ai-agents.extraPath = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [ ];
    description = "Packages on every AI agent's PATH.";
  };
}

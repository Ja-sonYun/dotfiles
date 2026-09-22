{ lib, ... }:
{
  options.programs.ai-agents.enable = lib.mkEnableOption "shared AI agent configuration";
}

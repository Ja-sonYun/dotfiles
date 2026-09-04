{ pkgs, ... }:
{
  hooks = import ./extensions/hooks { inherit pkgs; };
  mcp-adapter = import ./extensions/mcp-adapter { inherit pkgs; };
  providers = import ./extensions/providers { inherit pkgs; };
  subagent = import ./extensions/subagent { inherit pkgs; };
}

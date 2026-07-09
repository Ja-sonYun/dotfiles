{ pkgs, ... }:
{
  mcp-adapter = import ./extensions/mcp-adapter { inherit pkgs; };
  permission-system = import ./extensions/permission-system { inherit pkgs; };
  lmp = import ./extensions/lmp { inherit pkgs; };
  hooks = import ./extensions/hooks { inherit pkgs; };
}

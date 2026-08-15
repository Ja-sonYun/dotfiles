{ pkgs, ... }:
{
  providers = import ./extensions/providers { inherit pkgs; };
}

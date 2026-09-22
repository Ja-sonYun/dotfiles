{ pkgs, dream2nix, ... }:
{
  mkDreamPackage = import ./dream2nix { inherit pkgs dream2nix; };
}

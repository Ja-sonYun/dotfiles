{ pkgs, ... }:

pkgs.python312.asPackage {
  root = ./.;
}

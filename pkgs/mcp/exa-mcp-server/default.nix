{ pkgs, ... }:

pkgs.nodejs_22.asPackage {
  root = ./.;
}

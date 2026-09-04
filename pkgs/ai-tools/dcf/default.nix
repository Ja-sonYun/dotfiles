{ pkgs, ... }:

let
  knip = pkgs.callPackage ./knip { };
in
pkgs.writeShellApplication {
  name = "dcf";
  runtimeInputs = [
    knip
    pkgs.cargo-shear
    pkgs.deadnix
    pkgs.deptry
    pkgs.go-tools
    pkgs.git
    pkgs.python3Packages.vulture
  ];
  text = builtins.readFile ./dcf.sh;
}

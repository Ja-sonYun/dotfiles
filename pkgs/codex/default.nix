{ pkgs, ... }:
let
  outputHash = pkgs.hashfile."codex";
in

pkgs.lib.npm.mkNpmGlobalPackageDerivation {
  inherit pkgs outputHash;
  name = "openai-codex";
  packages = [
    "@openai/codex@0.89.0"
  ];
  exposedBinaries = [
    "codex"
  ];
}

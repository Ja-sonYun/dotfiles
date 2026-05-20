{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "codex";
  packageManager = "npm";
  packageName = "@openai/codex";
  packageVersion = "0.132.0";
  name = "codex";
  exposedBinaries = [
    "codex"
  ];
}

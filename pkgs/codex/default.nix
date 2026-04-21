{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "codex";
  packageManager = "npm";
  packageName = "@openai/codex";
  packageVersion = "0.122.0";
  name = "codex";
  exposedBinaries = [
    "codex"
  ];
}

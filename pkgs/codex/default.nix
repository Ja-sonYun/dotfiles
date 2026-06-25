{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "codex";
  packageManager = "npm";
  packageName = "@openai/codex";
  packageVersion = "0.142.1";
  name = "codex";
  exposedBinaries = [
    "codex"
  ];
}

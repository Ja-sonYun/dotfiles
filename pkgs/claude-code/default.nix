{ pkgs, ... }:

let
  packageVersion = "2.1.173";
  nativePackage = {
    aarch64-darwin = "@anthropic-ai/claude-code-darwin-arm64";
    x86_64-darwin = "@anthropic-ai/claude-code-darwin-x64";
    aarch64-linux = "@anthropic-ai/claude-code-linux-arm64";
    x86_64-linux = "@anthropic-ai/claude-code-linux-x64";
  }.${pkgs.stdenv.hostPlatform.system} or null;
in
pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "claude-code";
  packageManager = "npm";
  packageName = "@anthropic-ai/claude-code";
  inherit packageVersion;
  extraPackages = pkgs.lib.optionals (nativePackage != null) [
    "${nativePackage}@${packageVersion}"
  ];
  name = "claude-code";
  postInstall = ''
    makeWrapper "$(command -v node)" "$out/bin/claude" \
      --add-flags "$NODE_PATH/lib/node_modules/@anthropic-ai/claude-code/cli-wrapper.cjs" \
      --set DISABLE_BUG_COMMAND         1 \
      --set DISABLE_INSTALLATION_CHECKS 1 \
      --set DISABLE_AUTOUPDATER         1 \
      --set DISABLE_ERROR_REPORTING     1 \
      --set DISABLE_COST_WARNINGS       1 \
      --set DISABLE_TELEMETRY           1
  '';
}

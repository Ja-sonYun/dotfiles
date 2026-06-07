{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "claude-code";
  packageManager = "npm";
  packageName = "@anthropic-ai/claude-code";
  packageVersion = "2.1.168";
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

{
  pkgs,
  extraPackages ? [ ],
  extraPath ? [ ],
  ...
}:

let
  packageVersion = "2.1.211";
  nativePackage =
    {
      aarch64-darwin = "@anthropic-ai/claude-code-darwin-arm64";
      x86_64-darwin = "@anthropic-ai/claude-code-darwin-x64";
      aarch64-linux = "@anthropic-ai/claude-code-linux-arm64";
      x86_64-linux = "@anthropic-ai/claude-code-linux-x64";
    }
    .${pkgs.stdenv.hostPlatform.system} or null;
in
pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "claude-code";
  packageManager = "npm";
  packageName = "@anthropic-ai/claude-code";
  inherit packageVersion;
  extraPackages =
    pkgs.lib.optionals (nativePackage != null) [
      "${nativePackage}@${packageVersion}"
    ]
    ++ extraPackages;
  name = "claude-code";
  postInstall = ''
    makeWrapper "$(command -v node)" "$out/bin/claude" \
      --add-flags "$NODE_PATH/lib/node_modules/@anthropic-ai/claude-code/cli-wrapper.cjs" \
      --set DISABLE_BUG_COMMAND              1 \
      --set DISABLE_INSTALLATION_CHECKS      1 \
      --set DISABLE_AUTOUPDATER              1 \
      --set CLAUDE_CODE_DISABLE_MOUSE_CLICKS 1 \
      --set DISABLE_ERROR_REPORTING          1 \
      ${pkgs.lib.optionalString (extraPath != [ ]) "--prefix PATH : ${pkgs.lib.makeBinPath extraPath}"}
  '';
}

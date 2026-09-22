{
  config,
  lib,
  packageManifest,
  system,
  ...
}:
let
  nativePackage =
    {
      aarch64-darwin = "@anthropic-ai/claude-code-darwin-arm64";
      x86_64-linux = "@anthropic-ai/claude-code-linux-x64";
    }
    .${system};
in
{
  nodejs-package-json.packageJson = lib.mkForce (
    packageManifest
    // {
      dependencies = packageManifest.dependencies // {
        ${nativePackage} = config.version;
      };
    }
  );
}

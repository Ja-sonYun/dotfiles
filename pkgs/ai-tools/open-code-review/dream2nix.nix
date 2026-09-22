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
      aarch64-darwin = "@alibaba-group/ocr-darwin-arm64";
      x86_64-linux = "@alibaba-group/ocr-linux-x64";
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
  mkDerivation.postInstall = ''
    wrapProgram "$out/bin/ocr" --set OCR_NO_UPDATE 1
  '';
}

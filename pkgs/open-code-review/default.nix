{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "open-code-review";
  packageManager = "npm";
  packageName = "@alibaba-group/open-code-review";
  packageVersion = "1.7.14";
  name = "open-code-review";
  exposedBinaries = [ ];
  buildInputs = [
    pkgs.cacert
  ];
  postInstall = ''
    node "$NODE_PATH/lib/node_modules/@alibaba-group/open-code-review/scripts/install.js"
    makeWrapper "$NODE_PATH/bin/ocr" "$out/bin/ocr" \
      --set OCR_NO_UPDATE 1
  '';
}

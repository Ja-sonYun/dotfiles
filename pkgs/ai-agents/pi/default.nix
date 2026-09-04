{
  pkgs,
  extraPath ? [ ],
  extraPythonPath ? "",
  ...
}:

let
  inherit (pkgs) lib;

  wrapperArgs = lib.concatStringsSep " \\\n      " (
    lib.optional (extraPath != [ ]) ''--prefix PATH : "${lib.makeBinPath extraPath}"''
    ++ lib.optional (extraPythonPath != "") ''--prefix PYTHONPATH : "${extraPythonPath}"''
  );

  piRoot = "$NODE_PATH/lib/node_modules/@earendil-works/pi-coding-agent";
in
pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "pi";
  packageManager = "npm";
  packageName = "@earendil-works/pi-coding-agent";
  packageVersion = "0.85.0";
  nodeVersion = "22.23.2";
  name = "pi";
  exposedBinaries = [
    "pi"
  ];
  postInstall = ''
    for patchFile in ${./patches}/*.patch; do
      ${pkgs.patch}/bin/patch --batch --fuzz=0 -p1 -d "${piRoot}" < "$patchFile"
    done

    rm -f $out/bin/pi
    makeWrapper "${piRoot}/dist/cli.js" "$out/bin/pi" \
      ${wrapperArgs}
  '';
}

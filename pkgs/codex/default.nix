{
  pkgs,
  extraPath ? [ ],
  extraPythonPath ? "",
  ...
}:

let
  wrapperArgs = pkgs.lib.concatStringsSep " \\\n      " (
    pkgs.lib.optional (extraPath != [ ]) ''--prefix PATH : "${pkgs.lib.makeBinPath extraPath}"''
    ++ pkgs.lib.optional (extraPythonPath != "") ''--prefix PYTHONPATH : "${extraPythonPath}"''
  );
in
pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "codex";
  packageManager = "npm";
  packageName = "@openai/codex";
  packageVersion = "0.144.1";
  name = "codex";
  exposedBinaries = [
    "codex"
  ];
  postInstall = pkgs.lib.optionalString (extraPath != [ ] || extraPythonPath != "") ''
    rm -f $out/bin/codex
    makeWrapper "$NODE_PATH/bin/codex" "$out/bin/codex" \
      ${wrapperArgs}
  '';
}

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

in
(pkgs.nodejs_22.asPackage {
  root = ./.;
}).overrideAttrs
  (old: {
    postInstall = old.postInstall + ''
      chmod -R u+w "$appRoot"
      for patchFile in ${./patches}/*.patch; do
        ${pkgs.patch}/bin/patch --batch --fuzz=0 -p1 -d "$appRoot" < "$patchFile"
      done

      rm -f "$out/bin/pi"
      makeWrapper "${pkgs.nodejs_22}/bin/node" "$out/bin/pi" \
        --add-flags "$appRoot/dist/cli.js" ${wrapperArgs}
    '';
  })

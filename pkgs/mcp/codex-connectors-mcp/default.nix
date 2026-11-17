{ pkgs, ... }:

(pkgs.nodejs_22.asPackage {
  root = ./.;
}).overrideAttrs
  (old: {
    postInstall = (old.postInstall or "") + ''
      chmod u+w "$appRoot/dist" "$appRoot/dist/server.js"
      ${pkgs.patch}/bin/patch --directory="$appRoot" --batch --forward --fuzz=0 \
        -p1 < ${./write-approval.patch}
    '';
  })

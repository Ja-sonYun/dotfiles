{
  gh,
  lib,
  python3,
  stdenvNoCC,
}:
let
  python = python3.withPackages (packages: [ packages.graphql-core ]);
in
stdenvNoCC.mkDerivation {
  pname = "gh-ro";
  version = "0";
  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    substitute ${./gh_ro.py} "$out/bin/gh-ro" \
      --replace-fail '@GH_PATH@' '${gh}/bin/gh' \
      --replace-fail '@PYTHON_PATH@' '${python}/bin/python'
    chmod +x "$out/bin/gh-ro"

    runHook postInstall
  '';

  meta = {
    description = "Run GitHub CLI operations classified as read-only";
    mainProgram = "gh-ro";
    inherit (gh.meta) homepage license platforms;
  };
}

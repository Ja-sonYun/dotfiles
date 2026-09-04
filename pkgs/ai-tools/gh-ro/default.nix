{
  gh,
  lib,
  uv,
}:
let
  package = uv.asPackage {
    name = "gh-ro";
    root = ./.;
    entrypoint = "gh_ro:main";
    runtimeInputs = [ gh ];
  };
in
package.overrideAttrs {
  meta = {
    description = "Run GitHub CLI operations classified as read-only";
    mainProgram = "gh-ro";
    inherit (gh.meta) homepage license platforms;
  };
}

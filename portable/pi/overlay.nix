{ dream2nix }:
final: _prev:
let
  defaults = import ./config { pkgs = final; };
  resources = import ./nix/resources.nix { pkgs = final; };
  runtime = import ./nix/runtime.nix {
    pkgs = final;
    inherit dream2nix;
  };
  configure = import ./nix/configured.nix { pkgs = final; };
  evaluator = final.callPackage ./extensions/permissions/evaluator { };
in
{
  pi-runtime = runtime;
  pi-resources = resources;
  pi-configure = configure;
  pi = configure {
    runtime = runtime.override { inherit (defaults) extraPath; };
    inherit (defaults) settings;
    bundle = resources;
  };
  pi-extensions = {
    permissions.evaluator = evaluator;
  };
}

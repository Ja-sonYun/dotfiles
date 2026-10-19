{
  root,
  package,
  candidate,
  system,
  hashOnly ? false,
}:
let
  lock = builtins.fromJSON (builtins.readFile (root + "/flake.lock"));
  inputs = lock.nodes.${lock.root}.inputs;
  nixpkgs = builtins.fetchTree lock.nodes.${inputs.nixpkgs}.locked;
  dreamSource = builtins.fetchTree lock.nodes.${inputs.dream2nix}.locked;
  dream2nix = builtins.getFlake (builtins.unsafeDiscardStringContext "path:${dreamSource.outPath}");
  pkgs = import nixpkgs.outPath { inherit system; };
  runtime = (import (/. + package + "/nix/runtime.nix") { inherit pkgs dream2nix; }).override {
    spec = builtins.fromJSON (builtins.readFile (candidate + "/package-spec.json"));
    projectRoot = /. + candidate;
    packagePath = ".";
  };
in
if hashOnly then runtime.lockInvalidationHash else runtime.lock

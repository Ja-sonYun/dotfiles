{
  root,
  package,
  candidate,
  system,
}:
let
  lock = builtins.fromJSON (builtins.readFile (root + "/flake.lock"));
  inputs = lock.nodes.${lock.root}.inputs;
  nixpkgs = builtins.fetchTree lock.nodes.${inputs.nixpkgs}.locked;
  dreamSource = builtins.fetchTree lock.nodes.${inputs.dream2nix}.locked;
  dream2nix = builtins.getFlake (builtins.unsafeDiscardStringContext "path:${dreamSource.outPath}");
  pkgs = import nixpkgs.outPath { inherit system; };
  mkDreamPackage = import ./default.nix { inherit pkgs dream2nix; };
in
((mkDreamPackage (/. + package)).override {
  spec = builtins.fromJSON (builtins.readFile (candidate + "/package-spec.json"));
  projectRoot = /. + candidate;
  packagePath = ".";
}).lock

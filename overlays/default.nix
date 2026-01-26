{ inputs, hostname, ... }:
(import ./stable.nix { inherit inputs; })
// (import ./lib.nix)
// (import ./inputs.nix { inherit inputs; })
// (import ./patches.nix)
  // (import ./custom.nix { inherit hostname; })

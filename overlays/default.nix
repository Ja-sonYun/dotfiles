{ inputs, ... }:
(import ./stable.nix { inherit inputs; })
// (import ./lib.nix { inherit inputs; })
// (import ./inputs.nix { inherit inputs; })
// (import ./patches.nix { inherit inputs; })
// (import ./test-ignores.nix)
// (import ./custom.nix)

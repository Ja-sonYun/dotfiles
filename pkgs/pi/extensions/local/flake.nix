{
  description = "Dev shell for authoring local pi extensions";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        builtins.listToAttrs (
          map (system: {
            name = system;
            value = f system;
          }) systems
        );
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            name = "pi-ext-devshell";
            buildInputs = [
              pkgs.nodejs_22
              pkgs.typescript
            ];
            shellHook = ''
              root="$(git rev-parse --show-toplevel)/pkgs/pi/extensions/local"
              ( cd "$root" && [ -f package.json ] && npm install --ignore-scripts --no-audit --no-fund ) || true
              mkdir -p ~/.pi/agent/extensions
              for d in "$root"/*/; do
                name="$(basename "$d")"
                [ -f "$d/index.ts" ] || continue
                [ -f "$d/package.json" ] && ( cd "$d" && npm install --ignore-scripts --no-audit --no-fund ) || true
                ln -sfn "$d" ~/.pi/agent/extensions/"$name"
              done
              echo "pi-ext: linked local extensions -> ~/.pi/agent/extensions (edit + /reload-runtime in pi)"
            '';
          };
        }
      );
    };
}

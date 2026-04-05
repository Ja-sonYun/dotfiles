{
  description = "A Nix-flake-based AWS Node20 Python310 development environment";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = nixpkgs.lib.systems.flakeExposed;
      forEachSystem =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs {
              inherit system;
              config = {
                allowUnfree = true;
              };
            };
          }
        );
    in
    {
      devShells = forEachSystem (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              python310

              # Packages manager
              (poetry.withPlugins (
                ps: with ps; [
                  poetry-plugin-export
                ]
              ))
              uv
              rye

              nodejs_20
              pnpm
              yarn

              awscli2
            ];
            shellHook = ''
              # Load environment variables from .env if present.
              set -a
              if [ -f ".env" ]; then
                source .env
              fi
              set +a

              if [ ! -d "$UV_PROJECT_ENVIRONMENT" ]; then
                uv venv "$UV_PROJECT_ENVIRONMENT" --python "$UV_PYTHON"
              fi

              source "$UV_PROJECT_ENVIRONMENT/bin/activate"
            '';
            env = {
              UV_PROJECT_ENVIRONMENT = ".venv";
              UV_PYTHON = "${pkgs.python310}/bin/python3";
              UV_NO_SYNC = "1";
              UV_PYTHON_DOWNLOADS = "never";
            };
          };
        }
      );
    };
}

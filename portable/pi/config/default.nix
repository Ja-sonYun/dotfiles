{ pkgs }:
let
  defaults = builtins.fromJSON (builtins.readFile ./defaults.json);
in
{
  inherit (defaults) settings;

  extraPath = with pkgs; [
    nodejs_24

    uv
    ruff
    mypy
    pyright

    cargo
    rustc
    clippy
    rustfmt
    rust-analyzer
    clang-tools
    go
    golangci-lint

    shellcheck
    shfmt
    prettier
    typescript
    eslint

    taplo
    stylua
    sqlfluff
    google-java-format
    ktfmt
    rubyfmt

    nixfmt
    statix

    terraform
  ];
}

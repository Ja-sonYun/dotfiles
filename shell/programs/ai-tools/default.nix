{ pkgs, ... }:
{
  imports = [
    ./hooks.nix
    ./tool-guard.nix
  ];

  home.packages = with pkgs; [
    aws-ro
    gh-ro
  ];

  programs.ai-agents.extraPath = with pkgs; [
    aws-ro
    gh-ro
    dcf

    uv
    ruff
    mypy
    pyright

    rustfmt
    rust-analyzer
    clang-tools
    golangci-lint

    shellcheck
    shfmt
    prettier
    typescript
    eslint

    nixfmt
    statix

    terraform
  ];
}

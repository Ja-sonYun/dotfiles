{ pkgs, ... }:
{
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

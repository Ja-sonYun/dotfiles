{ pkgs, ... }:
{
  home.packages = with pkgs; [
    aws-ro
    gh-ro
    jev
    redact
  ];

  programs.ai-agents.extraPath = with pkgs; [
    aws-ro
    gh-ro
    jev
    redact
    dcf

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

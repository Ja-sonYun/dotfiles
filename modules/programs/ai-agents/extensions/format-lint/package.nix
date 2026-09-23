{
  callPackage,
  python3,
  writeShellApplication,
  ruff,
  prettier,
  eslint,
  shfmt,
  shellcheck,
  nixfmt,
  statix,
  terraform,
  go,
  clang-tools,
  google-java-format,
  ktfmt,
  rubyfmt,
  taplo,
  stylua,
  sqlfluff,
  rustfmt,
}:
let
  hookLibrary = callPackage ../../hooks/runtime { };
  python = python3.withPackages (_: [ hookLibrary ]);
in
writeShellApplication {
  name = "ai-agent-format-lint";
  runtimeInputs = [
    ruff
    prettier
    eslint
    shfmt
    shellcheck
    nixfmt
    statix
    terraform
    go
    clang-tools
    google-java-format
    ktfmt
    rubyfmt
    taplo
    stylua
    sqlfluff
    rustfmt
  ];
  text = ''
    exec ${python}/bin/python ${./format_lint.py} "$@"
  '';
}

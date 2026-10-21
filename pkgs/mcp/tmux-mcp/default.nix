{
  lib,
  redact,
  tmux,
  uv,
}:
(uv.asPackage {
  name = "tmux-mcp";
  root = ./.;
  entrypoint = "tmux_mcp.cli:main";
  runtimeInputs = [
    tmux
    redact
  ];
}).overrideAttrs
  {
    meta = {
      description = "Query selected tmux panes with redacted output and restricted key input";
      mainProgram = "tmux-mcp";
      platforms = lib.platforms.unix;
    };
  }

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.claude-code.statusLine;
  renderer = pkgs.callPackage ./package.nix { };
  command = pkgs.writeShellScript "claude-statusline" ''
    input="$(${pkgs.coreutils}/bin/cat)"
    ${lib.concatMapStringsSep "\n" (observer: ''
      printf '%s' "$input" | ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg observer} >/dev/null || true
    '') (builtins.attrValues cfg.observers)}
    ${lib.optionalString cfg.enable ''
      printf '%s' "$input" | ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg cfg.command}
    ''}
  '';
in
{
  options.programs.claude-code.statusLine = {
    enable = lib.mkEnableOption "Claude Code status line rendering";
    command = lib.mkOption {
      type = lib.types.str;
      default = lib.getExe renderer;
      description = "Renderer receiving the status line JSON on stdin.";
    };
    observers = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Commands receiving the status line JSON before rendering.";
    };
  };

  config = lib.mkIf (config.programs.claude-code.enable && (cfg.enable || cfg.observers != { })) {
    programs.claude-code.settings.statusLine = {
      type = "command";
      command = toString command;
    };
  };
}

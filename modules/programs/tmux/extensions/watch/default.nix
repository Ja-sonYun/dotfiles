{
  lib,
  ...
}:
let
  scripts = "${../..}/extensions/watch/scripts";
in
{
  options.programs.tmux.extensions.watch = {
    enable = lib.mkEnableOption "tmux pane notifications";
    scripts = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      default = scripts;
    };
    statusSegment = lib.mkOption {
      type = lib.types.lines;
      readOnly = true;
      internal = true;
      default = ''
        source "${scripts}/runtime.sh" || exit 1
        shopt -s nullglob
        watchers=("$NOTIFY_DIR"/*.info)
        [ "''${#watchers[@]}" -gt 0 ] && printf '#[fg=black,bg=yellow,bold] w:%s #[default] - ' "''${#watchers[@]}"
      '';
    };
  };
}

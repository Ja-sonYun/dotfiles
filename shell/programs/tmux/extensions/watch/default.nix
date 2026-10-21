{
  config,
  lib,
  ...
}:
let
  scripts = config.programs.tmux.extensions.watch.scripts;
in
lib.mkIf config.programs.tmux.extensions.watch.enable {
  programs.tmux.bindings = {
    l.command = ''run-shell -b "${scripts}/notify-watch.sh #{pane_id} #{q:client_name}"'';
    "C-l".command = ''run-shell -b "${scripts}/notify-cancel.sh #{pane_id} #{q:client_name}"'';
  };

  programs.tmux-customize = {
    segments.watch = config.programs.tmux.extensions.watch.statusSegment;

    groups = {
      normal.status.right = lib.mkBefore [ "watch" ];
    };
  };
}

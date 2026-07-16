{
  lib,
  pkgs,
  ...
}:
let
  tmuxRoot = ../..;
  scripts = "${tmuxRoot}/extensions/watch/scripts";
in
lib.mkIf pkgs.stdenv.isDarwin {
  programs.tmux.bindings = {
    l.command = "run-shell -b ${scripts}/notify-watch.sh";
    "C-l".command = "run-shell -b ${scripts}/notify-cancel.sh";
  };

  programs.tmux-customize = {
    segments.watch = ''
      now=$(date +%s)
      last=$(tmux show-option -gqv @notify_watch_cleanup)
      if [ -z "$last" ] || [ "$((now - last))" -ge 3600 ]; then
        tmux set-option -g @notify_watch_cleanup "$now"
        "${scripts}/notify-cancel.sh" --orphans-only
      fi
      shopt -s nullglob
      watchers=(/tmp/tmux-notify/*.info)
      [ "''${#watchers[@]}" -gt 0 ] && printf '#[fg=black,bg=yellow,bold] w:%s #[default] - ' "''${#watchers[@]}"
    '';

    groups = {
      normal.status.right = lib.mkBefore [ "watch" ];
    };
  };
}

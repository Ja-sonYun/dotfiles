{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.tmux.extensions.popup;
  tmuxRoot = config.programs.tmux.runtime;
  popupScript = pkgs.writeShellScript "tmux-popup" ''
    ${config.programs.tmux.loggingShell}
    TMUX_LOG_COMPONENT=tmux.popup.toggle
    tmux_log info toggle_requested
    main_session=${lib.escapeShellArg cfg.mainSession}
    client="''${1:-$(tmux display-message -p '#{client_name}')}"
    if [ -n "$(tmux display-message -p '#{E:MAIN_POPUP}')" ]; then
      if tmux list-clients -t "$main_session" -F '#{client_name}' 2>/dev/null | grep -q .; then
        tmux_log_run detach-client -t "$client"
      else
        tmux_log_run switch-client -c "$client" -t "$main_session"
      fi
    else
      outer="$client"
      if tmux list-clients -t popup -F '#{client_name}' 2>/dev/null | grep -q .; then
        tmux display-message "popup is already open on another client"
        exit 0
      fi
      tmux set -g @popup_client_popup "$outer"
      tmux set -g @popup_default_geom_popup "C C ${cfg.defaultWidth} ${cfg.defaultHeight}"
      # Reuse the geometry saved by scripts/popup/move ("x y w h" in
      # cells) so a moved/resized popup keeps its place across close/open.
      geom="$(tmux show-options -gqv @popup_geom_popup)"
      # popup-move closes this popup with SIGHUP; only its 129 status is expected.
      if [ -n "$geom" ]; then
        set -- $geom
        tmux_log_run popup -c "$outer" -e POPUP=1 -x "$1" -y "$2" -w "$3" -h "$4" -E "tmux attach -t popup || tmux new -s popup -e MAIN_POPUP=1 -e DEFAULT=1" || [ "$?" -eq 129 ]
      else
        tmux_log_run popup -c "$outer" -e POPUP=1 -w ${lib.escapeShellArg cfg.defaultWidth} -h ${lib.escapeShellArg cfg.defaultHeight} -E "tmux attach -t popup || tmux new -s popup -e MAIN_POPUP=1 -e DEFAULT=1" || [ "$?" -eq 129 ]
      fi
    fi
  '';

  swapScript = pkgs.writeShellScript "tmux-popup-swap" ''
    source "${tmuxRoot}/scripts/lib/common"
    TMUX_LOG_COMPONENT=tmux.popup.swap
    if ! tmux_lock __popup_swap_lock 2; then
      tmux display-message "popup swap: busy"
      tmux_log warning busy
      exit 0
    fi
    main_session=${lib.escapeShellArg cfg.mainSession}
    client="$1"
    if ! tmux has-session -t "$main_session" 2>/dev/null || ! tmux has-session -t popup 2>/dev/null ||
      tmux has-session -t _temp_current 2>/dev/null || tmux has-session -t _temp_popup 2>/dev/null; then
      tmux display-message "popup swap is unavailable"
      exit 0
    fi
    if tmux list-clients -t popup -F '#{client_name}' 2>/dev/null | grep -q .; then
      tmux display-message "popup swap is unavailable while popup is open"
      exit 0
    fi
    tmux_log info swap_requested "client=$client"
    tmux_log_run rename-session -t "$main_session" _temp_current \; \
      rename-session -t popup _temp_popup \; \
      rename-session -t _temp_current popup \; \
      rename-session -t _temp_popup "$main_session" \; \
      set-environment -t "$main_session" -u MAIN_POPUP \; \
      set-environment -t "$main_session" MAIN 1 \; \
      set-environment -t popup -u MAIN \; \
      set-environment -t popup MAIN_POPUP 1 \; \
      switch-client -c "$client" -t "$main_session"
    result=$?
    if [ "$result" -eq 0 ]; then
      tmux_log info swapped "client=$client"
    fi
    exit "$result"
  '';
in
{
  options.programs.tmux.extensions.popup = {
    enable = lib.mkEnableOption "tmux popup sessions";
    mainSession = lib.mkOption {
      type = lib.types.str;
      default = "main";
    };
    defaultWidth = lib.mkOption {
      type = lib.types.str;
      default = "75%";
    };
    defaultHeight = lib.mkOption {
      type = lib.types.str;
      default = "70%";
    };
    scripts = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      default = "${tmuxRoot}/extensions/popup/scripts";
    };
    toggleCommand = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      default = popupScript;
    };
    swapCommand = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      default = swapScript;
    };
  };
  config = lib.mkIf cfg.enable {
    programs.tmux.setGlobalOptions = {
      "@popup_default_width" = lib.escapeShellArg cfg.defaultWidth;
      "@popup_default_height" = lib.escapeShellArg cfg.defaultHeight;
    };
  };
}

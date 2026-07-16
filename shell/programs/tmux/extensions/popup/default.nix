{
  lib,
  pkgs,
  ...
}:
let
  tmuxRoot = ../..;
  scripts = "${tmuxRoot}/extensions/popup/scripts";
  sharedRootBindings = import ../../shared-root.nix;

  popupScript = pkgs.writeShellScript "tmux-popup" ''
    if tmux show-environment MAIN_POPUP >/dev/null 2>&1; then
      if tmux list-sessions | grep '^main:' | grep -q '(attached)'; then
        tmux detach-client
      else
        tmux switch-client -t main
      fi
    else
      # Record which client the popup is drawn on so the popup-move script
      # (prefix+m inside the popup) can close/reopen it on the right terminal.
      tmux set -g @popup_client "$(tmux display-message -p '#{client_name}')"
      tmux set -g @popup_default_geom_popup "C C 75% 70%"
      # Reuse the geometry saved by scripts/popup/move ("x y w h" in
      # cells) so a moved/resized popup keeps its place across close/open.
      geom="$(tmux show-options -gqv @popup_geom_popup)"
      # popup-move closes this popup with SIGHUP; only its 129 status is expected.
      if [ -n "$geom" ]; then
        set -- $geom
        tmux popup -e POPUP=1 -x "$1" -y "$2" -w "$3" -h "$4" -E "tmux attach -t popup || tmux new -s popup -e MAIN_POPUP=1 -e DEFAULT=1" || [ "$?" -eq 129 ]
      else
        tmux popup -e POPUP=1 -w75% -h70% -E "tmux attach -t popup || tmux new -s popup -e MAIN_POPUP=1 -e DEFAULT=1" || [ "$?" -eq 129 ]
      fi
    fi
  '';

  swapScript = ''
    tmux rename-session -t main _temp_current
    tmux rename-session -t popup _temp_popup
    tmux rename-session -t _temp_current popup
    tmux rename-session -t _temp_popup main
    tmux set-environment -t main -u MAIN_POPUP
    tmux set-environment -t main MAIN 1
    tmux set-environment -t popup -u MAIN
    tmux set-environment -t popup MAIN_POPUP 1
    tmux switch-client -t main
  '';

  popupRootMatch = ''table="$(tmux show-options -qv key-table)"; test "$table" = popup-root || test "$table" = popup-locked-root'';
  popupLockedRootMatch = ''test "$(tmux show-options -qv key-table)" = popup-locked-root'';
in
{
  programs.tmux = {
    bindings = {
      C-c = {
        noDefault = true;
        cases = [
          {
            whenEnv = [ "CTRL_C_AS_CLOSE" ];
            command = "send-keys C-c";
          }
        ];
      };
      w.cases = [
        {
          match = popupRootMatch;
          command = "detach";
        }
      ];
      s.cases = [
        {
          match = popupRootMatch;
          command = "detach";
        }
      ];
      c.cases = [
        {
          match = popupLockedRootMatch;
          command = "detach";
        }
      ];
      n.cases = [
        {
          match = popupLockedRootMatch;
          unlessEnv = [ "TMUX_AGENT_STATUS" ];
          command = "detach";
        }
      ];
      C-n = {
        repeat = true;
        cases = [
          {
            match = popupLockedRootMatch;
            unlessEnv = [ "TMUX_AGENT_STATUS" ];
            command = "detach";
          }
          { command = "next-window"; }
        ];
      };
      p.cases = [
        {
          match = popupLockedRootMatch;
          unlessEnv = [ "TMUX_AGENT_STATUS" ];
          command = "detach";
        }
      ];
      C-p = {
        repeat = true;
        cases = [
          {
            match = popupLockedRootMatch;
            unlessEnv = [ "TMUX_AGENT_STATUS" ];
            command = "detach";
          }
          { command = "previous-window"; }
        ];
      };
      "%".cases = [
        {
          match = popupLockedRootMatch;
          command = "detach";
        }
      ];
      menuQuote = {
        key = "'\"'";
        cases = [
          {
            match = popupLockedRootMatch;
            command = "detach";
          }
        ];
      };
      "!".cases = [
        {
          match = popupLockedRootMatch;
          command = "detach";
        }
      ];
      M = {
        noDefault = true;
        cases = [
          {
            whenEnv = [ "MAIN_POPUP" ];
            command = ''run-shell -b "${scripts}/move reset '#{session_name}'"'';
          }
          {
            match = popupRootMatch;
            command = ''run-shell -b "${scripts}/move reset '#{session_name}'"'';
          }
        ];
      };
      f.cases = [
        {
          unlessEnv = [ "MAIN" ];
          command = "detach";
        }
        { command = "run-shell -b ${popupScript}"; }
      ];
      "C-f".cases = [
        {
          unlessEnv = [ "MAIN" ];
          command = "detach";
        }
        { command = "run-shell -b ${popupScript}"; }
      ];
      "C-r".cases = [
        {
          unlessEnv = [ "MAIN" ];
          command = "detach";
        }
        { script = swapScript; }
      ];
      d = {
        noDefault = true;
        cases = [
          {
            unlessEnv = [ "DEFAULT" ];
            command = "detach";
          }
        ];
      };
      m.cases = [
        {
          whenEnv = [ "MAIN_POPUP" ];
          command = "switch-client -T popupmove";
        }
        {
          match = popupRootMatch;
          command = "switch-client -T popupmove";
        }
      ];
    };

    keyTables = {
      popup-root = sharedRootBindings;
      popup-locked-root = sharedRootBindings;
      popupmove = {
        h.command = ''run-shell -b "${scripts}/move -5 0 0 0 '#{session_name}'"'';
        l.command = ''run-shell -b "${scripts}/move 5 0 0 0 '#{session_name}'"'';
        j.command = ''run-shell -b "${scripts}/move 0 2 0 0 '#{session_name}'"'';
        k.command = ''run-shell -b "${scripts}/move 0 -2 0 0 '#{session_name}'"'';
        H.command = ''run-shell -b "${scripts}/move -5 0 5 0 '#{session_name}'"'';
        L.command = ''run-shell -b "${scripts}/move 5 0 -5 0 '#{session_name}'"'';
        J.command = ''run-shell -b "${scripts}/move 0 0 0 -2 '#{session_name}'"'';
        K.command = ''run-shell -b "${scripts}/move 0 0 0 2 '#{session_name}'"'';
      };
    };
  };

  programs.tmux-customize = {
    sessions.popup = {
      group = "normal";
      environment = {
        MAIN_POPUP = "1";
        DEFAULT = "1";
      };
    };
    launcher.startSessions = lib.mkBefore [ "popup" ];
  };
}

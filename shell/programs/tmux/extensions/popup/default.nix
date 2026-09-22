{
  lib,
  config,
  ...
}:
let
  popup = config.programs.tmux.extensions.popup;
  inherit (popup) scripts;
  sharedRootBindings = import ../../shared-root.nix;

  popupRootMatch = ''table="$(tmux show-options -qv key-table)"; test "$table" = popup-root || test "$table" = popup-locked-root'';
  popupLockedRootMatch = ''test "$(tmux show-options -qv key-table)" = popup-locked-root'';
in
lib.mkIf popup.enable {
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
          unlessEnv = [ "TMUX_POPUP_KEEP_OPEN" ];
          command = "detach";
        }
      ];
      C-n = {
        repeat = true;
        cases = [
          {
            match = popupLockedRootMatch;
            unlessEnv = [ "TMUX_POPUP_KEEP_OPEN" ];
            command = "detach";
          }
          { command = "next-window"; }
        ];
      };
      p.cases = [
        {
          match = popupLockedRootMatch;
          unlessEnv = [ "TMUX_POPUP_KEEP_OPEN" ];
          command = "detach";
        }
      ];
      C-p = {
        repeat = true;
        cases = [
          {
            match = popupLockedRootMatch;
            unlessEnv = [ "TMUX_POPUP_KEEP_OPEN" ];
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
        { command = "run-shell -b '${popup.toggleCommand} #{q:client_name}'"; }
      ];
      "C-f".cases = [
        {
          unlessEnv = [ "MAIN" ];
          command = "detach";
        }
        { command = "run-shell -b '${popup.toggleCommand} #{q:client_name}'"; }
      ];
      "C-r".cases = [
        {
          unlessEnv = [ "MAIN" ];
          command = "detach";
        }
        { command = "run-shell -b '${popup.swapCommand} #{q:client_name}'"; }
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

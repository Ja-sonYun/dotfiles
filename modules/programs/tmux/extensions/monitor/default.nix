{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.tmux.extensions.monitor;
  python = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.wcwidth ]);
  scripts = toString (
    pkgs.runCommand "tmux-monitor-scripts" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
      mkdir -p "$out"
      cp -R ${./scripts}/. "$out/"
      chmod -R u+w "$out"
      wrapProgram "$out/pane-monitor" --set PANE_MONITOR_PYTHON ${python}/bin/python
    ''
  );
  afterCreate = pkgs.writeShellScript "tmux-monitor-after-create" (
    lib.concatMapStringsSep "\n" (command: "${command} \"$1\"") cfg.afterCreateCommands
  );
in
{
  options.programs.tmux.extensions.monitor = {
    enable = lib.mkEnableOption "tmux pane monitoring";
    mainSession = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Session to monitor.";
    };
    scripts = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      default = scripts;
    };
    afterCreateCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Monitor startup commands receiving the active pane ID.";
    };
  };
  config = lib.mkIf cfg.enable {
    programs.tmux.hooks = {
      paneMonitorClientSessionChanged = {
        event = "client-session-changed";
        command = ''run-shell -b "${scripts}/pane-monitor follow"'';
      };
      paneMonitorWindowResized = {
        event = "window-resized";
        command = ''run-shell -b "${scripts}/pane-monitor resize #{hook_window}"'';
      };
      paneMonitorSessionWindowChanged = {
        event = "session-window-changed";
        command = ''run-shell -b -d 0.1 "${scripts}/pane-monitor follow #{hook_window}"'';
      };
      paneMonitorPaneExited = {
        event = "pane-exited";
        command = ''run-shell -b "${scripts}/pane-monitor cleanup #{hook_pane}"'';
      };
    };
    programs.tmux.setGlobalOptions = {
      "@pane_monitor_main_session" = lib.escapeShellArg cfg.mainSession;
      "@pane_monitor_after_create" = lib.escapeShellArg (toString afterCreate);
      "@pane_monitor_title_command" = lib.escapeShellArg (
        lib.optionalString config.programs.tmux.extensions.shell.enable "${config.programs.tmux.extensions.shell.scripts}/panes"
      );
    };
  };
}

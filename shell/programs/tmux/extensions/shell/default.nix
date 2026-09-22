{
  config,
  lib,
  ...
}:
{
  programs.tmux-menu = {
    menus.menu.items = lib.mkOrder 200 [
      {
        menu = {
          name = "shell";
          shortcut = "s";
          command =
            lib.optionalString config.programs.tmux.extensions.sessionCleanup.enable "_tmux-session-cleanup-register subshell && "
            + "/bin/zsh";
          session = true;
          sessionName = "subshell";
          keyTable = if config.programs.tmux.extensions.popup.enable then "popup-root" else "common-root";
          sessionOnDir = true;
          runOnRoot = ".root";
          runOnGitRoot = true;
          position = {
            w = "60%";
            h = "70%";
          };
        };
      }
    ];
  };

  programs.tmux-customize = {
    sessions.subshell.group = "shell";

    groups.shell = {
      status = {
        enable = true;
        position = "top";
        bg = "#FFFFFF";
        left = [ "space" ];
        right = [ ];
      };
      window = {
        format = "#{?#{@panes},#{@panes},#{pane_current_command}}";
        currentFormat = "#[fg=white]#[bg=green]▌#[default]#[bg=green]#{?#{@panes},#{@panes},#{pane_current_command}}#[default]#[fg=white]#[bg=green]▐#[default]";
      };
    };
  };
}

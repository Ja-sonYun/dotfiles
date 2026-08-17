{
  pkgs,
  ...
}:
{
  imports = [
    ./keybindings.nix
    ./sessions.nix
    ./status.nix
    ./tmuxmenu.nix
    ./extensions
  ];

  home.packages = [
    pkgs.pstree
  ];

  programs.tmux = {
    enable = true;

    setServerOptions = {
      escape-time = "30";
    };

    setGlobalOptions = {
      mouse = "off";
      renumber-windows = "on";
      history-limit = "50000";
      default-terminal = ''"tmux-256color"'';
      allow-passthrough = "on";
      set-clipboard = "on";
      focus-events = "on";
      pane-border-style = "'bg=default fg=color231'";
      pane-active-border-style = "'bg=default fg=color231'";
      copy-mode-line-numbers = "hybrid";
      copy-mode-line-number-style = "'fg=color244,bg=default'";
      copy-mode-current-line-number-style = "'fg=green,bg=default'";
      status-keys = "vi";
      status-interval = "10";
      status-left-length = "50";
      status-right-length = "120";
      status = "on";
    };

    setWindowOptions = {
      allow-set-title = "off";
      mode-keys = "vi";
      monitor-bell = "off";
    };

    extraConfig = ''
      set -gu terminal-features
      set -ga terminal-features ",xterm*:RGB"
      set-environment -g 'IGNOREEOF' 10
    '';
  };
}

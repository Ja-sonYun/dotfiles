_: {
  programs.tmux-customize = {
    sessions = {
      main = {
        group = "normal";
        environment = {
          MAIN = "1";
          DEFAULT = "1";
        };
        unicode = true;
      };
    };

    launcher = {
      enable = true;
      startSessions = [ "main" ];
      attach = "main";
    };
  };

}

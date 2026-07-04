_: {
  programs.navi = {
    enable = true;
    settings = {
      style = {
        tag = {
          color = "cyan";
          width_percentage = 26;
          min_width = 20;
        };
        comment = {
          color = "blue";
          width_percentage = 42;
          min_width = 45;
        };
        snippet.color = "white";
      };
      finder = {
        command = "fzf";
        overrides = "--height=40% --layout=reverse";
      };
      cheats.paths = [ (toString ./cheats) ];
      shell.command = "zsh";
    };
  };
}

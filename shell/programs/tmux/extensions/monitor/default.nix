{
  config,
  lib,
  ...
}:
let
  scripts = config.programs.tmux.extensions.monitor.scripts;
in
lib.mkIf config.programs.tmux.extensions.monitor.enable {
  programs.tmux-menu.menus = {
    menu.items = lib.mkOrder 500 [
      { separator = true; }
      {
        menu = {
          name = "pane monitor";
          shortcut = "m";
          nextMenu = "pane-monitor";
        };
      }
    ];

    pane-monitor = {
      title = "pane monitor";
      items = [
        {
          menu = {
            name = "monitor current pane globally";
            shortcut = "g";
            command = "${scripts}/pane-monitor add-global";
            background = true;
          };
        }
        {
          menu = {
            name = "monitor current pane locally";
            shortcut = "l";
            command = "${scripts}/pane-monitor add-local";
            background = true;
          };
        }
        { separator = true; }
        {
          menu = {
            name = "toggle global";
            shortcut = "t";
            command = "${scripts}/pane-monitor toggle-global";
            background = true;
          };
        }
        {
          menu = {
            name = "toggle local";
            shortcut = "T";
            command = "${scripts}/pane-monitor toggle-local";
            background = true;
          };
        }
        {
          menu = {
            name = "remove global";
            shortcut = "r";
            command = "${scripts}/pane-monitor remove-global";
            background = true;
          };
        }
        {
          menu = {
            name = "remove local";
            shortcut = "R";
            command = "${scripts}/pane-monitor remove-local";
            background = true;
          };
        }
        { separator = true; }
        {
          menu = {
            name = "set size";
            shortcut = "s";
            command = ''tmux command-prompt -p "width:","height:" "run-shell '${scripts}/pane-monitor size %1 %2'"'';
            background = true;
          };
        }
      ];
    };
  };

}

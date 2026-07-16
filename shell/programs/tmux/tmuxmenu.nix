{ lib, ... }:
{
  programs.tmux-menu = {
    enable = true;

    menus.menu = {
      title = " menu ";
      items = lib.mkMerge [
        (lib.mkOrder 100 [
          {
            menu = {
              name = "git";
              shortcut = "g";
              nextMenu = "git";
            };
          }
        ])
        (lib.mkOrder 300 [
          {
            menu = {
              name = "Navi";
              shortcut = "n";
              command = "navi --path=$CONFIG/navi --print | pbcopy";
              keyTable = "popup-root";
              position = {
                w = "40%";
                h = "55%";
              };
            };
          }
          {
            menu = {
              name = "taskwarrior";
              shortcut = "t";
              command = "cd ~/ && taskwarrior-tui";
              session = true;
              sessionName = "taskwarrior-tui";
              keyTable = "popup-locked-root";
              environment = {
                CTRL_C_AS_CLOSE = "1";
              };
              position = {
                w = "60%";
                h = "70%";
              };
            };
          }
        ])
      ];
    };

    menus.git = {
      title = " git ";
      items = [
        { noDim.name = "Folder #[fg=green]$(echo \${PWD##*/})"; }
        { noDim.name = "Branch #[fg=green]$(git rev-parse --abbrev-ref HEAD)"; }
        { separator = true; }
        {
          menu = {
            name = "tig";
            shortcut = "g";
            command = "_gen-close-hook tig && tig";
            session = true;
            sessionName = "tig";
            keyTable = "popup-locked-root";
            sessionOnDir = true;
            runOnGitRoot = true;
            position = {
              w = "140";
              h = "80";
            };
          };
        }
        {
          menu = {
            name = "gitui";
            shortcut = "u";
            command = "_gen-close-hook gitui && gitui";
            session = true;
            sessionName = "gitui";
            keyTable = "popup-locked-root";
            sessionOnDir = true;
            runOnGitRoot = true;
            position = {
              w = "140";
              h = "80";
            };
          };
        }
        {
          menu = {
            name = "gh dash";
            shortcut = "d";
            command = "_gen-close-hook gh-dash && gh dash";
            session = true;
            sessionName = "gh-dash";
            keyTable = "popup-locked-root";
            sessionOnDir = true;
            runOnGitRoot = true;
            position = {
              w = "150";
              h = "80";
            };
          };
        }
        { separator = true; }
        {
          menu = {
            name = "dump gitignore";
            shortcut = "i";
            command = "gibo dump %%LANGUAGE%% | less && gibo dump %%LANGUAGE%% | pbcopy";
            keyTable = "popup-root";
            inputs = [ "LANGUAGE" ];
            position = {
              w = "150";
              h = "80";
            };
          };
        }
      ];
    };
  };
}

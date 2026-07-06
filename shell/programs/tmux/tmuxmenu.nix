_: {
  programs.tmux-menu = {
    enable = true;

    scriptsDir = ./scripts;

    menus.menu = {
      title = " menu ";
      items = [
        {
          menu = {
            name = "git";
            shortcut = "g";
            nextMenu = "git";
          };
        }
        {
          menu = {
            name = "shell";
            shortcut = "s";
            command = "_gen-close-hook subshell && /bin/zsh";
            session = true;
            sessionName = "subshell";
            sessionOnDir = true;
            runOnGitRoot = true;
            environment.MENU_POPUP = "1";
            position = {
              w = "60%";
              h = "70%";
            };
          };
        }
        {
          menu = {
            name = "Navi";
            shortcut = "n";
            command = "navi --path=$CONFIG/navi --print | pbcopy";
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
            environment = {
              NO_WINDOW_MGNT = "1";
              CTRL_C_AS_CLOSE = "1";
              MENU_POPUP = "1";
            };
            position = {
              w = "60%";
              h = "70%";
            };
          };
        }
        { separator = true; }
        {
          menu = {
            name = "aoe";
            shortcut = "h";
            command = "aoe";
            position = {
              w = "60%";
              h = "55%";
            };
          };
        }
        {
          menu = {
            name = "pi";
            shortcut = "p";
            command = ''title="$(basename "$PWD") pi $(date +%H%M%S)-$$"; direnv exec . aoe add --cmd pi --title "$title" . && aoe session start "$title"'';
            runOnGitRoot = true;
            position = {
              w = "60%";
              h = "55%";
            };
          };
        }
        {
          menu = {
            name = "codex";
            shortcut = "c";
            command = ''title="$(basename "$PWD") codex $(date +%H%M%S)-$$"; direnv exec . aoe add --cmd codex --title "$title" . && aoe session start "$title"'';
            runOnGitRoot = true;
            position = {
              w = "60%";
              h = "55%";
            };
          };
        }
        {
          menu = {
            name = "claude";
            shortcut = "C";
            command = ''title="$(basename "$PWD") claude $(date +%H%M%S)-$$"; direnv exec . aoe add --cmd claude --title "$title" . && aoe session start "$title"'';
            runOnGitRoot = true;
            position = {
              w = "60%";
              h = "55%";
            };
          };
        }
        {
          menu = {
            name = "claude chrome";
            shortcut = "b";
            command = "_gen-close-hook claude && direnv exec . claude --chrome";
            session = true;
            sessionName = "claude-chrome";
            sessionOnDir = true;
            runOnGitRoot = true;
            environment = {
              MULTI_SESSION_COMMAND = "direnv exec . claude --chrome";
              NO_WINDOW_MGNT = "1";
              CTRL_C_AS_CLOSE = "1";
              MENU_POPUP = "1";
              TMUX_REMAP_CTRL_D = "C-n";
            };
            position = {
              w = "60%";
              h = "55%";
            };
          };
        }
        { separator = true; }
        {
          menu = {
            name = "notify watch";
            shortcut = "l";
            command = "$TMUX_CONFIG/scripts/notify-watch.sh";
            background = true;
          };
        }
        {
          menu = {
            name = "notify cancel";
            shortcut = "L";
            command = "$TMUX_CONFIG/scripts/notify-cancel.sh";
            background = true;
          };
        }
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
            sessionOnDir = true;
            runOnGitRoot = true;
            environment = {
              MENU_POPUP = "1";
              NO_WINDOW_MGNT = "1";
            };
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
            sessionOnDir = true;
            runOnGitRoot = true;
            environment = {
              MENU_POPUP = "1";
              NO_WINDOW_MGNT = "1";
            };
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
            sessionOnDir = true;
            runOnGitRoot = true;
            environment = {
              MENU_POPUP = "1";
              NO_WINDOW_MGNT = "1";
            };
            position = {
              w = "150";
              h = "80";
            };
          };
        }
        {
          menu = {
            name = "Git branch";
            shortcut = "b";
            command = "$CONFIG/tmux/scripts/gitbranch.sh";
            background = true;
          };
        }
        { separator = true; }
        {
          menu = {
            name = "dump gitignore";
            shortcut = "i";
            command = "gibo dump %%LANGUAGE%% | less && gibo dump %%LANGUAGE%% | pbcopy";
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

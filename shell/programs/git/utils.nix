{ pkgs, ... }:
let
  git-wt = (pkgs.writeShellScriptBin "git-wt" (builtins.readFile ./git-wt));
in
{
  programs.zshFunc = {
    git-wt = {
      source = true;
      command = ''
        # run underlying binary and capture output
        local out
        if ! out="$(${git-wt}/bin/git-wt "$@")"; then
          # propagate failure with any output
          printf '%s\n' "$out"
          return 1
        fi

        # cd to last line if it is a directory
        local dir
        dir="$(printf '%s\n' "$out" | tail -n 1)"
        if [ -d "$dir" ]; then
          cd "$dir" || return
        fi

        # echo original output
        printf '%s\n' "$out"
      '';
    };
  };

  home.shellAliases = {
    gw = "git wt";
  };

  programs.gh = {
    enable = true;

    settings = {
      git_protocol = "ssh";

      prompt = "enabled";

      aliases = {
        co = "pr checkout";
        pv = "pr view";
      };
    };
  };

  programs.gh-dash = {
    enable = true;

    settings = {
      prSections = [
        {
          title = "My Pull Requests";
          filters = "is:open author:@me";
        }
        {
          title = "Needs My Review";
          filters = "is:open review-requested:@me";
        }
        {
          title = "Subscribed";
          filters = "is:open -author:@me";
        }
      ];
      issuesSections = [
        {
          title = "My Issues";
          filters = "is:open author:@me";
        }
        {
          title = "Assigned";
          filters = "is:open assignee:@me";
        }
        {
          title = "Subscribed";
          filters = "is:open -author:@me repo:cli/cli repo:dlvhdr/gh-dash";
        }
      ];
      defaults = {
        preview = {
          open = true;
          width = 50;
        };
        prsLimit = 20;
        issuesLimit = 20;
        view = "prs";
      };
    };
  };

  programs.gitui = {
    enable = true;

    keyConfig = ''
      (
        move_left: Some(( code: Char('h'), modifiers: "")),
        move_right: Some(( code: Char('l'), modifiers: "")),
        move_up: Some(( code: Char('k'), modifiers: "")),
        move_down: Some(( code: Char('j'), modifiers: "")),

        stash_open: Some(( code: Char('l'), modifiers: "")),
        open_help: Some(( code: F(1), modifiers: "")),

        status_reset_item: Some(( code: Char('U'), modifiers: "SHIFT")),
      )
    '';
  };

  home.packages = with pkgs; [
    tig
  ];
}

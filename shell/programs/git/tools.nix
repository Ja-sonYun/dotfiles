{ pkgs, ... }:
{
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      features = "side-by-side";
    };
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
    git-absorb
  ];
}

{ lib
, pkgs
, ...
}:
{
  # `programs.git` will generate the config file: ~/.config/git/config
  # to make git use this config file, `~/.gitconfig` should not exist!
  #
  #    https://git-scm.com/docs/git-config#Documentation/git-config.txt---global
  home.activation.removeExistingGitconfig = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    rm -f ~/.gitconfig
  '';

  home.shellAliases = {
    gst = "git status";
  };

  programs.git = {
    enable = true;
    package = pkgs.git-wrapped;
    lfs.enable = true;

    ignores = [
      # Compiled source #
      ###################
      "*.com"
      "*.class"
      "*.dll"
      "*.exe"
      "*.o"
      "*.so"
      "*.pyc"
      "*.pyo"

      # Packages #
      ############
      # it's better to unpack these files and commit the raw source
      # git has its own built in compression methods
      "*.7z"
      "*.dmg"
      "*.gz"
      "*.iso"
      "*.jar"
      "*.rar"
      "*.tar"
      "*.zip"
      "*.msi"

      # Logs and databases #
      ######################
      "*.log"
      "*.sqlite"

      # OS generated files #
      ######################
      ".DS_Store"
      ".DS_Store?"
      "._*"
      ".Spotlight-V100"
      ".Trashes"
      "ehthumbs.db"
      "Thumbs.db"
      "desktop.ini"

      # Temporary files #
      ###################
      "*.bak"
      "*.swp"
      "*.swo"
      "*~"
      "*#"

      # IDE files #
      #############
      ".vscode"
      ".idea"
      ".iml"
      "*.sublime-workspace"

      # Vim #
      #######
      # Swap
      "[._]*.s[a-v][a-z]"
      "!*.svg"
      "[._]*.sw[a-p]"
      "[._]s[a-rt-v][a-z]"
      "[._]ss[a-gi-z]"
      "[._]sw[a-p]"

      # Session
      "Session.vim"
      "Sessionx.vim"

      # Temporary
      ".netrwhist"

      # Auto-generated tag files
      # "tags"
      # Persistent undo
      "[._]*.un~"

      ".vimspector.json"
      ".python-version"

      ".envrc"
      ".env"
      "pyrightconfig.json"
      ".venv"
      ".direnv"
      ".tmp"

      ".ccls-cache"
      "compile_commands.json"

      ".aider*"
      ".claude"
      ".serena"
      ".taskmaster"
      "CLAUDE.md"
      "backlog"
      ".hooks"
      "pyrefly.toml"
      ".vim_vars.json"
      ".playwright-mcp"
      "AGENTS.md"
      "AGENT.md"
      ".codex"
      ".codex*"
      ".sisyphus"
    ];

    includes = [
      # {
      #   # use diffrent email & name for work
      #   path = "~/work/.gitconfig";
      #   condition = "gitdir:~/work/";
      # }
    ];

    settings = {
      user = {
        name = "Ja-sonYun";
        email = "killa30867@gmail.com";
      };

      alias = {
        # common aliases
        br = "branch";
        co = "checkout";
        st = "status";
        ls = "log --pretty=format:\"%C(yellow)%h%Cred%d\\\\ %Creset%s%Cblue\\\\ [%cn]\" --decorate";
        ll = "log --pretty=format:\"%C(yellow)%h%Cred%d\\\\ %Creset%s%Cblue\\\\ [%cn]\" --decorate --numstat";
        cm = "commit -m";
        ca = "commit -am";
        dc = "diff --cached";
        amend = "commit --amend -m";

        # aliases for submodule
        update = "submodule update --init --recursive";
        foreach = "submodule foreach";
      };

      init.defaultBranch = "main";
      push.autoSetupRemote = true;
      pull.rebase = true;
      commit.verbose = true;
      branch.sort = "-committerdate";
      column.ui = "auto";
      tag.sort = "-version:refname";
      help.autocorrect = "prompt";

      diff.algorithm = "histogram";
      diff.tool = "vimdiff";

      difftool.prompt = false;
      "difftool \"vimdiff\"".cmd = "vim -d \"$LOCAL\" \"$REMOTE\"";

      merge.tool = "vimdiff";
      mergetool.prompt = false;
      mergetool.keepBackup = false;
      "mergetool \"vimdiff\"".cmd = "vim -d \"$MERGED\" \"$LOCAL\" \"$BASE\" \"$REMOTE\" -c 'wincmd J'";
    };
  };

  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      features = "side-by-side";
    };
  };
}

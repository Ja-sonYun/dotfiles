{ pkgs, lib, ... }:
{
  home.activation.setZshAsDefaultShell = lib.mkIf pkgs.stdenv.isLinux (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
      ZSH_PATH="$HOME/.nix-profile/bin/zsh"
      if [[ $(getent passwd $USER) != *"$ZSH_PATH"* ]]; then
        if ! grep -q "$ZSH_PATH" /etc/shells; then
          echo "$ZSH_PATH" | sudo tee -a /etc/shells
        fi
        sudo chsh -s "$ZSH_PATH" "$USER"
      fi
    ''
  );

  programs.zsh = {
    enable = true;

    autosuggestion.enable = true;
    enableCompletion = true;
    syntaxHighlighting.enable = true;

    shellAliases = {
      urldecode = "python3 -c 'import sys, urllib.parse as ul; print(ul.unquote_plus(sys.stdin.read()))'";
      urlencode = "python3 -c 'import sys, urllib.parse as ul; print(ul.quote_plus(sys.stdin.read()))'";
      dud = "du -h -d 1 ";
    };

    shellGlobalAliases = {
      G = "| grep";
      L = "| less";
      T = "| tail";
      H = "| head";
      S = "| sort";
      D = "| base64 -d";
      __ = "| ${pkgs.spacer}/bin/spacer";
    };

    localVariables = { };

    envExtra = "";
    profileExtra = "";
  };

  programs.zsh-customize = {
    enable = true;
    fpath = [ "$HOME/.zsh/completions" ];
    path = [
      "$HOME/.bin"
      "$HOME/.local/bin"
      "$HOME/go/bin"
    ];
    wordChars.remove = [
      "/"
      "-"
      "."
    ];
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
    historyWidget.command = ""; # atuin owns Ctrl-R
  };

  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
    options = [ "--cmd cd" ];
  };

  programs.atuin = {
    enable = true;
    enableZshIntegration = true;
    flags = [ "--disable-up-arrow" ];
    settings = {
      auto_sync = false;
      sync_address = "http://localhost:8080"; # Override with dummy
      style = "compact";
      show_help = false;
      show_tabs = false;
    };
  };

  programs.bat.enable = true;

  programs.eza = {
    enable = true;
    git = true;
    icons = "never";
    enableZshIntegration = true;
  };
}

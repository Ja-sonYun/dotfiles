{
  hasTag,
  lib,
  paths,
  pkgs,
  ...
}:
{
  home.packages =
    with pkgs;
    [
      amber-lang

      cf-tunnel

      # archives
      zip
      xz
      unzip
      p7zip

      # utils
      ripgrep # recursively searches directories for a regex pattern
      jq # A lightweight and flexible command-line JSON processor
      yq-go # yaml processer https://github.com/mikefarah/yq
      dasel

      aria2 # A lightweight multi-protocol & multi-source command-line download utility
      socat # replacement of openbsd-netcat
      nmap # A utility for network discovery and security auditing

      # misc
      file
      which
      tree
      gnused
      gnutar
      gawk
      moor
      zstd
      caddy
      gnupg
      flock
      argc

      # productivity
      glow # markdown previewer in terminal
      viu

      lazygit
      lazysql

      httpie
      wget

      hwatch

      nh
      comma
      nix-output-monitor
      devenv

      entr
      fd
      dua
      glance

      btop

      cookiecutter

      cloudflared

      awsdac

      hyperfine

      awscli2
      awscli-local

      (ledger.override { usePython = true; })

      # My vim config
      # plot

      vim-pkg

      agenix-utils

      # Cleaner
      dust
    ]
    ++ lib.optionals (hasTag "gui") [
      # say
      mermaid-cli
    ]
    ++ lib.optionals (hasTag "ai") [
      llmfit
    ];

  home.sessionVariables = {
    EDITOR = "${pkgs.vim-pkg}/bin/vim";
    # PAGER = "${pkgs.moor}/bin/moor";
    FLAKE_TEMPLATES_DIR = "${paths.dotfiles}/templates";
  };

  home.shellAliases = {
    vi = "vim";
    cat = "bat";
    gsed = "sed";
    watch = "hwatch";
  };
}

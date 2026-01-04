{ system, ... }:
{
  imports = [
    ./zsh
    ./core
    ./secrets # Agenix secrets management

    ./analysis

    ./programs/git
    ./programs/git/utils.nix
    # We'll use orbstack on macOS
    # ./programs/docker
    ./programs/ghostty
    ./programs/jujutsu
    ./programs/tmux
    ./programs/visidata
    ./programs/claude
    ./programs/codex
    ./programs/direnv
    ./programs/navi
  ]
  ++ (
    if system == "aarch64-darwin" then
      [
        ./programs/weechat
      ]
    else if system == "x86_64-linux" then
      [ ]
    else
      [ ]
  );

  home.file.profile = {
    target = ".profile";
    text = '''';
  };
}

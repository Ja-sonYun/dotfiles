{
  pkgs,
  ...
}:
{
  environment.shells = [
    pkgs.zsh
  ];
  environment.pathsToLink = [ "/share/zsh" ];

  environment.variables.EDITOR = "vim";
  environment.systemPath = [ ];
  environment.systemPackages = with pkgs; [
    vim-pkg
  ];
  environment.shellAliases = {
    preview = "/usr/bin/open -a Preview";
    vi = "vim";
  };
}

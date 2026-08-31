{
  hasTag,
  lib,
  pkgs,
  ...
}:
{
  environment.etc = lib.mkIf (hasTag "ai") {
    "codex/requirements.toml".text = ''
      default_permissions = "managed"

      [allowed_permission_profiles]
      managed = true
      ":read-only" = true
      ":danger-full-access" = true
    '';
  };

  environment.shells = [
    pkgs.zsh
  ];
  environment.pathsToLink = [ "/share/zsh" ];

  time.timeZone = "Asia/Tokyo";

  environment.variables.EDITOR = "vim";
  environment.systemPath = [ ];
  environment.systemPackages = with pkgs; [
    vim-pkg
  ];
  environment.shellAliases = {
    vi = "vim";
  };
}

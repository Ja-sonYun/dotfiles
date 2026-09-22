{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.loginShell;
in
{
  options.programs.loginShell = {
    enable = lib.mkEnableOption "login shell selection";
    path = lib.mkOption {
      type = lib.types.str;
      description = "Absolute path to the desired login shell.";
    };
  };
  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isLinux) {
    home.activation.setLoginShell = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
      login_shell=${lib.escapeShellArg cfg.path}
      login_user=${lib.escapeShellArg config.home.username}
      current_shell="$(getent passwd "$login_user" | cut -d: -f7)"
      if [[ "$current_shell" != "$login_shell" ]]; then
        if ! grep -Fqx -- "$login_shell" /etc/shells; then
          printf '%s\n' "$login_shell" | run sudo tee -a /etc/shells
        fi
        run sudo chsh -s "$login_shell" "$login_user"
      fi
    '';
  };
}

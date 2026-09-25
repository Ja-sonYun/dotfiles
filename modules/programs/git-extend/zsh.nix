{ config, lib, ... }:
{
  options.programs.gitExtend.enableZshIntegration = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Let Git commands change the parent shell's directory.";
  };

  config = lib.mkIf config.programs.gitExtend.enableZshIntegration {
    assertions = [
      {
        assertion = config.programs.gitExtend.enable && config.programs.git.enable;
        message = "gitExtend.enableZshIntegration requires programs.gitExtend.enable and programs.git.enable.";
      }
      {
        assertion = config.programs.zsh.enable && config.programs.zsh-customize.enable;
        message = "gitExtend.enableZshIntegration requires programs.zsh.enable and programs.zsh-customize.enable.";
      }
    ];

    programs.zsh-customize.blocks = [
      {
        raw = ''
          export SHELL_CD_REQUEST_FILE="''${TMPDIR:-/tmp}/shell-cd-$UID-$$"
          rm -f "$SHELL_CD_REQUEST_FILE" 2>/dev/null || true
        '';

        functions._shell_apply_cd_request = ''
          local dir
          [[ -f "$SHELL_CD_REQUEST_FILE" ]] || return
          IFS= read -r dir < "$SHELL_CD_REQUEST_FILE"
          rm -f "$SHELL_CD_REQUEST_FILE"
          [[ -d "$dir" ]] && cd "$dir"
        '';

        hooks.precmd = [ { function = "_shell_apply_cd_request"; } ];
      }
    ];
  };
}

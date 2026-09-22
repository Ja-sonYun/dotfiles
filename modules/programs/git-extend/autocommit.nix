{ config, lib, ... }:
let
  cfg = config.programs.gitExtend.autocommit;
in
{
  options.programs.gitExtend.autocommit = {
    enable = lib.mkEnableOption "generating a commit message with git commit -g";
    command = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Shell command to execute for git commit -g. The private configuration supplies the implementation.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.programs.gitExtend.enable;
        message = "programs.gitExtend.autocommit requires programs.gitExtend.enable.";
      }
    ];
    programs.gitExtend.commands = [
      {
        path = [ "commit" ];
        flag = "-g";
        help = "Generate a commit message and commit.";
        command = ''
          exec ${cfg.command} "$@"
        '';
      }
    ];
  };
}

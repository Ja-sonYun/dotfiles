{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi;
  nonEmptyString = lib.types.addCheck lib.types.str (value: value != "");
  positiveNumber = lib.types.addCheck lib.types.number (value: value > 0);
  eventNames = [
    "Notification"
    "PostCompact"
    "PostToolBatch"
    "PostToolUse"
    "PostToolUseFailure"
    "PreCompact"
    "PreToolUse"
    "SessionEnd"
    "SessionStart"
    "Stop"
    "StopFailure"
    "UserPromptSubmit"
  ];
  commandHookType = lib.types.submodule {
    options = {
      type = lib.mkOption {
        type = lib.types.enum [ "command" ];
        default = "command";
      };
      command = lib.mkOption {
        type = nonEmptyString;
        description = "Command executed with sh -c.";
      };
      timeout = lib.mkOption {
        type = lib.types.nullOr positiveNumber;
        default = null;
      };
    };
  };
  hookBlockType = lib.types.submodule {
    options = {
      matcher = lib.mkOption {
        type = lib.types.str;
        default = "";
      };
      hooks = lib.mkOption {
        type = lib.types.nonEmptyListOf commandHookType;
      };
    };
  };
  invalidEventNames = lib.subtractLists eventNames (builtins.attrNames cfg.hooks);
in
{
  options.programs.pi.hooks = lib.mkOption {
    type = lib.types.attrsOf (lib.types.nonEmptyListOf hookBlockType);
    default = { };
    description = "Claude-style hook events and configuration with Pi-native tool payloads.";
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = invalidEventNames == [ ];
          message = "programs.pi.hooks has unsupported events: ${lib.concatStringsSep ", " invalidEventNames}.";
        }
      ];
    }
    (lib.mkIf (cfg.enable && cfg.hooks != { }) {
      programs.pi.extensions.hooks = pkgs.pi-extensions.hooks cfg.hooks;
    })
  ];
}

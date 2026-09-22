{ lib }:
let
  nonEmptyString = lib.types.addCheck lib.types.str (value: value != "");
  commandHook = lib.types.submodule {
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
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
      };
    };
  };
in
{
  hookBlock = lib.types.submodule {
    options = {
      matcher = lib.mkOption {
        type = lib.types.str;
        default = "";
      };
      hooks = lib.mkOption {
        type = lib.types.nonEmptyListOf commandHook;
      };
    };
  };
}

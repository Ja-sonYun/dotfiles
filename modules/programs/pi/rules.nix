{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi.rules;
  package = pkgs.callPackage ../../../pkgs/pi/rules { };
  rules = lib.concatLists (
    lib.mapAttrsToList (
      target: definitions:
      lib.mapAttrsToList (name: rule: {
        inherit name;
        value = rule // {
          inherit target;
        };
      }) definitions
    ) cfg.rules
  );
  rulesFile = pkgs.writeText "pi-rules.json" (builtins.toJSON (lib.listToAttrs rules));
  nonEmptyString = lib.types.addCheck lib.types.str (
    value: builtins.match "[[:space:]]*" value == null
  );
  ruleType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Evaluate this rule in Pi.";
        };

        title = lib.mkOption {
          type = nonEmptyString;
          default = name;
          description = "Rule display name.";
        };

        extensions = lib.mkOption {
          type = lib.types.listOf (
            lib.types.addCheck lib.types.str (value: builtins.match "\\.[A-Za-z0-9]+" value != null)
          );
          default = [ ];
          example = [
            ".py"
            ".pyi"
          ];
          description = "Case-insensitive file extensions; empty matches all.";
        };

        trigger = lib.mkOption {
          default = { };
          description = "Rule trigger conditions.";
          type = lib.types.submodule {
            options = {
              matcher = lib.mkOption {
                type = lib.types.nullOr nonEmptyString;
                default = null;
                description = "Tool-name Python regex for tool rules.";
              };
              inputFields = lib.mkOption {
                type = lib.types.listOf nonEmptyString;
                default = [ ];
                description = "Input fields to inspect; empty selects all strings.";
              };
              pattern = lib.mkOption {
                type = lib.types.nullOr nonEmptyString;
                default = null;
                description = "Python regex required to match selected input.";
              };
            };
          };
        };

        check = lib.mkOption {
          description = "Exactly one intent or regex check.";
          type = lib.types.submodule {
            options = {
              intent = lib.mkOption {
                type = lib.types.nullOr nonEmptyString;
                default = null;
                description = "Violation criteria and exceptions for Jev.";
              };
              regex = lib.mkOption {
                type = lib.types.nullOr nonEmptyString;
                default = null;
                description = "Python regex matching violations.";
              };
            };
          };
        };

        why = lib.mkOption {
          type = nonEmptyString;
          description = "Why a violation matters.";
        };

        message = lib.mkOption {
          type = nonEmptyString;
          description = "Violation correction guidance.";
        };
      };
    }
  );
in
{
  options.programs.pi.rules = {
    evaluatorCommand = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = [
        "${package}/bin/pi-rules-check"
        "--rules"
        "${rulesFile}"
      ];
      description = "Stateless JSON tool and code rule evaluator command.";
    };
    enable = lib.mkEnableOption "Pi tool and code rule checks";
    rules = lib.genAttrs [ "code" "tool" ] (
      target:
      lib.mkOption {
        type = lib.types.attrsOf ruleType;
        default = { };
        description = "Static ${target} rules.";
      }
    );
  };

  config = lib.mkIf (config.programs.pi.enable && cfg.enable) {
    assertions = [
      {
        assertion = builtins.length rules == builtins.length (lib.unique (map (rule: rule.name) rules));
        message = "Rule IDs must be unique across code and tool groups.";
      }
    ]
    ++ lib.concatMap (rule: [
      {
        assertion = (rule.value.check.intent != null) != (rule.value.check.regex != null);
        message = "Rule ${rule.name}: specify exactly one of check.intent and check.regex.";
      }
      {
        assertion =
          rule.value.target == "tool"
          || (rule.value.trigger.matcher == null && rule.value.trigger.inputFields == [ ]);
        message = "Rule ${rule.name}: only tool rules may select tool names or input fields.";
      }
      {
        assertion = rule.value.target == "code" || rule.value.extensions == [ ];
        message = "Rule ${rule.name}: only code rules may specify extensions.";
      }
      {
        assertion = builtins.match "[A-Za-z0-9_-]+" rule.name != null;
        message = "Rule IDs may contain only letters, digits, underscores, and hyphens.";
      }
    ]) rules;
  };
}

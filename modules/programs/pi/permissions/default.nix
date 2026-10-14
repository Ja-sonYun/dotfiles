{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.pi;
  policy = cfg.permissions;
  catalog = builtins.fromJSON (builtins.readFile ./presets.json);
  presetNames = map (preset: preset.name) catalog;
  selectedPresets = lib.filter (preset: policy.presets.${preset.name}) catalog;
  decision = lib.types.enum [
    "allow"
    "ask"
    "deny"
  ];
  access = lib.types.enum [
    "allow"
    "deny"
  ];
  token = lib.types.strMatching "[A-Za-z0-9_./:@%+=,-]+";
  name = lib.types.strMatching "[A-Za-z0-9_.-]+";
  commandRule = lib.types.submodule {
    options = {
      prefix = lib.mkOption {
        type = lib.types.nonEmptyListOf token;
        description = "Literal command prefix.";
      };
      decision = lib.mkOption { type = decision; };
    };
  };
  fileRule = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "File path or glob.";
      };
      read = lib.mkOption {
        type = access;
        description = "Read access; deny also requires write denial.";
      };
      write = lib.mkOption {
        type = access;
        description = "Write access.";
      };
    };
  };
  serverPolicy = lib.types.submodule {
    options = {
      default = lib.mkOption {
        type = lib.types.nullOr decision;
        default = null;
        description = "Default tool permission; null keeps client defaults.";
      };
      tools = lib.mkOption {
        type = lib.types.attrsOf decision;
        default = { };
        description = "Permissions by exact MCP tool name.";
      };
    };
  };
  servers = policy.mcp;
in
{
  options.programs.pi.permissions = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          presets = lib.listToAttrs (
            map (
              preset:
              lib.nameValuePair preset.name (
                lib.mkOption {
                  type = lib.types.bool;
                  inherit (preset) default description;
                }
              )
            ) catalog
          );
          commands = {
            rules = lib.mkOption {
              type = lib.types.listOf commandRule;
              default = [ ];
            };
          };
          files = {
            rules = lib.mkOption {
              type = lib.types.listOf fileRule;
              default = [ ];
            };
          };
          mcp = lib.mkOption {
            type = lib.types.attrsOf serverPolicy;
            default = { };
            description = "Permissions by MCP server name.";
          };
          mcp_readonly_tools = lib.mkOption {
            type = lib.types.attrsOf (lib.types.listOf name);
            default = { };
            description = "Verified read-only MCP tools, by literal server and exact tool name.";
          };
        };
      }
    );
    default = { };
    description = "Pi file, command, and MCP permissions.";
  };

  config = lib.mkIf (cfg.enable && policy != null) {
    programs.pi.settings.extensions.permissions.policy =
      lib.mkIf cfg.settings.extensions.permissions.enable
        {
          inherit (policy) commands mcp mcp_readonly_tools;
          files.rules = policy.files.rules ++ lib.concatMap (preset: preset.files or [ ]) selectedPresets;
          defaultRead = policy.presets.defaults;
        };
    assertions = lib.mkIf cfg.settings.extensions.permissions.enable [
      {
        assertion = builtins.length presetNames == builtins.length (lib.unique presetNames);
        message = "Permission preset names must be unique.";
      }
      {
        assertion = lib.all (rule: rule.read != "deny" || rule.write == "deny") policy.files.rules;
        message = "Pi file permissions cannot allow writing while denying reading.";
      }
      {
        assertion = lib.all (
          server: name.check server && lib.all name.check (builtins.attrNames servers.${server}.tools)
        ) (builtins.attrNames servers);
        message = "Pi MCP permissions require literal server and tool names, without selectors or wildcards.";
      }
      {
        assertion = lib.all name.check (builtins.attrNames policy.mcp_readonly_tools);
        message = "Read-only MCP tool lists require literal server names.";
      }
    ];
  };
}

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents;
  policy = cfg.permissions;
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
  policyFile = (pkgs.formats.json { }).generate "ai-agent-permissions.json" policy;
  package = pkgs.callPackage ./package.nix { };
  command = lib.escapeShellArgs [
    (lib.getExe package)
    "--config"
    policyFile
  ];
  settingsTransform =
    client:
    pkgs.writeShellScript "${client}-permissions" ''
      exec ${command} --client ${client} \
        --claude-plugin ${lib.escapeShellArg config.programs.claude-code.mcpPluginName}
    '';
  codexRules = pkgs.runCommandLocal "codex-managed.rules" { } ''
    ${command} --client codex --rules > "$out"
  '';
in
{
  options.programs.ai-agents.permissions = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          presets = {
            denyDotenv = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Block workspace dotenv files.";
            };
            denySsh = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Block ~/.ssh access.";
            };
            allowGitWrite = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Allow Git metadata writes.";
            };
          };
          unixSockets.allow = lib.mkOption {
            type = lib.types.listOf (lib.types.strMatching "/.+");
            default = [ ];
            description = "Allowed Unix socket paths.";
          };
          webSearch = lib.mkOption {
            type = lib.types.nullOr access;
            default = null;
            description = "Web search permission; null keeps client settings.";
          };
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
        };
      }
    );
    default = null;
    description = "Shared Claude Code and Codex permissions.";
  };

  config = lib.mkIf (cfg.enable && policy != null) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = lib.all (rule: rule.read != "deny" || rule.write == "deny") policy.files.rules;
            message = "Shared file permissions cannot allow writing while denying reading.";
          }
          {
            assertion = lib.all (
              server: name.check server && lib.all name.check (builtins.attrNames servers.${server}.tools)
            ) (builtins.attrNames servers);
            message = "AI agent MCP permissions require literal server and tool names, without selectors or wildcards.";
          }
        ];
      }
      (lib.mkIf config.programs.codex.enable {
        programs.codex = {
          settingsTransform = settingsTransform "codex";
          rulesSources.managed = codexRules;
          settings =
            lib.mkIf
              (
                policy.files.rules != [ ]
                || policy.presets.denyDotenv
                || policy.presets.denySsh
                || policy.presets.allowGitWrite
                || policy.unixSockets.allow != [ ]
              )
              {
                default_permissions = lib.mkDefault "managed";
                permissions.managed.extends = lib.mkDefault ":workspace";
              };
        };
      })
      (lib.mkIf config.programs.claude-code.enable {
        programs.claude-code.settingsTransform = settingsTransform "claude";
      })
    ]
  );
}

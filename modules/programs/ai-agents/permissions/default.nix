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
        description = "Literal executable and argument prefix, without shell patterns.";
      };
      decision = lib.mkOption { type = decision; };
    };
  };
  fileRule = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Path glob relative to the tool working directory, or an absolute/home path. * matches one component; ** matches across directories.";
      };
      excludes = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = [ ];
        description = "Path globs excluded from this rule, relative to the tool working directory or absolute/home paths. Exclusions are matched separately against the original and resolved target paths and are not themselves symlink-resolved.";
      };
      read = lib.mkOption {
        type = lib.types.nullOr access;
        default = null;
        description = "Direct file-read decision; null preserves native behavior. Allow does not bypass native sandbox or approval checks.";
      };
      write = lib.mkOption {
        type = lib.types.nullOr access;
        default = null;
        description = "Direct file-write decision; null preserves native behavior. Allow does not bypass native sandbox or approval checks.";
      };
    };
  };
  serverPolicy = lib.types.submodule {
    options = {
      default = lib.mkOption {
        type = lib.types.nullOr decision;
        default = null;
        description = "Decision for tools without an explicit rule; null preserves native behavior.";
      };
      tools = lib.mkOption {
        type = lib.types.attrsOf decision;
        default = { };
        description = "Decisions keyed by exact MCP tool names.";
      };
    };
  };
  servers = policy.mcp;
  policyFile = (pkgs.formats.json { }).generate "ai-agent-permissions.json" {
    inherit (policy) files;
    mcp = servers;
    claudePlugin = config.programs.claude-code.mcpPluginName;
  };
  package = pkgs.callPackage ./package.nix { };
  command = lib.escapeShellArgs [
    (lib.getExe package)
    "--config"
    policyFile
  ];
  codexDecisions = {
    allow = "allow";
    ask = "prompt";
    deny = "forbidden";
  };
  codexApproval = {
    allow = "approve";
    ask = "prompt";
    deny = "prompt";
  };
  codexServers = lib.mapAttrs (
    _: server:
    let
      permitted = builtins.attrNames (lib.filterAttrs (_: value: value != "deny") server.tools);
    in
    {
      tools = lib.mapAttrs (_: value: {
        enabled = if value == "deny" then lib.mkForce false else lib.mkDefault true;
        approval_mode = codexApproval.${value};
      }) server.tools;
    }
    // lib.optionalAttrs (server.default != null) {
      default_tools_approval_mode = codexApproval.${server.default};
    }
    // lib.optionalAttrs (server.default == "deny") {
      enabled_tools = permitted;
    }
    // lib.optionalAttrs (server.default == "deny" && permitted == [ ]) {
      enabled = lib.mkForce false;
    }
  ) servers;
  claudeRules =
    value:
    lib.concatMap (
      rule:
      let
        prefix = lib.concatStringsSep " " rule.prefix;
      in
      lib.optionals (rule.decision == value) [
        "Bash(${prefix})"
        "Bash(${prefix} *)"
      ]
    ) policy.commands.rules;
  claudeReadDenyRules = map (
    rule:
    let
      path =
        if lib.hasPrefix "/" rule.path then
          "/" + rule.path
        else if lib.hasPrefix "~/" rule.path then
          rule.path
        else
          "./" + rule.path;
    in
    "Read(${path})"
  ) (lib.filter (rule: rule.read == "deny" && rule.excludes == [ ]) policy.files.rules);
  claudeMcpRules =
    value:
    lib.concatLists (
      lib.mapAttrsToList (
        server: entry:
        let
          prefixes = [
            "mcp__${server}__"
            "mcp__plugin_${config.programs.claude-code.mcpPluginName}_${server}__"
          ];
          tools = builtins.attrNames (lib.filterAttrs (_: decision: decision == value) entry.tools);
        in
        lib.concatMap (
          prefix:
          map (tool: prefix + tool) tools
          ++ lib.optional (value == "allow" && entry.default == "allow") (prefix + "*")
        ) prefixes
      ) servers
    );
  permissionHooks = [
    {
      matcher = "";
      hooks = [
        {
          type = "command";
          inherit command;
          timeout = 5;
        }
      ];
    }
  ];
in
{
  options.programs.ai-agents.permissions = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
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
            description = "Policies for literal MCP server names. Omitted servers and tools without a default preserve native behavior.";
          };
        };
      }
    );
    default = null;
    description = "Explicit Claude and Codex command, direct-file and MCP tool permissions. Unmatched calls preserve native behavior. Overlapping command/file rules use deny > ask > allow; exact MCP tools override server defaults. File rules govern direct file tools, not shell access, and do not grant sandbox access.";
  };

  config = lib.mkIf (cfg.enable && policy != null) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = lib.all (rule: rule.read != null || rule.write != null) policy.files.rules;
            message = "Each programs.ai-agents.permissions.files rule must set read or write.";
          }
          {
            assertion = lib.all (
              server: name.check server && lib.all name.check (builtins.attrNames servers.${server}.tools)
            ) (builtins.attrNames servers);
            message = "AI agent MCP permissions require literal server and tool names, without selectors or wildcards.";
          }
        ];
        programs.ai-agents.hooksByAgent = {
          claude = lib.optionalAttrs (policy.files.rules != [ ] || servers != { }) {
            PreToolUse = permissionHooks;
          };
          codex = lib.optionalAttrs (policy.files.rules != [ ]) {
            PreToolUse = permissionHooks;
          };
        };
      }
      (lib.mkIf config.programs.codex.enable {
        assertions = lib.mapAttrsToList (server: entry: {
          assertion =
            entry.default != "deny"
            || lib.all (tool: builtins.hasAttr tool entry.tools && entry.tools.${tool} != "deny") (
              config.programs.codex.settings.mcp_servers.${server}.enabled_tools or [ ]
            );
          message = "Codex MCP enabled_tools for ${server} must not expand the shared default-deny policy.";
        }) servers;
        programs.codex.rules.managed =
          lib.concatMapStringsSep "\n" (
            rule:
            ''prefix_rule(pattern = ${builtins.toJSON rule.prefix}, decision = "${
              codexDecisions.${rule.decision}
            }")''
          ) policy.commands.rules
          + "\n";
        programs.codex.settings.mcp_servers = codexServers;
      })
      (lib.mkIf config.programs.claude-code.enable {
        programs.claude-code.settings.permissions = {
          allow = claudeRules "allow" ++ claudeMcpRules "allow";
          ask = claudeRules "ask" ++ claudeMcpRules "ask";
          deny = claudeRules "deny" ++ claudeMcpRules "deny" ++ claudeReadDenyRules;
        };
      })
    ]
  );
}

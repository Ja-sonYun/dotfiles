{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents;
  jsonFormat = pkgs.formats.json { };

  sourceType =
    with lib.types;
    oneOf [
      package
      path
      str
    ];

  skillSourceType = lib.types.submodule {
    options = {
      source = lib.mkOption { type = lib.types.pathInStore; };
      skills = lib.mkOption { type = lib.types.nonEmptyListOf lib.types.str; };
    };
  };

  skillSourceInstallCommands = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (sourceName: source: ''
      work_dir="$(${pkgs.coreutils}/bin/mktemp -d "$TMPDIR/skills.XXXXXX")"
      (
        cd "$work_dir"
        ${pkgs.skills}/bin/skills add ${lib.escapeShellArg (toString source.source)} \
          --skill ${lib.escapeShellArgs source.skills} \
          --agent universal --copy --yes
      )

      for name in ${lib.escapeShellArgs source.skills}; do
        skill_dir="$work_dir/.agents/skills/$name"
        if [ ! -f "$skill_dir/SKILL.md" ]; then
          printf 'External skill source %s did not install skill %s\n' \
            ${lib.escapeShellArg sourceName} "$name" >&2
          exit 1
        fi
        if [ -e "$out/$name" ]; then
          echo "Duplicate external skill name: $name" >&2
          exit 1
        fi
        ${pkgs.coreutils}/bin/cp -R "$skill_dir" "$out/$name"
      done
    '') cfg.skillSources
  );

  externalSkillNames = lib.concatMap (source: source.skills) (builtins.attrValues cfg.skillSources);

  externalSkillsSrc = pkgs.runCommandLocal "ai-agent-external-skills" { } ''
    set -euo pipefail

    export DISABLE_TELEMETRY=1
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" "$out"

    ${skillSourceInstallCommands}
  '';

  externalSkills = lib.genAttrs externalSkillNames (name: externalSkillsSrc + "/${name}");

  duplicateSkillNames = lib.intersectLists (builtins.attrNames cfg.skills) (
    builtins.attrNames externalSkills
  );

  skills = cfg.skills // externalSkills;

  mcpServerType = lib.types.submodule {
    freeformType = jsonFormat.type;
    options = {
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      env = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.oneOf [
            lib.types.str
            (lib.types.submodule {
              options.file = lib.mkOption { type = lib.types.str; };
            })
          ]
        );
        default = { };
      };
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      headers = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
      enabled = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
      };
    };
  };

  mkDefaultValue =
    value:
    if builtins.isAttrs value && !lib.isDerivation value then
      lib.mapAttrs (_: mkDefaultValue) value
    else
      lib.mkDefault value;

  codexMcpServers = lib.mapAttrs (
    name: server:
    mkDefaultValue (
      lib.hm.mcp.transformMcpServer {
        inherit server;
        exclude = [
          "headers"
          "type"
        ];
        extraTransforms = [
          (value: value // lib.optionalAttrs (value.headers or { } != { }) { http_headers = value.headers; })
          lib.hm.mcp.addType
          (lib.hm.mcp.wrapEnvFilesCommand { inherit pkgs name; })
        ];
      }
    )
  ) cfg.mcp.servers;

  claudeMcpServers = lib.mapAttrs (
    name: server:
    mkDefaultValue (
      lib.hm.mcp.transformMcpServer {
        inherit server;
        exclude = [ "enabled" ];
        extraTransforms = [
          lib.hm.mcp.addType
          (lib.hm.mcp.wrapEnvFilesCommand { inherit pkgs name; })
        ];
      }
    )
  ) cfg.mcp.servers;

  piMcpServers = lib.mapAttrs (
    name: server:
    mkDefaultValue (
      lib.hm.mcp.transformMcpServer {
        inherit server;
        exclude = [ "type" ];
        extraTransforms = [
          (lib.hm.mcp.wrapEnvFilesCommand { inherit pkgs name; })
        ];
      }
    )
  ) cfg.mcp.servers;

  disabledMcpServers = builtins.attrNames (
    lib.filterAttrs (
      _: server: server.enabled == false || (server.disabled or null) == true
    ) cfg.mcp.servers
  );

  permissions =
    if cfg.permissions == null then
      null
    else
      import ./permissions.nix {
        inherit lib;
        data = cfg.permissions;
      };

  statusCommand =
    state: ''cat >/dev/null; "${config.programs.tmux.agentStatusScript}" ${state} || true'';

  notificationCommand =
    client: kind:
    let
      notification = {
        permission = {
          title = "${client}: Approval";
          message = "Permission requested";
          sound = "Funk";
        };
        input = {
          title = "${client}: Action Required";
          message = "Awaiting your input";
          sound = "Funk";
        };
      };
    in
    "${pkgs.notifycmd}/bin/notifycmd '${
      builtins.toJSON (
        {
          type = "desktop-notification";
        }
        // notification.${kind}
      )
    }'";

  statusAndNotification =
    state: client: kind:
    "${statusCommand state}; ${notificationCommand client kind}";

  stopCommand =
    client:
    "${pkgs.python3}/bin/python ${./stop-status.py} ${lib.escapeShellArg config.programs.tmux.agentStatusScript} ${pkgs.notifycmd}/bin/notifycmd ${lib.escapeShellArg client}";

  hook = command: {
    type = "command";
    inherit command;
    timeout = 5;
  };

  hookBlock = command: {
    hooks = [ (hook command) ];
  };

  matchedHookBlock = matcher: command: {
    inherit matcher;
    hooks = [ (hook command) ];
  };

  codexHooks = {
    SessionStart = [ (hookBlock (statusCommand "idle")) ];
    UserPromptSubmit = [ (hookBlock (statusCommand "running")) ];
    PreToolUse = [
      (matchedHookBlock "request_user_input|request_plugin_install|confirm_|_open_codex_api_key_setup" (
        statusAndNotification "waiting" "Codex" "input"
      ))
    ];
    PermissionRequest = [
      (hookBlock (statusAndNotification "waiting" "Codex" "permission"))
    ];
    Stop = [ (hookBlock (stopCommand "Codex")) ];
    PostToolUse = [ (hookBlock (statusCommand "running")) ];
  };

  claudeHooks = {
    SessionStart = [
      (matchedHookBlock "resume" (statusCommand "running"))
      (matchedHookBlock "startup|clear|compact" (statusCommand "idle"))
    ];
    UserPromptSubmit = [ (hookBlock (statusCommand "running")) ];
    PreToolUse = [ (matchedHookBlock "*" (statusCommand "running")) ];
    Stop = [ (hookBlock (stopCommand "Claude")) ];
    StopFailure = [ (hookBlock (statusCommand "idle")) ];
    Notification = [
      (matchedHookBlock "permission_prompt" (statusAndNotification "waiting" "Claude" "permission"))
      (matchedHookBlock "elicitation_dialog|idle_prompt" (
        statusAndNotification "waiting" "Claude" "input"
      ))
    ];
    ElicitationResult = [ (hookBlock (statusCommand "running")) ];
    SessionEnd = [ (hookBlock (statusCommand "idle")) ];
  };

  piHooks = claudeHooks // {
    Stop = [ (hookBlock (stopCommand "Pi")) ];
    Notification = [
      (matchedHookBlock "permission_prompt" (statusAndNotification "waiting" "Pi" "permission"))
      (matchedHookBlock "elicitation_dialog|idle_prompt" (statusAndNotification "waiting" "Pi" "input"))
    ];
    TurnStart = [ (hookBlock (statusCommand "running")) ];
  };
in
{
  options.programs.ai-agents = {
    enable = lib.mkEnableOption "shared AI agent configuration";

    context = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
    };

    skillSources = lib.mkOption {
      type = lib.types.attrsOf skillSourceType;
      default = { };
    };

    agentsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
    };

    permissions = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = null;
    };

    mcp.servers = lib.mkOption {
      type = lib.types.attrsOf mcpServerType;
      default = { };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = duplicateSkillNames == [ ];
            message = "programs.ai-agents has duplicate skill names: ${lib.concatStringsSep ", " duplicateSkillNames}.";
          }
        ]
        ++ lib.concatLists (
          lib.mapAttrsToList (name: server: [
            {
              assertion = (server.command != null) != (server.url != null);
              message = "programs.ai-agents.mcp.servers.${name}: exactly one of `command` or `url` must be set.";
            }
            {
              assertion = server.url == null || (server.args == [ ] && server.env == { });
              message = "programs.ai-agents.mcp.servers.${name}: `args` and `env` are only valid for local servers.";
            }
            {
              assertion = server.headers == { } || server.url != null;
              message = "programs.ai-agents.mcp.servers.${name}: `headers` is only valid for remote servers.";
            }
            {
              assertion =
                !(server.enabled != null && server ? disabled && server.disabled != null)
                || server.enabled != server.disabled;
              message = "programs.ai-agents.mcp.servers.${name}: `enabled` and `disabled` are incompatible.";
            }
          ]) cfg.mcp.servers
        );
      }

      (lib.mkIf config.programs.codex.enable {
        programs.codex = lib.mkMerge [
          {
            inherit (cfg) context;
            inherit skills;
            claudeAgentsDir = cfg.agentsDir;
            settings = {
              hooks = codexHooks;
              mcp_servers = codexMcpServers;
            };
          }
          (lib.mkIf (permissions != null) {
            rules.managed = permissions.codex.rules;
            settings = {
              default_permissions = "managed";
              permissions.managed = permissions.codex.profile;
              mcp_servers = permissions.codex.mcpServers;
            };
          })
        ];
      })

      (lib.mkIf config.programs.claude-code.enable {
        programs.claude-code = lib.mkMerge [
          {
            inherit skills;
            mcpServers = claudeMcpServers;
            desktopConfig.mcpServers = claudeMcpServers;
            settings = {
              hooks = claudeHooks;
              disabledMcpjsonServers = disabledMcpServers;
            };
          }
          (lib.mkIf (cfg.context != null) {
            inherit (cfg) context;
          })
          (lib.mkIf (cfg.agentsDir != null) {
            inherit (cfg) agentsDir;
          })
          (lib.mkIf (permissions != null) {
            settings.permissions = permissions.claude;
          })
        ];
      })

      (lib.mkIf config.programs.pi.enable {
        programs.pi = lib.mkMerge [
          {
            inherit (cfg) context;
            inherit skills;
            hooks = piHooks;
            mcp.servers = piMcpServers;
          }
          (lib.mkIf (permissions != null) {
            permissions.config = permissions.pi;
          })
        ];
      })
    ]
  );
}

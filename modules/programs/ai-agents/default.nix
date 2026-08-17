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

  inherit (cfg) skills;

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
        exclude = [
          "enabled"
          "type"
        ];
        extraTransforms = [
          (
            value:
            value
            // lib.optionalAttrs (server.enabled != null) {
              disabled = !server.enabled;
            }
          )
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
      (matchedHookBlock "request_user_input|confirm_|_open_codex_api_key_setup" (
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

  piHooks = {
    SessionStart = [
      (matchedHookBlock "resume" (statusCommand "running"))
      (matchedHookBlock "startup|clear|compact|fork" (statusCommand "idle"))
    ];
    UserPromptSubmit = [ (hookBlock (statusCommand "running")) ];
    PreToolUse = [ (matchedHookBlock "*" (statusCommand "running")) ];
    PostToolUse = [ (hookBlock (statusCommand "running")) ];
    PostToolUseFailure = [ (hookBlock (statusCommand "running")) ];
    Stop = [ (hookBlock (stopCommand "Pi")) ];
    StopFailure = [ (hookBlock (statusCommand "idle")) ];
    Notification = [
      (matchedHookBlock "permission_prompt" (statusAndNotification "waiting" "Pi" "permission"))
      (matchedHookBlock "idle_prompt" (statusAndNotification "waiting" "Pi" "input"))
    ];
    SessionEnd = [ (hookBlock (statusCommand "idle")) ];
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
        assertions = lib.concatLists (
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
        programs.pi = {
          inherit (cfg) context;
          hooks = piHooks;
          inherit skills;
          mcp.servers = piMcpServers;
        };
      })
    ]
  );
}

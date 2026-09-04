{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents;
  jsonFormat = pkgs.formats.json { };
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
      instructions = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        default = null;
        description = "Instructions exposed by the MCP server to connected clients.";
      };
      enabled = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
      };
      disabled = lib.mkOption {
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
  stringifyCommand =
    server:
    server
    // lib.optionalAttrs (lib.isDerivation (server.command or null)) {
      command = toString server.command;
    };
  wrapInstructionsCommand =
    name: server:
    let
      instructions = server.instructions or null;
      instructionsFile = pkgs.writeText "mcp-${name}-instructions" instructions;
      needsWrapping = instructions != null && server.command != null;
    in
    server
    // lib.optionalAttrs needsWrapping {
      command = pkgs.writeShellScript "mcp-${name}-instructions-wrapper" ''
        exec ${
          lib.escapeShellArgs (
            [
              "${pkgs.python3}/bin/python"
              "${./mcp_instructions.py}"
              "--instructions-file"
              instructionsFile
              "--"
              server.command
            ]
            ++ (server.args or [ ])
          )
        }
      '';
      args = [ ];
    };

  bridgeRemoteCommand =
    name: server:
    let
      headerArgs = lib.concatLists (
        lib.mapAttrsToList (header: value: [
          "--header"
          "${header}: ${value}"
        ]) (server.headers or { })
      );
    in
    if (server.url or null) == null then
      server
    else
      server
      // {
        command = pkgs.writeShellScript "mcp-${name}-remote-bridge" ''
          exec ${
            lib.escapeShellArgs (
              [
                "${pkgs.mcp-remote}/bin/mcp-remote"
                server.url
              ]
              ++ headerArgs
            )
          }
        '';
        args = [ ];
        url = null;
        headers = { };
      };

  codexMcpServers = lib.mapAttrs (
    name: server:
    mkDefaultValue (
      lib.hm.mcp.transformMcpServer {
        inherit server;
        exclude = [
          "headers"
          "instructions"
          "type"
        ];
        extraTransforms = [
          (value: value // lib.optionalAttrs (value.headers or { } != { }) { http_headers = value.headers; })
          lib.hm.mcp.addType
          (lib.hm.mcp.wrapEnvFilesCommand { inherit pkgs name; })
          (wrapInstructionsCommand name)
          stringifyCommand
        ];
      }
    )
  ) cfg.mcp.servers;

  mkClaudeMcpServers =
    { bridgeRemote }:
    lib.mapAttrs (
      name: server:
      mkDefaultValue (
        lib.hm.mcp.transformMcpServer {
          inherit server;
          exclude = [
            "enabled"
            "instructions"
          ];
          extraTransforms = lib.optional bridgeRemote (bridgeRemoteCommand name) ++ [
            lib.hm.mcp.addType
            (lib.hm.mcp.wrapEnvFilesCommand { inherit pkgs name; })
            (wrapInstructionsCommand name)
            stringifyCommand
          ];
        }
      )
    ) cfg.mcp.servers;

  claudeMcpServers = mkClaudeMcpServers { bridgeRemote = false; };
  claudeDesktopMcpServers = mkClaudeMcpServers { bridgeRemote = true; };

  piMcpServers = lib.mapAttrs (
    name: server:
    let
      enabled = lib.hm.mcp.resolveEnabled server;
      transformed = lib.hm.mcp.transformMcpServer {
        inherit server;
        exclude = [
          "enabled"
          "instructions"
          "type"
        ];
        extraTransforms = [
          (lib.hm.mcp.wrapEnvFilesCommand { inherit pkgs name; })
          (wrapInstructionsCommand name)
          stringifyCommand
        ];
      };
    in
    mkDefaultValue (transformed // lib.optionalAttrs (enabled != null) { disabled = !enabled; })
  ) cfg.mcp.servers;

  disabledMcpServers = builtins.attrNames (
    lib.filterAttrs (
      _: server: server.enabled == false || (server.disabled or null) == true
    ) cfg.mcp.servers
  );
in
{
  options.programs.ai-agents.mcp.servers = lib.mkOption {
    type = lib.types.attrsOf mcpServerType;
    default = { };
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
              assertion = server.instructions == null || server.command != null;
              message = "programs.ai-agents.mcp.servers.${name}: `instructions` is only valid for local servers.";
            }
            {
              assertion =
                !(server.enabled != null && server.disabled != null) || server.enabled != server.disabled;
              message = "programs.ai-agents.mcp.servers.${name}: `enabled` and `disabled` are incompatible.";
            }
          ]) cfg.mcp.servers
        );
      }

      (lib.mkIf config.programs.codex.enable {
        programs.codex.settings.mcp_servers = codexMcpServers;
      })

      (lib.mkIf config.programs.claude-code.enable {
        programs.claude-code = {
          mcpServers = claudeMcpServers;
          desktopConfig.mcpServers = claudeDesktopMcpServers;
          settings.disabledMcpjsonServers = disabledMcpServers;
        };
      })

      (lib.mkIf config.programs.pi.enable {
        programs.pi.mcp.servers = piMcpServers;
      })
    ]
  );
}

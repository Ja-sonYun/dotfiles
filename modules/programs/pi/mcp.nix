{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi;
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
            pkgs.tool.secretValue.type
          ]
        );
        default = { };
        description = "Server environment variables; supports { _secret = path; }.";
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
        description = "MCP server instructions.";
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

  stringifyCommand =
    server:
    server
    // lib.optionalAttrs (lib.isDerivation (server.command or null)) {
      command = toString server.command;
    };

  wrapSecretEnvCommand =
    name: server:
    let
      environment = server.env or { };
      secrets = lib.filterAttrs (_: pkgs.tool.secretValue.isSecret) environment;
    in
    server
    // lib.optionalAttrs (secrets != { } && (server.command or null) != null) {
      command = pkgs.writeShellScript "mcp-${name}-env-wrapper" ''
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (variable: value: ''
            until ${variable}="$(${pkgs.coreutils}/bin/cat -- "${value._secret}" 2>/dev/null)" \
              && [ -n "${"$" + variable}" ]; do
              ${pkgs.coreutils}/bin/sleep 1
            done
            export ${variable}
          '') secrets
        )}
        exec ${lib.escapeShellArgs ([ server.command ] ++ (server.args or [ ]))} "$@"
      '';
      args = [ ];
      env = lib.filterAttrs (_: value: !pkgs.tool.secretValue.isSecret value) environment;
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

  servers = lib.mapAttrs (
    name: server:
    lib.hm.mcp.transformMcpServer {
      inherit server;
      exclude = [ "instructions" ];
      extraTransforms = [
        (wrapSecretEnvCommand name)
        (wrapInstructionsCommand name)
        stringifyCommand
      ];
    }
  ) cfg.mcp.servers;
in
{
  options.programs.pi.mcp.servers = lib.mkOption {
    type = lib.types.attrsOf mcpServerType;
    default = { };
    description = "Pi MCP servers, with runtime secret environment and server instructions.";
  };

  config = lib.mkIf (cfg.enable && cfg.mcp.servers != { }) {
    assertions = lib.concatLists (
      lib.mapAttrsToList (name: server: [
        {
          assertion = (server.command != null) != (server.url != null);
          message = "programs.pi.mcp.servers.${name}: exactly one of `command` or `url` must be set.";
        }
        {
          assertion = server.url == null || (server.args == [ ] && server.env == { });
          message = "programs.pi.mcp.servers.${name}: `args` and `env` are only valid for local servers.";
        }
        {
          assertion = server.headers == { } || server.url != null;
          message = "programs.pi.mcp.servers.${name}: `headers` is only valid for remote servers.";
        }
        {
          assertion = server.instructions == null || server.command != null;
          message = "programs.pi.mcp.servers.${name}: `instructions` is only valid for local servers.";
        }
        {
          assertion =
            !(server.enabled != null && server.disabled != null) || server.enabled != server.disabled;
          message = "programs.pi.mcp.servers.${name}: `enabled` and `disabled` are incompatible.";
        }
      ]) cfg.mcp.servers
    );

    home.file =
      lib.genAttrs
        (
          [ ".pi/agent/mcp.json" ] ++ lib.optional (cfg.dev.extensionsSource != null) ".pi/agent-dev/mcp.json"
        )
        (_: {
          source = jsonFormat.generate "pi-mcp.json" {
            mcpServers = servers;
          };
        });
  };
}

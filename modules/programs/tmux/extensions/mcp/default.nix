{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.tmux.extensions.mcp;
  supportedKeys = [
    "Enter"
    "Tab"
    "Escape"
    "Backspace"
    "Delete"
    "Up"
    "Down"
    "Left"
    "Right"
    "Home"
    "End"
    "PageUp"
    "PageDown"
  ]
  ++ lib.genList (index: "F${toString (index + 1)}") 12
  ++ map (letter: "C-${letter}") (lib.stringToCharacters "abcdefghijklmnoprstuvwxyz");
  configFile = (pkgs.formats.json { }).generate "tmux-mcp.json" {
    inherit (cfg)
      allowedSessionPatterns
      capture
      sendKeys
      redaction
      instructions
      ;
  };
in
{
  options.programs.tmux.extensions.mcp = {
    enable = lib.mkEnableOption "tmux MCP with redacted output and restricted pane access";
    allowedSessionPatterns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Python regular expressions matched against complete session names. Empty denies all panes.";
    };
    instructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Personal tmux usage appended to the server's fixed project-scope and key-input guidance.";
    };
    capture = {
      defaultLines = lib.mkOption {
        type = lib.types.ints.positive;
        default = 200;
        description = "Default number of recent pane lines to return.";
      };
      maxLines = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5000;
        description = "Maximum requested number of recent pane lines.";
      };
      maxOutputBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 65536;
        description = "Maximum UTF-8 bytes of capture text after redaction.";
      };
    };
    sendKeys = {
      enable = lib.mkEnableOption "explicitly requested text and key input through tmux MCP";
      allowedKeys = lib.mkOption {
        type = lib.types.listOf (lib.types.enum supportedKeys);
        default = supportedKeys;
        description = "Allowed named keys. Ctrl+q and current tmux prefix keys remain prohibited.";
      };
    };
    redaction = {
      timeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Time limit for each redact invocation; failure withholds the original output.";
      };
      maxInputBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 16777216;
        description = "Maximum buffered bytes passed to redact; larger input is rejected.";
      };
    };
    server = lib.mkOption {
      type = lib.types.submodule {
        options = {
          command = lib.mkOption {
            type = lib.types.str;
          };
          args = lib.mkOption {
            type = lib.types.listOf lib.types.str;
          };
        };
      };
      readOnly = true;
      default = {
        command = lib.getExe pkgs.tmux-mcp;
        args = [
          "--config"
          (toString configFile)
        ];
      };
      description = "Shared MCP command and arguments for clients using this tmux configuration.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.programs.ai-agents.enable;
        message = "tmux MCP requires programs.ai-agents.enable.";
      }
      {
        assertion = cfg.capture.defaultLines <= cfg.capture.maxLines;
        message = "tmux MCP capture.defaultLines must not exceed capture.maxLines.";
      }
    ];
    home.packages = [ pkgs.tmux-mcp ];
    programs.ai-agents.mcp.servers.tmux = cfg.server;
  };
}

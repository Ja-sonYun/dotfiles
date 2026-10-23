{
  config,
  lib,
  pkgs,
  ...
}:
let
  tmuxRoot = config.programs.tmux.runtime;
  package = pkgs.callPackage ./package.nix {
    logSocket = if config.programs.logging.enable then config.programs.logging.socketPath else "";
  };
  command = lib.escapeShellArgs [
    (lib.getExe package)
    "${tmuxRoot}/extensions/agent/scripts/status"
  ];
  block = timeout: {
    hooks = [
      {
        type = "command";
        inherit command timeout;
      }
    ];
  };
in
{
  config = lib.mkMerge [
    (lib.mkIf
      (
        config.programs.tmux.extensions.agent.enable
        && config.programs.ai-agents.enable
        && config.programs.antigravity-cli.enable
      )
      {
        programs = {
          ai-agents.hooksByAgent.antigravity.StopFailure = [ (block 5) ];
          antigravity-cli = {
            lifecycleObserver = pkgs.writeShellScriptBin "antigravity-tmux" ''
              export TMUX_LOG_SOCKET=${
                lib.escapeShellArg (
                  if config.programs.logging.enable then config.programs.logging.socketPath else ""
                )
              }
              exec ${pkgs.python3}/bin/python3 ${./.}/antigravity.py \
                ${lib.escapeShellArg "AI_AGENT_CLIENT=Antigravity ${command}"} "$@"
            '';
            settings.statusLine = {
              type = "command";
              command = "AI_AGENT_CLIENT=Antigravity ANTIGRAVITY_STATUS_LINE=1 ${command}";
              stack_with_default = true;
            };
          };
        };
      }
    )
    (lib.mkIf (config.programs.tmux.extensions.agent.enable && config.programs.pi.enable) {
      programs.pi.extraExtensions = [
        (toString (
          pkgs.replaceVars ./pi.ts {
            statusCommand = lib.getExe package;
            statusScript = "${tmuxRoot}/extensions/agent/scripts/status";
            logSocket =
              let
                encoded = builtins.toJSON (
                  if config.programs.logging.enable then config.programs.logging.socketPath else ""
                );
              in
              builtins.substring 1 (builtins.stringLength encoded - 2) encoded;
          }
        ))
      ];
    })
    (lib.mkIf (config.programs.tmux.extensions.agent.enable && config.programs.ai-agents.enable) {
      programs = {
        ai-agents = {
          hooks =
            (lib.genAttrs [
              "SessionStart"
              "UserPromptSubmit"
              "PreToolUse"
              "PostToolUse"
              "Stop"
              "SessionEnd"
            ] (event: [ (block (if event == "SessionEnd" then 3 else 5)) ]))
            // {
              Notification = map (matcher: (block 5) // { inherit matcher; }) [
                "permission_prompt"
                "elicitation_dialog|idle_prompt"
              ];
            };
          hooksByAgent = {
            claude.StopFailure = [ (block 5) ];
          };
        };
        claude-code.statusLine.observers.tmux = lib.mkIf config.programs.claude-code.enable "AI_AGENT_CLIENT=Claude ${lib.getExe package} --statusline";
      };
    })
  ];
}

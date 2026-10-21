{
  config,
  lib,
  pkgs,
  ...
}:
let
  tmuxRoot = ../..;
  package = pkgs.callPackage ./package.nix { };
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
    (lib.mkIf (config.programs.tmux.extensions.agent.enable && config.programs.pi.enable) {
      programs.pi.extraExtensions = [
        (toString (
          pkgs.replaceVars ./pi.ts {
            statusCommand = lib.getExe package;
            statusScript = "${tmuxRoot}/extensions/agent/scripts/status";
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

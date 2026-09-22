{
  lib,
  pkgs,
  helper,
  enable,
}:
let
  hook = timeout: {
    hooks = [
      {
        type = "command";
        command = "${pkgs.python3}/bin/python ${./ai-agents.py} --hook ${helper}/bin/activity-history ${pkgs.tmux}/bin/tmux || true";
        inherit timeout;
      }
    ];
  };
in
{
  observerCommand = [
    "${pkgs.python3}/bin/python"
    "${./ai-agents.py}"
    "--observe"
    "${pkgs.tmux}/bin/tmux"
  ];
  homeManagerModule =
    { config, ... }:
    {
      config = lib.mkIf enable {
        programs = {
          ai-agents = {
            hooks = lib.genAttrs [
              "SessionStart"
              "UserPromptSubmit"
              "Stop"
              "SessionEnd"
            ] (event: [ (hook (if event == "SessionEnd" then 3 else 5)) ]);
            hooksByAgent.pi.SessionInfoChanged = [ (hook 5) ];
          };
          claude-code.statusLine.observers.activityHistory = lib.mkIf config.programs.claude-code.enable "${pkgs.python3}/bin/python ${./ai-agents.py} --statusline ${helper}/bin/activity-history ${pkgs.tmux}/bin/tmux";
        };
      };
    };
}

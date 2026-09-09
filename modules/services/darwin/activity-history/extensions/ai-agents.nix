{
  lib,
  pkgs,
  helper,
}:
{
  observerCommand = [
    "${pkgs.python3}/bin/python"
    "${./ai-agents.py}"
    "--observe"
    "${pkgs.tmux}/bin/tmux"
  ];
  homeManagerModule.programs.ai-agents.hooks =
    lib.genAttrs
      [
        "SessionStart"
        "UserPromptSubmit"
        "Stop"
      ]
      (_: [
        {
          hooks = [
            {
              type = "command";
              command = "${pkgs.python3}/bin/python ${./ai-agents.py} --hook ${helper}/bin/activity-history ${pkgs.tmux}/bin/tmux || true";
              timeout = 5;
            }
          ];
        }
      ]);
}

{
  config,
  lib,
  pkgs,
  ...
}:
let
  hooksDir = ./hooks;
  statusCommand = "${pkgs.python3}/bin/python ${hooksDir}/status.py ${lib.escapeShellArg config.programs.tmux.agentStatusScript}";
  notificationCommand = "${pkgs.python3}/bin/python ${hooksDir}/notification.py ${pkgs.notifycmd}/bin/notifycmd";

  hook = command: {
    type = "command";
    inherit command;
    timeout = 5;
  };

  hookBlock = commands: {
    hooks = map hook commands;
  };

  matchedHookBlock = matcher: commands: {
    inherit matcher;
    hooks = map hook commands;
  };

  statusHookBlock = hookBlock [ statusCommand ];
  statusAndNotificationHookBlock = hookBlock [
    statusCommand
    notificationCommand
  ];

  commonHooks = {
    SessionStart = [ statusHookBlock ];
    UserPromptSubmit = [ statusHookBlock ];
    PreToolUse = [ statusHookBlock ];
    PostToolUse = [ statusHookBlock ];
    Notification = [
      (matchedHookBlock "permission_prompt" [
        statusCommand
        notificationCommand
      ])
      (matchedHookBlock "elicitation_dialog|idle_prompt" [
        statusCommand
        notificationCommand
      ])
    ];
    Stop = [ statusAndNotificationHookBlock ];
    SessionEnd = [ statusHookBlock ];
  };
in
{
  programs.ai-agents.hooks = commonHooks;
}

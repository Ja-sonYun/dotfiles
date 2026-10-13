{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs.ai-agents.modelMap.pi =
    lib.genAttrs
      [
        "xhigh"
        "high"
        "middle"
        "low"
      ]
      (_: {
        model = "${config.programs.pi.settings.defaultProvider}/${config.programs.pi.settings.defaultModel}";
        reasoning_effort = config.programs.pi.settings.defaultThinkingLevel;
      });

  programs.pi = {
    enable = true;
    extraPath = [ pkgs.nodejs_24 ];
    dev.extensionsSource = config.lib.file.mkRepoSource {
      path = "pkgs/ai-agents/pi/extensions";
      mode = "mutable";
    };
    mcp.servers.rules.enabled = false;

    settings = {
      extensions.subagent.enable = true;
      extensions.permissions.enable = true;
      extensions.redact.enable = true;
      extensions.message-lines.enable = true;
      extensions.tool-summaries = {
        enable = true;
        provider = "lmp";
        model = "gpt-6-luna";
      };
      quietStartup = true;
      defaultProvider = "lmp";
      defaultModel = "syn:large:text";
      defaultThinkingLevel = "high";
      defaultTools = [
        "+codemode"
        "+tool_search"
      ];
      enabledModels = [
        "lmp/**"
        "openai/**"
      ];
    };

    providers.lmp = {
      name = "LMP";
      fallbackModels = [ "gpt-5.4" ];
      defaults = {
        contextWindow = 256000;
        maxTokens = 32000;
      };
      imageModelMarkers = [
        "vision"
        "image"
      ];
      nonReasoningModelMarkers = [ "image" ];
    };
  };
}

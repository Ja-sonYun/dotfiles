{
  config,
  pkgs,
  ...
}:
{
  programs.ai-agents.modelMap.pi = {
    xhigh = {
      model = "lmp/syn:large:text";
      reasoning_effort = "xhigh";
    };
    high = {
      model = "lmp/syn:large:text";
      reasoning_effort = "high";
    };
    middle = {
      model = "lmp/syn:large:text";
      reasoning_effort = "medium";
    };
    low = {
      model = "lmp/syn:large:text";
      reasoning_effort = "low";
    };
  };

  programs.pi = {
    enable = true;
    extraPath = [ pkgs.nodejs_24 ];

    settings = {
      quietStartup = true;
      defaultProvider = "lmp";
      defaultModel = "syn:large:text";
      defaultThinkingLevel = "high";
      enabledModels = [ "lmp/**" ];
    };

    providers.lmp = {
      name = "LMP";
      baseUrlEnv = "LLM_DOMAIN";
      apiKeyEnv = "CAPI_KEY";
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

    envFiles = {
      CAPI_KEY = config.age.secrets."capi-key".path;
      LLM_DOMAIN = config.age.secrets."llm-domain".path;
    };

    extensions.subagent = "${pkgs.pi-extensions.subagent}/extension";
  };
}

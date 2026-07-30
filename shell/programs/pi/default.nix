{
  config,
  pkgs,
  ...
}:
{
  programs.pi = {
    enable = true;

    settings = {
      quietStartup = true;
      defaultProvider = "lmp";
      defaultModel = "syn:large:text";
      defaultThinkingLevel = "high";
      enabledModels = [ "lmp/**" ];
    };

    extensions = {
      lmp = pkgs.pi-extensions.lmp;
    };

    mcp.settings = {
      toolPrefix = "server";
      idleTimeout = 10;
    };

    permissions.enable = true;

    envFiles = {
      CAPI_KEY = config.age.secrets."capi-key".path;
      LLM_DOMAIN = config.age.secrets."llm-domain".path;
    };
  };
}

{
  config,
  pkgs,
  agenix-secrets,
  ...
}:
{
  imports = [ "${agenix-secrets}/modules/ai-bundle/pi" ];

  programs.pi = {
    enable = true;
    enableMcpIntegration = true;

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
      AI_ADDRESS = config.age.secrets."ai-address".path;
    };
  };
}

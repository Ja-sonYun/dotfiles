{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs = {
    claude-desktop.enable = pkgs.stdenv.hostPlatform.isDarwin;

    ai-agents.modelMap.claude = {
      xhigh = {
        model = "claude-fable-5-1";
        reasoning_effort = "xhigh";
      };
      high = {
        model = "claude-opus-5-5";
        reasoning_effort = "high";
      };
      middle = {
        model = "claude-sonnet-5";
        reasoning_effort = "low";
      };
      low = {
        model = "claude-haiku-4-5-20251001";
      };
    };

    claude-code = {
      enable = true;
      statusLine.enable = true;
      defaultProfileName = "claude-1";
      chromeNativeHost.enable = true;

      mcpServers.antigravity =
        lib.mkIf
          (
            pkgs.stdenv.hostPlatform.system == "aarch64-darwin"
            && config.programs.antigravity-cli.enable
            && config.programs.antigravity-cli.package != null
          )
          {
            command = lib.getExe pkgs.antigravity-mcp;
            env.ANTIGRAVITY_EXECUTABLE = "${config.programs.antigravity-cli.package}/bin/agy";
          };

      instances = {
        claude-1 = {
          home = ".claude";
        };
        claude-work = {
          home = ".claude-work";
        };
      };

      settings = {
        disabledMcpjsonServers = [
          "rea"
          "r2mcp"
        ];
        alwaysThinkingEnabled = true;
        attribution = {
          commit = "";
          pr = "";
        };
        language = "korean";
        promptSuggestionEnabled = false;
        effortLevel = "high";
      };
    };
  };
}

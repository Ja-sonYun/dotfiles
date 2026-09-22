{ pkgs, ... }:
{
  programs = {
    claude-desktop.enable = pkgs.stdenv.hostPlatform.isDarwin;

    ai-agents.modelMap.claude = {
      xhigh = {
        model = "claude-fable-5-1";
        reasoning_effort = "xhigh";
      };
      high = {
        model = "claude-opus-5";
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

      instances = {
        claude-1 = {
          home = ".claude";
        };
        claude-work = {
          home = ".claude-work";
        };
      };

      settings = {
        alwaysThinkingEnabled = true;
        attribution = {
          commit = "";
          pr = "";
        };
        language = "korean";
        promptSuggestionEnabled = false;
        effortLevel = "high";
      };

      keybindings = {
        bindings = [
          {
            context = "Scroll";
            bindings = {
              "ctrl+u" = "scroll:halfPageUp";
              "ctrl+n" = "scroll:halfPageDown";
            };
          }
        ];
      };
    };
  };
}

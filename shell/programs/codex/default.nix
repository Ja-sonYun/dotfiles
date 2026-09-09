{
  hasTag,
  lib,
  ...
}:
{
  programs.ai-agents.modelMap.codex = {
    xhigh = {
      model = "gpt-6-astra";
      reasoning_effort = "xhigh";
    };
    high = {
      model = "gpt-6-astra";
      reasoning_effort = "medium";
    };
    middle = {
      model = "gpt-6-astra";
      reasoning_effort = "low";
    };
    low = {
      model = "gpt-5.6-luna";
      reasoning_effort = "medium";
    };
  };

  programs.codex = {
    enable = true;
    defaultProfileName = "codex-1";

    instances = {
      codex-2 = {
        home = ".codex2";
        shareWith = ".codex";
      };
      codex-work = {
        home = ".codex-work";
      };
    };

    toolGuard.computer-use = lib.mkIf (!hasTag "unsafe-ai") {
      matcher = "^mcp__cua_repl__";
    };

    settings = {
      model = "gpt-6-astra";
      model_reasoning_effort = "medium";
      plan_mode_reasoning_effort = "xhigh";
      model_verbosity = "low";

      approval_policy = "on-request";

      suppress_unstable_features_warning = true;
      check_for_update_on_startup = false;
      hide_rate_limit_model_nudge = true;

      file_opener = "none";

      web_search = "live";

      # service_tier = "fast";

      features = {
        unified_exec = true;
        shell_snapshot = true;
        multi_agent = true;
        personality = true;
        skill_mcp_dependency_install = false;
        memories = false;
      };

      agents = {
        max_threads = 10;
      };

      tui = {
        alternate_screen = "always";
        status_line = [
          "context-remaining"
          "current-dir"
          "model-with-reasoning"
        ];
        show_tooltips = false;
        keymap = {
          pager = {
            half_page_up = "ctrl-u";
            half_page_down = "ctrl-n";
          };
        };
      };

      feedback = {
        enabled = false;
      };
    };
  };
}

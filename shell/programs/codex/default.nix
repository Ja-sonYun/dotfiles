{
  pkgs,
  config,
  ...
}:
let
  codexLmp = pkgs.writeShellScriptBin "codex-lmp" ''
    set -euo pipefail

    llm_domain="$(${pkgs.coreutils}/bin/cat ${
      config.age.secrets."llm-domain".path
    } 2>/dev/null || true)"
    export LLM_DOMAIN="$llm_domain"
    export CAPI_KEY="$(${pkgs.coreutils}/bin/cat ${
      config.age.secrets."capi-key".path
    } 2>/dev/null || true)"

    if [ -n "$llm_domain" ]; then
      exec codex \
        --config "model_provider=\"lmp\"" \
        --config "model_providers.lmp.base_url=\"''${llm_domain%/}/v1\"" \
        --model "syn:large:text" \
        "$@"
    fi

    exec codex "$@"
  '';
in
{
  programs.codex = {
    enable = true;
    extraPath = [
      pkgs.aws-ro
      pkgs.gh-ro
      pkgs.uv
    ];

    settings = {
      model = "gpt-5.6-sol";
      model_reasoning_effort = "xhigh";
      plan_mode_reasoning_effort = "xhigh";
      model_verbosity = "low";

      approval_policy = "on-request";

      suppress_unstable_features_warning = true;
      check_for_update_on_startup = false;
      hide_rate_limit_model_nudge = true;

      file_opener = "none";

      web_search = "live";

      service_tier = "fast";

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

      model_providers.lmp = {
        name = "LMP";
        base_url = "$LLM_DOMAIN/v1";
        wire_api = "responses";
        env_key = "CAPI_KEY";
      };
    };
  };

  home.packages = [ codexLmp ];
}

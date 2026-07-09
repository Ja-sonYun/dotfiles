{
  pkgs,
  config,
  agenix-secrets,
  ...
}:
let
  nodeOnly = pkgs.runCommand "nodejs-24-node-only" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.nodejs_24}/bin/node $out/bin/node
  '';

  codex = pkgs.codex.override {
    extraPath = [
      nodeOnly
    ];
  };

  codexLmp = pkgs.writeShellScriptBin "codex-lmp" ''
    set -euo pipefail

    ai_address="$(${pkgs.coreutils}/bin/cat ${
      config.age.secrets."ai-address".path
    } 2>/dev/null || true)"
    export AI_ADDRESS="$ai_address"
    export CAPI_KEY="$(${pkgs.coreutils}/bin/cat ${
      config.age.secrets."capi-key".path
    } 2>/dev/null || true)"

    if [ -n "$ai_address" ]; then
      exec ${codex}/bin/codex \
        --profile ${config.programs.codex.profileName} \
        --config "projects.\"$PWD\".trust_level=\"trusted\"" \
        --config "model_provider=\"lmp\"" \
        --config "model_providers.lmp.base_url=\"''${ai_address%/}/v1\"" \
        --model "syn:large:text" \
        "$@"
    fi

    exec ${codex}/bin/codex \
      --profile ${config.programs.codex.profileName} \
      --config "projects.\"$PWD\".trust_level=\"trusted\"" \
      "$@"
  '';
in
{
  imports = [ "${agenix-secrets}/modules/ai-bundle/codex" ];

  programs.codex = {
    enable = true;
    package = codex;
    enableMcpIntegration = true;

    settings = {
      model = "gpt-5.5";
      model_reasoning_effort = "xhigh";
      plan_mode_reasoning_effort = "xhigh";
      model_verbosity = "medium";
      developer_instructions = ''
        # Response Readability

        Write final answers so they are easy to understand on the first read.

        - Start with the direct answer or outcome
        - Use short paragraphs by default
        - Use bullets only when they improve scanning
        - Use Markdown tables for comparisons, options, tradeoffs, file lists, command results, and before/after summaries
        - Use small ASCII diagrams for architecture, data flow, dependency relationships, or multi-step flows when they clarify the explanation
        - Keep diagrams compact and label nodes/edges clearly
        - Do not use a table or diagram for simple confirmations, one-step answers, or cases where plain text is clearer
        - Prefer plain Markdown that renders well in a terminal
        - Avoid decorative formatting, long templates, and repeated caveats
        - For code changes, mention what changed, where, and whether verification ran
      '';

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
        notifications = [
          "plan-mode-prompt"
        ];
        notification_method = "osc9";
        notification_condition = "always";
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
        base_url = "$AI_ADDRESS/v1";
        wire_api = "responses";
        env_key = "CAPI_KEY";
      };

      mcp_servers = {
        claude = {
          command = "${config.home.profileDirectory}/bin/claude";
          args = [
            "mcp"
            "serve"
          ];
          env = { };
        };
      };
    };
  };

  home.packages = [ codexLmp ];
}

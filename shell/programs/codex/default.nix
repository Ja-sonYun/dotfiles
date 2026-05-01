{ pkgs
, lib
, config
, agenix-secrets
, ...
}:
let
  pythonWithPackages = pkgs.python313.withPackages (ps: [
  ]);

  nodeOnly = pkgs.runCommand "nodejs-24-node-only" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.nodejs_24}/bin/node $out/bin/node
  '';

  codexPath = [
    nodeOnly
    pythonWithPackages
  ];

  codexWrapped = pkgs.symlinkJoin {
    name = "codex-wrapped-${lib.getVersion pkgs.codex}";
    paths = [ pkgs.codex ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      rm -f $out/bin/.codex-wrapped
      wrapProgram $out/bin/codex \
        --prefix PATH : "${lib.makeBinPath codexPath}" \
        --prefix PATH : "$out/bin" \
        --prefix PYTHONPATH : "${pythonWithPackages}/${pythonWithPackages.sitePackages}"
    '';
  };

  notifierScript = pkgs.writeShellScript "codex-notifier-script" ''
    export PATH="$PATH:${pkgs.terminal-notifier}/bin"
    ${pythonWithPackages}/bin/python ${toString ./notify.py} "$@"
  '';

  aiBundle = import "${agenix-secrets}/ai-bundle.nix" { inherit pkgs; };
in
{
  programs.codex = {
    enable = true;
    package = codexWrapped;
    enableMcpIntegration = true;

    settings = {
      model = "gpt-5.5";
      model_reasoning_effort = "high";
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
      sandbox_mode = "workspace-write";

      suppress_unstable_features_warning = true;
      check_for_update_on_startup = false;

      notify = [ "${notifierScript}" ];
      file_opener = "none";

      web_search = "live";

      profile = "deep-fast";

      sandbox_workspace_write = {
        network_access = true;
      };

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
        status_line = [
          "model-with-reasoning"
          "context-remaining"
          "current-dir"
          "model-name"
          "git-branch"
          "five-hour-limit"
          "weekly-limit"
        ];
      };

      profiles = {
        fast = {
          service_tier = "fast";
          model_reasoning_effort = "low";
        };
        deep = {
          service_tier = "flex";
          model_reasoning_effort = "high";
        };
        deep-fast = {
          service_tier = "fast";
          model_reasoning_effort = "high";
        };
      };

      feedback = {
        enabled = false;
      };

      mcp_servers = {
        claude = {
          command = "${config.home.profileDirectory}/bin/claude";
          args = [ "mcp" "serve" ];
          env = { };
        };
      };

    };

    context = builtins.readFile aiBundle.agentsMdSrc;

    skills = builtins.mapAttrs
      (name: _: aiBundle.skillsSrc + "/${name}")
      (builtins.readDir aiBundle.skillsSrc);

    rules = {
      managed = ./rules/managed.rules;
    };
  };

  home.file = {
    ".codex/agents" = {
      source = aiBundle.agentsSrc;
      recursive = true;
      force = true;
    };
  };
}

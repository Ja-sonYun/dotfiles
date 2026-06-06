{
  pkgs,
  lib,
  config,
  agenix-secrets,
  ...
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

  codexConfigDir = ".codex-cli";
  codexConfigGuiDir = ".codex";
  codexHome = "${config.home.homeDirectory}/${codexConfigDir}";
  skillsDir = "${codexConfigDir}/skills";
  tomlFormat = pkgs.formats.toml { };

  codexWrapped = pkgs.symlinkJoin {
    name = "codex-wrapped-${lib.getVersion pkgs.codex}";
    paths = [ pkgs.codex ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      rm -f $out/bin/.codex-wrapped
      wrapProgram $out/bin/codex \
        --set CODEX_HOME "${codexHome}" \
        --prefix PATH : "${lib.makeBinPath codexPath}" \
        --prefix PATH : "$out/bin" \
        --prefix PYTHONPATH : "${pythonWithPackages}/${pythonWithPackages.sitePackages}" \
        --run "set -- --config 'projects.''''\"\$PWD\"''''.trust_level=\"trusted\"'"
    '';
  };

  notifierScript = pkgs.writeShellScript "codex-notifier-script" ''
    export PATH="$PATH:${pkgs.terminal-notifier}/bin"
    ${pythonWithPackages}/bin/python ${toString ./notify.py} "$@"
  '';

  aiBundle = import "${agenix-secrets}/ai-bundle.nix" { inherit pkgs; };

  codexHooks = import ./hooks.nix {
    inherit
      pkgs
      lib
      config
      agenix-secrets
      codexHome
      ;
  };

  codexSettings = {
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
    sandbox_mode = "workspace-write";

    suppress_unstable_features_warning = true;
    check_for_update_on_startup = false;

    notify = [ "${notifierScript}" ];
    file_opener = "none";

    web_search = "live";

    service_tier = "fast";

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
        "context-remaining"
        "current-dir"
        "model-with-reasoning"
      ];
      notifications = [
        "plan-mode-prompt"
      ];
      notification_method = "bel";
      notification_condition = "unfocused";
    };

    feedback = {
      enabled = false;
    };

    hooks = codexHooks;

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

  codexContext =
    (pkgs.lib.trim (builtins.readFile aiBundle.agentsMdSrc))
    + "\n\n@${codexHome}/RTK.md\n";

  codexSkills = builtins.mapAttrs (name: _: aiBundle.skillsSrc + "/${name}") (
    builtins.readDir aiBundle.skillsSrc
  );

  codexRules = {
    managed = ./rules/managed.rules;
  };

  mkSkillEntry = name: source: lib.nameValuePair "${skillsDir}/${name}" { inherit source; };

  mkRuleEntry =
    name: source:
    lib.nameValuePair "${codexConfigDir}/rules/${name}.rules" { inherit source; };

  transformedMcpServers = lib.optionalAttrs config.programs.mcp.enable (
    lib.mapAttrs (
      _name: server:
      (lib.removeAttrs server [
        "disabled"
        "headers"
      ])
      // (lib.optionalAttrs (server ? headers && !(server ? http_headers)) {
        http_headers = server.headers;
      })
      // {
        enabled = !(server.disabled or false);
      }
    ) config.programs.mcp.servers
  );

  settingMcpServers = lib.attrByPath [ "mcp_servers" ] { } codexSettings;
  mergedMcpServers = transformedMcpServers // settingMcpServers;
  mergedSettings =
    codexSettings // lib.optionalAttrs (mergedMcpServers != { }) { mcp_servers = mergedMcpServers; };
in
{
  home.packages = [ codexWrapped ];

  home.file =
    {
      "${codexConfigDir}/config.toml".source = tomlFormat.generate "codex-config" mergedSettings;
      "${codexConfigDir}/AGENTS.md".text = codexContext;
      "${codexConfigGuiDir}/AGENTS.md".text = codexContext;

      "${codexConfigDir}/agents" = {
        source = aiBundle.agentsSrc;
        recursive = true;
        force = true;
      };
    }
    // lib.mapAttrs' mkSkillEntry codexSkills
    // lib.mapAttrs' mkRuleEntry codexRules;
}

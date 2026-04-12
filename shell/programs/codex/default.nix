{ pkgs
, lib
, config
, agenix-secrets
, ...
}:
let
  pythonWithPackages = pkgs.python313.withPackages (ps: [
    ps.libtmux
    ps.pydantic
    ps.pydantic-settings
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
      rm $out/bin/.codex-wrapped
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
      model = "gpt-5.4";
      model_reasoning_effort = "high";

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
          "context-used"
          "context-window-size"
          "used-tokens"
          "total-output-tokens"
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

    };

    custom-instructions = builtins.readFile aiBundle.agentsMdSrc;

    skills = builtins.mapAttrs
      (name: _: aiBundle.skillsSrc + "/${name}")
      (builtins.readDir aiBundle.skillsSrc);

    rules = {
      default = ./rules/default.rules;
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

{ pkgs
, lib
, config
, agenix-secrets
, ...
}:
let
  genCodexMcpServer = server: ''
    [mcp_servers.${server.name}]
    ${if server ? url then ''
      url = "${server.url}"
    '' else ''
      command = "${server.command}"
      args = ${builtins.replaceStrings [ ''":"'' ] [ ''"="'' ] (builtins.toJSON server.args)}
      env = ${builtins.replaceStrings [ ''":"'' ] [ ''"="'' ] (builtins.toJSON server.env)}
    ''}
    ${lib.optionalString (server ? enabled) "enabled = ${lib.boolToString server.enabled}"}
  '';

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
    name = "codex-wrapped";
    paths = [ pkgs.codex ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
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

  mcpServers = [
    {
      name = "context7";
      command = pkgs.writeShellScript "context7-mcp-wrapper" ''
        ${pkgs.context7}/bin/context7-mcp \
          --api-key "$(cat ${config.age.secrets.context7-api-key.path})"
      '';
      args = [ ];
      env = { };
    }
    {
      name = "chrome-devtools";
      command = "${pkgs.chrome-devtools-mcp}/bin/chrome-devtools-mcp";
      args = [ ];
      env = { };
      enabled = false;
    }
    {
      name = "aws-documentation";
      command = "${pkgs.aws-documentation}/bin/awslabs.aws-documentation-mcp-server";
      args = [ ];
      env = { };
      enabled = false;
    }
    {
      name = "awsdac";
      command = "${pkgs.awsdac}/bin/awsdac-mcp-server";
      args = [ ];
      env = { };
      enabled = false;
    }
    {
      name = "terraform";
      command = "${pkgs.terraform-mcp-server}/bin/terraform-mcp-server";
      args = [ "stdio" ];
      env = { };
      enabled = false;
    }
    {
      name = "websearch";
      command = pkgs.writeShellScript "firecrawl-mcp-wrapper" ''
        export FIRECRAWL_API_URL="https://firecrawl.test0.zip"
        export FIRECRAWL_API_KEY="$(cat ${config.age.secrets.capi-key.path})"
        exec ${pkgs.firecrawl-mcp}/bin/firecrawl-mcp
      '';
      args = [ ];
      env = { };
    }
    {
      name = "grep_app";
      url = "https://mcp.grep.app";
    }
  ];

  codexMcpServersConfig = lib.concatMapStringsSep "\n" genCodexMcpServer mcpServers;
in
{
  home.packages = [
    codexWrapped
  ];

  home.activation.installCodexSkills = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target="$HOME/.agents/skills"

    mkdir -p "$HOME/.agents"
    if [ -e "$target" ]; then
      find "$target" -type d -exec chmod u+w {} +
      rm -rf "$target"
    fi
    cp -RpL "${aiBundle.skillsSrc}" "$target"

    find "$target" -type d -exec chmod 0555 {} +
    find "$target" -type f -exec chmod 0444 {} +
    find "$target" -type f -perm /111 -exec chmod 0555 {} +
  '';

  home.file = {
    ".codex/AGENTS.md" = {
      source = aiBundle.agentsMdSrc;
      force = true;
    };
    ".codex/agents" = {
      source = aiBundle.agentsSrc;
      recursive = true;
      force = true;
    };
    "codex-config.toml" = {
      target = ".codex/config.toml";
      force = true;
      text = ''
        model = "gpt-5.4"
        model_reasoning_effort = "high"

        approval_policy = "on-request"
        sandbox_mode = "workspace-write"

        suppress_unstable_features_warning = true

        notify = ["${notifierScript}"]
        file_opener = "none"

        web_search = "live"

        profile = "deep-fast"

        [sandbox_workspace_write]
        network_access = true

        [features]
        unified_exec = true
        shell_snapshot = true
        multi_agent = true
        personality = true
        skill_mcp_dependency_install = false

        [agents]
        max_threads = 10

        [tui]
        status_line = ["model-with-reasoning", "context-remaining", "current-dir", "model-name", "git-branch", "context-used", "context-window-size", "used-tokens", "total-output-tokens", "five-hour-limit", "weekly-limit"]

        [profiles.fast]
        service_tier = "fast"
        model_reasoning_effort = "low"

        [profiles.deep]
        service_tier = "flex"
        model_reasoning_effort = "high"

        [profiles.deep-fast]
        service_tier = "fast"
        model_reasoning_effort = "high"

        [feedback]
        enabled = false

        ${codexMcpServersConfig}
      '';
    };
  };
}

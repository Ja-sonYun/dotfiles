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

  codexBundleSrc = "${agenix-secrets}/ai-bundle";
  codexBundleEntries = builtins.readDir codexBundleSrc;

  codexBundleFiles = lib.listToAttrs (
    map
      (name: {
        name = ".codex/${name}";
        value = {
          source = codexBundleSrc + "/${name}";
          force = true;
        }
        // lib.optionalAttrs (codexBundleEntries.${name} == "directory") { recursive = true; };
      })
      (builtins.attrNames codexBundleEntries)
  );

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

  # Remove this when codex supports specifying skills directory via linking
  home.activation.codexSkillsOverride = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -euo pipefail
    target="$HOME/.codex/skills"
    rm -rf "$target"
    mkdir -p "$HOME/.codex"
    ${pkgs.coreutils}/bin/cp -aL "${codexBundleSrc}/skills" "$target"
    exec_list="$(${pkgs.coreutils}/bin/mktemp)"
    ${pkgs.findutils}/bin/find "$target" -type f -perm /111 -print0 > "$exec_list"
    ${pkgs.findutils}/bin/find "$target" -type d -exec ${pkgs.coreutils}/bin/chmod 0755 {} +
    ${pkgs.findutils}/bin/find "$target" -type f -exec ${pkgs.coreutils}/bin/chmod 0444 {} +
    if [ -s "$exec_list" ]; then
      while IFS= read -r -d $'\0' file; do
        ${pkgs.coreutils}/bin/chmod 0555 "$file"
      done < "$exec_list"
    fi
    ${pkgs.coreutils}/bin/rm -f "$exec_list"
  '';

  home.file = codexBundleFiles // {
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
        max_depth = 1

        [tui]
        status_line = ["model-with-reasoning", "context-remaining", "current-dir", "model-name", "git-branch", "context-used", "context-window-size", "used-tokens", "total-output-tokens", "five-hour-limit", "weekly-limit"]

        [profiles.fast]
        model_reasoning_effort = "low"

        [profiles.deep]
        model_reasoning_effort = "high"

        [feedback]
        enabled = false

        ${codexMcpServersConfig}
      '';
    };
  };
}

{ pkgs
, lib
, config
, agenix-secrets
, ...
}:
let
  mcpServers = {
    github = {
      command = pkgs.writeShellScript "github-mcp-wrapper" ''
        export GITHUB_PERSONAL_ACCESS_TOKEN=$(cat ${config.age.secrets.github-token.path})
        exec docker run -i --rm \
          -e GITHUB_PERSONAL_ACCESS_TOKEN \
          ghcr.io/github/github-mcp-server
      '';
      args = [ ];
      env = { };
      transportType = "stdio";
      autoApprove = [
        "get_file_contents"
        "search_repositories"
        "search_code"
      ];
    };
    context7 = {
      command = pkgs.writeShellScript "context7-mcp-wrapper" ''
        ${pkgs.context7}/bin/context7-mcp \
          --api-key "$(cat ${config.age.secrets.context7-api-key.path})"
      '';
      args = [ ];
      env = { };
      transportType = "stdio";
      autoApprove = [
        "resolve-library-id"
        "get-library-docs"
      ];
    };
    chrome-devtools = {
      command = "${pkgs.chrome-devtools-mcp}/bin/chrome-devtools-mcp";
      args = [ ];
      env = { };
      transportType = "stdio";
      autoApprove = [ ];
    };
    # playwright = {
    #   command = "${pkgs.playwright-mcp}/bin/mcp-server-playwright";
    #   args = [ ];
    #   env = { };
    #   transportType = "stdio";
    #   autoApprove = [ ];
    # };
    aws-documentation = {
      command = "${pkgs.aws-documentation}/bin/awslabs.aws-documentation-mcp-server";
      args = [ ];
      env = { };
      transportType = "stdio";
      autoApprove = [
        "read_documentation"
        "search_documentation"
        "recommend"
      ];
    };
    terraform = {
      command = "${pkgs.terraform-mcp-server}/bin/terraform-mcp-server";
      args = [ "stdio" ];
      env = { };
      transportType = "stdio";
      autoApprove = [ ];
    };
    codex = {
      command = "${pkgs.codex}/bin/codex";
      args = [ "mcp-server" ];
      env = { };
      transportType = "stdio";
      autoApprove = [ ];
    };
  };

  settings = {
    permissions = {
      allow = [
        "WebSearch"
        "WebFetch(domain:*)"
        "Read(**)"
        "Bash(git status:*)"
        "Bash(git diff:*)"
        "Bash(git log:*)"
        "Bash(git show:*)"
        "Bash(ls :*)"
        "Bash(cat :*)"
        "Bash(rg:*)"
        "Bash(find :*)"
        "Bash(grep :*)"
        "Bash(tail :*)"
        "Bash(head :*)"
        "Bash(echo :*)"
        "Bash(jq :*)"
        "Bash(yq :*)"
        "Bash(make:*)"
        "Bash(nix build:*)"
        "Bash(nix log:*)"
        "Bash(nix flake lock:*)"
        "Skill(diagram:*)"
        "Skill(python:*)"
      ];
      deny = [
        "Read(./.env)"
        "Read(./.env.*)"
      ];
    };
    alwaysThinkingEnabled = true;
    hooks = {
      Notification = [
        {
          matcher = "permission_prompt";
          hooks = [
            {
              type = "command";
              command = "${pkgs.terminal-notifier}/bin/terminal-notifier -title 'cc' -message 'Permission requested' -sound Funk";
            }
          ];
        }
        {
          matcher = "idle_prompt";
          hooks = [
            {
              type = "command";
              command = "${pkgs.terminal-notifier}/bin/terminal-notifier -title 'cci' -message 'Awaiting your input' -sound Funk";
            }
          ];
        }
      ];
    };
  };
  managedSettingsFile = pkgs.writeText "claude-managed-settings.json" (builtins.toJSON settings);
  managedClaudeJson = pkgs.writeText "claude-managed.json" (
    builtins.toJSON {
      inherit mcpServers;
      language = "korean";
    }
  );

  claudeBundleSrc = "${agenix-secrets}/claude-bundle";
  claudeBundleEntries = builtins.readDir claudeBundleSrc;

  claudeBundleFiles = lib.listToAttrs (
    map
      (name: {
        name = ".claude/${name}";
        value = {
          source = claudeBundleSrc + "/${name}";
        }
        // lib.optionalAttrs (claudeBundleEntries.${name} == "directory") { recursive = true; };
      })
      (builtins.attrNames claudeBundleEntries)
  );
in
{
  home.packages = [
    pkgs.claude-code
  ];

  home.file = claudeBundleFiles // {
    ".claude/nix/settings.json" = {
      text = builtins.toJSON settings;
      force = true;
    };
    "Library/Application Support/Claude/claude_desktop_config.json" = {
      target = "Library/Application Support/Claude/claude_desktop_config.json";
      force = true;
      text = builtins.toJSON {
        inherit mcpServers;
      };
    };
  };

  home.activation.inject-claude-code-mcp = lib.hm.dag.entryAfter [ "installPackages" ] ''
    ${pkgs.python3}/bin/python3 ${./merge-claude-json.py} \
    ~/.claude.json \
    ${managedClaudeJson}
  '';

  home.activation.inject-claude-code-settings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    ${pkgs.python3}/bin/python3 ${./merge-claude-settings.py} \
    ~/.claude/settings.json \
    ${managedSettingsFile} \
    ~/.claude/nix/settings.json
  '';
}

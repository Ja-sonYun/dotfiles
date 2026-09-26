{
  custom-packages = final: _prev: {
    agenix-utils = final.callPackage ../libs/nixlib/pkg/agenix-utils { };

    claude-code = final.callPackage ../pkgs/ai-agents/claude-code { };
    codex = final.callPackage ../pkgs/ai-agents/codex { };
    pi = final.callPackage ../pkgs/ai-agents/pi { };
    pi-extensions = import ../pkgs/ai-agents/pi/extensions.nix { pkgs = final; };

    aws-ro = final.callPackage ../pkgs/ai-tools/aws-ro { };
    dcf = final.callPackage ../pkgs/ai-tools/dcf { };
    gh-ro = final.callPackage ../pkgs/ai-tools/gh-ro { };
    jev = final.callPackage ../pkgs/ai-tools/jev { };
    open-code-review = final.callPackage ../pkgs/ai-tools/open-code-review { };
    redact = final.callPackage ../pkgs/ai-tools/redact { };
    sed-readonly = final.callPackage ../pkgs/ai-tools/sed { };
    shell-assistant = final.callPackage ../pkgs/ai-tools/shell-assistant { };
    whisper-local = final.callPackage ../pkgs/ai-tools/whisper-local { };

    git-extend = final.callPackage ../pkgs/cli-tools/git-extend { };
    mermaid-ascii = final.callPackage ../pkgs/cli-tools/mermaid-ascii { };
    state-get = final.callPackage ../pkgs/cli-tools/state-get { };
    templates-cli = final.callPackage ../pkgs/cli-tools/templates-cli { };
    tmux-menu = final.callPackage ../pkgs/cli-tools/tmux-menu { };

    awsdac = final.callPackage ../pkgs/cloud/awsdac { };
    cf-tunnel = final.callPackage ../pkgs/cloud/cf-tunnel { };

    dismiss-notifications = final.callPackage ../pkgs/darwin/dismiss-notifications { };
    icalPal = final.callPackage ../pkgs/darwin/icalPal { };
    macism = final.callPackage ../pkgs/darwin/macism { };
    macnotesapp = final.callPackage ../pkgs/darwin/macnotesapp { };
    notifycmd = final.callPackage ../pkgs/darwin/notifycmd { };
    rotate-input-source = final.callPackage ../pkgs/darwin/rotate-input-source { };
    select-input-source = final.callPackage ../pkgs/darwin/select-input-source { };
    yabai = final.callPackage ../pkgs/darwin/yabai { };

    local-fonts = final.callPackage ../pkgs/fonts/local-fonts { };

    aws-documentation-mcp-server = final.callPackage ../pkgs/mcp/aws-documentation-mcp-server { };
    chrome-devtools-mcp = final.callPackage ../pkgs/mcp/chrome-devtools-mcp { };
    context7 = final.callPackage ../pkgs/mcp/context7 { };
    exa-mcp-server = final.callPackage ../pkgs/mcp/exa-mcp-server { };
    firecrawl-mcp = final.callPackage ../pkgs/mcp/firecrawl-mcp { };
    freecad-mcp = final.callPackage ../pkgs/mcp/freecad-mcp { };
    mcp-remote = final.callPackage ../pkgs/mcp/mcp-remote { };
    n8n-mcp = final.callPackage ../pkgs/mcp/n8n-mcp { };

    r2dec = final.callPackage ../pkgs/radare2/r2dec { };
    r2ghidra = final.callPackage ../pkgs/radare2/r2ghidra { };
  };
}

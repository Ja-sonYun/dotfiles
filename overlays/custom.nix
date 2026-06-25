{ hostname, ... }:
{
  custom-packages-hashfile =
    final: _prev:
    let
      rawhashfile = builtins.readFile ../pkgs/hashfile.json;
      allhashfile = builtins.fromJSON rawhashfile;
      currentHostHashfile = allhashfile.${hostname} or { };
      fakeHash = final.lib.fakeSha256;
    in
    {
      hashfile = {
        raw = currentHostHashfile;
        all = allhashfile;
        get =
          { hashKey, packageVersion }:
          let
            entry = currentHostHashfile.${hashKey} or null;
          in
          if entry == null || !(builtins.isAttrs entry) || !(entry ? version) || !(entry ? hash) then
            fakeHash
          else if entry.version == null || entry.hash == null || entry.version == "" || entry.hash == "" then
            fakeHash
          else if entry.version != packageVersion then
            fakeHash
          else
            entry.hash;
      };
    };

  custom-packages = final: _prev: {
    # Local custom packages
    git-wrapped = final.callPackage ../pkgs/git-wrapped { };
    awscli-local = final.callPackage ../pkgs/awscli-local { };
    macnotesapp = final.callPackage ../pkgs/macnotesapp { };
    cf-tunnel = final.callPackage ../pkgs/cf-tunnel { };
    agenix-utils = final.callPackage ../libs/nixlib/pkg/agenix-utils { };

    # Npm
    claude-code = final.callPackage ../pkgs/claude-code { };
    codex = final.callPackage ../pkgs/codex { };
    open-code-review = final.callPackage ../pkgs/open-code-review { };
    context7 = final.callPackage ../pkgs/context7 { };
    chrome-devtools-mcp = final.callPackage ../pkgs/chrome-devtools-mcp { };
    exa-mcp-server = final.callPackage ../pkgs/exa-mcp-server { };
    firecrawl-mcp = final.callPackage ../pkgs/firecrawl-mcp { };
    n8n-mcp = final.callPackage ../pkgs/n8n-mcp { };
    pi = final.callPackage ../pkgs/pi { };
    ponytail = final.callPackage ../pkgs/ponytail { };
    pi-subagents = final.callPackage ../pkgs/pi-extensions/pi-subagents { };
    pi-permission-system = final.callPackage ../pkgs/pi-extensions/pi-permission-system { };
    pi-mcp-adapter = final.callPackage ../pkgs/pi-extensions/pi-mcp-adapter { };
    piolium = final.callPackage ../pkgs/pi-extensions/piolium { };
    pi-lens = final.callPackage ../pkgs/pi-extensions/pi-lens { };

    # Pypi
    aws-documentation = final.callPackage ../pkgs/aws-documentation { };

    # Cargo
    tmux-menu = final.callPackage ../pkgs/tmux-menu { };

    # Go
    awsdac = final.callPackage ../pkgs/awsdac { };
    mermaid-ascii = final.callPackage ../pkgs/mermaid-ascii { };

    # Mac
    icalPal = final.callPackage ../pkgs/icalPal { };
    inputSourceSelector = final.callPackage ../pkgs/inputSourceSelector { };
  };
}

{ hostname, ... }:
{
  custom-packages-hashfile =
    final: prev:
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

  custom-packages = final: prev: {
    # Local custom packages
    git-wrapped = final.callPackage ../pkgs/git-wrapped { };
    awscli-local = final.callPackage ../pkgs/awscli-local { };
    macnotesapp = final.callPackage ../pkgs/macnotesapp { };

    # Npm
    codex = final.callPackage ../pkgs/codex {
      codex = prev.codex;
    };
    context7 = final.callPackage ../pkgs/context7 { };
    chrome-devtools-mcp = final.callPackage ../pkgs/chrome-devtools-mcp { };
    drawio-mcp = final.callPackage ../pkgs/drawio-mcp { };
    firecrawl-mcp = final.callPackage ../pkgs/firecrawl-mcp { };
    n8n-mcp = final.callPackage ../pkgs/n8n-mcp { };

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

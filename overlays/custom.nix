{ hostname, ... }:
{
  custom-packages-hashfile =
    final: prev:
    let
      rawhashfile = builtins.readFile ../pkgs/hashfile.json;
      allhashfile = builtins.fromJSON rawhashfile;
    in
    {
      hashfile = allhashfile.${hostname} or { };
    };

  custom-packages = final: prev: {
    # Local custom packages
    git-wrapped = final.callPackage ../pkgs/git-wrapped { };
    awscli-local = final.callPackage ../pkgs/awscli-local { };
    macnotesapp = final.callPackage ../pkgs/macnotesapp { };

    # Npm
    codex = final.callPackage ../pkgs/codex { };
    claude-code = final.callPackage ../pkgs/claude-code { };
    opencode = final.callPackage ../pkgs/opencode { };
    context7 = final.callPackage ../pkgs/context7 { };
    chrome-devtools-mcp = final.callPackage ../pkgs/chrome-devtools-mcp { };
    firecrawl-mcp = final.callPackage ../pkgs/firecrawl-mcp { };

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

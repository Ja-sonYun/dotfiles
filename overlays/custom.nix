{ hostname, ... }:
{
  custom-packages-hashfile =
    final: _prev:
    let
      rawhashfile = builtins.readFile (../pkgs/_hashfiles + "/${hostname}.json");
      currentHostHashfile = builtins.fromJSON rawhashfile;
      fakeHash = final.lib.fakeSha256;
    in
    {
      hashfile = {
        raw = currentHostHashfile;
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
    agenix-utils = final.callPackage ../libs/nixlib/pkg/agenix-utils { };

    claude-code = final.callPackage ../pkgs/ai-agents/claude-code { };
    codex = final.callPackage ../pkgs/ai-agents/codex { };
    pi = final.callPackage ../pkgs/ai-agents/pi { };
    pi-extensions = import ../pkgs/ai-agents/pi/extensions.nix { pkgs = final; };

    aws-ro = final.callPackage ../pkgs/ai-tools/aws-ro { };
    dcf = final.callPackage ../pkgs/ai-tools/dcf { };
    gh-ro = final.callPackage ../pkgs/ai-tools/gh-ro { };
    open-code-review = final.callPackage ../pkgs/ai-tools/open-code-review { };
    whisper-local = final.callPackage ../pkgs/ai-tools/whisper-local { };

    git-extend = final.callPackage ../pkgs/cli-tools/git-extend { };
    mermaid-ascii = final.callPackage ../pkgs/cli-tools/mermaid-ascii { };
    tmux-menu = final.callPackage ../pkgs/cli-tools/tmux-menu { };

    awsdac = final.callPackage ../pkgs/cloud/awsdac { };
    awscli-local = final.callPackage ../pkgs/cloud/awscli-local { };
    cf-tunnel = final.callPackage ../pkgs/cloud/cf-tunnel { };

    audio-process-watcher = final.callPackage ../pkgs/darwin/audio-process-watcher { };
    calendar-event-query = final.callPackage ../pkgs/darwin/calendar-event-query { };
    meeting-recorder = final.callPackage ../pkgs/darwin/meeting-recorder { };
    icalPal = final.callPackage ../pkgs/darwin/icalPal { };
    macism = final.callPackage ../pkgs/darwin/macism { };
    macnotesapp = final.callPackage ../pkgs/darwin/macnotesapp { };
    notifycmd = final.callPackage ../pkgs/darwin/notifycmd { };
    select-input-source = final.callPackage ../pkgs/darwin/select-input-source { };
    yabai = final.callPackage ../pkgs/darwin/yabai { };

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

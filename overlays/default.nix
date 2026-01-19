{ inputs, hostname, ... }:
{
  stable-packages = final: prev: rec {
    # Allow access stable package via `pkgs.stable.<package>`
    stable = import inputs.nixpkgs-stable {
      system = final.system;
      config.allowUnfree = true;
    };

    # Use stable for commonly broken packages
    gitui = stable.gitui;
    jujutsu = stable.jujutsu;
  };

  # prev-packages =
  #   final: prev:
  #   let
  #     prev = import inputs.nixpkgs-prev {
  #       system = final.system;
  #     };
  #   in
  #   {
  #     visidata = prev.visidata;
  #     ollama = prev.ollama;
  #   };

  lib-injection = final: prev: {
    # Inject custom libs into the lib namespace
    lib =
      prev.lib
      // (import ../libs {
        pkgs = final;
        system = final.stdenv.hostPlatform.system;
      });
  };

  vim = inputs.vim.overlays.default;

  # Override swift-format to skip build on Linux
  swift-format-skip-linux = final: prev:
    prev.lib.optionalAttrs prev.stdenv.hostPlatform.isLinux {
      swift-format = prev.runCommand "swift-format-dummy" { } "mkdir -p $out/bin";
    };
  say = inputs.say.overlays.default;
  plot = inputs.plot.overlays.default;
  seqdia = inputs.sequence-diagram-cli.overlays.default;

  tmux-with-sixel = final: prev: {
    tmux = prev.tmux.overrideAttrs (old: rec {
      version = "3.6";

      src = final.fetchFromGitHub {
        owner = "tmux";
        repo = "tmux";
        rev = version;
        sha256 = "sha256-jIHnwidzqt+uDDFz8UVHihTgHJybbVg3pQvzlMzOXPE=";
      };
      configureFlags = (old.configureFlags or [ ]) ++ [ "--enable-sixel" ];
    });
  };

  custom-packages-hashfile =
    final: prev:
    let
      rawhashfile = builtins.readFile ../pkgs/hashfile.json;
      allhashfile = builtins.fromJSON rawhashfile;
    in
    {
      hashfile = allhashfile."${hostname}";
    };
  custom-packages = final: prev: {
    # Local custom packages
    git-wrapped = final.callPackage ../pkgs/git-wrapped { };
    awscli-local = final.callPackage ../pkgs/awscli-local { };

    # Npm
    codex = final.callPackage ../pkgs/codex { };
    claude-code = final.callPackage ../pkgs/claude-code { };
    opencode = final.callPackage ../pkgs/opencode { };
    context7 = final.callPackage ../pkgs/context7 { };
    playwright-mcp = final.callPackage ../pkgs/playwright-mcp { };
    chrome-devtools-mcp = final.callPackage ../pkgs/chrome-devtools-mcp { };

    # Pypi
    aws-documentation = final.callPackage ../pkgs/aws-documentation { };

    # Cargo
    tmux-menu = final.callPackage ../pkgs/tmux-menu { };

    # Go
    mermaid-ascii = final.callPackage ../pkgs/mermaid-ascii { };

    # Mac
    icalPal = final.callPackage ../pkgs/icalPal { };
    inputSourceSelector = final.callPackage ../pkgs/inputSourceSelector { };
  };

  # Override upstream packages using our local pkgs/* definitions
  unstable-pkgs-override = final: prev: {
    # yabai = final.callPackage ../pkgs/yabai { inherit prev final; };
    jankyborders = final.callPackage ../pkgs/jankyborders { inherit prev final; };
  };
}

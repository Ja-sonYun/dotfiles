{
  # Override swift-format to skip build on Linux
  swift-format-skip-linux =
    final: prev:
    prev.lib.optionalAttrs prev.stdenv.hostPlatform.isLinux {
      swift-format = prev.runCommand "swift-format-dummy" { } "mkdir -p $out/bin";
    };

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

  # Override upstream packages using our local pkgs/* definitions
  unstable-pkgs-override = final: prev: {
    # yabai = final.callPackage ../pkgs/yabai { inherit prev final; };
    jankyborders = final.callPackage ../pkgs/jankyborders { inherit prev final; };
  };
}

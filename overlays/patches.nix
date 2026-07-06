{
  # Override swift-format to skip build on Linux
  swift-format-skip-linux =
    _final: prev:
    prev.lib.optionalAttrs prev.stdenv.hostPlatform.isLinux {
      swift-format = prev.runCommand "swift-format-dummy" { } "mkdir -p $out/bin";
    };

  # tmux-pin = _final: prev: {
  #   tmux = prev.tmux.overrideAttrs (_: {
  #     version = "3.7a";
  #     src = prev.fetchFromGitHub {
  #       owner = "tmux";
  #       repo = "tmux";
  #       tag = "3.7a";
  #       hash = "sha256-60lcDSOkIvTjqxAROwraPsHcBdv0MvST2ev+sYJDgo8=";
  #     };
  #   });
  # };

  # Override upstream packages using our local pkgs/* definitions
  unstable-pkgs-override = _final: _prev: {
    # yabai = final.callPackage ../pkgs/yabai { inherit prev final; };
  };
}

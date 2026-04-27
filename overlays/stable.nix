{ inputs, ... }:
{
  stable-packages = final: prev: rec {
    # Allow access stable package via `pkgs.stable.<package>`
    stable = import inputs.nixpkgs-stable {
      system = final.stdenv.hostPlatform.system;
      config.allowUnfree = true;
    };

    # Use stable for commonly broken packages
    gitui = stable.gitui;
    jujutsu = stable.jujutsu;
    swift-format = stable.swift-format;

    direnv = stable.direnv;
  };

  # prev-packages = final: prev: rec {
  #   prev = import inputs.nixpkgs-prev {
  #     system = final.stdenv.hostPlatform.system;
  #   };

  #   direnv = prev.direnv;
  # };
}

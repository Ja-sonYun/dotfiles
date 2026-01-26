{ inputs, ... }:
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
    swift-format = stable.swift-format;
  };
}

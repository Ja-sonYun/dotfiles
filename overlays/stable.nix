{ inputs, ... }:
{
  stable-packages = final: _prev: rec {
    # Allow access stable package via `pkgs.stable.<package>`
    stable = import inputs.nixpkgs-stable {
      system = final.stdenv.hostPlatform.system;
      config.allowUnfree = true;
    };

    # Use stable for commonly broken packages
    inherit (stable) amber-lang;
    inherit (stable) gitui;
    inherit (stable) jujutsu;
    inherit (stable) swift-format;
    inherit (stable) taskwarrior3;
    inherit (stable) unar;
    inherit (stable) visidata;

    inherit (stable) direnv;
  };
}

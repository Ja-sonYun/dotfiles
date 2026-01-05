{ pkgs, ... }:

let
  yabaiIndicator = pkgs.stdenv.mkDerivation rec {
    pname = "YabaiIndicator";
    version = "0.3.4";

    src = pkgs.fetchurl {
      url = "https://github.com/xiamaz/YabaiIndicator/releases/download/${version}/YabaiIndicator-${version}.zip";
      sha256 = "1vqj34pg8rsyph5lk83zbhin8qynzgg3qb93jchl8gxymqniipjx";
    };

    nativeBuildInputs = [ pkgs.unzip ];
    sourceRoot = "YabaiIndicator-${version}";

    installPhase = ''
      mkdir -p $out/Applications
      cp -r YabaiIndicator.app $out/Applications/
    '';
  };
in
{
  home.file."Applications/YabaiIndicator.app".source =
    "${yabaiIndicator}/Applications/YabaiIndicator.app";

  launchd.agents.yabai-indicator = {
    enable = true;
    config = {
      ProgramArguments = [
        "${yabaiIndicator}/Applications/YabaiIndicator.app/Contents/MacOS/YabaiIndicator"
      ];
      RunAtLoad = true;
      KeepAlive = false;
    };
  };
}

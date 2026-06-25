{ pkgs, ... }:
{
  programs.direnv = {
    enable = true;
    enableZshIntegration = true;

    silent = true;

    package = pkgs.direnv.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
      postInstall = (old.postInstall or "") + ''
        wrapProgram $out/bin/direnv \
          --set DIRENV_WARN_TIMEOUT "1m"
      '';
    });
  };
}

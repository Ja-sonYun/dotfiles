{ pkgs, ... }:

let
  package = pkgs.stdenvNoCC.mkDerivation {
    pname = "ponytail";
    version = "4.7.0";

    src = pkgs.fetchFromGitHub {
      owner = "DietrichGebert";
      repo = "ponytail";
      rev = "v4.7.0";
      hash = "sha256-Q6vlkbTfBFrNFTxEwYeMe5ciOe6QdULegvExwT//gJs=";
    };

    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -R . $out/
      runHook postInstall
    '';
  };
in
package
// {
  piExtensionPath = "${package}/pi-extension/index.js";
  skillsPath = "${package}/skills";
  hooksPath = "${package}/hooks";
}

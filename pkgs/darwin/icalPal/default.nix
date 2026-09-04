{ pkgs, lib, ... }:

pkgs.stdenv.mkDerivation rec {
  pname = "icalPal";
  version = "3.7.0";

  buildInputs = with pkgs; [
    ruby_3_4
    sqlite
  ];

  nativeBuildInputs = with pkgs; [
    makeWrapper
    ruby_3_4.devEnv
  ];

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/bin
    export GEM_HOME=$out/lib/ruby/gems/3.4.0
    export GEM_PATH=$GEM_HOME

    gem install icalPal -v ${version} --no-document

    makeWrapper ${pkgs.ruby_3_4}/bin/ruby $out/bin/icalPal \
      --add-flags "$GEM_HOME/gems/icalPal-${version}/bin/icalPal" \
      --set GEM_HOME "$GEM_HOME" \
      --set GEM_PATH "$GEM_HOME"
  '';

  meta = with lib; {
    description = "Ruby gem that accesses macOS calendar data";
    platforms = platforms.darwin;
    license = licenses.mit;
  };
}

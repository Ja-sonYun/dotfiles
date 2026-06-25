{
  stdenv,
  weechat,
}:

stdenv.mkDerivation {
  pname = "weechat-vimmode";
  version = "3.10";

  src = toString ./vimmode.py;

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/share
    cp $src $out/share/vimmode.py
  '';

  passthru = {
    scripts = [ "vimmode.py" ];
  };

  meta = {
    inherit (weechat.meta) platforms;
    description = "Vim mode for weechat";
  };
}

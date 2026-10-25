{
  lib,
  fetchurl,
  runCommand,
  patch,
  writeShellApplication,
  bash,
  bc,
  coreutils,
  file,
  findutils,
  flock,
  gawk,
  gnugrep,
  gnused,
  imagemagick,
  python3,
  tmux,
}:
let
  tupimageSource = fetchurl {
    url = "https://raw.githubusercontent.com/sergei-grechanik/tupimage/7190b180ef904abcdd32882b1f1a93c2e5ffd54a/tupimage";
    hash = "sha256-tgYrIvUEClInKy4yL1F3MpGcmRGjqkhLyWJUlj3seTs=";
  };
  tupimage = runCommand "tupimage" { nativeBuildInputs = [ patch ]; } ''
    cp ${tupimageSource} tupimage
    chmod u+w tupimage
    patch --batch --fuzz=0 -p1 < ${./shared-tmux-image-ids.patch}
    install -m444 tupimage "$out"
  '';
in
{
  uploader = writeShellApplication {
    name = "vim-image-upload";
    runtimeInputs = [
      bash
      bc
      coreutils
      file
      findutils
      flock
      gawk
      gnugrep
      gnused
      imagemagick
      tmux
    ];
    text = ''
      exec ${lib.getExe python3} ${./upload.py} ${tupimage} "$@"
    '';
  };
}

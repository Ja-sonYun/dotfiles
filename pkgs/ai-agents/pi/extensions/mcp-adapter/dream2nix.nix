{
  mkDerivation.postInstall = ''
    ln -s "$appRoot" "$out/extension"
  '';
}

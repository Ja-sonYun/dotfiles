{
  stdenv,
  lib,
  fetchFromGitHub,
  apple-sdk_15,
}:

stdenv.mkDerivation {
  pname = "mac-input-source-selector";
  version = "unstable-2023-01-01";

  src = fetchFromGitHub {
    owner = "minoki";
    repo = "InputSourceSelector";
    rev = "master";
    sha256 = "sha256-TD9RksjyUrUNufmH+rMTlS1HrOf6alLMVNRcEe9aGIg=";
  };

  buildInputs = [
    apple-sdk_15
  ];

  buildPhase = ''
    make
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp InputSourceSelector $out/bin/
  '';

  meta = with lib; {
    description = "macOS input source switcher";
    platforms = platforms.darwin;
    license = licenses.mit;
  };
}

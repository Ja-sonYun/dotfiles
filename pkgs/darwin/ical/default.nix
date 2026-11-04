{
  apple-sdk_15,
  buildGoModule,
  fetchFromGitHub,
  lib,
}:
buildGoModule {
  pname = "ical";
  version = "0.13.1";
  src = fetchFromGitHub {
    owner = "BRO3886";
    repo = "ical";
    rev = "d75e8173e78777c542c6bac48d32ef152afff23c";
    sha256 = "1inw4qdppqikgv9rgyhwpjh2rm5f17n4zyf935zq2nnlbzzcpm4k";
  };
  vendorHash = "sha256-0RpCUpExlbZS5UIjdWlPteyLqE2Ff0cH3MnT4Et+Us4=";
  subPackages = [ "cmd/ical" ];
  env.CGO_ENABLED = "1";
  buildInputs = [ apple-sdk_15 ];
  ldflags = [
    "-X main.version=0.13.1"
    "-X main.commit=d75e8173e78777c542c6bac48d32ef152afff23c"
  ];
  doCheck = false;
  meta = {
    description = "Apple Calendar command-line interface";
    homepage = "https://github.com/BRO3886/ical";
    mainProgram = "ical";
    platforms = lib.platforms.darwin;
  };
}

{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule rec {
  pname = "mermaid-ascii";
  version = "1.0.1";

  src = fetchFromGitHub {
    owner = "AlexanderGrooff";
    repo = "mermaid-ascii";
    rev = version;
    hash = "sha256-kaH7RwUuqUDNRl4WWJGqTnAJbVUK2CgCUw1ej2R94R8=";
  };

  vendorHash = "sha256-aB9sbTtlHbptM2995jizGFtSmEIg3i8zWkXz1zzbIek=";

  meta = with lib; {
    description = "Render mermaid diagrams in your terminal";
    homepage = "https://github.com/AlexanderGrooff/mermaid-ascii";
    license = licenses.mit;
    mainProgram = "mermaid-ascii";
  };
}

{ pkgs, ... }:
let
  openCodeReviewWrapped = pkgs.writeShellScriptBin "ocr" ''
    set -euo pipefail

    if [ -n "''${AI_ADDRESS:-}" ]; then
      export OCR_LLM_URL="$AI_ADDRESS/v1"
    fi

    if [ -n "''${CAPI_KEY:-}" ]; then
      export OCR_LLM_TOKEN="$CAPI_KEY"
    fi

    export OCR_LLM_MODEL="gpt-5.6-sol"
    export OCR_USE_ANTHROPIC="false"
    export OCR_NO_UPDATE="1"

    exec ${pkgs.open-code-review}/bin/ocr "$@"
  '';
in
{
  home.packages = [ openCodeReviewWrapped ];
}

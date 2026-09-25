{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.open-code-review;
  openCodeReviewWrapped = pkgs.writeShellScriptBin "ocr" ''
    set -euo pipefail

    if [ -n "''${LLM_DOMAIN:-}" ]; then
      export OCR_LLM_URL="$LLM_DOMAIN/v1"
    fi

    if [ -n "''${CAPI_KEY:-}" ]; then
      export OCR_LLM_TOKEN="$CAPI_KEY"
    fi

    export OCR_LLM_MODEL=${lib.escapeShellArg cfg.model}
    export OCR_USE_ANTHROPIC="false"
    export OCR_NO_UPDATE="1"
    export PATH="${pkgs.lib.makeBinPath [ pkgs.aws-ro ]}:$PATH"

    exec ${pkgs.open-code-review}/bin/ocr "$@"
  '';
in
{
  options.programs.open-code-review = {
    enable = lib.mkEnableOption "Open Code Review";
    model = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "OCR model.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ openCodeReviewWrapped ];
  };
}

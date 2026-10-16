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

    domain="''${LLM_DOMAIN%/}"
    if [[ "$domain" != */v1 ]]; then
      domain="$domain/v1"
    fi

    export OCR_USE_ANTHROPIC="false"
    export OCR_NO_UPDATE="1"
    export PATH="${pkgs.lib.makeBinPath [ pkgs.aws-ro ]}:$PATH"

    config_file="$HOME/.opencodereview/config.json"
    if [ -f "$config_file" ]; then
      extra_body=$(${pkgs.jq}/bin/jq -c --arg effort "$STRONG_LLM_REASONING_EFFORT" \
        '(.llm.extra_body // {}) | .reasoning.effort = $effort' "$config_file")
    else
      extra_body=$(${pkgs.jq}/bin/jq -cn --arg effort "$STRONG_LLM_REASONING_EFFORT" \
        '{reasoning: {effort: $effort}}')
    fi
    ${pkgs.open-code-review}/bin/ocr config set llm.url "$domain" >/dev/null
    ${pkgs.open-code-review}/bin/ocr config set llm.model "$STRONG_LLM_MODEL" >/dev/null
    ${pkgs.open-code-review}/bin/ocr config set llm.protocol "openai-responses" >/dev/null
    ${pkgs.open-code-review}/bin/ocr config set llm.auth_token "" >/dev/null
    ${pkgs.open-code-review}/bin/ocr config set llm.auth_token_cmd 'printf "%s" "$CAPI_KEY"' >/dev/null
    ${pkgs.open-code-review}/bin/ocr config set llm.extra_body "$extra_body" >/dev/null

    exec ${pkgs.open-code-review}/bin/ocr "$@"
  '';
in
{
  options.programs.open-code-review = {
    enable = lib.mkEnableOption "Open Code Review";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ openCodeReviewWrapped ];
  };
}

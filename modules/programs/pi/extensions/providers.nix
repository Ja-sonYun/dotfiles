{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi;
  nonEmptyString = lib.types.addCheck lib.types.str (value: value != "");
  positiveInteger = lib.types.addCheck lib.types.int (value: value > 0);

  providerType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = nonEmptyString;
        description = "Provider display name.";
      };
      baseUrlEnv = lib.mkOption {
        type = nonEmptyString;
        description = "Environment variable containing the provider base URL.";
      };
      apiKeyEnv = lib.mkOption {
        type = nonEmptyString;
        description = "Environment variable containing the provider API key.";
      };
      fallbackModels = lib.mkOption {
        type = lib.types.nonEmptyListOf nonEmptyString;
        description = "Model IDs available before catalog refresh.";
      };
      defaults = lib.mkOption {
        type = lib.types.submodule {
          options = {
            contextWindow = lib.mkOption { type = positiveInteger; };
            maxTokens = lib.mkOption { type = positiveInteger; };
          };
        };
      };
      imageModelMarkers = lib.mkOption {
        type = lib.types.listOf nonEmptyString;
        default = [ ];
        description = "Model ID substrings that indicate image input support.";
      };
      nonReasoningModelMarkers = lib.mkOption {
        type = lib.types.listOf nonEmptyString;
        default = [ ];
        description = "Model ID substrings that disable reasoning support.";
      };
    };
  };
in
{
  options.programs.pi.providers = lib.mkOption {
    type = lib.types.attrsOf providerType;
    default = { };
    description = "OpenAI-compatible providers with dynamic model catalogs.";
  };

  config = lib.mkIf (cfg.enable && cfg.providers != { }) {
    programs.pi.extensions.providers = pkgs.pi-extensions.providers cfg.providers;
  };
}

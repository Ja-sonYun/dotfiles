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
      baseUrl = lib.mkOption {
        type = lib.types.either nonEmptyString pkgs.tool.secretValue.type;
        description = "Base URL; supports { _secret = path; }.";
      };
      apiKey = lib.mkOption {
        type = lib.types.either lib.types.str pkgs.tool.secretValue.type;
        description = "API key; supports { _secret = path; }.";
      };
      fallbackModels = lib.mkOption {
        type = lib.types.nonEmptyListOf nonEmptyString;
        description = "Initial model IDs.";
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
        description = "Model ID substrings enabling image input.";
      };
      nonReasoningModelMarkers = lib.mkOption {
        type = lib.types.listOf nonEmptyString;
        default = [ ];
        description = "Model ID substrings disabling reasoning.";
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

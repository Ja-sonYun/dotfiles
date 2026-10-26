{
  config,
  lib,
  pkgs,
}:
let
  cfg = config.programs.claude-code;
  jsonFormat = pkgs.formats.json { };
  baseSettingsFile = jsonFormat.generate "claude-code-settings.json" (
    cfg.settings
    // lib.optionalAttrs (cfg.customInstructions != "") {
      outputStyle = "Shared Instructions";
    }
    // {
      "$schema" = "https://json.schemastore.org/claude-code-settings.json";
    }
  );
  settingsFile =
    if cfg.settingsTransform == null then
      baseSettingsFile
    else
      pkgs.runCommandLocal "claude-code-settings.json" { } ''
        ${cfg.settingsTransform} < ${baseSettingsFile} > "$out"
      '';

  sharedFiles =
    home:
    lib.optionalAttrs (cfg.context != null) {
      "${home}/CLAUDE.md".text = cfg.context;
    }
    // lib.optionalAttrs (cfg.customInstructions != "") {
      "${home}/output-styles/shared-instructions.md".text = ''
        ---
        name: Shared Instructions
        description: Shared personal working and response preferences
        keep-coding-instructions: true
        ---

        ${cfg.customInstructions}
      '';
    }
    // lib.optionalAttrs (cfg.keybindings != null) {
      "${home}/keybindings.json".text = builtins.toJSON cfg.keybindings;
    };
in
{
  inherit settingsFile sharedFiles;
}

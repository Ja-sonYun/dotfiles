{ config, lib, ... }:

with lib;

let
  zleCommandAttrs = config.programs.zleCommands;
in
{
  ##############################
  # Module Options Definition
  ##############################
  options.programs.zleCommands = mkOption {
    type = types.attrs;
    default = { };
    description = ''
      Configuration for zsh zle commands.
      Each attribute is a widget name with a definition containing:
      - command: The shell command to execute when widget is invoked.
      - bindkeys: A list of keybindings for the widget.
    '';
  };

  #################################################
  # Configuration: Generate `.zle_widgets` File
  #################################################
  config =
    let
      # Generate the content of a single zle widget
      generateZleWidget =
        widgetName:
        let
          widgetConf = zleCommandAttrs.${widgetName};
          widgetCommand = widgetConf.command or "echo 'No command provided.'";
          bindkeys = widgetConf.bindkeys or "echo 'No bindkeys provided.'";
        in
        ''
          ${widgetName}() {
            ${widgetCommand}
          }

          # Register the zle widget
          zle -N ${widgetName}

          # Bind keys to the widget
          ${bindkeys}
        '';

      # Generate all widgets as a single file content
      zleWidgetsFileContent = concatStringsSep "\n\n" (map generateZleWidget (attrNames zleCommandAttrs));
    in
    {
      # Write the single .zle_widgets file to the home directory
      home.file.".zle_widgets" = {
        text = ''
          #/bin/zsh

          ${zleWidgetsFileContent}
        '';
      };
    };
}

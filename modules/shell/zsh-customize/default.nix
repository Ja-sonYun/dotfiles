{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.zsh-customize;

  autoloadType = lib.types.submodule {
    options.flags = lib.mkOption {
      type = lib.types.str;
      default = "-Uz";
    };
  };

  commandType = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Help text. When null, no -h/--help parsing is added.";
      };
      body = lib.mkOption {
        type = lib.types.lines;
      };
    };
  };

  variableType = lib.types.submodule {
    options = {
      flags = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "When set, render with typeset and these flags.";
      };
      value = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };
  };

  zleType = lib.types.submodule {
    options = {
      function = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Existing shell function registered as this zle widget.";
      };
      body = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        default = null;
        description = "Inline shell body for this zle widget.";
      };
      bindkeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
  };

  blockType = lib.types.submodule {
    options = {
      order = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
      };
      fpath = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      autoload = lib.mkOption {
        type = lib.types.attrsOf autoloadType;
        default = { };
      };
      variables = lib.mkOption {
        type = lib.types.attrsOf variableType;
        default = { };
      };
      functions = lib.mkOption {
        type = lib.types.attrsOf lib.types.lines;
        default = { };
      };
      zle = lib.mkOption {
        type = lib.types.attrsOf zleType;
        default = { };
      };
      raw = lib.mkOption {
        type = lib.types.lines;
        default = "";
      };
      hooks = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = { };
      };
    };
  };

  renderFpath = fpath: lib.concatMapStringsSep "\n" (path: ''fpath+=("${path}")'') fpath;

  renderPath =
    path: lib.optionalString (path != [ ]) ''export PATH="$PATH:${lib.concatStringsSep ":" path}"'';

  renderAutoload =
    autoload:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: value: "autoload ${value.flags} ${name}") autoload
    );

  escapeWordCharPattern =
    char: lib.replaceStrings [ "\\" "/" "-" "]" "^" ] [ "\\\\" "\\/" "\\-" "\\]" "\\^" ] char;

  renderWordChars =
    wordChars:
    lib.optionalString (
      wordChars.remove != [ ]
    ) "WORDCHARS=\${WORDCHARS//[${lib.concatMapStrings escapeWordCharPattern wordChars.remove}]/}";

  renderVariable =
    name: variable:
    let
      assignment = "${name}${
        lib.optionalString (variable.value != null) "=${lib.escapeShellArg variable.value}"
      }";
    in
    if variable.flags == null then assignment else "typeset ${variable.flags} ${assignment}";

  renderVariables =
    variables: lib.concatStringsSep "\n" (lib.mapAttrsToList renderVariable variables);

  renderFunction = name: body: ''
    ${name}() {
    ${body}
    }
  '';

  renderFunctions =
    functions: lib.concatStringsSep "\n\n" (lib.mapAttrsToList renderFunction functions);

  renderZle =
    name: widget:
    assert lib.assertMsg (
      (widget.function != null) != (widget.body != null)
    ) "programs.zsh-customize.zle.${name}: set exactly one of function or body";
    lib.concatStringsSep "\n" (
      lib.optional (widget.body != null) (renderFunction name widget.body)
      ++ [
        (if widget.function != null then "zle -N ${name} ${widget.function}" else "zle -N ${name}")
      ]
      ++ map (key: "bindkey ${lib.escapeShellArg key} ${name}") widget.bindkeys
    );

  renderZleWidgets = widgets: lib.concatStringsSep "\n\n" (lib.mapAttrsToList renderZle widgets);

  renderHooks =
    hooks:
    lib.optionalString (hooks != { }) ''
      autoload -Uz add-zsh-hook
      ${lib.concatStringsSep "\n" (
        lib.flatten (
          lib.mapAttrsToList (hook: functions: map (fn: "add-zsh-hook ${hook} ${fn}") functions) hooks
        )
      )}
    '';

  renderBlock =
    block:
    lib.concatStringsSep "\n\n" (
      lib.filter (s: s != "") [
        (renderFpath block.fpath)
        (renderAutoload block.autoload)
        (renderVariables block.variables)
        block.raw
        (renderFunctions block.functions)
        (renderZleWidgets block.zle)
        (renderHooks block.hooks)
      ]
    );

  orderedBlocks =
    let
      indexed = lib.imap0 (index: block: {
        inherit index block;
        order = if block.order == null then 1000 else block.order;
      }) cfg.blocks;
    in
    map (entry: entry.block) (
      lib.sort (a: b: a.order < b.order || (a.order == b.order && a.index < b.index)) indexed
    );

  topText = renderBlock {
    order = null;
    inherit (cfg)
      autoload
      variables
      ;
    fpath = [ ];
    raw = lib.concatStringsSep "\n\n" (
      lib.filter (s: s != "") [
        (renderPath cfg.path)
        (renderWordChars cfg.wordChars)
        ''[ -f "$HOME/.zle_widgets" ] && source "$HOME/.zle_widgets"''
      ]
    );
    functions = { };
    hooks = { };
    zle = { };
  };

  blocksText = lib.concatStringsSep "\n\n" (map renderBlock orderedBlocks);

  zleWidgetsText = ''
    #/bin/zsh

    ${renderZleWidgets cfg.zle}
  '';

  toScriptBin =
    name: command:
    let
      hasDesc = command.description != null;
      helpBlock = lib.optionalString hasDesc ''
        if [[ "''${1-}" == "-h" || "''${1-}" == "--help" ]]; then
          print -- "${command.description}"
          exit 0
        fi
      '';
    in
    pkgs.writeScriptBin name ''
      #!${pkgs.zsh}/bin/zsh
      set -euo pipefail
      ${helpBlock}
      ${command.body}
    '';
in
{
  options.programs.zsh-customize = {
    enable = lib.mkEnableOption "zsh customization helpers";

    fpath = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Entries appended to zsh fpath.";
    };

    path = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Entries appended to PATH.";
    };

    autoload = lib.mkOption {
      type = lib.types.attrsOf autoloadType;
      default = { };
      description = "Functions autoloaded with zsh autoload.";
    };

    variables = lib.mkOption {
      type = lib.types.attrsOf variableType;
      default = { };
      description = "Top-level shell variables.";
    };

    wordChars.remove = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Characters removed from zsh WORDCHARS.";
    };

    zle = lib.mkOption {
      type = lib.types.attrsOf zleType;
      default = { };
      description = "Top-level zle widgets.";
    };

    blocks = lib.mkOption {
      type = lib.types.listOf blockType;
      default = [ ];
      description = "Ordered zsh init blocks. Omit order unless sequencing matters.";
    };

    commands = lib.mkOption {
      type = lib.types.attrsOf commandType;
      default = { };
      description = "Executable zsh scripts added to home.packages.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file.".zle_widgets".text = zleWidgetsText;

    home.packages = lib.mapAttrsToList toScriptBin cfg.commands;

    programs.zsh.initContent = lib.mkMerge [
      (lib.mkOrder 550 (renderFpath cfg.fpath))
      (lib.mkOrder 900 topText)
      (lib.mkOrder 1000 blocksText)
    ];
  };
}

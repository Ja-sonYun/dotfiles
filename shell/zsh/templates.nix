{
  lib,
  paths,
  pkgs,
  ...
}:
let
  templateMeta = import ../../templates/meta.nix;
  templateNames = builtins.attrNames templateMeta;
  templateNamesStr = builtins.concatStringsSep " " templateNames;

  templateListFile = pkgs.writeText "template-list" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: meta: "${name}\t${meta.description}") templateMeta
    )
  );

  templateInfoFile = pkgs.writeText "template-info" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: meta: "${name}\t${meta.description}\t${builtins.concatStringsSep "," meta.tags}"
      ) templateMeta
    )
  );

  completionScript = pkgs.writeText "_templates" ''
    #compdef templates

    _templates() {
      local -a subcommands
      subcommands=(
        'list:List all available templates'
        'init:Create .envrc with template and run direnv allow'
        'info:Show template description and tags'
        'search:Search templates by name or tag'
        'direnv:Print direnv use-flake line'
        'echo:Show template source files'
      )

      local -a template_names
      template_names=(${templateNamesStr})

      if (( CURRENT == 2 )); then
        _describe 'subcommand' subcommands
      else
        case "$words[2]" in
          init|info|direnv)
            _describe 'template' template_names
            ;;
          search)
            _message 'keyword'
            ;;
          *)
            ;;
        esac
      fi
    }

    _templates "$@"
  '';
in
{
  home.file.".zsh/completions/_templates".source = completionScript;

  programs.zsh-customize.commands.templates = {
    description = "Manage flake dev environment templates. Subcommands: list, init, info, search, direnv, echo";
    body = ''
      local templates_dir="${paths.dotfiles}/templates"

      _validate_name() {
        local name="$1"
        if ! ${pkgs.gnugrep}/bin/grep -qP "^''${name}\t" "${templateInfoFile}"; then
          echo "Error: Template '$name' not found."
          echo "Run 'templates list' to see available templates."
          exit 1
        fi
      }

      case "$1" in
        list)
          ${pkgs.coreutils}/bin/cat "${templateListFile}" | ${pkgs.util-linux}/bin/column -t -s $'\t'
          ;;

        init)
          shift
          if [ $# -eq 0 ]; then
            echo "Usage: templates init <name>"
            exit 1
          fi
          _validate_name "$1"
          if [ -f ".envrc" ]; then
            echo ".envrc already exists:"
            cat .envrc
            echo ""
            printf "Overwrite? [y/N] "
            read -r answer
            if [[ "$answer" != [yY] ]]; then
              echo "Aborted."
              exit 0
            fi
          fi
          echo "use flake \"\$FLAKE_TEMPLATES_DIR#$1\"" > .envrc
          echo "Created .envrc with template: $1"
          ${pkgs.direnv}/bin/direnv allow
          ;;

        info)
          if [ -z "$2" ]; then
            echo "Usage: templates info <name>"
            exit 1
          fi
          _validate_name "$2"
          local line
          line=$(${pkgs.gnugrep}/bin/grep -P "^''${2}\t" "${templateInfoFile}")
          local desc tags
          desc=$(echo "$line" | ${pkgs.coreutils}/bin/cut -f2)
          tags=$(echo "$line" | ${pkgs.coreutils}/bin/cut -f3)
          echo "Template: $2"
          echo "Description: $desc"
          echo "Tags: ''${tags//,/, }"
          ;;

        search)
          if [ -z "$2" ]; then
            echo "Usage: templates search <keyword>"
            exit 1
          fi
          ${pkgs.gnugrep}/bin/grep -i "$2" "${templateInfoFile}" \
            | ${pkgs.gawk}/bin/awk -F'\t' '{printf "%-40s %s\n", $1, $2}'
          ;;

        direnv)
          if [ -z "$2" ]; then
            echo "Usage: templates direnv <name>"
            exit 1
          fi
          _validate_name "$2"
          echo "use flake \"\$FLAKE_TEMPLATES_DIR#$2\""
          ;;

        echo)
          cat "$templates_dir/shells.nix"
          ;;

        *)
          echo "Usage: templates <command> [args]"
          echo ""
          echo "Commands:"
          echo "  list              List all available templates"
          echo "  init <name>       Create .envrc with template and run direnv allow"
          echo "  info <name>       Show template description and tags"
          echo "  search <keyword>  Search templates by name, description, or tag"
          echo "  direnv <name>     Print direnv use-flake line"
          echo "  echo              Show template source (shells.nix)"
          ;;
      esac
    '';
  };
}

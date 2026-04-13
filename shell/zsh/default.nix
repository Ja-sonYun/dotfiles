{ pkgs
, lib
, cacheDir
, configDir
, purpose
, ...
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
        name: meta:
        "${name}\t${meta.description}\t${builtins.concatStringsSep "," meta.tags}"
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
  home.activation.setZshAsDefaultShell = lib.mkIf pkgs.stdenv.isLinux
    (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
      ZSH_PATH="$HOME/.nix-profile/bin/zsh"
      if [[ $(getent passwd $USER) != *"$ZSH_PATH"* ]]; then
        if ! grep -q "$ZSH_PATH" /etc/shells; then
          echo "$ZSH_PATH" | sudo tee -a /etc/shells
        fi
        sudo chsh -s "$ZSH_PATH" "$USER"
      fi
    '');

  imports = [
    ../../modules/zshFunc

    ./zle/better_grammar
    ./zle/command_generator
  ];

  programs.zsh = {
    enable = true;

    autosuggestion.enable = true;
    enableCompletion = true;
    syntaxHighlighting.enable = true;
    historySubstringSearch.enable = true;

    oh-my-zsh = {
      enable = true;
      plugins = [
        "git"
        "sudo"
      ];
    };

    zplug = {
      enable = true;

      zplugHome = "${cacheDir}/zplug";
      plugins = [
        { name = "jeffreytse/zsh-vi-mode"; }
      ];
    };

    shellAliases = {
      urldecode = "python3 -c 'import sys, urllib.parse as ul; print(ul.unquote_plus(sys.stdin.read()))'";
      urlencode = "python3 -c 'import sys, urllib.parse as ul; print(ul.quote_plus(sys.stdin.read()))'";
      dud = "du -h -d 1 ";
    };

    shellGlobalAliases = {
      G = "| grep";
      L = "| less";
      T = "| tail";
      H = "| head";
      S = "| sort";
      D = "| base64 -d";
      __ = "| ${pkgs.spacer}/bin/spacer";
    };

    localVariables = { };

    initContent =
      let
        PS1 =
          let
            promptTime = "[%D{%d/%m,%H:%M:%S}]";
            jobStatus = "%{$fg[red]%}%(1j.%U•%j%u|.)%{$reset_color%}";
            directory = "$(shorten-pwd)";
            symbol = " %{$fg[green]%}$%{$reset_color%}";
          in
          "${promptTime}${jobStatus}${directory}${symbol} ";
      in
      ''
        fpath+=("$HOME/.zsh/completions")

        set -o ignoreeof

        export PATH="$PATH:$HOME/.bin:$HOME/.local/bin:$HOME/go/bin"

        function zvm_after_init() {
          if [[ $options[zle] = on ]]; then
            source ${pkgs.fzf}/share/fzf/completion.zsh
            source ${pkgs.fzf}/share/fzf/key-bindings.zsh

            eval "$(${pkgs.atuin}/bin/atuin init zsh --disable-up-arrow)"
            eval "$(${pkgs.navi}/bin/navi widget zsh)"
          fi
        }

        [ -f "$HOME/.zle_widgets" ] && source "$HOME/.zle_widgets"

        # Initialize ps1 after source zshfuncs since we're using it
        PS1='${PS1}'

        find_hooks_dir() {
            local dir="$1"
            while [[ "$dir" != "/" ]]; do
                if [[ -d "$dir/.hooks" ]]; then
                    echo "$dir/.hooks"
                    return 0
                fi
                dir=$(dirname "$dir")
            done
            return 1
        }

        chpwd() {
            [[ -n "$VIM" ]] && return
            local old_hooks=""
            local new_hooks=""

            # Find hooks directories
            [[ -n "$OLDPWD" ]] && old_hooks=$(find_hooks_dir "$OLDPWD")
            new_hooks=$(find_hooks_dir "$PWD")

            # Only run hooks if we're changing between different hook contexts
            if [[ "$old_hooks" != "$new_hooks" ]]; then
                # Run on_leave hooks
                if [[ -n "$old_hooks" && -d "$old_hooks/on_leave" ]]; then
                    setopt localoptions nullglob
                    for file in "$old_hooks/on_leave/"*; do
                        if [[ -f "$file" ]]; then
                            source "$file"
                        fi
                    done
                fi
                # Run on_enter hooks
                if [[ -n "$new_hooks" && -d "$new_hooks/on_enter" ]]; then
                    setopt localoptions nullglob
                    for file in "$new_hooks/on_enter/"*; do
                        if [[ -f "$file" ]]; then
                            source "$file"
                        fi
                    done
                fi
            fi
        }

        zshexit() {
            [[ -n "$VIM" ]] && return
            local current_hooks=$(find_hooks_dir "$PWD")

            if [[ -n "$current_hooks" && -d "$current_hooks/on_exit" ]]; then
                export OLDPWD="$PWD"
                setopt localoptions nullglob
                for file in "$current_hooks/on_exit/"*; do
                    if [[ -f "$file" ]]; then
                        source "$file"
                    fi
                done
            fi
        }

        ask_yes_no() {
            local prompt="''${1:-Continue}"
            local answer

            while true; do
                echo -n "$prompt (y/n): "
                read -k1 answer
                echo
                if [[ $answer == "y" || $answer == "Y" ]]; then
                    return 0
                elif [[ $answer == "n" || $answer == "N" ]]; then
                    return 1
                else
                    echo "Please enter y or n."
                fi
            done
        }

        chpwd-hook-init() {
          mkdir -p .hooks/on_enter .hooks/on_leave
          echo "echo 'You have entered $(basename \"$PWD\")'" > .hooks/on_enter/enter.sh
          echo "echo 'You have left $(basename \"$PWD\")'" > .hooks/on_leave/leave.sh
          echo "echo 'You have exited $(basename \"$PWD\")'" > .hooks/on_exit/exit.sh
        }
      '';

    envExtra = '''';
    profileExtra = '''';
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.atuin = {
    enable = true;
    flags = [
      "--disable-up-arrow"
    ];
    # Will manually enable in the zsh initContent
    settings = {
      auto_sync = false;
      sync_address = "http://localhost:8080"; # Override dummy address
      show_help = false;
      show_tabs = false;
    };
  };

  programs.bat.enable = true;

  # A modern replacement for ‘ls’
  # useful in bash/zsh prompt, not in nushell.
  programs.eza = {
    enable = true;
    git = true;
    icons = "never";
    enableZshIntegration = true;
  };

  # skim provides a single executable: sk.
  # Basically anywhere you would want to use grep, try sk instead.
  programs.skim = {
    enable = true;
    enableBashIntegration = true;
  };

  programs.zshFunc = {
    shorten-pwd = {
      description = "Display current path in a shortened format";
      command = ''
        # Replace the home directory with ~ and split the path into an array using / as the delimiter
        local -a path_parts
        path_parts=("''${(@s:/:)''${PWD/#$HOME/~}}")

        # Process each element
        for i in {1..''$#path_parts}; do
          # Skip the home directory (~), empty elements, and the last element
          if [[ $path_parts[i] != "~" ]] && [[ -n $path_parts[i] ]] && (( i < $#path_parts )); then
            # Abbreviate the element to the first three characters and add ' '
            path_parts[i]=''${path_parts[i][1,3]}…
          fi
        done

        # Join the elements back into a string
        local new_path="''${(j:/:)path_parts}"
        echo "$new_path"
      '';
    };
    shorten-str = {
      description = "Short long string in a shortened format. `shorten-str 20 $str`";
      command = ''
        maxlen="$1"
        shift
        str="$@"

        # If the string length is less than or equal to maxlen, return the string as is
        if (( ''${#str} <= maxlen )); then
          echo $str
        else
          # Calculate the length to keep at the end of the string
          end_len=$((maxlen / 2))

          # Ensure that the total length is not more than maxlen
          start_len=$((maxlen - end_len - 1))

          echo "''${str:0:$start_len}…''${str: -end_len}"
        fi
      '';
    };
    unzipany = {
      description = "Unzip any archive type. `unzipany file.zip`";
      command = ''
        local input_file="$1"
        local output_dir="''${2:-''${input_file%.*}}" # Default output dir is input filename without extension

        if [[ ! -f "$input_file" ]]; then
          echo "Error: File '$input_file' not found!"
          return 1
        fi

        mkdir -p "$output_dir"

        case "$input_file" in
          *.tar.gz|*.tgz) ${pkgs.gnutar}/bin/tar -xzf "$input_file" -C "$output_dir" ;;
          *.tar.bz2|*.tbz2) ${pkgs.gnutar}/bin/tar -xjf "$input_file" -C "$output_dir" ;;
          *.tar.xz|*.txz) ${pkgs.gnutar}/bin/tar -xJf "$input_file" -C "$output_dir" ;;
          *.tar) ${pkgs.gnutar}/bin/tar -xf "$input_file" -C "$output_dir" ;;
          *.zip) ${pkgs.unzip}/bin/unzip -d "$output_dir" "$input_file" ;;
          *.rar) ${pkgs.unrar-wrapper}/bin/unrar x "$input_file" "$output_dir" ;;
          *.7z) ${pkgs.p7zip}/bin/7z x "$input_file" -o"$output_dir" ;;
          *.gz) ${pkgs.gzip}/bin/gunzip -c "$input_file" > "$output_dir/''${input_file%.*}" ;;
          *.bz2) ${pkgs.bzip2}/bin/bunzip2 -c "$input_file" > "$output_dir/''${input_file%.*}" ;;
          *.xz) ${pkgs.xz}/bin/unxz -c "$input_file" > "$output_dir/''${input_file%.*}" ;;
          *) echo "Error: Unsupported file format!" && return 1 ;;
        esac

        echo "Extraction completed: $output_dir"
      '';
    };
    flake-ignore = {
      description = "Ignore flake in git repository";
      command = ''
        if [ -f "flake.nix" ]; then
          git add --intent-to-add flake.nix
          git update-index --assume-unchanged flake.nix
        fi
        if [ -f "flake.lock" ]; then
          git add --intent-to-add flake.lock
          git update-index --assume-unchanged flake.lock
        fi
      '';
    };
    flake-undo-ignore = {
      description = "Ignore flake in git repository";
      command = ''
        if [ -f "flake.nix" ]; then
          git update-index assume-unchanged flake.nix
        fi
        if [ -f "flake.lock" ]; then
          git update-index assume-unchanged flake.lock
        fi
      '';
    };
    templates = {
      description = "Manage flake dev environment templates. Subcommands: list, init, info, search, direnv, echo";
      command = ''
        local templates_dir="${configDir}/templates"

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
  };
}

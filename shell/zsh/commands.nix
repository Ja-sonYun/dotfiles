{ pkgs, ... }:
{
  programs.zsh-customize.commands = {
    lstmp = {
      description = "List .tmp directories below the current directory with their total sizes";
      body = ''
        ${pkgs.fd}/bin/fd --hidden --no-ignore --type directory --glob .tmp . \
          --exec-batch ${pkgs.eza}/bin/eza --long --treat-dirs-as-files --total-size --
      '';
    };

    shorten-pwd = {
      description = "Display current path in a shortened format";
      body = ''
        local -a path_parts
        path_parts=("''${(@s:/:)''${PWD/#$HOME/~}}")

        for i in {1..''$#path_parts}; do
          if [[ $path_parts[i] != "~" ]] && [[ -n $path_parts[i] ]] && (( i < $#path_parts )); then
            path_parts[i]=''${path_parts[i][1,3]}…
          fi
        done

        local new_path="''${(j:/:)path_parts}"
        echo "$new_path"
      '';
    };

    shorten-str = {
      description = "Short long string in a shortened format. `shorten-str 20 $str`";
      body = ''
        maxlen="$1"
        shift
        str="$@"

        if (( ''${#str} <= maxlen )); then
          echo $str
        else
          end_len=$((maxlen / 2))

          start_len=$((maxlen - end_len - 1))

          echo "''${str:0:$start_len}…''${str: -end_len}"
        fi
      '';
    };

    unzipany = {
      description = "Unzip any archive type. `unzipany file.zip`";
      body = ''
        local input_file="$1"
        local output_dir="''${2:-''${input_file%.*}}"
        local output_file="''${input_file##*/}"
        output_file="''${output_file%.*}"

        if [[ ! -f "$input_file" ]]; then
          echo "Error: File '$input_file' not found!"
          return 1
        fi

        mkdir -p "$output_dir" || return $?

        case "$input_file" in
          *.tar.gz|*.tgz) ${pkgs.gnutar}/bin/tar -xzf "$input_file" -C "$output_dir" ;;
          *.tar.bz2|*.tbz2) ${pkgs.gnutar}/bin/tar -xjf "$input_file" -C "$output_dir" ;;
          *.tar.xz|*.txz) ${pkgs.gnutar}/bin/tar -xJf "$input_file" -C "$output_dir" ;;
          *.tar) ${pkgs.gnutar}/bin/tar -xf "$input_file" -C "$output_dir" ;;
          *.zip) ${pkgs.unzip}/bin/unzip -d "$output_dir" "$input_file" ;;
          *.rar) ${pkgs.unrar-wrapper}/bin/unrar x "$input_file" "$output_dir" ;;
          *.7z) ${pkgs.p7zip}/bin/7z x "$input_file" -o"$output_dir" ;;
          *.gz) ${pkgs.gzip}/bin/gunzip -c "$input_file" > "$output_dir/$output_file" ;;
          *.bz2) ${pkgs.bzip2}/bin/bunzip2 -c "$input_file" > "$output_dir/$output_file" ;;
          *.xz) ${pkgs.xz}/bin/unxz -c "$input_file" > "$output_dir/$output_file" ;;
          *) echo "Error: Unsupported file format!" && return 1 ;;
        esac || return $?

        echo "Extraction completed: $output_dir"
      '';
    };
  };
}

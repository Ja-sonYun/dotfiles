{ pkgs, ... }:
{
  programs.zsh-customize.commands = {
    shorten-pwd = {
      description = "Display current path in a shortened format";
      body = ''
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
      body = ''
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
      body = ''
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
  };
}

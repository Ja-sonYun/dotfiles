{ pkgs, ... }:

pkgs.symlinkJoin {
  name = "shell-assistant";
  paths =
    map
      (
        command:
        pkgs.uv.asPackage {
          inherit (command) name entrypoint;
          root = ./.;
        }
      )
      [
        {
          name = "generate-shell-command-with-openai";
          entrypoint = "shell_assistant:generate_command";
        }
        {
          name = "fix-grammar-with-openai";
          entrypoint = "shell_assistant:fix_grammar";
        }
      ];
}

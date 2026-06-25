import { defineCommand, shellExecCmd } from "../helpers.ts";

// `-c <script>` (incl. clusters like -lc) re-parses the script; `<shell> file.sh` reads the script.
export default defineCommand(
  ["sh", "bash", "zsh", "dash", "ksh", "ash", "mksh"],
  shellExecCmd(),
);

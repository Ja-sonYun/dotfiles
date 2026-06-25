import { defineCommand, specThenWriteCmd } from "../helpers.ts";

// chown OWNER[:GROUP] FILE... — OWNER is not a path; files are writes. `--reference FILE` reads FILE.
export default defineCommand(["chown"], specThenWriteCmd(["--from"]));

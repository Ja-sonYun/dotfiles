import { defineCommand, specThenWriteCmd } from "../helpers.ts";

// chmod MODE FILE... — MODE is not a path; files are writes. `--reference FILE` reads FILE.
export default defineCommand(["chmod"], specThenWriteCmd());

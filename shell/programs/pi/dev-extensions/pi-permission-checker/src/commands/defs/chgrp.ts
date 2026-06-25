import { defineCommand, specThenWriteCmd } from "../helpers.ts";

// chgrp GROUP FILE... — GROUP is not a path; files are writes. `--reference FILE` reads FILE.
export default defineCommand(["chgrp"], specThenWriteCmd());

import { defineCommand, wrapperCmd } from "../helpers.ts";

export default defineCommand(["ionice"], wrapperCmd(["-c", "-n", "-p"]));

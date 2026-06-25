import { defineCommand, wrapperCmd } from "../helpers.ts";

export default defineCommand(["stdbuf"], wrapperCmd(["-i", "-o", "-e"]));

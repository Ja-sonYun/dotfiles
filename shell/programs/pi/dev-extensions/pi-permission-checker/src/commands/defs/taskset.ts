import { defineCommand, wrapperCmd } from "../helpers.ts";

export default defineCommand(["taskset"], wrapperCmd(["-c", "-p"]));

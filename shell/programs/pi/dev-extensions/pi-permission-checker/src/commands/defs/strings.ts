import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(["strings"], readCmd(["-n", "-t"]));

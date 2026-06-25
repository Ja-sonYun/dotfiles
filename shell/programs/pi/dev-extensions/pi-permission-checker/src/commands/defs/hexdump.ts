import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(["hexdump"], readCmd(["-n", "-s", "-e", "-f"]));

import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(
  ["od"],
  readCmd(["-N", "-j", "-A", "-t", "-S", "-w"]),
);

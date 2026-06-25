import { defineCommand, writeCmd } from "../helpers.ts";

// All operands are written. tee has no value-taking flags (-p/-a/-i are booleans).
export default defineCommand(["tee"], writeCmd());

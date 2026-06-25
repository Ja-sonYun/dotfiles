import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(["pr"], readCmd(["-l", "-w", "-o"]));

import { defineCommand, writeCmd } from "../helpers.ts";

export default defineCommand(["mkfifo"], writeCmd(["-m", "--mode"]));

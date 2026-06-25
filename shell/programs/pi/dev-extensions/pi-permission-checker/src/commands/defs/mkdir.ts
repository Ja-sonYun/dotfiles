import { defineCommand, writeCmd } from "../helpers.ts";

export default defineCommand(["mkdir"], writeCmd(["-m", "--mode"]));

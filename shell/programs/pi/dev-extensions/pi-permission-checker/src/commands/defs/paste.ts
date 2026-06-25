import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(["paste"], readCmd(["-d", "--delimiters"]));

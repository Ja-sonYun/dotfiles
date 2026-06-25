import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(["fold"], readCmd(["-w"]));

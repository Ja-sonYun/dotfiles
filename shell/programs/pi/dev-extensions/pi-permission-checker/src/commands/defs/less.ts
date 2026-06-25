import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(["less", "more"], readCmd());

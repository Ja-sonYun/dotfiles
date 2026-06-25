import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(["column"], readCmd(["-s", "-o", "-c"]));

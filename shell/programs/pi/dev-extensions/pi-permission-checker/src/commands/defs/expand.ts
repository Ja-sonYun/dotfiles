import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(["expand", "unexpand"], readCmd(["-t", "--tabs"]));

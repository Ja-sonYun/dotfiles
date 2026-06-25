import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(["xxd"], readCmd(["-s", "-l", "-c", "-g"]));

import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(["file"], readCmd(["-m"]));

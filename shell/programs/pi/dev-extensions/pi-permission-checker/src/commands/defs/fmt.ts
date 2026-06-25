import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(["fmt"], readCmd(["-w"]));

import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(["base64", "base32"], readCmd(["-w", "--wrap"]));

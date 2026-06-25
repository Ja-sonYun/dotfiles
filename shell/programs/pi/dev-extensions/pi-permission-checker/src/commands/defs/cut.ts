import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(
  ["cut"],
  readCmd([
    "-f",
    "-d",
    "-c",
    "-b",
    "--output-delimiter",
    "--fields",
    "--delimiter",
    "--characters",
    "--bytes",
  ]),
);

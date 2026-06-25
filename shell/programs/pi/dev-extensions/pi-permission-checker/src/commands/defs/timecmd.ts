import { defineCommand, wrapperCmd } from "../helpers.ts";

export default defineCommand(
  ["time"],
  wrapperCmd(["-o", "--output", "-f", "--format"]),
);

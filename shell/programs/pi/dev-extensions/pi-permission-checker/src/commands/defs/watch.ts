import { defineCommand, wrapperCmd } from "../helpers.ts";

export default defineCommand(
  ["watch"],
  wrapperCmd(["-n", "--interval", "-d", "--differences"]),
);

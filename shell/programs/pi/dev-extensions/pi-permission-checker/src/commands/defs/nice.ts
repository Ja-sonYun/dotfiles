import { defineCommand, wrapperCmd } from "../helpers.ts";

export default defineCommand(["nice"], wrapperCmd(["-n", "--adjustment"]));

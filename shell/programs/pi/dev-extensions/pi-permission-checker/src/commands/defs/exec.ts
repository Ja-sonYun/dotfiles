import { defineCommand, wrapperCmd } from "../helpers.ts";

export default defineCommand(["exec"], wrapperCmd(["-a"]));

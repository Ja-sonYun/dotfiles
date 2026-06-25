import { defineCommand, wrapperCmd } from "../helpers.ts";

export default defineCommand(["chrt"], wrapperCmd(["-p"]));

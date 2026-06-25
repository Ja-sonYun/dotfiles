import { defineCommand, opaqueAsk } from "../helpers.ts";

export default defineCommand(["make", "gmake"], () => opaqueAsk());

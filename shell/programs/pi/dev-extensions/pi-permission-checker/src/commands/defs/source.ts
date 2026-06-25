import { defineCommand, opaqueAsk } from "../helpers.ts";

// `source FILE` / `. FILE` reads and executes a script in the current shell. The file is a
// read, but the executed contents can't be statically analyzed → force an ask.
export default defineCommand(["source", "."], (argv) => {
  const file = argv[1];
  const acc =
    file && file !== "-" ? [{ kind: "read" as const, path: file }] : [];
  return { ...opaqueAsk(), pathAccesses: acc };
});

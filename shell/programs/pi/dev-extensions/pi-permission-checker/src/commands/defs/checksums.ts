import { defineCommand, readCmd } from "../helpers.ts";

export default defineCommand(
  [
    "md5sum",
    "sha1sum",
    "sha224sum",
    "sha256sum",
    "sha384sum",
    "sha512sum",
    "cksum",
    "b2sum",
    "shasum",
  ],
  readCmd(["-a"]),
);

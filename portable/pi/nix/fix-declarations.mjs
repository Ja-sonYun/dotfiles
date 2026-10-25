import {
  chmodSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

const modules = process.argv[2];
const providers = join(modules, "@earendil-works/pi-ai/dist/providers");

for (const name of readdirSync(providers)) {
  if (!name.endsWith(".models.d.ts")) continue;

  const file = join(providers, name);
  const source = readFileSync(file, "utf8");
  const updated = source.replace(
    /^(import values from "\.\/data\/[^"\n]+\.json");/m,
    '$1 with { type: "json" };',
  );
  if (updated === source) {
    throw new Error(`Expected JSON model import in ${file}`);
  }
  chmodSync(file, statSync(file).mode | 0o200);
  writeFileSync(file, updated);
}

const findDeclaration = join(
  modules,
  "@earendil-works/pi-coding-agent/dist/core/tools/find.d.ts",
);
const source = readFileSync(findDeclaration, "utf8");
if (!source.includes("pathModule?: path.PlatformPath")) {
  throw new Error(`Expected PlatformPath parameter in ${findDeclaration}`);
}
writeFileSync(
  findDeclaration,
  source.replace("pathModule?: path.PlatformPath", "pathModule?: typeof path"),
);

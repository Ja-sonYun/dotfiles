{ pkgs, ... }:

let
  name = "rpiv-pi";
  packageName = "@juicesharp/rpiv-pi";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "rpiv-pi";
    packageManager = "npm";
    packageVersion = "1.19.1";
    extraPackages = [
      "@juicesharp/rpiv-workflow@1.19.1"
    ];
    postInstall = ''
      substituteInPlace "$NODE_PATH/lib/node_modules/${packageName}/extensions/rpiv-core/package-checks.ts" \
        --replace-fail 'export function findMissingSiblings(): SiblingPlugin[] {
	const result = readPiAgentSettings();
	if (!result) return [...SIBLINGS];
	const installed = result.packages.filter((e): e is string => typeof e === "string");
	return SIBLINGS.filter((s) => !installed.some((entry) => s.matches.test(entry)));
}' 'export function findMissingSiblings(): SiblingPlugin[] {
	const result = readPiAgentSettings();
	const configured = result?.packages.filter((e): e is string => typeof e === "string") ?? [];
	const cliExtensions: string[] = [];

	for (let i = 0; i < process.argv.length; i++) {
		const arg = process.argv[i];
		if (arg === "-e" || arg === "--extension") {
			const next = process.argv[i + 1];
			if (typeof next === "string") cliExtensions.push(next);
			i++;
			continue;
		}
		if (arg?.startsWith("--extension=")) {
			cliExtensions.push(arg.slice("--extension=".length));
		}
	}

	const installed = [...configured, ...cliExtensions];
	return SIBLINGS.filter((s) => !installed.some((entry) => s.matches.test(entry)));
}'
    '';
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
  siblingExtensionPaths = {
    rpivWorkflow = "${package}/node_modules/${name}/lib/node_modules/@juicesharp/rpiv-workflow";
  };
}

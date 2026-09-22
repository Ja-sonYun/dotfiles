{
  config,
  lib,
  dream2nix,
  pkgs,
  spec,
  system,
  packageManifest,
  ...
}:
{
  imports = [
    dream2nix.modules.dream2nix.nodejs-package-json-v3
    dream2nix.modules.dream2nix.nodejs-granular-v3
    {
      options.nodejs-package-json.packageJson = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = packageManifest;
      };
    }
  ];

  inherit (packageManifest) name;
  deps = { nixpkgs, ... }: {
    nodejs = nixpkgs.nodejs_22;
    npm = pkgs.writeShellApplication {
      name = "npm";
      runtimeInputs = [
        nixpkgs.nodejs_22
        nixpkgs.jq
      ];
      text = ''
        ${nixpkgs.nodejs_22}/bin/npm "$@"

        missing=$(jq -r '.packages | to_entries[] | select(.key != "" and .value.integrity == null) | .key' package-lock.json)
        while IFS= read -r entry; do
          if [[ -z "$entry" ]]; then
            continue
          fi

          name=$(jq -r --arg entry "$entry" '.packages[$entry] | .name // ($entry | split("node_modules/") | last)' package-lock.json)
          version=$(jq -r --arg entry "$entry" '.packages[$entry].version' package-lock.json)
          resolved=$(jq -r --arg entry "$entry" '.packages[$entry].resolved' package-lock.json)
          if ! metadata=$(${nixpkgs.nodejs_22}/bin/npm view --registry=https://registry.npmjs.org "$name@$version" name version dist --json); then
            echo "Could not fetch registry metadata for $entry: $name@$version" >&2
            exit 1
          fi
          if ! integrity=$(jq -er --arg name "$name" --arg version "$version" --arg resolved "$resolved" '
            select(.name == $name and .version == $version and .dist.tarball == $resolved)
            | .dist.integrity | strings | select(test("^(sha256|sha512)-[A-Za-z0-9+/]+=*$"))
          ' <<< "$metadata"); then
            echo "No matching registry integrity for $entry: $name@$version ($resolved)" >&2
            exit 1
          fi

          jq --arg entry "$entry" --arg integrity "$integrity" \
            '.packages[$entry].integrity = $integrity' package-lock.json > complete-package-lock.json
          mv complete-package-lock.json package-lock.json
        done <<< "$missing"
      '';
    };
  };

  # Override the upstream source read to keep the generated manifest out of evaluation.
  lock.invalidationData = lib.mkForce {
    packageJson = config.nodejs-package-json.packageJson;
    nodeVersion = config.deps.nodejs.version;
    targetSystem = system;
  };
  nodejs-package-json = {
    source = pkgs.writeTextDir "package.json" (builtins.toJSON config.nodejs-package-json.packageJson);
    npmArgs = [
      "--ignore-scripts"
      "--no-audit"
      "--no-fund"
    ];
  };
  nodejs-granular-v3 = {
    installMethod = "copy";
    buildScript = ":";
    overrideAll = {
      deps = { nixpkgs, ... }: {
        nodejs = nixpkgs.nodejs_22;
      };
      nodejs-granular-v3.buildScript = ":";
    };
  };

  mkDerivation = {
    src = config.nodejs-package-json.source;
    preInstall = ''
      appRoot="$out/lib/node_modules/${config.name}/node_modules/${spec.name}"
      mkdir -p "$out/bin"
      while IFS=$'\t' read -r binary target; do
        case "$binary" in
          ""|*/*|.*) echo "Invalid executable name: $binary" >&2; exit 1 ;;
        esac
        chmod +x "$appRoot/$target"
        ln -sf "$appRoot/$target" "$out/bin/$binary"
      done < <(jq -r '
        if (.bin | type) == "string" then
          [(.name | split("/") | last), .bin] | @tsv
        else
          (.bin // {} | to_entries[]) | [.key, .value] | @tsv
        end
      ' "$appRoot/package.json")
    '';
    postInstall = lib.mkDefault "";
  };
}

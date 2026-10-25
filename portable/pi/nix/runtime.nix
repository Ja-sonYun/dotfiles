{ pkgs, dream2nix }:
pkgs.lib.makeOverridable (
  {
    spec ? builtins.fromJSON (builtins.readFile ../package-spec.json),
    projectRoot ? ../.,
    packagePath ? ".",
    extraPath ? [ ],
    extraPythonPath ? "",
  }:
  let
    inherit (pkgs) lib;
    system = pkgs.stdenv.hostPlatform.system;
    version = spec.versions.${system} or (throw "Pi is not available on ${system}");
    packageManifest = {
      name = "dotfiles-pi";
      inherit version;
      private = true;
      dependencies = {
        ${spec.name} = version;
      }
      // lib.optionalAttrs (version == "1.4.0") {
        "@modelcontextprotocol/sdk" = "^1.25.2";
      };
    };
    wrapperArgs = lib.concatStringsSep " " (
      lib.optional (extraPath != [ ]) ''--prefix PATH : "${lib.makeBinPath extraPath}"''
      ++ lib.optional (extraPythonPath != "") ''--prefix PYTHONPATH : "${extraPythonPath}"''
    );
  in
  dream2nix.lib.evalModules {
    packageSets.nixpkgs = pkgs;
    specialArgs = {
      inherit
        pkgs
        spec
        system
        packageManifest
        ;
      dream2nixSource = dream2nix.outPath;
    };
    modules = [
      ./npm.nix
      ({ config, ... }: {
        inherit version;
        paths = {
          inherit projectRoot;
          projectRootFile = "flake.nix";
          package = packagePath;
          lockFile = "lock.${system}.json";
        };
        public.lockInvalidationHash = builtins.hashString "sha256" (
          builtins.toJSON config.lock.invalidationData
        );
        public.overrideAttrs = config.package-func.result.overrideAttrs;
        mkDerivation = {
          nativeBuildInputs = [
            pkgs.makeWrapper
            pkgs.patch
            pkgs.jq
          ];
          meta.platforms = builtins.attrNames spec.versions;
          postInstall = ''
            chmod -R u+w "$appRoot"
            for patchFile in ${../patches}/*.patch; do
              patch --batch --fuzz=0 -p1 -d "$appRoot" < "$patchFile"
            done
            ${lib.optionalString (version == "1.4.0") ''
              ${pkgs.nodejs_22}/bin/node ${./fix-declarations.mjs} \
                "$out/lib/node_modules/${config.name}/node_modules"
            ''}
            rm -f "$out/bin/pi"
            makeWrapper "${pkgs.nodejs_22}/bin/node" "$out/bin/pi" \
              --add-flags "$appRoot/dist/cli.js" ${wrapperArgs}
            makeWrapper "${pkgs.bash}/bin/bash" "$out/bin/pi-dev" \
              --add-flags ${../dev/pi-dev}
          '';
        };
      })
    ];
  }
) { }

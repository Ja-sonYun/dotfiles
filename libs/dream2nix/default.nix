{ pkgs, dream2nix }:
packageDir:
pkgs.lib.makeOverridable (
  {
    spec ? builtins.fromJSON (builtins.readFile (packageDir + "/package-spec.json")),
    projectRoot ? ../..,
    packagePath ? pkgs.lib.removePrefix "${toString projectRoot}/" (toString packageDir),
  }:
  let
    system = pkgs.stdenv.hostPlatform.system;
    version = spec.versions.${system} or (throw "${spec.name} is not available on ${system}");
    packageManifest = {
      name = "dotfiles-${baseNameOf packageDir}";
      inherit version;
      private = true;
      dependencies.${spec.name} = version;
    };
  in
  dream2nix.lib.evalModules {
    packageSets.nixpkgs = pkgs;
    specialArgs = {
      dream2nixSource = dream2nix.outPath;
      inherit
        pkgs
        spec
        system
        packageDir
        packageManifest
        ;
    };
    modules = [
      (
        if spec.registry == "pypi" then
          ./python.nix
        else if spec.registry == "npm" then
          ./npm.nix
        else
          throw "Unsupported registry: ${spec.registry}"
      )
      (
        { config, ... }:
        {
          inherit version;
          paths = {
            inherit projectRoot;
            projectRootFile = "flake.nix";
            package = packagePath;
            lockFile = "lock.${system}.json";
          };
          lock.invalidationData.targetSystem = system;
          public.lockInvalidationHash = builtins.hashString "sha256" (
            builtins.toJSON config.lock.invalidationData
          );
          mkDerivation.meta.platforms = builtins.attrNames spec.versions;
          public.overrideAttrs = config.package-func.result.overrideAttrs;
        }
      )
    ]
    ++ pkgs.lib.optional (builtins.pathExists (packageDir + "/dream2nix.nix")) (
      packageDir + "/dream2nix.nix"
    );
  }
) { }

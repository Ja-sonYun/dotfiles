{ pkgs, system, ... }:
let
  targetNodeVersion = {
    "22" = "22.15.1";
  };
  targetSystem =
    {
      "aarch64-darwin" = "darwin-arm64";
      "x86_64-darwin" = "darwin-x64";
      "x86_64-linux" = "linux-x64";
    }."${system}";
  sha256 = {
    "https://nodejs.org/dist/v22.15.1/node-v22.15.1-darwin-arm64.tar.gz" =
      "sha256-0mibhrF+G1Hnb4Af/i2azKQiXnbtpLhDw9hDjUp81v4=";
    "https://nodejs.org/dist/v22.15.1/node-v22.15.1-linux-x64.tar.gz" =
      "sha256-9LjuxoNwissaKnPHGCui3lRmpd1fcFk0oIMJA98oghw=";
  };
  mkNpmUrl =
    version: targetSystem:
    "https://nodejs.org/dist/v${version}/node-v${version}-${targetSystem}.tar.gz";
  nodeBinary = pkgs.lib.mapAttrs
    (
      name: version:
        pkgs.stdenv.mkDerivation {
          name = "node-${version}";
          src = pkgs.fetchurl {
            url = mkNpmUrl version targetSystem;
            sha256 = sha256."${mkNpmUrl version targetSystem}";
          };
          installPhase = ''
            runHook preInstall

            mkdir -p $out
            tar -C $out --strip-components=1 -xzf $src

            runHook postInstall
          '';
        }
    )
    targetNodeVersion;
in
{
  mkNpmGlobalPackageDerivation =
    { pkgs
    , name
    , packages ? [ ]
    , # List of packages to install, e.g. ["npm" "yarn" "express@latest"]
      exposedBinaries ? [ ]
    , buildInputs ? [ ]
    , postFixup ? { node ? null
                  ,
                  }:
        ""
    , postBuild ? ""
    , postInstall ? ""
    , outputHash ? null
    , nodeVersion ? "22"
    , ...
    }:
    let
      packagesRequirements = pkgs.lib.concatStringsSep " " packages;
      version = builtins.hashString "sha256" packagesRequirements;
      pname = "${name}-${version}";
      tarball = pkgs.stdenv.mkDerivation {
        name = "${pname}-tarball";
        src = nodeBinary."${nodeVersion}";
        doCheck = false;
        dontFixup = true;
        nativeBuildInputs = with pkgs; [
          cacert
          gnutar
        ];
        installPhase = ''
          runHook preInstall

          export HOME=$PWD
          export PATH=$src/bin:$PATH
          export CACHE=$HOME/cache

          npm install --ignore-scripts --no-audit --no-fund \
              --cache "$CACHE" \
              ${packagesRequirements}

          GZIP=-n tar --sort=name -C "$CACHE" -czf npm-cache.tgz "$CACHE" .
          mv npm-cache.tgz $out

          runHook postInstall
        '';

        outputHashAlgo = "sha256";
        outputHashMode = "recursive";
        outputHash = if outputHash == null then pkgs.lib.fakeSha256 else outputHash;
      };
    in
    pkgs.stdenv.mkDerivation {
      inherit name version pname;
      src = tarball;
      dontUnpack = true;
      nativeBuildInputs =
        with pkgs;
        [
          gnutar
          makeWrapper
          nodeBinary."${nodeVersion}"
        ]
        ++ buildInputs;

      installPhase = ''
        runHook preInstall

        mkdir -p $out/bin $out/node_modules/${name}
        export HOME=$PWD
        export NODE_PATH=$out/node_modules/${name}
        export NPM_CONFIG_CACHE=$HOME/cache

        mkdir -p $NPM_CONFIG_CACHE
        tar -C $NPM_CONFIG_CACHE -xzf $src

        npm install -g --prefix $NODE_PATH ${packagesRequirements} --offline --ignore-scripts

        for bin in ${builtins.concatStringsSep " " exposedBinaries}; do
          ln -s $NODE_PATH/bin/$bin $out/bin/$bin
        done

        runHook postInstall
      '';
      postBuild = postBuild;
      postInstall = postInstall;
      postFixup =
        ''
          patchShebangs $out
          cd $out
        ''
        + (postFixup {
          node = nodeBinary."${nodeVersion}";
        });
    };
}

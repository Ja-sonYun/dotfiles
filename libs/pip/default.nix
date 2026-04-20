{ pkgs, ... }:
let
  pythonVersions = {
    "312" = "3.12.10";
    "311" = "3.11.9";
  };
  pythonSha256 = {
    "3.12.10" = "sha256-B6tpdHRZXgbwZkdBfTx/qX3tB6/Bp+RFTFY5kZtG6uo=";
    "3.11.9" = "sha256-mx6JZSP8UQaREmyGRAbZNgo9Hphqy9pZzaV7Wr2kW4c=";
  };
  pythonBuilds = pkgs.lib.mapAttrs
    (
      name: version:
        let
          pythonForBuild = pkgs.buildPackages.python3;
        in
        pkgs.stdenv.mkDerivation rec {
          pname = "python";
          name = "${pname}-${version}";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://www.python.org/ftp/python/${version}/Python-${version}.tar.xz";
            sha256 = pythonSha256.${version};
          };

          nativeBuildInputs = with pkgs; [
            pkg-config
            pythonForBuild
          ];

          buildInputs = with pkgs; [
            openssl
            zlib
            bzip2
            expat
            libffi
            gdbm
            sqlite
            readline
            ncurses
            xz
          ];

          preConfigure = ''
            echo "_ssl _ssl.c -lssl -lcrypto" >> Modules/Setup.local

            export PKG_CONFIG_PATH="${pkgs.openssl.dev}/lib/pkgconfig:$PKG_CONFIG_PATH"

            export NIX_CFLAGS_COMPILE="-I${pkgs.openssl.dev}/include $NIX_CFLAGS_COMPILE"
            export NIX_LDFLAGS="-L${pkgs.openssl.out}/lib -rpath ${pkgs.openssl.out}/lib $NIX_LDFLAGS"

            sed -i "s|#_ssl|_ssl|" Modules/Setup
            sed -i "s|#[\t ]*-DUSE_SSL|-DUSE_SSL -I${pkgs.openssl.dev}/include|" Modules/Setup
            sed -i "s|#[\t ]*-L\$(SSL)|_ssl _ssl.c -L${pkgs.openssl.out}/lib|" Modules/Setup
          '';

          configureFlags = [
            "--enable-shared"
            "--with-system-expat"
            "--with-system-ffi"
            "--with-openssl=${pkgs.openssl.dev}"
            "--with-openssl-rpath=auto"
            "--with-computed-gotos"
            "--with-dbmliborder=gdbm:ndbm"
            "--enable-loadable-sqlite-extensions"
          ];

          enableParallelBuilding = true;

          postInstall = ''
            if $out/bin/python3 -c "import ssl; print('SSL support: OK')"; then
              echo "SSL module successfully built!"
            else
              echo "ERROR: SSL module still not available"
              exit 1
            fi
          '';
        }
    )
    pythonVersions;
in
{
  mkPipGlobalPackageDerivation =
    { pkgs
    , name
    , version
    , pythonVersion ? "312"
    , preInstall ? [ ]
    , # List of packages to install before pip packages, e.g. ["hatchling"]
      packages ? [ ]
    , # List of packages to install, e.g. ["numpy" "pandas" "scipy==1.10.1"]
      exposedBinaries ? [ ]
    , buildInputs ? [ ]
    , postBuild ? ""
    , postInstall ? ""
    , postFixup ? { python ? null
                  ,
                  }:
        ""
    , outputHash ? null
    , ...
    }:

    let
      pipRequirements = pkgs.lib.concatStringsSep " " packages;
      preInstallPipRequirements = pkgs.lib.concatStringsSep " " preInstall;
      pname = name;

      tarball = pkgs.stdenv.mkDerivation {
        name = "${pname}-${version}-tarball";
        phases = [ "buildPhase" ];
        nativeBuildInputs = with pkgs; [
          cacert
          gnutar
          git
          pythonBuilds."${pythonVersion}"
        ];
        buildPhase = ''
          runHook preInstall

          export HOME=$PWD
          export PATH=${pythonBuilds."${pythonVersion}"}/bin:$PATH
          mkdir -p wheelhouse

          python3 -m ensurepip --upgrade
          ${
            if preInstallPipRequirements != "" then
              "python3 -m pip download --dest wheelhouse ${preInstallPipRequirements};"
            else
              ""
          }
          python3 -m pip download --dest wheelhouse ${pipRequirements}

          GZIP=-n tar --sort=name -C wheelhouse -czf wheelhouse.tgz .
          mv wheelhouse.tgz $out

          runHook postInstall
        '';

        outputHashAlgo = "sha256";
        outputHashMode = "flat";
        outputHash = if outputHash == null then pkgs.lib.fakeSha256 else outputHash;
      };

      _pipRequirementsList = map
        (
          pkg:
          let
            match = builtins.match "git\\+https?://.*#egg=([^&]+)" pkg;
          in
          if match != null then builtins.elemAt match 0 else pkg
        )
        packages;
      wheelhousePipRequirements = pkgs.lib.concatStringsSep " " _pipRequirementsList;
    in
    pkgs.stdenv.mkDerivation {
      inherit version pname;
      name = "${pname}-${version}";
      src = tarball;
      dontUnpack = true;
      nativeBuildInputs =
        with pkgs;
        [
          gnutar
          makeWrapper
          pkgs."python${pythonVersion}"
        ]
        ++ buildInputs;

      installPhase = ''
        runHook preInstall

        mkdir -p $out/bin wheelhouse
        tar -C wheelhouse -xzf $src

        export HOME=$PWD
        python3 -m venv $out/venv/${name}
        source $out/venv/${name}/bin/activate

        ${
          if preInstallPipRequirements != "" then
            "python3 -m pip install --no-index --find-links=wheelhouse ${preInstallPipRequirements};"
          else
            ""
        }
        pip install --no-index --find-links=wheelhouse ${wheelhousePipRequirements};

        for bin in ${builtins.concatStringsSep " " exposedBinaries}; do
          ln -s $out/venv/${name}/bin/$bin $out/bin/$bin
        done

        deactivate

        runHook postInstall
      '';
      postBuild = postBuild;
      postInstall = postInstall;
      postFixup = ''
        patchShebangs $out
        cd $out
      ''
      + (postFixup {
        python = pkgs."python${pythonVersion}";
      });
    };
}

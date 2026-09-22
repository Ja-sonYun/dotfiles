{
  config,
  lib,
  dream2nix,
  dream2nixSource,
  pkgs,
  spec,
  ...
}:
let
  pipWheel = pkgs.fetchurl {
    url = "https://files.pythonhosted.org/packages/8a/6a/19e9fe04fca059ccf770861c7d5721ab4c2aebc539889e97c7977528a53b/pip-24.0-py3-none-any.whl";
    sha256 = "ba0d021a166865d2265246961bec0152ff124de910c5cc39f1156ce3fa7c69dc";
  };
  wheelWheel = pkgs.fetchurl {
    url = "https://files.pythonhosted.org/packages/7d/cd/d7460c9a869b16c3dd4e1e403cce337df165368c71d6af229a74699622ce/wheel-0.43.0-py3-none-any.whl";
    sha256 = "55c570405f142630c6b9f72fe09d9b67cf1477fcf543ae5b8dcb1f5b7377da81";
  };
  bootstrap = pkgs.linkFarm "pip-lock-bootstrap" [
    {
      name = "pip-24.0-py3-none-any.whl";
      path = pipWheel;
    }
    {
      name = "wheel-0.43.0-py3-none-any.whl";
      path = wheelWheel;
    }
  ];
  metadata =
    (import (dream2nixSource + "/pkgs/fetchPipMetadata/package.nix") {
      inherit lib;
      inherit (pkgs) python3 gitMinimal nix-prefetch-scripts;
    }).overrideAttrs
      (old: {
        doCheck = false;
        postPatch = (old.postPatch or "") + ''
          substituteInPlace fetch_pip_metadata/__init__.py \
            --replace-fail '"--upgrade",' '"--no-index", "--no-deps",' \
            --replace-fail 'f"pip=={pip_version}"' '"${bootstrap}/pip-24.0-py3-none-any.whl"' \
            --replace-fail 'f"wheel=={wheel_version}"' '"${bootstrap}/wheel-0.43.0-py3-none-any.whl"'
        '';
      });
  arguments = pkgs.writeText "pip-lock-arguments.json" (
    builtins.toJSON {
      inherit (config.pip)
        pipFlags
        pipVersion
        requirementsList
        requirementsFiles
        ;
      pythonInterpreter = "${config.deps.python}/bin/python";
      wheelVersion = "0.43.0";
    }
  );
in
{
  imports = [ dream2nix.modules.dream2nix.pip ];
  name = lib.concatStringsSep "-" (
    builtins.filter builtins.isString (builtins.split "[-_.]+" (lib.toLower spec.name))
  );
  deps = { nixpkgs, ... }: {
    python = nixpkgs.python312;
    fetchPipMetadataScript = lib.getExe (
      pkgs.writeShellApplication {
        name = "fetch-pip-metadata";
        runtimeInputs = [
          pkgs.nix
          pkgs.gitMinimal
          pkgs.openssh
        ]
        ++ config.pip.nativeBuildInputs;
        text = ''
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") config.pip.env
          )}
          exec ${metadata}/bin/fetch_pip_metadata \
            --json-args-file ${arguments} \
            --project-root "$(${config.paths.findRoot})"
        '';
      }
    );
  };
  buildPythonPackage.format = "wheel";
  pip = {
    requirementsList = lib.mkDefault [ "${spec.name}==${config.version}" ];
    pipFlags = [ "--only-binary=:all:" ];
    overrideAll.buildPythonPackage.format = "wheel";
  };
  lock.invalidationData.bootstrapWheels = [
    (toString pipWheel)
    (toString wheelWheel)
  ];
}

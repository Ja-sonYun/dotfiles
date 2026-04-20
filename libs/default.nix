{ pkgs, system }:
let
  npm = import ./npm { inherit pkgs system; };
  pip = import ./pip { inherit pkgs system; };
in
{
  inherit npm pip;

  mkPackageDerivation =
    { pkgs
    , hashKey
    , packageManager
    , packageName
    , packageVersion
    , packageSpec ? null
    , extraPackages ? [ ]
    , ...
    }@args:
    let
      basePackageSpec =
        if packageSpec != null then
          packageSpec
        else if packageManager == "npm" then
          "${packageName}@${packageVersion}"
        else if packageManager == "pip" then
          "${packageName}==${packageVersion}"
        else
          throw "Unsupported packageManager: ${packageManager}";

      commonArgs = builtins.removeAttrs args [
        "hashKey"
        "packageManager"
        "packageName"
        "packageVersion"
        "packageSpec"
        "extraPackages"
      ] // {
        version = packageVersion;
        outputHash = pkgs.hashfile.get {
          inherit hashKey packageVersion;
        };
        packages = [ basePackageSpec ] ++ extraPackages;
      };
    in
    if packageManager == "npm" then
      npm.mkNpmGlobalPackageDerivation commonArgs
    else if packageManager == "pip" then
      pip.mkPipGlobalPackageDerivation commonArgs
    else
      throw "Unsupported packageManager: ${packageManager}";
}

{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  discover =
    directory:
    lib.concatMap
      (
        name:
        let
          path = directory + "/${name}";
        in
        if builtins.pathExists (path + "/package-spec.json") then
          [ path ] ++ discover path
        else
          discover path
      )
      (
        builtins.attrNames (
          lib.filterAttrs (name: type: type == "directory" && name != "node_modules" && name != ".git") (
            builtins.readDir directory
          )
        )
      );
  directories = discover ../pkgs;
in
{
  packages = lib.genAttrs [ "aarch64-darwin" "x86_64-linux" ] (
    system:
    let
      pkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays =
          builtins.attrValues (import ../overlays { inherit inputs; })
          ++ builtins.attrValues inputs.nixlib.overlays;
      };
      inherit
        (import ../libs {
          inherit pkgs;
          inherit (inputs) dream2nix;
        })
        mkDreamPackage
        ;
      supported = builtins.filter (
        path: (builtins.fromJSON (builtins.readFile (path + "/package-spec.json"))).versions ? ${system}
      ) directories;
    in
    builtins.listToAttrs (
      lib.concatMap (
        path:
        let
          name = lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "${toString ../pkgs}/" (toString path));
        in
        [
          {
            inherit name;
            value = pkgs.callPackage path { };
          }
          {
            name = "${name}-lock";
            value = (mkDreamPackage path).lock;
          }
        ]
      ) supported
    )
  );
}

{ inputs }:
{
  package-functions =
    final: prev:
    let
      inherit
        (import ../libs {
          pkgs = final;
          inherit (inputs) dream2nix;
        })
        mkDreamPackage
        ;
      asPackage =
        registry:
        { root }:
        let
          spec = builtins.fromJSON (builtins.readFile (root + "/package-spec.json"));
        in
        assert final.lib.assertMsg (
          spec.registry == registry
        ) "Expected ${registry} package in ${toString root}/package-spec.json";
        mkDreamPackage root;
    in
    {
      python312 = prev.python312.overrideAttrs (oldAttrs: {
        passthru = (oldAttrs.passthru or { }) // {
          asPackage = asPackage "pypi";
        };
      });
      nodejs_22 = prev.nodejs_22.overrideAttrs (oldAttrs: {
        passthru = (oldAttrs.passthru or { }) // {
          asPackage = asPackage "npm";
        };
      });
    };
}

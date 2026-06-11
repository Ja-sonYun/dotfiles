{ pkgs, ... }:

let
  name = "context-mode";
  packageName = "context-mode";
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs name packageName;
    hashKey = "context-mode";
    packageManager = "npm";
    packageVersion = "1.0.162";
    buildInputs = with pkgs;
      [
        python3
      ]
      ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
        darwin.cctools
        xcbuild
      ];
    postInstall = ''
      export npm_config_build_from_source=true
      export npm_config_nodedir="$(dirname "$(dirname "$(command -v node)")")"

      better_sqlite3_dir="$NODE_PATH/lib/node_modules/context-mode/node_modules/better-sqlite3"
      npm \
        --prefix "$better_sqlite3_dir" \
        --offline \
        --foreground-scripts \
        run build-release

      test -f "$better_sqlite3_dir/build/Release/better_sqlite3.node"
    '';
  };
in
package // {
  piExtensionPath = "${package}/node_modules/${name}/lib/node_modules/${packageName}";
}

{ inputs }:
let
  inherit (inputs)
    git-hooks
    home-manager
    mkutils
    nixlib
    nixpkgs
    ;
  inherit (nixpkgs) lib;
  excludedPaths =
    let
      lines = lib.splitString "\n" (builtins.readFile ../.gitmodules);
      pathLines = builtins.filter (line: lib.hasInfix "path = " line) lines;
      submodulePaths = map (line: lib.trim (lib.last (lib.splitString " = " line))) pathLines;
    in
    submodulePaths ++ [ "portable/vim" ];
  excludeRegexes = map (path: "^" + lib.escapeRegex path + "/") excludedPaths;
  supportedSystems = [
    "aarch64-darwin"
    "x86_64-linux"
  ];
  forAllSystems = lib.genAttrs supportedSystems;

  checks = forAllSystems (
    system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      statixConfig = (pkgs.formats.toml { }).generate "statix.toml" {
        disabled = [ "repeated_keys" ];
        ignore = excludedPaths;
      };
    in
    {
      ai-tools = import ../tests/modules/programs/ai-agents {
        inherit
          home-manager
          nixlib
          pkgs
          ;
      };
      radare2 = import ../tests/modules/programs/radare2 {
        inherit home-manager pkgs;
      };
      pre-commit-check = git-hooks.lib.${system}.run {
        src = ../.;
        excludes = excludeRegexes;
        hooks = {
          nixfmt.enable = true;
          deadnix.enable = true;
          deadnix.settings.noLambdaPatternNames = true;
          statix.enable = true;
          statix.settings.config = toString statixConfig;
          beautysh = {
            enable = true;
            name = "beautysh";
            package = pkgs.beautysh;
            entry = "${pkgs.beautysh}/bin/beautysh --tab";
            types = [ "shell" ];
            excludes = [
              "^scripts/update-versions$"
              "^scripts/build-pkgs$"
            ];
          };
          prettier.enable = true;
          taplo.enable = true;
        };
      };
    }
  );
in
{
  inherit checks;
  devShells = forAllSystems (
    system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      default = pkgs.mkShell {
        inherit (checks.${system}.pre-commit-check) shellHook;
        buildInputs = checks.${system}.pre-commit-check.enabledPackages ++ [
          pkgs.amber-lang
          mkutils.packages.${system}.default
        ];
      };
    }
  );
}

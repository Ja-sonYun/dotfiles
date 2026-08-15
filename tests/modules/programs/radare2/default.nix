{ home-manager, pkgs }:
let
  inherit (pkgs) lib;
  baseModule = {
    home = {
      username = "test-user";
      homeDirectory = "/home/test-user";
      stateVersion = "26.05";
    };
    programs.radare2.package = pkgs.writeShellScriptBin "radare2" "exit 0";
  };
  generatedFilePrefixes = [
    ".config/radare2/"
    ".config/r2ai/"
    ".local/share/radare2/plugins/"
  ];
  mkCase =
    {
      name,
      module,
      expected,
    }:
    let
      configuration = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ../../../../modules/programs/radare2
          baseModule
          module
        ];
      };
      home = configuration.config.home;
      homeFiles = import ../../../lib/home-files.nix {
        inherit lib home pkgs;
      };
      actual = {
        generatedFiles = homeFiles.generated generatedFilePrefixes;
        files = lib.mapAttrs (
          destination: _expectation: homeFiles.materialized (lib.removePrefix "~/" destination)
        ) expected.files;
      };
    in
    {
      inherit actual expected name;
    };
  cases = [
    (mkCase {
      name = "radare2 extra config";
      module.programs.radare2 = {
        enable = true;
        extraConfig = ''
          e scr.color=1
          e asm.bytes=false
        '';
      };
      expected = {
        generatedFiles = [ "~/.config/radare2/radare2rc" ];
        files."~/.config/radare2/radare2rc".text = ''
          e scr.color=1
          e asm.bytes=false
        '';
      };
    })
    (mkCase {
      name = "radare2 plugin";
      module.programs.radare2 = {
        enable = true;
        plugins."test-plugin.r2.js" = ./fixtures/test-plugin.r2.js;
      };
      expected = {
        generatedFiles = [ "~/.local/share/radare2/plugins/test-plugin.r2.js" ];
        files."~/.local/share/radare2/plugins/test-plugin.r2.js".sameAs = ./fixtures/test-plugin.r2.js;
      };
    })
    (mkCase {
      name = "radare2 decai";
      module.programs.radare2 = {
        enable = true;
        decai = {
          enable = true;
          package = ./fixtures/decai.r2.js;
          settings = {
            api = "openai";
            cmds = "pdd,pdg";
            model = "test-model";
          };
        };
      };
      expected = {
        generatedFiles = [
          "~/.config/r2ai/decai.txt"
          "~/.local/share/radare2/plugins/decai.r2.js"
        ];
        files = {
          "~/.config/r2ai/decai.txt".text = ''
            api=openai
            cmds=pdd,pdg
            model=test-model
          '';
          "~/.local/share/radare2/plugins/decai.r2.js".sameAs = ./fixtures/decai.r2.js;
        };
      };
    })
  ];
  manifests = map (
    case:
    pkgs.writeText "${lib.strings.sanitizeDerivationName case.name}-expected-files.json" (
      builtins.toJSON case
    )
  ) cases;
in
pkgs.runCommand "radare2-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  ${pkgs.python3}/bin/python3 ${../../../lib/check-generated-files.py} \
    ${lib.escapeShellArgs manifests}
  printf 'PASS: radare2 generated the expected files in all cases.\n' > "$out"
''

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.radare2;
  decaiTxt = lib.concatMapStrings (n: "${n}=${cfg.decai.settings.${n}}\n") (
    lib.attrNames cfg.decai.settings
  );
  sourceType =
    with lib.types;
    oneOf [
      package
      path
      str
    ];

  # Read secrets at launch to avoid baking them into the store.
  wrappedPackage =
    if cfg.env == { } then
      cfg.package
    else
      pkgs.runCommand "${cfg.package.name}-wrapped" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
        mkdir -p $out/bin
        for b in ${cfg.package}/bin/*; do ln -s "$b" "$out/bin/$(basename "$b")"; done
        for b in r2 radare2; do
          rm -f "$out/bin/$b"
          makeWrapper ${cfg.package}/bin/$b $out/bin/$b \
            --run ${lib.escapeShellArg (pkgs.tool.shell.util.shellExports cfg.env)}
        done
      '';
in
{
  options.programs.radare2 = {
    enable = lib.mkEnableOption "radare2";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.radare2;
      description = "radare2 package.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "radare2rc content.";
    };

    plugins = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      example = lib.literalExpression ''{ "r2dec.r2.js" = ./r2dec.r2.js; }'';
      description = "Plugins by filename.";
    };

    env = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          pkgs.tool.secretValue.type
        ]
      );
      default = { };
      example = {
        OPENAI_API_KEY._secret = "/run/agenix/capi-key";
      };
      description = "Environment variables; supports { _secret = path; }.";
    };

    decai = {
      enable = lib.mkEnableOption "decai (r2ai decompiler plugin)";

      package = lib.mkOption {
        type = lib.types.path;
        default = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/radareorg/r2ai/888251a2eaf76820f2a8ddc681d16d2b0d3ed139/decai/decai.r2.js";
          sha256 = "1sjw84zrln2s7ai6dl9w9cviv3zw2z7n64l3jwj39l7y9rykrgr0";
        };
        description = "decai plugin package.";
      };

      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          api = "openai";
        };
        description = "decai evaluation variables.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ wrappedPackage ];

    home.file = lib.mkMerge [
      (lib.mkIf (cfg.extraConfig != "") {
        ".config/radare2/radare2rc".text = cfg.extraConfig;
      })
      (lib.mapAttrs' (
        name: src: lib.nameValuePair ".local/share/radare2/plugins/${name}" { source = src; }
      ) cfg.plugins)
      (lib.mkIf cfg.decai.enable {
        ".local/share/radare2/plugins/decai.r2.js".source = cfg.decai.package;
        ".config/r2ai/decai.txt".text = decaiTxt;
      })
    ];
  };
}

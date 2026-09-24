{
  pkgs,
  extraPath ? [ ],
  ...
}:

let
  package =
    (pkgs.nodejs_22.asPackage {
      root = ./.;
    }).overrideAttrs
      (old: {
        postInstall = old.postInstall + ''
          rm -f "$out/bin/claude"
          makeWrapper "${pkgs.nodejs_22}/bin/node" "$out/bin/claude" \
            --add-flags "$appRoot/cli-wrapper.cjs" \
            --set DISABLE_BUG_COMMAND              1 \
            --set DISABLE_INSTALLATION_CHECKS      1 \
            --set DISABLE_AUTOUPDATER              1 \
            --set CLAUDE_CODE_DISABLE_AUTO_MEMORY  1 \
            --set CLAUDE_CODE_DISABLE_MOUSE_CLICKS 1 \
            --set CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN 1 \
            --set DISABLE_ERROR_REPORTING          1 \
            ${pkgs.lib.optionalString (extraPath != [ ]) "--prefix PATH : ${pkgs.lib.makeBinPath extraPath}"}
        '';
      });
  blockConfigMutation =
    path:
    let
      command = pkgs.lib.concatStringsSep " " path;
    in
    {
      inherit path;
      matchAnywhere = true;
      command = ''
        printf '%s\n' ${pkgs.lib.escapeShellArg "error: claude ${command} is disabled; manage this setting in Nix."} >&2
        exit 1
      '';
    };
in
pkgs.command.hook {
  inherit package;
  binary = "claude";
  hooks = map blockConfigMutation [
    [
      "mcp"
      "add"
    ]
    [
      "mcp"
      "add-json"
    ]
    [
      "mcp"
      "add-from-claude-desktop"
    ]
    [
      "mcp"
      "remove"
    ]
    [
      "mcp"
      "reset-project-choices"
    ]
  ];
}

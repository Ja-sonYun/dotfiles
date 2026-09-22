{
  pkgs,
  extraPath ? [ ],
  extraPythonPath ? "",
  ...
}:

let
  wrapperArgs = pkgs.lib.concatStringsSep " \\\n      " (
    pkgs.lib.optional (extraPath != [ ]) ''--prefix PATH : "${pkgs.lib.makeBinPath extraPath}"''
    ++ pkgs.lib.optional (extraPythonPath != "") ''--prefix PYTHONPATH : "${extraPythonPath}"''
  );
  package =
    (pkgs.nodejs_22.asPackage {
      root = ./.;
    }).overrideAttrs
      (old: {
        postInstall =
          old.postInstall
          + pkgs.lib.optionalString (extraPath != [ ] || extraPythonPath != "") ''
            wrapProgram "$out/bin/codex" ${wrapperArgs}
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
        printf '%s\n' ${pkgs.lib.escapeShellArg "error: codex ${command} is disabled; manage this setting in Nix."} >&2
        exit 1
      '';
    };
in
pkgs.command.hook {
  inherit package;
  binary = "codex";
  hooks = map blockConfigMutation [
    [
      "mcp"
      "add"
    ]
    [
      "mcp"
      "remove"
    ]
    [
      "features"
      "enable"
    ]
    [
      "features"
      "disable"
    ]
  ];
}

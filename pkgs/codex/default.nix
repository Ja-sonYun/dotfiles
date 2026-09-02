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
  package = pkgs.lib.mkPackageDerivation {
    inherit pkgs;
    hashKey = "codex";
    packageManager = "npm";
    packageName = "@openai/codex";
    packageVersion = "0.152.1";
    name = "codex";
    exposedBinaries = [
      "codex"
    ];
    postInstall = pkgs.lib.optionalString (extraPath != [ ] || extraPythonPath != "") ''
      rm -f $out/bin/codex
      makeWrapper "$NODE_PATH/bin/codex" "$out/bin/codex" \
        ${wrapperArgs}
    '';
  };
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

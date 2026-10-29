{ pkgs, ... }:

(pkgs.nodejs_22.asPackage {
  root = ./.;
}).overrideAttrs
  (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];

    postFixup = (old.postFixup or "") + ''
      for program in rea rea-agents; do
        wrapProgram "$out/bin/$program" \
          --set GHIDRA_INSTALL_DIR "${pkgs.ghidra}/lib/ghidra" \
          --set JAVA_HOME "${pkgs.openjdk21.home}" \
          --prefix PATH : ${
            pkgs.lib.makeBinPath [
              pkgs.ghidra
              pkgs.openjdk21
            ]
          }
      done
    '';
  })

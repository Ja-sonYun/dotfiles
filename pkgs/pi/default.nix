{ pkgs, ... }:

pkgs.lib.mkPackageDerivation {
  inherit pkgs;
  hashKey = "pi";
  packageManager = "npm";
  packageName = "@earendil-works/pi-coding-agent";
  packageVersion = "0.80.2";
  name = "pi";
  exposedBinaries = [
    "pi"
  ];
  postFixup = _: ''
        mv $out/bin/pi $out/bin/pi-real
        pi_real="$out/bin/pi-real"
        cat > $out/bin/pi <<EOF
    #!${pkgs.runtimeShell}
    if [ -t 1 ]; then
      printf '\033[>4;1f\033[>4;2m'
      trap 'printf "\033[>4m\033[>4f"' EXIT
    fi

    "$pi_real" "\$@"
    status=\$?
    exit "\$status"
    EOF
        chmod +x $out/bin/pi
  '';
}

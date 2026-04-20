let
  pkgs = import <nixpkgs> { };
  system = builtins.currentSystem;
  hostname = "__HOSTNAME__";
  allhashfile = builtins.fromJSON (builtins.readFile __ROOT_DIR__/pkgs/hashfile.json);
  customLibs = import __ROOT_DIR__/libs { inherit pkgs system; };
  currentHostHashfile = allhashfile."${hostname}" or { };
  finalPkgs = pkgs // {
    hashfile = {
      raw = currentHostHashfile;
      all = allhashfile;
      get =
        { hashKey, packageVersion }:
        let
          entry = currentHostHashfile.${hashKey} or null;
        in
        if entry == null || !(builtins.isAttrs entry) || !(entry ? version) || !(entry ? hash) then
          pkgs.lib.fakeSha256
        else if entry.version == null || entry.hash == null || entry.version == "" || entry.hash == "" then
          pkgs.lib.fakeSha256
        else if entry.version != packageVersion then
          pkgs.lib.fakeSha256
        else
          entry.hash;
    };
    lib = pkgs.lib // customLibs;
  };
in
pkgs.callPackage __FILE__ { pkgs = finalPkgs; }

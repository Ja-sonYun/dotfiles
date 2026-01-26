{
  lib-injection = final: prev: {
    # Inject custom libs into the lib namespace
    lib =
      prev.lib
      // (import ../libs {
        pkgs = final;
        system = final.stdenv.hostPlatform.system;
      });
  };
}

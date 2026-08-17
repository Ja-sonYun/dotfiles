let
  ignoredTests = {
    aarch64-darwin = {
      disabledPythonPackages = [ ];
      ctest = { };
    };
  };
in
{
  ignored-tests =
    _final: prev:
    let
      current = ignoredTests.${prev.stdenv.hostPlatform.system} or { };
      disabledPythonPackages = current.disabledPythonPackages or [ ];
      ctest = current.ctest or { };
      pytest = current.pytest or { };
      disableTests =
        package:
        package.overrideAttrs (_: {
          doCheck = false;
          doInstallCheck = false;
        });
      ignoreCTestTests =
        package: tests:
        package.overrideAttrs (oldAttrs: {
          preCheck = (oldAttrs.preCheck or "") + ''
            cat <<'EOW' >>CTestCustom.cmake
            list(APPEND CTEST_CUSTOM_TESTS_IGNORE ${toString tests})
            EOW
          '';
        });
      ignorePytestTests =
        package: tests:
        package.overridePythonAttrs (oldAttrs: {
          disabledTestPaths = (oldAttrs.disabledTestPaths or [ ]) ++ tests;
        });
    in
    prev.lib.mapAttrs (name: tests: ignoreCTestTests prev.${name} tests) ctest
    // {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (
          _pythonFinal: pythonPrev:
          (prev.lib.genAttrs disabledPythonPackages (name: disableTests pythonPrev.${name}))
          // prev.lib.mapAttrs (name: tests: ignorePytestTests pythonPrev.${name} tests) pytest
        )
      ];
    };
}

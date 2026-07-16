{
  disable-selected-python-tests =
    _final: prev:
    let
      packages = [
        "backrefs"
        "inline-snapshot"
        "seaborn"
      ];
      disableTests =
        package:
        let
          disabled = package.overridePythonAttrs (_: {
            doCheck = false;
          });
        in
        disabled
        // prev.lib.optionalAttrs (package ? override) {
          override = args: disableTests (package.override args);
        };
    in
    {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (_pythonFinal: pythonPrev: prev.lib.genAttrs packages (name: disableTests pythonPrev.${name}))
      ];
    };
}

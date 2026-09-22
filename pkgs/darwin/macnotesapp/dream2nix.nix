{ lib, ... }:
{
  # Both packages are direct app dependencies; remove their optional dependency cycle.
  pip.overrides.lxml.mkDerivation.propagatedBuildInputs = lib.mkForce [ ];
}

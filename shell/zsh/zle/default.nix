{ hasTag, lib, ... }:
{
  imports = lib.optionals (hasTag "ai") [
    ./better_grammar
    ./command_generator
  ];
}

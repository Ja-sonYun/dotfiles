{ inputs, ... }:
{
  vim = inputs.vim.overlays.default;
  say = inputs.say.overlays.default;
  plot = inputs.plot.overlays.default;
  seqdia = inputs.sequence-diagram-cli.overlays.default;
}

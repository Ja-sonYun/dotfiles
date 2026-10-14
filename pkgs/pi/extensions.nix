{ pkgs, ... }:
{
  providers = import ./extensions/providers { inherit pkgs; };
  subagent = import ./extensions/subagent { inherit pkgs; };
  permissions = import ./extensions/permissions { inherit pkgs; };
  redact = import ./extensions/redact { inherit pkgs; };
  message-lines = import ./extensions/message-lines { inherit pkgs; };
}

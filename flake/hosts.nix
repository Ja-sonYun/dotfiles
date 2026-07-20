let
  tagConfig = import ./tags.nix;
  hosts =
    builtins.mapAttrs
      (
        hostname: host:
        host
        // {
          paths = {
            dotfiles = "${host.userhome}/dotfiles";
            cache = "${host.userhome}/.nixcache/${host.username}";
          };
          tags = tagConfig.validate "host '${hostname}'" host.tags;
        }
      )
      {
        "Jays-MacBook-Pro" = {
          system = "aarch64-darwin";
          username = "jaykuroyanagi";
          useremail = "jason@abex.dev";
          userhome = "/Users/jaykuroyanagi";
          tags = [
            "gui"
            "ai"
          ];
        };
        "Jays-MacBook-Pro-Server" = {
          system = "aarch64-darwin";
          username = "jaykuroyanagi";
          useremail = "jason@abex.dev";
          userhome = "/Users/jaykuroyanagi";
          tags = [
            "gui"
            "server"
            "ai"
          ];
        };
        "linux-devel" = {
          system = "x86_64-linux";
          username = "vagrant";
          useremail = "jason@abex.dev";
          userhome = "/home/vagrant";
          tags = [
            "server"
          ];
        };
        "Jasonyun-wsl-server" = {
          system = "x86_64-linux";
          username = "jason";
          useremail = "jason@abex.dev";
          userhome = "/home/jason";
          tags = [
            "server"
            "gpu"
            "wsl"
          ];
        };
      };
in
{
  inherit hosts;
  hasTag = hostname: tagConfig.has hosts.${hostname}.tags;
}

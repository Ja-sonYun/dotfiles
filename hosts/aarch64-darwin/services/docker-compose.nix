{
  services.dockerCompose = {
    dockerBin = "/usr/local/bin/docker";
    extraPath = [
      "/usr/local/bin"
      "/opt/homebrew/bin"
      "/Applications/OrbStack.app/Contents/MacOS/xbin"
    ];
  };
}

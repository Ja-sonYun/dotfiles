{ config, ... }:
{
  services.atticCacheUpload = {
    enable = true;
    endpoint = "https://ncc.test0.zip/";
    tokenFile = config.age.secrets."nix-cache-upload-token".path;
    cache = "default";
    jobs = 5;
  };
}

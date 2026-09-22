{
  base64 = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "sha256-JzN66rrW/64FwmXEUEkGKO8+vUtnvlglc5MidYj1qXs=";
      type = "gem";
    };
    version = "0.3.0";
  };
  bigdecimal = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "sha256-Yevh5eVZvcPMbywO5/QnMh/IOPWWEcKUNW6wTW4hz2Y=";
      type = "gem";
    };
    version = "4.1.3";
  };
  csv = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "sha256-q6YeflB6ZvA9RcsfPEtjWYYcNQQDi0IpYoddzgmeRFY=";
      type = "gem";
    };
    version = "3.3.6";
  };
  icalPal = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "sha256-B9pXUYHTexvnvreCn4k/a7Yj7CEx/XqzvkvCL/ft/Ss=";
      type = "gem";
    };
    version = "3.7.0";
  };
  mini_portile2 = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "sha256-DNfH+CTgEMBy4z9ovALYWgCutvzgW7SBnAPf08FAwok=";
      type = "gem";
    };
    version = "2.8.9";
  };
  ostruct = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "sha256-laLtSkvR0ZB4TmZrR7LT8Hjkqe/aL8zxj4TdxlOO2RI=";
      type = "gem";
    };
    version = "0.6.3";
  };
  plist = {
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "sha256-03pFJ8wRFgZDk99LQOHbvJTGX6nKLuxS7fmhNhZxikI=";
      type = "gem";
    };
    version = "3.7.2";
  };
  sqlite3 = {
    dependencies = [ "mini_portile2" ];
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "sha256-lW/mBpVkINBKxxV9Os5iDIyrohNbLgXHbkg0k9ok0I4=";
      type = "gem";
    };
    version = "2.9.6";
  };
  timezone = {
    dependencies = [
      "base64"
      "ostruct"
    ];
    groups = [ "default" ];
    platforms = [ ];
    source = {
      remotes = [ "https://rubygems.org" ];
      sha256 = "sha256-/g5AHEDEsziQlr+Hg8STEZneGyP6v6aM5FaIcSpONOs=";
      type = "gem";
    };
    version = "1.3.30";
  };
}

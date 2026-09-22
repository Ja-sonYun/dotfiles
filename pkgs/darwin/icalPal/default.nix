{ pkgs, lib, ... }:

pkgs.bundlerEnv {
  pname = "icalPal";
  ruby = pkgs.ruby_3_4;
  gemdir = ./.;
  gemConfig = pkgs.defaultGemConfig // {
    icalPal = _: {
      dontBuild = false;
      # Lock the Ruby 3.4 dependencies instead of installing them in extconf.rb.
      postPatch = ''
        cat > ext/extconf.rb <<'RUBY'
        File.write("Makefile", "clean:\n\ttrue\ninstall:\n\ttrue\n")
        RUBY
      '';
    };
  };

  meta = with lib; {
    description = "Ruby gem that accesses macOS calendar data";
    mainProgram = "icalPal";
    platforms = platforms.darwin;
    license = licenses.gpl3Plus;
  };
}

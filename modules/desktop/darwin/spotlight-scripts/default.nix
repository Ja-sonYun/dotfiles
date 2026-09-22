{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.spotlightScripts;
  shortVersion = "1.0.0";
  generatorVersion = 1;

  hexValues = {
    "0" = 0;
    "1" = 1;
    "2" = 2;
    "3" = 3;
    "4" = 4;
    "5" = 5;
    "6" = 6;
    "7" = 7;
    "8" = 8;
    "9" = 9;
    a = 10;
    b = 11;
    c = 12;
    d = 13;
    e = 14;
    f = 15;
  };

  hexToInt =
    value:
    lib.foldl' (result: character: result * 16 + hexValues.${character}) 0 (
      lib.stringToCharacters value
    );

  modulo = value: divisor: value - (value / divisor) * divisor;

  appType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        displayName = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Name shown in Spotlight.";
        };

        command = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          description = "Command and arguments executed by the application.";
        };

        runAsAdmin = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Run the command with administrator privileges.";
        };

        icon = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "SVG source rendered as the application icon.";
        };

        appleEventsUsageDescription = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Reason the application sends Apple events.";
        };
      };
    }
  );

  mkSpotlightApp =
    name: app:
    let
      command = lib.escapeShellArgs app.command;
      bundleIdentifier = "${cfg.bundleIdentifierPrefix}.${name}";
      fingerprint = builtins.hashString "sha256" (
        builtins.toJSON {
          inherit bundleIdentifier generatorVersion;
          inherit (app)
            appleEventsUsageDescription
            command
            displayName
            runAsAdmin
            ;
          iconHash = if app.icon == null then null else builtins.hashFile "sha256" app.icon;
        }
      );
      hashNumber = hexToInt (builtins.substring 0 8 fingerprint);
      normalizedVersion = modulo hashNumber 90000000;
      bundleVersion = builtins.concatStringsSep "." [
        (toString (1000 + normalizedVersion / 10000))
        (toString (modulo (normalizedVersion / 100) 100))
        (toString (modulo normalizedVersion 100))
      ];

      cli = pkgs.writeShellApplication {
        inherit name;
        text = ''
          exec ${lib.optionalString app.runAsAdmin "/usr/bin/sudo "}${command}
        '';
      };

      launcher = pkgs.writeShellScript "${name}-spotlight-launcher" (
        if app.runAsAdmin then
          let
            appleScript = "do shell script ${builtins.toJSON command} with administrator privileges";
          in
          ''
            exec /usr/bin/osascript -e ${lib.escapeShellArg appleScript}
          ''
        else
          ''
            exec ${command}
          ''
      );

      info = pkgs.writeText "${name}-Info.plist" ''
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleDisplayName</key>
          <string>${lib.escapeXML app.displayName}</string>
          <key>CFBundleExecutable</key>
          <string>${lib.escapeXML name}</string>
          <key>CFBundleIdentifier</key>
          <string>${lib.escapeXML bundleIdentifier}</string>
          ${lib.optionalString (app.icon != null) ''
            <key>CFBundleIconFile</key>
            <string>AppIcon</string>
          ''}
          <key>CFBundleInfoDictionaryVersion</key>
          <string>6.0</string>
          <key>CFBundleName</key>
          <string>${lib.escapeXML app.displayName}</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>CFBundleShortVersionString</key>
          <string>${shortVersion}</string>
          <key>CFBundleVersion</key>
          <string>${bundleVersion}</string>
          <key>LSUIElement</key>
          <true/>
          ${lib.optionalString (app.appleEventsUsageDescription != null) ''
            <key>NSAppleEventsUsageDescription</key>
            <string>${lib.escapeXML app.appleEventsUsageDescription}</string>
          ''}
        </dict>
        </plist>
      '';

      appContents = "Applications/${app.displayName}.app/Contents";
    in
    pkgs.runCommand "${name}-spotlight-app-${shortVersion}"
      {
        nativeBuildInputs = lib.optionals (app.icon != null) [
          pkgs.libicns
          pkgs.librsvg
        ];
        meta = {
          description = "Spotlight application for ${app.displayName}";
          platforms = lib.platforms.darwin;
        };
      }
      ''
        mkdir -p "$out/bin"
        ln -s ${cli}/bin/${lib.escapeShellArg name} "$out/bin/"${lib.escapeShellArg name}

        app_dir="$out/"${lib.escapeShellArg appContents}
        mkdir -p "$app_dir/MacOS"
        cp ${launcher} "$app_dir/MacOS/"${lib.escapeShellArg name}
        cp ${info} "$app_dir/Info.plist"
        ${lib.optionalString (app.icon != null) ''
          mkdir -p "$app_dir/Resources"
          icon_dir="icon-${name}"
          mkdir -p "$icon_dir"
          for size in 16 32 48 128 256 512 1024; do
            rsvg-convert \
              --width "$size" \
              --height "$size" \
              --output "$icon_dir/icon-$size.png" \
              ${app.icon}
          done
          png2icns \
            "$app_dir/Resources/AppIcon.icns" \
            "$icon_dir/icon-16.png" \
            "$icon_dir/icon-32.png" \
            "$icon_dir/icon-48.png" \
            "$icon_dir/icon-128.png" \
            "$icon_dir/icon-256.png" \
            "$icon_dir/icon-512.png" \
            "$icon_dir/icon-1024.png"
        ''}
      '';
in
{
  options.programs.spotlightScripts = {
    enable = lib.mkEnableOption "Spotlight script applications";

    bundleIdentifierPrefix = lib.mkOption {
      type = lib.types.str;
      default = "local.spotlight-script";
      description = "Bundle identifier prefix used by generated applications.";
    };

    apps = lib.mkOption {
      type = lib.types.attrsOf appType;
      default = { };
      description = "Scripts exposed as command-line and Spotlight applications.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = lib.mapAttrsToList mkSpotlightApp cfg.apps;
  };
}

{ lib, pkgs, userhome, ... }:
let
  documentsPath = "${userhome}/Documents";
  documentsUri = "file://${userhome}/Documents";
  downloadsPath = "${userhome}/Downloads";
  downloadsUri = "file://${userhome}/Downloads";
  icloudDrivePath = "${userhome}/Library/Mobile Documents/com~apple~CloudDocs";
  icloudDriveUri = "file://${userhome}/Library/Mobile%20Documents/com~apple~CloudDocs";
  myfilesPath = "${icloudDrivePath}/Documents/MyFiles";
  myfilesUri = "${icloudDriveUri}/Documents/MyFiles";

  finder-sidebar = pkgs.writeShellApplication {
    name = "finder-sidebar";
    runtimeInputs = [ pkgs.mysides ];
    text = ''
      documents_path=${lib.escapeShellArg documentsPath}
      documents_uri=${lib.escapeShellArg documentsUri}
      downloads_path=${lib.escapeShellArg downloadsPath}
      downloads_uri=${lib.escapeShellArg downloadsUri}
      icloud_drive_path=${lib.escapeShellArg icloudDrivePath}
      icloud_drive_uri=${lib.escapeShellArg icloudDriveUri}
      myfiles_path=${lib.escapeShellArg myfilesPath}
      myfiles_uri=${lib.escapeShellArg myfilesUri}

      set_sidebar_item() {
        name=$1
        uri=$2

        mysides remove "$name" 2>/dev/null || true
        mysides add "$name" "$uri"
      }

      if [ -d "$documents_path" ]; then
        set_sidebar_item "Documents" "$documents_uri"
      fi

      if [ -d "$icloud_drive_path" ]; then
        current_month=$(/bin/date +%Y.%m)
        previous_month=$(/bin/date -v-1m +%Y.%m)

        /bin/mkdir -p "$myfiles_path/$current_month" "$myfiles_path/$previous_month"

        while IFS= read -r month_path; do
          month_name=$(/usr/bin/basename "$month_path")

          if [ "$month_name" = "$current_month" ] || [ "$month_name" = "$previous_month" ]; then
            continue
          fi

          mysides remove "$month_name" 2>/dev/null || true
        done < <(/usr/bin/find "$myfiles_path" -maxdepth 1 -type d -name '????.??')

        set_sidebar_item "$current_month" "$myfiles_uri/$current_month"
        set_sidebar_item "$previous_month" "$myfiles_uri/$previous_month"
        set_sidebar_item "iCloud Drive" "$icloud_drive_uri"
      fi

      if [ -d "$downloads_path" ]; then
        set_sidebar_item "Downloads" "$downloads_uri"
      fi
    '';
  };
in
{
  launchd.agents.finder-sidebar = {
    enable = true;
    config = {
      Label = "com.user.finder-sidebar";
      ProgramArguments = [ "${finder-sidebar}/bin/finder-sidebar" ];
      StartCalendarInterval = [{
        Hour = 0;
        Minute = 5;
      }];
      RunAtLoad = true;
      StandardOutPath = "/tmp/finder-sidebar.log";
      StandardErrorPath = "/tmp/finder-sidebar.log";
    };
  };
}

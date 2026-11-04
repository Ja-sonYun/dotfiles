{
  hasTag,
  userhome,
  osConfig,
  ...
}:
let
  icloudDrive = "${userhome}/Library/Mobile Documents/com~apple~CloudDocs";
in
{
  services.finderSidebar = {
    enable = hasTag "gui";
    items = [
      {
        name = "Documents";
        path = "${userhome}/Documents";
      }
      {
        name = "iCloud Drive";
        path = icloudDrive;
      }
      {
        name = "Downloads";
        path = "${userhome}/Downloads";
      }
    ];
    hiddenItems = [
      {
        name = "Recents";
        uri = "file:///System/Library/CoreServices/Finder.app/Contents/Resources/MyLibraries/myDocuments.cannedSearch";
      }
    ];
    monthlyFolders = {
      path = (builtins.head osConfig.services.fileOrganizer.policies).destination;
      format = (builtins.head osConfig.services.fileOrganizer.policies).monthFormat;
      after = "Documents";
    };
  };
}

{
  hasTag,
  userhome,
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
      path = "${icloudDrive}/Documents/MyFiles";
      after = "Documents";
    };
  };
}

{
  config,
  hasTag,
  username,
  userhome,
  ...
}:
{
  services.fileOrganizer = {
    enable = hasTag "gui" && hasTag "ai";
    apiKeyFile = config.home-manager.users.${username}.age.secrets."typesafe-api-key".path;
    onMonthlyFoldersReady = config.home-manager.users.${username}.services.finderSidebar.refreshCommand;
    policies = [
      {
        source = "${userhome}/Downloads";
        destination = "${userhome}/Library/Mobile Documents/com~apple~CloudDocs/Documents/MyFiles";
        maxFileSize = 1000000000;
      }
    ];
    tags = {
      CAD = "Computer-aided design drawings or engineering models";
      "3DModel" = "Three-dimensional models, meshes, or scenes";
      Receipt = "Proof of completed payment";
      Invoice = "A bill requesting payment";
      Contract = "A legal agreement";
      Report = "A report of findings or results";
      Manual = "Instructions for using a product";
      Paper = "An academic research paper";
      Finance = "Financial or accounting material";
      Technology = "Technical or computing material";
      Travel = "Travel-related material";
      Health = "Health-related material";
      Learning = "Educational material";
      Work = "Explicit evidence of professional work use";
      Personal = "Explicit evidence of personal use";
    };
    extensions = {
      ".step" = [
        "CAD"
        "3DModel"
      ];
      ".stp" = [
        "CAD"
        "3DModel"
      ];
      ".iges" = [
        "CAD"
        "3DModel"
      ];
      ".igs" = [
        "CAD"
        "3DModel"
      ];
      ".dwg" = [ "CAD" ];
      ".dxf" = [ "CAD" ];
      ".stl" = [ "3DModel" ];
      ".obj" = [ "3DModel" ];
      ".fbx" = [ "3DModel" ];
      ".gltf" = [ "3DModel" ];
      ".glb" = [ "3DModel" ];
      ".blend" = [ "3DModel" ];
    };
  };
}

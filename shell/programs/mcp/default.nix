{ pkgs
, config
, ...
}:
{
  programs.mcp = {
    enable = true;
    servers = {
      context7 = {
        command = toString (pkgs.writeShellScript "context7-mcp-wrapper" ''
          ${pkgs.context7}/bin/context7-mcp \
            --api-key "$(cat ${config.age.secrets.context7-api-key.path})"
        '');
        args = [ ];
        env = { };
      };
      websearch = {
        command = toString (pkgs.writeShellScript "firecrawl-mcp-wrapper" ''
          export FIRECRAWL_API_URL="https://firecrawl.test0.zip"
          export FIRECRAWL_API_KEY="$(cat ${config.age.secrets.capi-key.path})"
          exec ${pkgs.firecrawl-mcp}/bin/firecrawl-mcp
        '');
        args = [ ];
        env = { };
      };
      aws-documentation = {
        command = "${pkgs.aws-documentation}/bin/awslabs.aws-documentation-mcp-server";
        args = [ ];
        env = { };
      };
      terraform = {
        command = "${pkgs.terraform-mcp-server}/bin/terraform-mcp-server";
        args = [ "stdio" ];
        env = { };
      };
      n8n-mcp = {
        command = toString (pkgs.writeShellScript "n8n-mcp-wrapper" ''
          export N8N_API_URL="https://n8n.test0.zip"
          export N8N_API_KEY="$(cat ${config.age.secrets.n8n-api-key.path})"
          exec ${pkgs.n8n-mcp}/bin/n8n-mcp
        '');
        args = [ ];
        env = { };
      };
      chrome-devtools = {
        command = "${pkgs.chrome-devtools-mcp}/bin/chrome-devtools-mcp";
        args = [ ];
        env = { };
      };
      awsdac = {
        command = "${pkgs.awsdac}/bin/awsdac-mcp-server";
        args = [ ];
        env = { };
      };
      drawio = {
        command = "${pkgs.drawio-mcp}/bin/drawio-mcp";
        args = [ ];
        env = { };
      };
      grep_app = {
        url = "https://mcp.grep.app";
      };
    };
  };
}

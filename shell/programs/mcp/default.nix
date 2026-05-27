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
            --api-key "${config.home.sessionVariables.CONTEXT7_API_KEY}"
        '');
        args = [ ];
        env = { };
      };
      # websearch = {
      #   command = toString (pkgs.writeShellScript "firecrawl-mcp-wrapper" ''
      #     export FIRECRAWL_API_URL="https://firecrawl.test0.zip"
      #     export FIRECRAWL_API_KEY="${config.home.sessionVariables.CAPI_KEY}"
      #     exec ${pkgs.firecrawl-mcp}/bin/firecrawl-mcp
      #   '');
      #   args = [ ];
      #   env = { };
      # };
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
      # n8n-mcp = {
      #   command = toString (pkgs.writeShellScript "n8n-mcp-wrapper" ''
      #     export N8N_API_URL="https://n8n.test0.zip"
      #     export N8N_API_KEY="${config.home.sessionVariables.N8N_API_KEY}"
      #     exec ${pkgs.n8n-mcp}/bin/n8n-mcp
      #   '');
      #   args = [ ];
      #   env = { };
      # };
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
      # drawio = {
      #   url = "https://mcp.draw.io/mcp";
      # };
      grep_app = {
        url = "https://mcp.grep.app";
      };
    };
  };
}

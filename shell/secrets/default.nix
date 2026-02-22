{ config
, pkgs
, agenix-secrets
, agenix
, ...
}:
{
  home.packages = [ agenix.packages.${pkgs.system}.default ];

  age.secrets = {
    github-token = {
      file = "${agenix-secrets}/encrypted/github-token.age";
    };
    openai-api-key = {
      file = "${agenix-secrets}/encrypted/openai-api-key.age";
    };
    openai-api-pkey = {
      file = "${agenix-secrets}/encrypted/openai-api-pkey.age";
    };
    context7-api-key = {
      file = "${agenix-secrets}/encrypted/context7-api-key.age";
    };
    deepseek-api-key = {
      file = "${agenix-secrets}/encrypted/deepseek-api-key.age";
    };
    llm-proxy-api-key = {
      file = "${agenix-secrets}/encrypted/llm-proxy-api-key.age";
    };
    common-key = {
      file = "${agenix-secrets}/encrypted/common-key.age";
    };
  };

  home.sessionVariables = {
    GITHUB_PAT = "$(cat ${config.age.secrets.github-token.path} 2>/dev/null || echo '')";
    OPENAI_API_KEY = "$(cat ${config.age.secrets.openai-api-key.path} 2>/dev/null || echo '')";
    OPENAI_API_PKEY = "$(cat ${config.age.secrets.openai-api-pkey.path} 2>/dev/null || echo '')";
    DEEPSEEK_API_KEY = "$(cat ${config.age.secrets.deepseek-api-key.path} 2>/dev/null || echo '')";
    LLM_PROXY_API_KEY = "$(cat ${config.age.secrets.llm-proxy-api-key.path} 2>/dev/null || echo '')";
    COMMON_KEY = "$(cat ${config.age.secrets.common-key.path} 2>/dev/null || echo '')";
  };
}

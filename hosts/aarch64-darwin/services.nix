{
  hostname,
  infraSrc,
  ...
}:
{
  imports =
    if hostname == "Jays-MacBook-Pro-Server" then
      [
        ./sharing.nix
        (infraSrc + "/services/Jays-MacBook-Pro-Server")
      ]
    else
      [
        ./yabai
        ./skhd
      ];

  # services.dockerCompose = {
  #   preStart = "open -ga OrbStack";
  #   dockerBin = "/usr/local/bin/docker";

  #   firecrawl = {
  #     enable = true;
  #     options.extraFlags = [ "--remove-orphans" ];
  #     networks.backend.driver = "bridge";
  #     services = {
  #       "playwright-service" = {
  #         image = "ghcr.io/firecrawl/playwright-service:latest";
  #         networks = [ "backend" ];
  #         environment = {
  #           PORT = "3000";
  #           MAX_CONCURRENT_PAGES = "10";
  #         };
  #         mem_limit = "4G";
  #       };
  #       api = {
  #         image = "ghcr.io/firecrawl/firecrawl";
  #         networks = [ "backend" ];
  #         extra_hosts = [ "host.docker.internal:host-gateway" ];
  #         ports = [ "127.0.0.1:3002:3002" ];
  #         command = "node dist/src/harness.js --start-docker";
  #         depends_on = {
  #           redis.condition = "service_started";
  #           "playwright-service".condition = "service_started";
  #           rabbitmq.condition = "service_healthy";
  #           "nuq-postgres".condition = "service_started";
  #         };
  #         environment = {
  #           HOST = "0.0.0.0";
  #           PORT = "3002";
  #           ENV = "local";
  #           REDIS_URL = "redis://redis:6379";
  #           REDIS_RATE_LIMIT_URL = "redis://redis:6379";
  #           PLAYWRIGHT_MICROSERVICE_URL = "http://playwright-service:3000/scrape";
  #           NUQ_RABBITMQ_URL = "amqp://rabbitmq:5672";
  #           POSTGRES_USER = "postgres";
  #           POSTGRES_PASSWORD = "postgres";
  #           POSTGRES_DB = "postgres";
  #           POSTGRES_HOST = "nuq-postgres";
  #           POSTGRES_PORT = "5432";
  #           USE_DB_AUTHENTICATION = "false";
  #         };
  #         mem_limit = "8G";
  #       };
  #       redis = {
  #         image = "redis:alpine";
  #         networks = [ "backend" ];
  #         command = "redis-server --bind 0.0.0.0";
  #       };
  #       rabbitmq = {
  #         image = "rabbitmq:3-management";
  #         networks = [ "backend" ];
  #         command = "rabbitmq-server";
  #         healthcheck = {
  #           test = [
  #             "CMD"
  #             "rabbitmq-diagnostics"
  #             "-q"
  #             "check_running"
  #           ];
  #           interval = "5s";
  #           timeout = "5s";
  #           retries = 3;
  #           start_period = "5s";
  #         };
  #       };
  #       "nuq-postgres" = {
  #         image = "ghcr.io/firecrawl/nuq-postgres:latest";
  #         networks = [ "backend" ];
  #         environment = {
  #           POSTGRES_USER = "postgres";
  #           POSTGRES_PASSWORD = "postgres";
  #           POSTGRES_DB = "postgres";
  #         };
  #       };
  #     };
  #   };
  # };
}

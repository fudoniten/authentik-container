{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.authentikContainer;

  hostSecrets = config.fudo.secrets.host-secrets."${config.instance.hostname}";

  mkEnvFile = envVars:
    let
      envLines =
        mapAttrsToList (var: val: ''${var}="${toString val}"'') envVars;
    in pkgs.writeText "envFile" (concatStringsSep "\n" envLines);

  postgresPasswdFile =
    pkgs.lib.passwd.stablerandom-passwd-file "authentik-postgresql-passwd"
    config.instance.build-seed;

in {
  options.services.authentikContainer = with types; {
    enable = mkEnableOption "Enable Authentik running in an Arion container.";

    state-directory = mkOption {
      type = str;
      description = "Directory at which to store server state data.";
    };

    images = {
      authentik = mkOption { type = str; };
      postgres = mkOption { type = str; };
      redis = mkOption { type = str; };
    };

    uids = {
      authentik = mkOption {
        type = int;
        default = 721;
      };
      authentik-postgres = mkOption {
        type = int;
        default = 722;
      };
      authentik-redis = mkOption {
        type = int;
        default = 723;
      };
    };
  };

  config = mkIf cfg.enable {
    systemd = {
      tmpfiles.rules = [
        "d ${cfg.state-directory}/postgres  0700 authentik-postgres root - -"
        "d ${cfg.state-directory}/redis     0700 authentik-redis    root - -"
        "d ${cfg.state-directory}/media     0700 authentik          root - -"
        "d ${cfg.state-directory}/templates 0700 authentik          root - -"
        "d ${cfg.state-directory}/certs     0700 authentik          root - -"
      ];
      services.arion-authentik = {
        after = [ "network-online.target" ];
        requires = [ "network-online.target" ];
      };
    };

    users.users = {
      authentik = {
        isSystemUser = true;
        group = "authentik";
        uid = cfg.uids.authentik;
      };
      authentik-postgres = {
        isSystemUser = true;
        group = "authentik";
        uid = cfg.uids.authentik-postgres;
      };
      authentik-redis = {
        isSystemUser = true;
        group = "authentik";
        uid = cfg.uids.authentik-redis;
      };
    };

    fudo.secrets.host-secrets."${hostname}" = {
      authentikEnv = {
        source-file = mkEnvFile {
          AUTHENTIK_REDIS__HOST = "redis";
          AUTHENTIK_POSTGRESQL__HOST = "postgres";
          AUTHENTIK_POSTGRESQL__NAME = "authentik";
          AUTHENTIK_POSTGRESQL__USER = "authentik";
          AUTHENTIK_POSTGRESQL__PASSWORD = readFile postgresPasswdFile;
        };
        target-file = "/run/authentik/authentik.env";
      };
      authentikPostgresEnv = {
        source-file = mkEnvFile {
          POSTGRES_DB = "authentik";
          POSTGRES_USER = "authentik";
          POSTGRES_PASSWORD = readFile postgresPasswdFile;
        };
        target-file = "/run/authentik/postgres.env";
      };
    };

    virtualisation.arion.projects.authentik.settings = let
      image = { ... }: {
        project.name = "authentik";
        services = {
          postgres = {
            image = cfg.images.postgres;
            restart = "always";
            volumes =
              [ "${cfg.state-directory}/postgres:/var/lib/postgresql/data" ];
            healthcheck = {
              test = [ "CMD" "pg_isready" "-U" "postgres" ];
              start_period = "20s";
              interval = "30s";
              retries = "5";
              timeout = "3s";
            };
            user = mkUserMap cfg.uids.postgres;
            env_file = [ hostSecrets.authentikPostgresEnv.target-file ];
          };
          redis = {
            image = cfg.images.redis;
            restart = "always";
            command = "--save 60 1 --loglevel warning";
            volumes = [ "${cfg.state-directory}:/data" ];
            healthcheck = {
              test = [ "CMD" "redis-cli" "ping" ];
              start_period = "20s";
              interval = "30s";
              retries = "5";
              timeout = "3s";
            };
            user = mkUserMap cfg.uids.redis;
          };
          server = {
            image = cfg.images.authentik;
            restart = "always";
            command = "server";
            env_file = [ hostSecrets.authentikEnv.target-file ];
            volumes = [
              "${cfg.state-directory}/media:/media"
              "${cfg.state-directory}/templates:/templates"
            ];
            user = mkUserMap cfg.uids.authentik;
            ports = [
              "${toString cfg.ports.http}:9000"
              "${toString cfg.ports.https}:9443"
            ];
            depends_on = [ "postgresql" "redis" ];
          };
          worker = {
            image = cfg.images.authentik;
            restart = "always";
            command = "worker";
            env_file = [ hostSecrets.authentikEnv.target-file ];
            volumes = [
              "${cfg.state-directory}/media:/media"
              "${cfg.state-directory}/certs:/certs"
              "${cfg.state-directory}/templates:/templates"
            ];
            user = mkUserMap cfg.uids.authentik;
            depends_on = [ "postgresql" "redis" ];
          };
        };
      };
    in { imports = [ image ]; };
  };
}

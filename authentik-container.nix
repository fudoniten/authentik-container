{ config, lib, pkgs, ... }@toplevel:

with lib;
let
  cfg = config.services.authentikContainer;

  hostname = config.instance.hostname;

  domainName = config.fudo.hosts."${hostname}".domain;

  hostSecrets = config.fudo.secrets.host-secrets."${hostname}";

  # Creates an environment file from an attrset of environment variables
  # Used to pass configuration to containers via env_file directive
  mkEnvFile = envVars:
    let
      envLines =
        mapAttrsToList (var: val: ''${var}="${toString val}"'') envVars;
    in pkgs.writeText "envFile" (concatStringsSep "\n" envLines);

  # Creates a Docker user mapping string (uid:gid format)
  # Maps the container's internal UID to the host UID for proper file permissions
  mkUserMap = uid: "${toString uid}:${toString uid}";

  # Generate deterministic passwords using build-seed
  # This ensures passwords remain consistent across NixOS rebuilds
  # while still being unique per deployment (different hosts have different seeds)
  postgresPasswdFile =
    pkgs.lib.passwd.stablerandom-passwd-file "authentik-postgresql-passwd"
    config.instance.build-seed;

  authentikSecretKeyFile =
    pkgs.lib.passwd.stablerandom-passwd-file "authentik-secret-key"
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

    ports = {
      http = mkOption {
        type = port;
        default = 5030;
      };
      https = mkOption {
        type = port;
        default = 5031;
      };
    };

    smtp = {
      host = mkOption {
        type = str;
        default = "smtp.${domainName}";
      };
      port = mkOption {
        type = port;
        default = 587;
      };
      user = mkOption {
        type = str;
        default = "authentik";
      };
      password-file = mkOption { type = str; };
      from-address = mkOption {
        type = str;
        default =
          "Fudo Authentication <${toplevel.config.services.authentikContainer.smtp.user}@${domainName}>";
      };
    };

    extraCerts = mkOption {
      type = attrsOf str;
      description = "Map of certificate name to certificate location.";
      default = { };
    };

    uids = {
      authentik = mkOption {
        type = int;
        default = 721;
      };
      postgres = mkOption {
        type = int;
        default = 722;
      };
      redis = mkOption {
        type = int;
        default = 723;
      };
    };
  };

  config = mkIf cfg.enable {
    # Input validation
    assertions = [
      {
        assertion = cfg.state-directory != "";
        message = "services.authentikContainer.state-directory must be set";
      }
      {
        assertion = cfg.images.authentik != "";
        message = "services.authentikContainer.images.authentik must be set";
      }
      {
        assertion = cfg.images.postgres != "";
        message = "services.authentikContainer.images.postgres must be set";
      }
      {
        assertion = cfg.images.redis != "";
        message = "services.authentikContainer.images.redis must be set";
      }
      {
        assertion = cfg.smtp.password-file != "";
        message = "services.authentikContainer.smtp.password-file must be set";
      }
    ];

    systemd = {
      tmpfiles.rules = [
        "d ${cfg.state-directory}/postgres  0700 authentik-postgres root - -"
        "d ${cfg.state-directory}/redis     0700 authentik-redis    root - -"
        "d ${cfg.state-directory}/media     0700 authentik          root - -"
        "d ${cfg.state-directory}/templates 0700 authentik          root - -"
        "d ${cfg.state-directory}/certs     0700 authentik          root - -"
      ];
      services = {
        # Only create cert-copy service if there are actually certs to copy
        authentik-cert-copy = mkIf (cfg.extraCerts != { }) {
          wantedBy = [ "arion-authentik.service" ];
          before = [ "arion-authentik.service" ];
          serviceConfig = {
            ExecStart = let
              mkCopyCommand = name: src:
                let target = "${cfg.state-directory}/certs/${name}";
                in ''
                  cp -v "${src}" "${target}"
                  chown authentik:root "${target}"
                '';
            in pkgs.writeShellScript "authentik-copy-certs.sh"
            (concatStringsSep "\n"
              (mapAttrsToList mkCopyCommand cfg.extraCerts));
            Type = "oneshot";
          };
        };
        arion-authentik = {
          after = [ "network-online.target" "podman.service" ];
          requires = [ "network-online.target" "podman.service" ];
          serviceConfig = {
            Restart = "on-failure";
            RestartSec = 120;
          };
        };
      };
    };

    users = {
      users = {
        authentik = {
          isSystemUser = true;
          group = "authentik";
          uid = cfg.uids.authentik;
        };
        authentik-postgres = {
          isSystemUser = true;
          group = "authentik";
          uid = cfg.uids.postgres;
        };
        authentik-redis = {
          isSystemUser = true;
          group = "authentik";
          uid = cfg.uids.redis;
        };
      };
      groups.authentik.members =
        [ "authentik" "authentik-postgres" "authentik-redis" ];
    };

    # Generate environment files for containers
    # These are placed in /run/authentik/ and passed to containers via env_file
    fudo.secrets.host-secrets."${hostname}" = {
      authentikEnv = {
        source-file = mkEnvFile {
          AUTHENTIK_REDIS__HOST = "redis";

          AUTHENTIK_POSTGRESQL__HOST = "postgres";
          AUTHENTIK_POSTGRESQL__NAME = "authentik";
          AUTHENTIK_POSTGRESQL__USER = "authentik";
          AUTHENTIK_POSTGRESQL__PASSWORD = readFile postgresPasswdFile;

          AUTHENTIK_SECRET_KEY = readFile authentikSecretKeyFile;

          AUTHENTIK_DEFAULT_USER_CHANGE_USERNAME = toString false;

          AUTHENTIK_EMAIL__HOST = cfg.smtp.host;
          AUTHENTIK_EMAIL__PORT = toString cfg.smtp.port;
          AUTHENTIK_EMAIL__USERNAME = cfg.smtp.user;
          AUTHENTIK_EMAIL__PASSWORD =
            removeSuffix "\n" (readFile cfg.smtp.password-file);
          # Infer SSL/TLS based on port: 465=SSL, 25/587=TLS
          # This is a simplification; override if your SMTP server differs
          AUTHENTIK_EMAIL__USE_SSL =
            optionalString (cfg.smtp.port == 465) "TRUE";
          AUTHENTIK_EMAIL__USE_TLS =
            optionalString (cfg.smtp.port == 25 || cfg.smtp.port == 587) "TRUE";
          AUTHENTIK_EMAIL__TIMEOUT = 10;
          AUTHENTIK_EMAIL__FROM = cfg.smtp.from-address;
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

    # Arion configuration - defines the Docker Compose-like container setup
    # Containers communicate via internal Docker network (postgres, redis hostnames)
    virtualisation.arion.projects.authentik.settings = let
      image = { ... }: {
        project.name = "authentik";
        services = {
          postgres.service = {
            image = cfg.images.postgres;
            restart = "always";
            command = "-c max_connections=300";
            volumes =
              [ "${cfg.state-directory}/postgres:/var/lib/postgresql/data" ];
            healthcheck = {
              test = [ "CMD" "pg_isready" "-U" "authentik" "-d" "authentik" ];
              start_period = "20s";
              interval = "30s";
              retries = 5;
              timeout = "3s";
            };
            user = mkUserMap cfg.uids.postgres;
            env_file = [ hostSecrets.authentikPostgresEnv.target-file ];
          };
          redis.service = {
            image = cfg.images.redis;
            restart = "always";
            command = "--save 60 1 --loglevel warning";
            volumes = [ "${cfg.state-directory}/redis:/data" ];
            healthcheck = {
              test = [ "CMD" "redis-cli" "ping" ];
              start_period = "20s";
              interval = "30s";
              retries = 5;
              timeout = "3s";
            };
            user = mkUserMap cfg.uids.redis;
          };
          server.service = {
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
            depends_on = [ "postgres" "redis" ];
          };
          worker.service = {
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
            depends_on = [ "postgres" "redis" ];
          };
        };
      };
    in { imports = [ image ]; };
  };
}

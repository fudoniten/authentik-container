{ config, lib, pkgs, ... }@toplevel:

with lib;
let
  cfg = config.services.authentikContainer;

  hostname = config.instance.hostname;

  domainName = config.fudo.hosts."${hostname}".domain;

  mkUserMap = uid: "${toString uid}:${toString uid}";

  postgresPasswdFile =
    pkgs.lib.passwd.stablerandom-passwd-file "authentik-postgresql-passwd"
    config.instance.build-seed;

  authentikSecretKeyFile =
    pkgs.lib.passwd.stablerandom-passwd-file "authentik-secret-key"
    config.instance.build-seed;

  # Runtime paths for the two env files below, shared between the assembly
  # script and the arion container `env_file` entries that read them.
  authentikEnvPath = "/run/authentik/authentik.env";
  authentikPostgresEnvPath = "/run/authentik/postgres.env";

  # These used to be built with `pkgs.writeText` + `readFile` of
  # postgresPasswdFile/authentikSecretKeyFile/cfg.smtp.password-file, which
  # resolves every secret at EVAL TIME -- baking the Postgres password and
  # Authentik's own signing/encryption secret key into the world-readable
  # Nix store as plaintext, and, for cfg.smtp.password-file specifically,
  # failing evaluation outright once that option points at a runtime
  # secrets store (Aegis) whose path only exists after boot. Assembling
  # both env files here instead, from the actual runtime paths, fixes both:
  # nothing secret touches the store, and a path that doesn't exist until
  # boot is no longer read before boot.
  assembleAuthentikSecrets = pkgs.writeShellScript "authentik-secrets-assembly" ''
    set -euo pipefail
    umask 077

    POSTGRES_PW="$(cat ${escapeShellArg postgresPasswdFile})"
    SECRET_KEY="$(cat ${escapeShellArg authentikSecretKeyFile})"
    SMTP_PW="$(cat ${escapeShellArg cfg.smtp.password-file})"

    install -d -m 0755 "$(dirname ${escapeShellArg authentikEnvPath})"

    # World-readable to match the containers' expectations: they run as
    # in-container UIDs with no fixed relationship to the host.
    cat > ${escapeShellArg authentikEnvPath} <<EOF
    AUTHENTIK_REDIS__HOST="redis"
    AUTHENTIK_POSTGRESQL__HOST="postgres"
    AUTHENTIK_POSTGRESQL__NAME="authentik"
    AUTHENTIK_POSTGRESQL__USER="authentik"
    AUTHENTIK_POSTGRESQL__PASSWORD="$POSTGRES_PW"
    AUTHENTIK_SECRET_KEY="$SECRET_KEY"
    AUTHENTIK_DEFAULT_USER_CHANGE_USERNAME="false"
    AUTHENTIK_LISTEN__HTTP="${cfg.listenAddress}:9000"
    AUTHENTIK_LISTEN__HTTPS="${cfg.listenAddress}:9443"
    AUTHENTIK_LISTEN__METRICS="${cfg.listenAddress}:9300"
    AUTHENTIK_EMAIL__HOST="${cfg.smtp.host}"
    AUTHENTIK_EMAIL__PORT="${toString cfg.smtp.port}"
    AUTHENTIK_EMAIL__USERNAME="${cfg.smtp.user}"
    AUTHENTIK_EMAIL__PASSWORD="$SMTP_PW"
    AUTHENTIK_EMAIL__USE_SSL="${optionalString (cfg.smtp.port == 465) "TRUE"}"
    AUTHENTIK_EMAIL__USE_TLS="${
      optionalString (cfg.smtp.port == 25 || cfg.smtp.port == 587) "TRUE"
    }"
    AUTHENTIK_EMAIL__TIMEOUT="10"
    AUTHENTIK_EMAIL__FROM="${cfg.smtp.from-address}"
    EOF
    chmod 0644 ${escapeShellArg authentikEnvPath}

    cat > ${escapeShellArg authentikPostgresEnvPath} <<EOF
    POSTGRES_DB="authentik"
    POSTGRES_USER="authentik"
    POSTGRES_PASSWORD="$POSTGRES_PW"
    EOF
    chmod 0644 ${escapeShellArg authentikPostgresEnvPath}
  '';

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

    listenAddress = mkOption {
      type = str;
      default = "0.0.0.0";
      description = ''
        Address the authentik server and worker bind to inside their
        containers. Authentik >= 2026.5 defaults to binding "[::]", which
        fails to start on hosts with IPv6 disabled; this pins it back to the
        previous IPv4 default. Must remain reachable from the container's
        published-port path (i.e. not "127.0.0.1"), since the host reaches
        the container via its container-network interface, not loopback.
      '';
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
    systemd = {
      tmpfiles.rules = [
        "d ${cfg.state-directory}/postgres  0700 authentik-postgres root - -"
        "d ${cfg.state-directory}/redis     0700 authentik-redis    root - -"
        "d ${cfg.state-directory}/media     0700 authentik          root - -"
        "d ${cfg.state-directory}/templates 0700 authentik          root - -"
        "d ${cfg.state-directory}/certs     0700 authentik          root - -"
      ];
      services = {
        authentik-cert-copy = {
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
        authentik-secrets = {
          description = "Assemble Authentik's composed runtime secrets.";
          wantedBy = [ "multi-user.target" ];
          before = [ "arion-authentik.service" ];
          requiredBy = [ "arion-authentik.service" ];
          after = [ "aegis-secrets.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = assembleAuthentikSecrets;
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

    virtualisation.arion.projects.authentik.settings = let
      image = { ... }: {
        project.name = "authentik";
        services = {
          postgres.service = {
            image = cfg.images.postgres;
            restart = "always";
            command = "-c 'max_connections=300'";
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
            env_file = [ authentikPostgresEnvPath ];
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
            env_file = [ authentikEnvPath ];
            volumes = [
              "${cfg.state-directory}/media:/media"
              "${cfg.state-directory}/templates:/templates"
            ];
            user = mkUserMap cfg.uids.authentik;
            ports = [
              "${toString cfg.ports.http}:9000"
              "${toString cfg.ports.https}:9443"
            ];
            healthcheck = {
              test = [ "CMD" "ak" "healthcheck" ];
              start_period = "60s";
              interval = "30s";
              retries = 5;
              timeout = "3s";
            };
            depends_on = {
              postgres.condition = "service_healthy";
              redis.condition = "service_healthy";
            };
          };
          worker.service = {
            image = cfg.images.authentik;
            restart = "always";
            command = "worker";
            env_file = [ authentikEnvPath ];
            volumes = [
              "${cfg.state-directory}/media:/media"
              "${cfg.state-directory}/certs:/certs"
              "${cfg.state-directory}/templates:/templates"
            ];
            user = mkUserMap cfg.uids.authentik;
            healthcheck = {
              test = [ "CMD" "ak" "healthcheck" ];
              start_period = "60s";
              interval = "30s";
              retries = 5;
              timeout = "3s";
            };
            depends_on = {
              postgres.condition = "service_healthy";
              redis.condition = "service_healthy";
            };
          };
        };
      };
    in { imports = [ image ]; };
  };
}

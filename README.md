# Authentik Container

A NixOS module for deploying [Authentik](https://goauthentik.io/) (identity provider/SSO solution) using Arion (Docker Compose for Nix).

> **⚠️ WARNING**: This is a personal configuration repository. You're welcome to use it for inspiration, but **do not depend on it** for production use. Breaking changes may occur without notice.

## What It Does

This module creates a containerized Authentik deployment with:
- **PostgreSQL** database (for Authentik data storage)
- **Redis** cache (for sessions and caching)
- **Authentik Server** (web UI and API)
- **Authentik Worker** (background task processing)

All services run in containers managed by Arion/Podman with proper user separation, health checks, and restart policies.

## Prerequisites

### External Dependencies

This module depends on infrastructure from my personal NixOS configuration:

- **`config.fudo.hosts.${hostname}.domain`**: Domain name configuration
- **`config.fudo.secrets.host-secrets.${hostname}`**: Secret management system
- **`config.instance.hostname`**: Hostname configuration
- **`config.instance.build-seed`**: Seed for deterministic password generation
- **`pkgs.lib.passwd.stablerandom-passwd-file`**: Custom function for stable random password generation

If you're using this as inspiration, you'll need to replace these with your own infrastructure or adapt the code.

### System Requirements

- NixOS with Arion support
- Podman (for container runtime)
- Network connectivity for pulling container images

## Configuration Example

```nix
{
  services.authentikContainer = {
    enable = true;

    # Where to store persistent data (PostgreSQL, Redis, media files)
    state-directory = "/var/lib/authentik";

    # Container images to use
    images = {
      authentik = "ghcr.io/goauthentik/server:2024.8.3";
      postgres = "docker.io/library/postgres:16-alpine";
      redis = "docker.io/library/redis:7-alpine";
    };

    # Ports to expose on host
    ports = {
      http = 5030;   # Authentik HTTP port
      https = 5031;  # Authentik HTTPS port
    };

    # SMTP configuration for sending emails
    smtp = {
      host = "smtp.example.com";
      port = 587;
      user = "authentik";
      password-file = "/run/secrets/smtp-password";
      from-address = "Authentik <authentik@example.com>";
      # Optional: Explicit SSL/TLS settings (defaults inferred from port)
      use-ssl = false;  # true for port 465
      use-tls = true;   # true for port 25 or 587
    };

    # Optional: Add custom CA certificates
    extraCerts = {
      "my-ca.pem" = "/etc/ssl/certs/my-ca.pem";
    };

    # Optional: Custom UIDs for container users (defaults shown)
    uids = {
      authentik = 721;
      postgres = 722;
      redis = 723;
    };

    # Optional: Resource limits to prevent containers from consuming all host resources
    resources = {
      postgres = {
        cpus = "2.0";    # Limit to 2 CPUs
        memory = "2G";   # Limit to 2GB RAM
      };
      redis = {
        cpus = "1.0";    # Limit to 1 CPU
        memory = "512M"; # Limit to 512MB RAM
      };
      authentik = {
        cpus = "2.0";    # Limit to 2 CPUs (applies to both server and worker)
        memory = "1G";   # Limit to 1GB RAM each
      };
    };
  };
}
```

## How It Works

### Architecture

```
┌─────────────────────────────────────────────────┐
│                   Host System                   │
│                                                 │
│  ┌───────────┐  ┌────────┐  ┌────────────────┐ │
│  │ PostgreSQL│  │ Redis  │  │   Authentik    │ │
│  │ Container │  │Container│  │    Containers  │ │
│  │           │  │        │  │  (server+worker)│ │
│  │ UID: 722  │  │UID: 723│  │    UID: 721    │ │
│  └─────┬─────┘  └────┬───┘  └────────┬───────┘ │
│        │             │               │         │
│        └─────────────┴───────────────┘         │
│                      │                         │
│         Shared state-directory                 │
│         /var/lib/authentik/                    │
│         ├── postgres/  (PostgreSQL data)       │
│         ├── redis/     (Redis data)            │
│         ├── media/     (uploaded files)        │
│         ├── templates/ (custom templates)      │
│         └── certs/     (custom CA certs)       │
└─────────────────────────────────────────────────┘
```

### Security Features

- **User Isolation**: Each service runs as a dedicated system user (authentik, authentik-postgres, authentik-redis)
- **Secret Management**: Passwords stored in files (not environment variables visible in `ps`)
- **Deterministic Secrets**: Passwords generated deterministically from build-seed (consistent across rebuilds)
- **Proper Permissions**: State directories created with 0700 permissions
- **Health Checks**: PostgreSQL and Redis have health checks to ensure they're running

### Service Lifecycle

1. **`authentik-cert-copy.service`** runs first (if `extraCerts` configured)
   - Copies certificates from Nix store to state directory
   - Sets proper ownership (authentik:root)

2. **`arion-authentik.service`** starts the containers
   - Waits for network and Podman
   - Starts PostgreSQL and Redis
   - Waits for health checks to pass
   - Starts Authentik server and worker

3. **Restart Policy**: If containers crash, systemd restarts them after 120 seconds

## File Structure

- **`flake.nix`**: Nix flake definition, imports nixpkgs and Arion, includes syntax checks
- **`authentik-container.nix`**: Main NixOS module with all configuration

## Validation and Testing

### Flake Checks

The flake includes built-in checks to validate syntax before deployment:

```bash
# Run all checks
nix flake check

# This validates:
# - Module syntax is correct
# - Flake structure is valid
# - No obvious configuration errors
```

### Configuration Validation

The module includes built-in assertions that validate your configuration at build time:

- **Required options**: Ensures all required options are set (state-directory, images, smtp.password-file)
- **Port validation**: Checks that ports are >= 1024 (unprivileged) and don't conflict
- **Certificate validation**: Verifies that certificate source files exist before trying to copy them
- **Resource limits**: Validates CPU/memory limit format if specified

If any validation fails, `nixos-rebuild` will fail with a clear error message explaining what needs to be fixed.

## Configuration Options

### Required Options

- `state-directory`: Where to store persistent data
- `images.authentik`: Authentik container image
- `images.postgres`: PostgreSQL container image
- `images.redis`: Redis container image
- `smtp.password-file`: Path to SMTP password file

### Optional Options

- `ports.http` (default: 5030): HTTP port to expose
- `ports.https` (default: 5031): HTTPS port to expose
- `smtp.host` (default: `smtp.${domainName}`): SMTP server hostname
- `smtp.port` (default: 587): SMTP server port
- `smtp.user` (default: "authentik"): SMTP username
- `smtp.from-address`: Email sender address
- `smtp.use-ssl` (default: inferred from port): Use SSL for SMTP (typically port 465)
- `smtp.use-tls` (default: inferred from port): Use TLS/STARTTLS for SMTP (typically port 25/587)
- `extraCerts` (default: {}): Map of certificate name → file path
- `uids.*`: Custom UIDs for service users
- `resources.postgres.{cpus,memory}`: CPU and memory limits for PostgreSQL
- `resources.redis.{cpus,memory}`: CPU and memory limits for Redis
- `resources.authentik.{cpus,memory}`: CPU and memory limits for Authentik server and worker

## Email Configuration

By default, SMTP SSL/TLS settings are inferred from the port number:
- **Port 465**: `use-ssl = true` (SSL)
- **Port 25 or 587**: `use-tls = true` (TLS/STARTTLS)

You can explicitly override these settings if your SMTP server uses non-standard ports:
```nix
smtp = {
  port = 2525;  # Non-standard port
  use-ssl = false;
  use-tls = true;
};
```

## Accessing Authentik

After deployment:
- HTTP: `http://your-host:5030`
- HTTPS: `https://your-host:5031`

Default admin credentials are set during first setup via Authentik's initial setup wizard.

## Troubleshooting

### Check Service Status
```bash
systemctl status arion-authentik.service
```

### View Logs
```bash
# All containers
journalctl -u arion-authentik.service -f

# Individual containers
podman logs -f authentik-postgres-1
podman logs -f authentik-redis-1
podman logs -f authentik-server-1
podman logs -f authentik-worker-1
```

### Common Issues

**Containers won't start:**
- Check that `state-directory` exists and has correct permissions
- Verify container images are accessible
- Check `journalctl -u arion-authentik.service` for errors

**Email not working:**
- Verify SMTP credentials in `smtp.password-file`
- Check SMTP port (465 for SSL, 587 for TLS)
- Look for email errors in Authentik server logs

**Database connection errors:**
- Ensure PostgreSQL health check passes: `podman exec authentik-postgres-1 pg_isready -U authentik`
- Check PostgreSQL logs: `podman logs authentik-postgres-1`

**Permission errors:**
- Verify state directory ownership matches configured UIDs
- Check tmpfiles were created: `systemd-tmpfiles --create`

## Backup and Recovery

### What to Backup
```bash
# Critical data in state-directory:
/var/lib/authentik/postgres/    # Database
/var/lib/authentik/media/       # Uploaded files
/var/lib/authentik/templates/   # Custom templates
```

### Backup Script Example
```bash
#!/usr/bin/env bash
tar czf authentik-backup-$(date +%Y%m%d).tar.gz \
  /var/lib/authentik/postgres \
  /var/lib/authentik/media \
  /var/lib/authentik/templates
```

### Recovery
1. Stop services: `systemctl stop arion-authentik.service`
2. Restore files to state-directory
3. Fix permissions: `systemd-tmpfiles --create`
4. Start services: `systemctl start arion-authentik.service`

## Upgrading

### Container Images
1. Update `images.*` in your configuration
2. Rebuild NixOS configuration: `nixos-rebuild switch`
3. Arion will pull new images and recreate containers

### PostgreSQL Major Versions

PostgreSQL major version upgrades (e.g., 15 → 16) require manual intervention because the data directory format changes between major versions. Here's the detailed process:

#### Option 1: Using pg_dumpall (Recommended - Safest)

This method exports the entire database to SQL and imports it into the new version.

```bash
# 1. Backup your data first!
tar czf authentik-backup-$(date +%Y%m%d).tar.gz /var/lib/authentik/

# 2. Export the database while the old version is still running
podman exec authentik-postgres-1 pg_dumpall -U authentik > authentik-db-backup.sql

# 3. Stop Authentik services
systemctl stop arion-authentik.service

# 4. Backup the old PostgreSQL data directory and clear it
mv /var/lib/authentik/postgres /var/lib/authentik/postgres.old
mkdir -p /var/lib/authentik/postgres
chown authentik-postgres:authentik /var/lib/authentik/postgres
chmod 0700 /var/lib/authentik/postgres

# 5. Update your NixOS configuration with new PostgreSQL image
# Change: images.postgres = "docker.io/library/postgres:16-alpine";
# To:     images.postgres = "docker.io/library/postgres:17-alpine";

# 6. Rebuild NixOS configuration (pulls new image and recreates containers)
nixos-rebuild switch

# 7. Wait for PostgreSQL to initialize (check logs)
journalctl -u arion-authentik.service -f
# Wait until you see "database system is ready to accept connections"

# 8. Import the database backup
cat authentik-db-backup.sql | podman exec -i authentik-postgres-1 psql -U authentik

# 9. Verify the import worked
podman exec authentik-postgres-1 psql -U authentik -d authentik -c "\dt"

# 10. If everything works, you can delete the old data directory
rm -rf /var/lib/authentik/postgres.old
```

#### Option 2: Using pg_upgrade (Faster, More Complex)

This method upgrades the data directory in-place, which is faster but more complex.

```bash
# 1. Backup your data first!
tar czf authentik-backup-$(date +%Y%m%d).tar.gz /var/lib/authentik/

# 2. Stop Authentik services
systemctl stop arion-authentik.service

# 3. Prepare directories
mkdir -p /var/lib/authentik/postgres-new
chown authentik-postgres:authentik /var/lib/authentik/postgres-new
chmod 0700 /var/lib/authentik/postgres-new

# 4. Run pg_upgrade using both old and new PostgreSQL versions
# This is complex and requires running both versions simultaneously
# See: https://www.postgresql.org/docs/current/pgupgrade.html

# Note: This method is more error-prone for containerized setups.
# The pg_dumpall method (Option 1) is recommended unless you have
# a very large database where downtime is critical.
```

#### Troubleshooting PostgreSQL Upgrades

**Database won't start after upgrade:**
- Check logs: `journalctl -u arion-authentik.service -f`
- Verify data directory ownership: `ls -la /var/lib/authentik/postgres`
- Try restoring from your pre-upgrade backup

**Import fails with "role does not exist":**
- The dump includes role creation, this is normal
- Check that the import completed despite warnings

**Authentik can't connect after upgrade:**
- Verify PostgreSQL is accepting connections: `podman exec authentik-postgres-1 pg_isready`
- Check Authentik logs: `podman logs authentik-server-1`
- Restart Authentik containers: `systemctl restart arion-authentik.service`

## Technical Details

### Password Generation
Passwords are generated deterministically using `stablerandom-passwd-file`:
- PostgreSQL password: seed + "authentik-postgresql-passwd"
- Authentik secret key: seed + "authentik-secret-key"

This ensures passwords remain consistent across NixOS rebuilds.

### Container Networking
Containers communicate via Docker Compose networking:
- PostgreSQL accessible as `postgres` (internal DNS)
- Redis accessible as `redis` (internal DNS)
- Ports 9000 (HTTP) and 9443 (HTTPS) exposed to host

### Resource Limits
Resource limits can be configured to prevent containers from consuming all host resources. By default, no limits are set. Configure them using the `resources` option:

```nix
services.authentikContainer.resources = {
  postgres = {
    cpus = "2.0";    # Limit PostgreSQL to 2 CPUs
    memory = "2G";   # Limit PostgreSQL to 2GB RAM
  };
  redis = {
    cpus = "1.0";    # Limit Redis to 1 CPU
    memory = "512M"; # Limit Redis to 512MB RAM
  };
  authentik = {
    cpus = "2.0";    # Limit Authentik to 2 CPUs (per container)
    memory = "1G";   # Limit Authentik to 1GB RAM (per container)
  };
};
```

The `authentik` resource limits apply to both the server and worker containers independently (each gets the specified limits).

## Future Improvements

Potential enhancements:
- [x] Explicit SSL/TLS options instead of port-based inference
- [x] Resource limits configuration
- [x] Input validation and better error messages
- [x] Flake checks for syntax validation
- [ ] Backup automation
- [ ] Prometheus metrics export
- [ ] Container image digest pinning (instead of tags)
- [ ] Network isolation options

## License

This is personal configuration code. Use at your own risk. No license is provided.

## References

- [Authentik Documentation](https://goauthentik.io/docs/)
- [Arion Documentation](https://docs.hercules-ci.com/arion/)
- [NixOS Options Search](https://search.nixos.org/)

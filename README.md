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

- **`flake.nix`**: Nix flake definition, imports nixpkgs and Arion
- **`authentik-container.nix`**: Main NixOS module with all configuration

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
- `extraCerts` (default: {}): Map of certificate name → file path
- `uids.*`: Custom UIDs for service users

## Email Configuration

SMTP settings are inferred from the port number:
- **Port 465**: Uses SSL (`AUTHENTIK_EMAIL__USE_SSL = TRUE`)
- **Port 25 or 587**: Uses TLS (`AUTHENTIK_EMAIL__USE_TLS = TRUE`)

If you need different settings, you'll need to modify the module.

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
PostgreSQL major version upgrades require manual intervention:
1. Backup database
2. Stop Authentik
3. Use `pg_upgrade` or dump/restore
4. Update `images.postgres`
5. Start Authentik

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
No CPU/memory limits configured by default. Add them if needed:
```nix
# In authentik-container.nix, modify service definitions:
postgres.service.deploy.resources.limits = {
  cpus = "2.0";
  memory = "2G";
};
```

## Future Improvements

Potential enhancements (not implemented):
- [ ] Explicit SSL/TLS options instead of port-based inference
- [ ] Resource limits configuration
- [ ] Backup automation
- [ ] Prometheus metrics export
- [ ] Container image version pinning
- [ ] Network isolation options

## License

This is personal configuration code. Use at your own risk. No license is provided.

## References

- [Authentik Documentation](https://goauthentik.io/docs/)
- [Arion Documentation](https://docs.hercules-ci.com/arion/)
- [NixOS Options Search](https://search.nixos.org/)

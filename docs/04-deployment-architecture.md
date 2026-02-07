# 04 -- Deployment Architecture

This document is a complete technical reference for the Docker Compose deployment architecture of this self-hosted Matrix server. It covers every service, every volume, every dependency edge, and every design decision that shaped this system. If you want to understand not just *what* is deployed but *why* it is deployed this way, this is the document to read.

**Related documentation:**

- [02-synapse-homeserver.md](02-synapse-homeserver.md) -- Synapse configuration details, tuning, and federation
- [03-authentication.md](03-authentication.md) -- MAS, Keycloak, and the full authentication flow
- [05-bridges.md](05-bridges.md) -- Bridge protocol details, per-bridge setup, and troubleshooting
- [06-operations.md](06-operations.md) -- Day-to-day operational procedures, backups, and monitoring

---

## Table of Contents

1. [Overview and Service Map](#1-overview-and-service-map)
2. [The Init Container Pattern](#2-the-init-container-pattern)
3. [The Inline Entrypoint Pattern](#3-the-inline-entrypoint-pattern)
4. [Database Architecture](#4-database-architecture)
5. [Volume Architecture](#5-volume-architecture)
6. [Network Architecture](#6-network-architecture)
7. [Dependency Graph](#7-dependency-graph)
8. [Configuration Patterns by Bridge Type](#8-configuration-patterns-by-bridge-type)
9. [Security Model](#9-security-model)
10. [Coolify Integration](#10-coolify-integration)
11. [Scaling Considerations](#11-scaling-considerations)

---

## 1. Overview and Service Map

The deployment consists of **17 services** and **12 named volumes**, all defined in a single `docker-compose.yaml`. There are no external configuration files, no Dockerfiles, and no bind mounts. Everything is generated at startup from environment variables.

### Service Inventory

| # | Service | Type | Image | Restart | Purpose |
|---|---------|------|-------|---------|---------|
| 1 | `postgres-synapse` | Database | `postgres:15` | unless-stopped | Synapse homeserver database |
| 2 | `postgres-sliding-sync` | Database | `postgres:15` | unless-stopped | Sliding sync proxy database |
| 3 | `postgres-synapse-mas` | Database | `postgres:15` | unless-stopped | MAS authentication database |
| 4 | `postgres-bridges` | Database | `postgres:15` | unless-stopped | Shared database for all 4 bridges |
| 5 | `mas-config-init` | Init | `matrix-authentication-service:latest-debug` | no | Generates MAS config.yaml |
| 6 | `whatsapp-init` | Init | `mautrix/whatsapp:latest` | no | Generates WhatsApp bridge config + registration |
| 7 | `telegram-init` | Init | `mautrix/telegram:latest` | no | Generates Telegram bridge config + registration |
| 8 | `discord-init` | Init | `mautrix/discord:latest` | no | Generates Discord bridge config + registration |
| 9 | `slack-init` | Init | `mautrix/slack:latest` | no | Generates Slack bridge config + registration |
| 10 | `synapse` | Runtime | `matrixdotorg/synapse:latest` | unless-stopped | Matrix homeserver |
| 11 | `sliding-sync` | Runtime | `matrix-org/sliding-sync:latest` | unless-stopped | MSC3575 sliding sync proxy |
| 12 | `synapse-mass-authentication-service` | Runtime | `matrix-authentication-service:latest` | unless-stopped | MAS auth server |
| 13 | `nginx` | Runtime | `nginx:latest` | unless-stopped | Reverse proxy, .well-known |
| 14 | `mautrix-whatsapp` | Runtime | `mautrix/whatsapp:latest` | unless-stopped | WhatsApp bridge |
| 15 | `mautrix-telegram` | Runtime | `mautrix/telegram:latest` | unless-stopped | Telegram bridge |
| 16 | `mautrix-discord` | Runtime | `mautrix/discord:latest` | unless-stopped | Discord bridge |
| 17 | `mautrix-slack` | Runtime | `mautrix/slack:latest` | unless-stopped | Slack bridge |

### Service Map

```
                         EXTERNAL TRAFFIC
                              |
                              v
                     +--------+--------+
                     |      nginx      |  :80
                     |  (reverse proxy)|
                     +---+------+------+
                         |      |
          +--------------+      +--------------+
          v                                    v
    +-----------+                  +--------------------------+
    |  synapse  | :8008            |  synapse-mass-           |
    | (Matrix   |                  |  authentication-service  | :8080
    | homeserver)|                 |  (MAS)                   |
    +-----+-----+                  +------------+-------------+
          |                                     |
          |  app_service_config_files           |  config from init
          |  (reads bridge registrations)       |
          |                                     |
    +-----+------+------+------+      +---------+---------+
    |     |      |      |      |      | mas-config-init   |
    v     v      v      v      |      | (generates config)|
  +--+ +--+  +--+  +--+       |      +-------------------+
  |WA| |TG|  |DC|  |SL|       |
  +--+ +--+  +--+  +--+       |
  Bridge Runtime Services      |
    |     |      |      |      |
    v     v      v      v      |
  +--+ +--+  +--+  +--+       |
  |WA| |TG|  |DC|  |SL|       |
  +--+ +--+  +--+  +--+       |
  Bridge Init Containers       |
    |     |      |      |      |
    +-----+------+------+------+
          |
          v
    +-----+--------+    +----------+    +----------+    +----------+
    | postgres-     |    | postgres-|    | postgres-|    | postgres-|
    | bridges       |    | synapse  |    | sliding- |    | synapse- |
    | (4 databases) |    |          |    | sync     |    | mas      |
    +---------------+    +----------+    +----------+    +----------+

    +---------------+
    | sliding-sync  | :8009
    | (sync proxy)  |
    +---------------+
          |
          v
      postgres-sliding-sync
```

### Data Flow Summary

1. **Client request** arrives at nginx on port 80 (Coolify terminates TLS upstream).
2. **nginx** inspects the path:
   - `/_matrix/client/*/login`, `logout`, `refresh` --> forwarded to MAS (:8080)
   - `/_matrix/*`, `/_synapse/client/*`, `/` --> forwarded to Synapse (:8008)
   - `/.well-known/matrix/client` --> served as static JSON from disk
3. **Synapse** handles Matrix protocol operations, queries its PostgreSQL, and communicates with bridges via the Application Service API.
4. **Bridges** maintain persistent connections to their respective platforms (WhatsApp, Telegram, Discord, Slack) and relay messages to/from Synapse.
5. **Sliding sync** connects to the Synapse FQDN (external URL) and its own PostgreSQL to maintain a sliding window view of room state for clients that support MSC3575.

---

## 2. The Init Container Pattern

### The Problem

A Matrix deployment with bridges requires a significant amount of configuration: YAML files with database URIs, homeserver addresses, shared secrets, bridge registration files (which contain cryptographic tokens that both the bridge and Synapse must agree on), and more.

The traditional approach is to maintain these config files in the git repository or on disk. This creates several problems:

- **Secrets in git.** Database passwords, API tokens, and shared secrets end up committed.
- **Environment drift.** Config files on disk diverge from what the docker-compose.yaml expects.
- **Manual coordination.** Bridge registration files must be generated by the bridge, then placed where Synapse can read them. If you regenerate a bridge config, you must also update Synapse.
- **Non-reproducible.** A fresh deployment requires manually running multiple commands in the correct order.

### The Solution: Init Containers

This deployment uses 5 init containers -- services with `restart: "no"` that run once, generate configuration files, write them to shared volumes, and exit. The runtime services then start and read those files.

```yaml
# Init container pattern
some-init:
  image: same-image-as-runtime
  user: "0:0"                    # Root, for volume permissions
  restart: "no"                  # Run once, then exit
  depends_on:
    postgres-bridges:
      condition: service_healthy  # Wait for database
  entrypoint: ["/bin/bash", "-c", "
    # Generate config if not exists (idempotent)
    if [ ! -f /data/config.yaml ]; then
      generate-config-command -c /data/config.yaml -e
    fi
    # Patch config with environment variables
    yq -i '.homeserver.address = \"http://synapse:8008\"' /data/config.yaml
    yq -i '.database.uri = \"postgres://...\"' /data/config.yaml
    # Generate registration file
    generate-registration -g -c /data/config.yaml -r /data/registration.yaml
    # Copy registration to shared volume
    cp /data/registration.yaml /registrations/bridge-registration.yaml
    # Fix ownership for runtime container
    chown -R 1337:1337 /data
  "]
  volumes:
    - bridge-data:/data                    # Persistent config + state
    - bridge-registrations:/registrations  # Shared with Synapse
```

### The `service_completed_successfully` Dependency

Docker Compose supports several dependency conditions. The critical one for init containers is `service_completed_successfully`:

```yaml
synapse:
  depends_on:
    whatsapp-init:
      condition: service_completed_successfully
    telegram-init:
      condition: service_completed_successfully
    discord-init:
      condition: service_completed_successfully
    slack-init:
      condition: service_completed_successfully
```

This means Synapse will not start until **all four** init containers have run to completion with exit code 0. If any init container fails, Synapse will not start, and `docker compose up` will report the failure. This is the mechanism that ensures bridge registration files are present before Synapse tries to load them.

Compare this with the other dependency conditions used in this deployment:

| Condition | Used By | Meaning |
|-----------|---------|---------|
| `service_healthy` | Runtime services depending on PostgreSQL | Wait until the healthcheck passes |
| `service_completed_successfully` | Runtime services depending on init containers | Wait until the container exits with code 0 |
| `service_started` | Services that just need the dependent to be running | Do not wait for healthy or complete |

### Idempotency

Every init container is idempotent. They check `if [ ! -f /data/config.yaml ]` before generating a new config. If the config already exists (because the volume persists across restarts), they skip generation and proceed directly to patching. This means:

- **First deploy:** Config is generated from scratch, patched, and registration files are created.
- **Subsequent deploys:** Config already exists, patching re-applies current environment variable values (so changing an env var in Coolify takes effect on next deploy), and registration files are regenerated.

The one exception is `mas-config-init`, which skips entirely if config exists (`exit 0`). MAS config is generated once and then preserved. To regenerate, you must delete the `mas-data` volume.

---

## 3. The Inline Entrypoint Pattern

### How It Works

Instead of mounting external configuration files, services generate their configuration at startup using shell heredocs embedded directly in the `entrypoint` array of the docker-compose.yaml. Here is the Synapse service as the canonical example:

```yaml
synapse:
  entrypoint: ["/bin/sh", "-c", "
    mkdir -p /data/config

    cat > /data/config/homeserver.yaml <<ENDCONF
    server_name: $${SYNAPSE_SERVER_NAME}
    listeners:
      - port: 8008
        type: http
        ...
    ENDCONF

    cat > /data/config/db.yaml <<ENDCONF
    database:
      name: psycopg2
      args:
        user: $${POSTGRES_SYNAPSE_USER}
        password: $${POSTGRES_SYNAPSE_PASSWORD}
        ...
    ENDCONF

    cat > /data/config/email.yaml <<ENDCONF
    email:
      smtp_host: $${SMTP_HOST}
      ...
    ENDCONF

    exec python -m synapse.app.homeserver \
      -c /data/config/homeserver.yaml \
      -c /data/config/db.yaml \
      -c /data/config/email.yaml \
      --keys-directory /data
  "]
```

Note the `$$` syntax. In Docker Compose, `$$` is an escaped dollar sign, which passes a literal `$` to the shell inside the container. This is necessary because Docker Compose itself performs variable substitution on `${VAR}` syntax before passing the entrypoint to the container. The `$${}` syntax defers substitution to the shell inside the container, where the environment variables are set.

In practice, `${SYNAPSE_SERVER_NAME}` is substituted by Docker Compose from the `.env` file, and `$${SYNAPSE_SERVER_NAME}` is substituted by `/bin/sh` inside the container from the `environment:` block. Both resolve to the same value. The `$$` form is used here for clarity and to keep the entrypoint self-contained.

### Why Synapse Uses Three Config Files

Synapse supports loading multiple `-c` config files that are merged in order. This deployment splits configuration into three files:

| File | Contents | Why Separate |
|------|----------|--------------|
| `homeserver.yaml` | Server name, listeners, federation, MAS integration, bridge registrations | Core identity and protocol config |
| `db.yaml` | Database connection parameters, connection pool settings | Database credentials isolated |
| `email.yaml` | SMTP host, port, credentials, notification settings | Email config isolated |

This split is purely organizational. Synapse merges them all into a single config at startup. But it makes the entrypoint more readable and easier to maintain when individual sections need changes.

### Why This Pattern Exists

This deployment runs on Coolify, a self-hosted PaaS. In Coolify's deployment model:

1. You point Coolify at a git repository containing a `docker-compose.yaml`.
2. You set environment variables in Coolify's web UI.
3. On deploy, Coolify pulls the repo, substitutes env vars, and runs `docker compose up`.

There is **no mechanism** to deploy additional configuration files alongside the compose file. You get the compose file and environment variables -- nothing else. This constraint makes the inline entrypoint pattern not just convenient but *necessary*. The entire deployment must be expressible as `docker-compose.yaml` + `.env`.

### The nginx Entrypoint

The nginx service takes this pattern further by generating both its nginx configuration **and** a static `.well-known` response:

```yaml
nginx:
  entrypoint: ["/bin/sh", "-c", "
    # Generate nginx config
    cat > /etc/nginx/conf.d/default.conf <<'ENDNGINX'
    resolver 127.0.0.11 valid=10s;
    server {
        listen 80;
        set $$mas_upstream http://synapse-mass-authentication-service:8080;
        set $$synapse_upstream http://synapse:8008;
        ...
    }
    ENDNGINX

    # Generate .well-known response
    mkdir -p /usr/share/nginx/html/.well-known/matrix/client
    cat > /.../index.html <<ENDHTML
    {\"m.homeserver\":{\"base_url\":\"$${SYNAPSE_FQDN}\"}, ...}
    ENDHTML

    exec nginx -g 'daemon off;'
  "]
```

The `ENDNGINX` heredoc uses `<<'ENDNGINX'` (quoted delimiter) to prevent shell variable expansion inside the nginx config. This is important because nginx uses `$` for its own variables (`$proxy_add_x_forwarded_for`, `$remote_addr`, etc.). The `ENDHTML` heredoc uses `<<ENDHTML` (unquoted) because it *does* need shell variable expansion for the FQDNs.

---

## 4. Database Architecture

### Four Separate PostgreSQL Instances

This deployment runs four independent PostgreSQL 15 containers rather than a single shared database server. This is an intentional design choice.

```
+------------------+     +----------------------+     +------------------+     +------------------+
| postgres-synapse |     | postgres-sliding-sync|     | postgres-synapse-|     | postgres-bridges |
|                  |     |                      |     | mas              |     |                  |
| DB: synapse      |     | DB: sync-v3          |     | DB: synapse_mas  |     | DB: mautrix_     |
| User: synapse_   |     | User: sliding_sync_  |     | User: synapse_   |     |   whatsapp (def) |
|   user           |     |   user               |     |   mas_user       |     | DB: mautrix_     |
|                  |     |                      |     |                  |     |   telegram       |
| Used by:         |     | Used by:             |     | Used by:         |     | DB: mautrix_     |
|   synapse        |     |   sliding-sync       |     |   MAS            |     |   discord        |
+------------------+     +----------------------+     +------------------+     | DB: mautrix_     |
                                                                               |   slack          |
                                                                               |                  |
                                                                               | Used by:         |
                                                                               |   all 4 bridges  |
                                                                               +------------------+
```

### Why Not One PostgreSQL?

| Concern | Separate Instances | Shared Instance |
|---------|-------------------|-----------------|
| **Blast radius** | A runaway query in one service cannot starve another | All services compete for connections and I/O |
| **Independent healthchecks** | Each instance has its own `pg_isready` check; Synapse starts when *its* database is ready regardless of bridge DB state | A single healthcheck cannot express "database X is ready for service Y" |
| **Independent restarts** | You can restart `postgres-bridges` without affecting Synapse | Restarting PostgreSQL takes down everything |
| **Resource isolation** | Each instance has its own connection pool, shared buffers, and WAL | Must tune a single instance for very different workload patterns |
| **Credentials** | Each service has unique credentials | Must manage per-database users within a shared instance (more complex) |
| **Backup granularity** | Can back up Synapse DB without including bridge data | Must back up everything together or use `pg_dump` per database |

The trade-off is memory. Each PostgreSQL 15 instance uses roughly 30-50 MB at idle. Four instances cost approximately 120-200 MB. On the Hetzner server with 128 GB RAM, this is negligible.

### The Shared Bridges Database

The four bridges share a single PostgreSQL instance (`postgres-bridges`). This is a deliberate middle ground: bridges have similar workload profiles (light writes, mostly reads) and similar operational lifecycles (they all restart when bridge config changes). Splitting them into four separate PostgreSQL instances would add complexity without meaningful benefit.

The trick is that PostgreSQL's official Docker image only creates one database (the `POSTGRES_DB` value) on first startup. To create the additional three databases, the container uses an entrypoint wrapper:

```yaml
postgres-bridges:
  entrypoint: ["/bin/sh", "-c",
    "printf 'CREATE DATABASE mautrix_telegram;\n
             CREATE DATABASE mautrix_discord;\n
             CREATE DATABASE mautrix_slack;\n'
     > /docker-entrypoint-initdb.d/create-bridge-dbs.sql
     && exec docker-entrypoint.sh postgres"]
```

This works because:

1. The custom entrypoint runs **before** the standard PostgreSQL entrypoint (`docker-entrypoint.sh`).
2. It writes a SQL file to `/docker-entrypoint-initdb.d/`, which is a directory the official PostgreSQL image processes on first initialization.
3. It then calls `exec docker-entrypoint.sh postgres`, which is the standard entrypoint. This initializes PostgreSQL, creates `mautrix_whatsapp` (from `POSTGRES_DB`), and then executes the SQL file which creates the remaining three databases.
4. On subsequent starts (when the data volume already has an initialized cluster), the `initdb.d` directory is ignored entirely.

The `POSTGRES_DB: mautrix_whatsapp` is set as the default because the healthcheck uses it:

```yaml
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_BRIDGES_USER} -d mautrix_whatsapp"]
```

All four databases share the same user (`POSTGRES_BRIDGES_USER`). This user is the owner of all databases since it is the superuser created during initialization.

### Healthcheck Configuration

All four PostgreSQL instances use identical healthcheck parameters:

```yaml
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U <user> -d <database>"]
  interval: 5s
  timeout: 5s
  retries: 5    # synapse/sliding-sync/mas
  retries: 10   # bridges (slightly more retries, for the extra database creation time)
```

`pg_isready` checks that PostgreSQL is accepting connections, which is sufficient. The bridges database has `retries: 10` (50 seconds total) instead of 5 (25 seconds) because it must complete the `initdb.d` SQL execution before the healthcheck can pass.

---

## 5. Volume Architecture

### Volume Inventory

| # | Volume | Mounted By | Contents | Persistence |
|---|--------|------------|----------|-------------|
| 1 | `postgres-synapse` | `postgres-synapse` | PostgreSQL data directory | **Critical** -- all Synapse room state, messages, user accounts |
| 2 | `postgres-sliding-sync` | `postgres-sliding-sync` | PostgreSQL data directory | **Rebuildable** -- sliding sync can reindex from Synapse |
| 3 | `postgres-synapse-mas` | `postgres-synapse-mas` | PostgreSQL data directory | **Critical** -- auth sessions, user mappings, OAuth tokens |
| 4 | `postgres-bridges` | `postgres-bridges` | PostgreSQL data directory | **Important** -- bridge state, puppet mappings, message dedup history |
| 5 | `synapse-data` | `synapse` | Generated config files, signing keys, pid files | **Critical** -- signing keys are server identity. Config is regenerated on startup. |
| 6 | `synapse-media` | `synapse` | Uploaded media files (images, videos, documents) | **Critical** -- user-uploaded content, not recoverable |
| 7 | `mas-data` | `mas-config-init`, `synapse-mass-authentication-service` | MAS config.yaml, encryption keys | **Critical** -- MAS config is generated once, encryption keys are not recoverable |
| 8 | `bridge-registrations` | All 4 init containers (rw), `synapse` (ro) | Bridge registration YAML files | **Regenerated** -- rebuilt by init containers on every deploy |
| 9 | `mautrix-whatsapp-data` | `whatsapp-init`, `mautrix-whatsapp` | Bridge config, state, session data | **Important** -- contains WhatsApp session; losing it requires re-linking |
| 10 | `mautrix-telegram-data` | `telegram-init`, `mautrix-telegram` | Bridge config, state, session data | **Important** -- contains Telegram session |
| 11 | `mautrix-discord-data` | `discord-init`, `mautrix-discord` | Bridge config, state, session data | **Important** -- contains Discord bot token state |
| 12 | `mautrix-slack-data` | `slack-init`, `mautrix-slack` | Bridge config, state, session data | **Important** -- contains Slack app credentials |

### The Bridge Registrations Shared Volume

The `bridge-registrations` volume is the linchpin of bridge-to-homeserver coordination. It is the only volume that is shared across service boundaries (mounted by 5 different services).

**How it works:**

1. Each bridge init container generates a registration file (e.g., `whatsapp-registration.yaml`) that contains:
   - The bridge's unique Application Service ID
   - The `as_token` (used by the bridge to authenticate to Synapse)
   - The `hs_token` (used by Synapse to authenticate to the bridge)
   - Namespace declarations (which users and rooms the bridge claims)

2. The init container copies this file to `/registrations/<bridge>-registration.yaml` on the shared volume.

3. Synapse mounts this volume read-only at `/bridges/`:
   ```yaml
   synapse:
     volumes:
       - bridge-registrations:/bridges:ro
   ```

4. Synapse's config references these files:
   ```yaml
   app_service_config_files:
     - /bridges/whatsapp-registration.yaml
     - /bridges/telegram-registration.yaml
     - /bridges/discord-registration.yaml
     - /bridges/slack-registration.yaml
   ```

The `:ro` (read-only) mount on the Synapse side is a security measure. Synapse should never modify bridge registrations.

**Regeneration behavior:** Init containers unconditionally delete and regenerate the registration file on every run (`rm -f /data/registration.yaml` followed by the generation command). This ensures that the registration is always consistent with the current config. However, the `as_token` and `hs_token` are typically derived from the bridge config (which persists), so regeneration does not invalidate existing sessions.

### Volume Lifecycle and Backup Priority

For backup purposes, volumes fall into three tiers:

**Tier 1 -- Must back up (data loss is unrecoverable):**
- `postgres-synapse` -- All Matrix room state and message history
- `postgres-synapse-mas` -- Authentication state
- `synapse-data` -- Server signing keys (new keys = new server identity to the federation)
- `synapse-media` -- User-uploaded media files
- `mas-data` -- MAS encryption keys and config

**Tier 2 -- Should back up (data loss causes disruption but is recoverable):**
- `postgres-bridges` -- Bridge state; losing it means re-linking all bridged conversations
- `mautrix-whatsapp-data` -- WhatsApp session; losing it requires scanning the QR code again
- `mautrix-telegram-data` -- Telegram session; losing it requires re-authentication
- `mautrix-discord-data` -- Discord session state
- `mautrix-slack-data` -- Slack app session state

**Tier 3 -- Can skip (rebuilt automatically):**
- `postgres-sliding-sync` -- Rebuilt by reindexing from Synapse
- `bridge-registrations` -- Regenerated by init containers on every deploy

See [06-operations.md](06-operations.md) for backup procedures.

---

## 6. Network Architecture

### Single Flat Network

All 17 services run on Docker Compose's default network. No custom networks are defined. This means every service can reach every other service by its service name via Docker's embedded DNS resolver.

```
+-----------------------------------------------------------------------+
|                        Default Docker Network                          |
|                                                                        |
|  DNS: 127.0.0.11 (Docker embedded DNS)                                |
|                                                                        |
|  postgres-synapse -----> postgres-synapse:5432                         |
|  postgres-sliding-sync > postgres-sliding-sync:5432                    |
|  postgres-synapse-mas -> postgres-synapse-mas:5432                     |
|  postgres-bridges -----> postgres-bridges:5432                         |
|  synapse ---------------> synapse:8008                                  |
|  sliding-sync ----------> sliding-sync:8009                            |
|  synapse-mass-authentication-service -> ...:8080                       |
|  mautrix-whatsapp -----> mautrix-whatsapp:29318                        |
|  mautrix-telegram -----> mautrix-telegram:29317                        |
|  mautrix-discord ------> mautrix-discord:29334                         |
|  mautrix-slack --------> mautrix-slack:29335                           |
|  nginx ----------------> nginx:80                                      |
|                                                                        |
+-----------------------------------------------------------------------+
                              |
                        Only nginx:80 is
                       exposed externally
                      (via Coolify's proxy)
```

### Docker Embedded DNS

The nginx configuration contains:

```nginx
resolver 127.0.0.11 valid=10s;
```

`127.0.0.11` is Docker's embedded DNS server. It resolves container names to their current IP addresses on the Docker network. The `valid=10s` directive tells nginx to cache DNS results for only 10 seconds, which is important because container IPs can change on restart.

The `set $variable` pattern in the nginx config:

```nginx
set $mas_upstream http://synapse-mass-authentication-service:8080;
set $synapse_upstream http://synapse:8008;
```

This is a well-known nginx trick. When you use `proxy_pass` with a literal URL, nginx resolves the DNS at startup and caches it forever. By using a variable, nginx resolves the DNS on every request (subject to the `resolver` cache). This is critical in Docker because container IPs change when containers restart.

### Internal HTTP Communication

All inter-service communication uses plain HTTP over the Docker network:

| From | To | Protocol | Port | Path |
|------|----|----------|------|------|
| nginx | synapse | HTTP | 8008 | `/_matrix/*`, `/_synapse/client/*` |
| nginx | MAS | HTTP | 8080 | `/_matrix/client/*/login\|logout\|refresh` |
| synapse | MAS | HTTP | 8080 | Internal auth verification (MSC3861) |
| sliding-sync | synapse | HTTPS | 443 | Via `SYNCV3_SERVER` (external FQDN) |
| bridges | synapse | HTTP | 8008 | Application Service API |
| synapse | bridges | HTTP | 29317-29335 | Application Service push notifications |

Note that `sliding-sync` connects to Synapse via the external FQDN (`SYNCV3_SERVER: ${SYNAPSE_FQDN}`), not the internal Docker hostname. This is because the sliding sync proxy needs to reach Synapse through the same URL that clients use, to correctly proxy federation and media endpoints. This means sliding sync traffic goes out through nginx (or Coolify's proxy) and back in.

### No Exposed Ports

No service in the `docker-compose.yaml` has a `ports:` directive. No ports are published to the host. The only way traffic enters the network is through Coolify's reverse proxy, which is configured to forward traffic to the nginx container's port 80. This is a security feature: databases, bridges, and internal APIs are unreachable from outside the Docker network.

---

## 7. Dependency Graph

### Full Dependency Chain

```
                                        START
                                          |
              +---------------------------+---------------------------+
              |              |            |            |              |
              v              v            v            v              v
        postgres-      postgres-    postgres-    postgres-      (no deps)
        synapse        sliding-     synapse-     bridges
                       sync         mas
              |              |            |            |
              |              |            |            +--------+--------+--------+
              |              |            |            |        |        |        |
              |              |            v            v        v        v        v
              |              |      mas-config-   whatsapp  telegram discord  slack
              |              |      init          -init     -init    -init    -init
              |              |            |            |        |        |        |
              |              |            v            |        |        |        |
              |              |      synapse-mass-     |        |        |        |
              |              |      authentication-   |        |        |        |
              |              |      service            |        |        |        |
              |              |            |            |        |        |        |
              +---------+----+----+-------+            |        |        |        |
                        |         |                    |        |        |        |
                        v         v                    |        |        |        |
                   +---------+   synapse  <------------+--------+--------+--------+
                   |         |     |
                   |  sliding |    |
                   |  -sync   |    |
                   +---------+    |
                                  |
                                  v
                               nginx   (also depends on MAS: service_started)
                                  |
                                  v
                               READY
```

### Dependency Types and Startup Order

The following table shows every dependency edge in the system, the condition type, and the practical implication:

| Service | Depends On | Condition | Why |
|---------|-----------|-----------|-----|
| `mas-config-init` | *(none)* | -- | Has no dependencies; starts immediately and writes config to volume |
| `whatsapp-init` | `postgres-bridges` | `service_healthy` | Needs database ready to validate connection string |
| `telegram-init` | `postgres-bridges` | `service_healthy` | Same |
| `discord-init` | `postgres-bridges` | `service_healthy` | Same |
| `slack-init` | `postgres-bridges` | `service_healthy` | Same |
| `synapse-mass-authentication-service` | `mas-config-init` | `service_completed_successfully` | Config must be generated before MAS reads it |
| `synapse-mass-authentication-service` | `postgres-synapse-mas` | `service_healthy` | Database must be accepting connections |
| `synapse` | `postgres-synapse` | `service_healthy` | Database must be accepting connections |
| `synapse` | `synapse-mass-authentication-service` | `service_started` | MAS should be running (but Synapse does not block on it being healthy) |
| `synapse` | `whatsapp-init` | `service_completed_successfully` | Bridge registration must be on shared volume |
| `synapse` | `telegram-init` | `service_completed_successfully` | Same |
| `synapse` | `discord-init` | `service_completed_successfully` | Same |
| `synapse` | `slack-init` | `service_completed_successfully` | Same |
| `sliding-sync` | `synapse` | `service_started` | Synapse must be running to proxy |
| `sliding-sync` | `postgres-sliding-sync` | `service_healthy` | Database must be accepting connections |
| `nginx` | `synapse` | `service_started` | Upstream must exist for proxying |
| `nginx` | `synapse-mass-authentication-service` | `service_started` | Upstream must exist for proxying |
| `mautrix-whatsapp` | `whatsapp-init` | `service_completed_successfully` | Config must be generated |
| `mautrix-whatsapp` | `synapse` | `service_started` | Homeserver must be running |
| `mautrix-telegram` | `telegram-init` | `service_completed_successfully` | Config must be generated |
| `mautrix-telegram` | `synapse` | `service_started` | Homeserver must be running |
| `mautrix-discord` | `discord-init` | `service_completed_successfully` | Config must be generated |
| `mautrix-discord` | `synapse` | `service_started` | Homeserver must be running |
| `mautrix-slack` | `slack-init` | `service_completed_successfully` | Config must be generated |
| `mautrix-slack` | `synapse` | `service_started` | Homeserver must be running |

### Typical Startup Timeline

On a cold start (all containers stopped, volumes intact):

```
t=0s    postgres-synapse, postgres-sliding-sync, postgres-synapse-mas,
        postgres-bridges all start simultaneously.
        mas-config-init also starts (no database dependency).

t=2s    mas-config-init exits (config already exists, immediate exit 0).

t=5-10s PostgreSQL instances pass healthchecks.

t=10s   synapse-mass-authentication-service starts (mas-config-init done + postgres-synapse-mas healthy).
        whatsapp-init, telegram-init, discord-init, slack-init start
        (postgres-bridges healthy).

t=12-15s Bridge init containers complete (config patching + registration generation).

t=15s   synapse starts (postgres-synapse healthy + MAS started + all inits completed).

t=16s   nginx starts (synapse started + MAS started).
        sliding-sync starts (synapse started + postgres-sliding-sync healthy).
        mautrix-whatsapp, mautrix-telegram, mautrix-discord, mautrix-slack start.

t=20s   All services running. System ready.
```

On a first-ever deploy (empty volumes), add approximately 5-10 seconds for config generation and database initialization.

---

## 8. Configuration Patterns by Bridge Type

The four bridges use two distinct ecosystems with different tooling, config structures, and quirks.

### Go Bridges: WhatsApp, Discord, Slack

WhatsApp, Discord, and Slack bridges are written in Go and use the `mautrix-go` framework. They share several characteristics:

**Config generation:** Go bridges generate their initial config using the binary itself with `-c <path> -e` flags:

```bash
# WhatsApp and Slack
/usr/bin/mautrix-whatsapp -c /data/config.yaml -e
/usr/bin/mautrix-slack    -c /data/config.yaml -e

# Discord (copies from bundled example instead)
cp /opt/mautrix-discord/example-config.yaml /data/config.yaml
```

**Registration generation:** Go bridges use the binary with `-g` flag:

```bash
/usr/bin/mautrix-whatsapp -g -c /data/config.yaml -r /data/registration.yaml
/usr/bin/mautrix-discord  -g -c /data/config.yaml -r /data/registration.yaml
/usr/bin/mautrix-slack    -g -c /data/config.yaml -r /data/registration.yaml
```

**Config patching:** All use `yq` (bundled in the image) to modify YAML in-place.

**Database config location varies between Go bridges:**

| Bridge | Database Type Path | Database URI Path |
|--------|-------------------|-------------------|
| WhatsApp | `.database.type` | `.database.uri` |
| Discord | `.appservice.database.type` | `.appservice.database.uri` |
| Slack | `.database.type` | `.database.uri` |

This inconsistency is an upstream issue. WhatsApp and Slack use the newer `mautrix-go` config layout with top-level `.database`, while Discord uses the older layout with `.appservice.database` (nested under `appservice`). When adding a new Go bridge, check the example config to determine which layout it uses.

**Application Service ports:**

| Bridge | Port | Hostname |
|--------|------|----------|
| WhatsApp | 29318 | `mautrix-whatsapp` |
| Discord | 29334 | `mautrix-discord` |
| Slack | 29335 | `mautrix-slack` |

### Python Bridge: Telegram

The Telegram bridge is the only Python bridge in this deployment. It uses `mautrix-python` and has distinct patterns:

**Config generation:** Copies from a bundled example config rather than generating:

```bash
cp /opt/mautrix-telegram/example-config.yaml /data/config.yaml
```

**Registration generation:** Uses `python3 -m` syntax instead of a binary:

```bash
python3 -m mautrix_telegram -g -c /data/config.yaml -r /data/registration.yaml
```

**Database config location:** Uses a flat string directly under `.appservice.database` (not a nested object):

```yaml
# Telegram (Python bridge) -- flat string
appservice:
  database: "postgres://user:pass@host:5432/mautrix_telegram?sslmode=disable"

# Compare with Discord (Go bridge) -- nested object
appservice:
  database:
    type: "postgres"
    uri: "postgres://user:pass@host:5432/mautrix_discord?sslmode=disable"
```

**Permission levels differ:**

| Bridge | Levels Available |
|--------|-----------------|
| Go bridges (WA, DC, SL) | `relay`, `user`, `admin` |
| Python bridge (TG) | `relaybot`, `full`, `admin` |

The yq commands reflect this:

```bash
# Go bridges
yq -i '.bridge.permissions = {"*": "relay", env(SYNAPSE_SERVER_NAME): "user", ...}'

# Telegram (Python)
yq -i '.bridge.permissions = {"*": "relaybot", env(SYNAPSE_SERVER_NAME): "full", ...}'
```

### The Telegram `api_id` Type Coercion

Telegram requires `api_id` and `api_hash` credentials from `https://my.telegram.org/apps`. The `api_id` is an integer, but environment variables are always strings. The Telegram init container uses a `yq` type tag to force the value to an integer:

```bash
yq -i '.telegram.api_id = (env(TELEGRAM_API_ID) | tag = "!!int")' /data/config.yaml
```

Without the `tag = "!!int"` modifier, yq would write `api_id: "12345678"` (a quoted string), and the Telegram bridge would fail to parse it. This is a subtle but critical detail unique to the Telegram bridge.

### Summary Comparison Table

| Aspect | WhatsApp | Telegram | Discord | Slack |
|--------|----------|----------|---------|-------|
| Language | Go | Python | Go | Go |
| Image registry | dock.mau.dev | dock.mau.dev | dock.mau.dev | dock.mau.dev |
| Config generation | binary `-c X -e` | copy example-config.yaml | copy example-config.yaml | binary `-c X -e` |
| Registration generation | binary `-g` | `python3 -m ... -g` | binary `-g` | binary `-g` |
| DB config path | `.database.*` | `.appservice.database` (string) | `.appservice.database.*` | `.database.*` |
| AppService port | 29318 | 29317 | 29334 | 29335 |
| Permission levels | relay/user/admin | relaybot/full/admin | relay/user/admin | relay/user/admin |
| Special considerations | None | `api_id` needs `!!int` tag | DB config nested under appservice | None |

See [05-bridges.md](05-bridges.md) for protocol-specific details and per-bridge operational procedures.

---

## 9. Security Model

### Secrets Management

**Principle: No secrets in git. Ever.**

All secrets are stored as environment variables, set in Coolify's web UI, and injected at deploy time. The `.env.example` file in the repository contains only placeholder values. The actual `.env` file (or Coolify's equivalent) is never committed.

Secrets in this deployment:

| Secret | Env Var | Used By |
|--------|---------|---------|
| Synapse DB password | `POSTGRES_SYNAPSE_PASSWORD` | `postgres-synapse`, `synapse` |
| Sliding sync DB password | `POSTGRES_SLIDING_SYNC_PASSWORD` | `postgres-sliding-sync`, `sliding-sync` |
| MAS DB password | `POSTGRES_SYNAPSE_MAS_PASSWORD` | `postgres-synapse-mas`, `mas-config-init` |
| Bridges DB password | `POSTGRES_BRIDGES_PASSWORD` | `postgres-bridges`, all bridge inits |
| Sliding sync secret | `SLIDING_SYNC_SECRET` | `sliding-sync` |
| MAS shared secret | `SYNAPSE_MAS_SECRET` | `synapse`, `mas-config-init` |
| Synapse admin API token | `SYNAPSE_API_ADMIN_TOKEN` | `synapse`, `mas-config-init` |
| Keycloak client secret | `KEYCLOAK_CLIENT_SECRET` | `synapse`, `mas-config-init` |
| SMTP password | `SMTP_PASSWORD` | `synapse` |
| Telegram API ID | `TELEGRAM_API_ID` | `telegram-init` |
| Telegram API hash | `TELEGRAM_API_HASH` | `telegram-init` |

### Container User Model

Init containers and runtime containers use different user models:

**Init containers run as root (`user: "0:0"`):**

```yaml
mas-config-init:
  user: "0:0"     # root:root
  # ...
  entrypoint: ["...",
    "chown -R 65532:65532 /data"   # MAS runs as UID 65532
  ]

whatsapp-init:
  user: "0:0"
  # ...
  entrypoint: ["...",
    "chown -R 1337:1337 /data"    # Bridge runs as UID 1337
  ]
```

Init containers must run as root because:
1. Named Docker volumes are created with `root:root` ownership.
2. The init container needs to write config files to the volume.
3. It then `chown`s the files to the UID that the runtime container runs as.

**Runtime containers run as their default user:**

The bridge runtime services do not specify `user:` in the compose file, meaning they run as whatever user the Docker image defines. For mautrix bridges, this is UID 1337. For MAS, this is UID 65532. For Synapse, it is UID 991 (the `synapse` user in the image).

This is a defense-in-depth measure: even if a bridge were compromised, the attacker would have limited privileges inside the container.

### Network Isolation

As described in [Section 6](#6-network-architecture), no ports are published to the host. The only externally reachable service is nginx (via Coolify's proxy). This means:

- PostgreSQL instances are unreachable from outside the Docker network.
- Bridge Application Service APIs are unreachable from outside.
- MAS is only reachable through nginx's routing rules.
- Synapse's admin API (`/_synapse/admin`) is reachable through nginx but requires the admin token for authentication.

### TLS Termination

TLS is terminated at Coolify's Traefik reverse proxy, upstream of the nginx container in this deployment. All internal communication within the Docker network is plain HTTP. This is standard practice for containerized deployments behind a reverse proxy.

The chain is:

```
Client --> HTTPS --> Coolify/Traefik --> HTTP --> nginx:80 --> HTTP --> synapse:8008/MAS:8080
```

nginx sets `X-Forwarded-Proto: https` on all proxied requests so that Synapse and MAS correctly generate HTTPS URLs in their responses.

---

## 10. Coolify Integration

### What Coolify Does

Coolify is a self-hosted PaaS (Platform as a Service) running on the Hetzner server at `37.27.69.212`. It provides:

- **Git-based deployments:** Point Coolify at a git repository, and it deploys on push.
- **Environment variable management:** Set secrets in the web UI, not in git.
- **Automatic TLS:** Coolify's Traefik instance handles Let's Encrypt certificate provisioning and renewal.
- **Docker Compose support:** Coolify runs `docker compose up` with the repo's compose file.
- **Deployment history:** Roll back to previous deployments.
- **Resource monitoring:** Basic container health and resource usage monitoring.

### Deployment Flow

```
1. Developer pushes to git repository (main branch)
         |
         v
2. Coolify detects push (webhook or polling)
         |
         v
3. Coolify pulls repository to deployment directory
         |
         v
4. Coolify injects environment variables (from its UI)
   into the docker compose environment
         |
         v
5. Coolify runs: docker compose pull && docker compose up -d
         |
         v
6. Docker Compose resolves dependency graph:
   - Starts PostgreSQL instances
   - Waits for healthchecks
   - Runs init containers
   - Waits for completion
   - Starts runtime services
         |
         v
7. Coolify configures Traefik routes:
   - matrix.example.com  --> nginx:80
   - mas.example.com     --> (via nginx) --> MAS:8080
   - sync.example.com    --> sliding-sync:8009
         |
         v
8. TLS certificates provisioned/renewed automatically
         |
         v
9. System ready to serve traffic
```

### Why Inline Entrypoints

Coolify's Docker Compose support has an important constraint: **it only deploys the `docker-compose.yaml` file and environment variables.** There is no mechanism to include additional files (nginx configs, synapse configs, bridge configs, etc.) in the deployment. This is why the inline entrypoint pattern (Section 3) exists -- every configuration file is generated at runtime from the compose file itself.

This constraint also explains why there are no `Dockerfile`s, no `build:` directives, and no bind mounts to host paths in the compose file. Everything uses pre-built images from registries.

### Coolify-Specific Considerations

**Domain routing:** Coolify manages Traefik labels/rules that route incoming HTTPS traffic to the correct container. The domains (`SYNAPSE_FQDN`, `SYNAPSE_SYNC_FQDN`, `SYNAPSE_MAS_FQDN`) are configured both in Coolify's UI (for Traefik routing) and in the `.env` (for service configuration).

**Zero-downtime deploys are not supported** with this architecture. When Coolify runs `docker compose up -d` with updated images, containers are stopped and recreated. During the startup sequence (approximately 20 seconds), the server is unavailable. For a personal/small-team Matrix server, this is acceptable.

**Persistent volumes survive redeployment.** Coolify does not remove Docker volumes when redeploying. This means database data, media files, and generated configs persist across deployments. To force a clean start, volumes must be manually deleted through Coolify's UI or the Docker CLI.

**Environment variable changes take effect on next deploy.** Since all configuration is generated at startup from environment variables, changing a value in Coolify's UI and redeploying will pick up the change. The one exception is `mas-data` -- since `mas-config-init` exits early if config already exists, MAS config changes require deleting the `mas-data` volume before redeploying.

---

## 11. Scaling Considerations

This deployment is designed for a personal or small-team Matrix server (1-50 users). Here is what would need to change for larger deployments, and at what thresholds those changes become necessary.

### Current Architecture Limits

| Resource | Current Design | Limit |
|----------|---------------|-------|
| Synapse | Single process | ~200-500 concurrent users before CPU saturation |
| PostgreSQL | 4 separate containerized instances | ~1000 users before needing tuning/external DB |
| Media storage | Docker volume (local disk) | Limited by server disk space |
| Bridges | Single instance per bridge | Fine for personal use; enterprise bridging needs bridge clustering |

### Synapse Workers (50-500 users)

The first bottleneck is typically Synapse itself. Synapse supports a worker architecture where the main process offloads specific tasks to worker processes:

```
                          nginx
                       /    |     \
                     /      |       \
              sync worker  main    federation worker
              (port 8009)  process  (port 8010)
                           (8008)
                    \       |       /
                     \      |      /
                       PostgreSQL
                    (+ Redis for replication)
```

To implement workers, you would:

1. Add a Redis service (for inter-process communication).
2. Add worker containers (using the same Synapse image with different `--worker` flags).
3. Update nginx to route specific paths to specific workers.
4. Update Synapse's config to enable worker mode.

The `docker-compose.yaml` would grow by approximately 3-5 services (Redis + 2-4 workers depending on workload).

### External PostgreSQL (500+ users)

At scale, containerized PostgreSQL becomes a bottleneck due to:

- No connection pooling (add PgBouncer).
- Default `postgresql.conf` settings (not tuned for workload).
- No replication or failover.
- Docker volume I/O overhead vs. native disk.

The migration path:

1. Deploy a managed PostgreSQL instance (or a dedicated VM with tuned PostgreSQL).
2. Migrate data using `pg_dump`/`pg_restore`.
3. Update connection strings in environment variables.
4. Remove the PostgreSQL containers from the compose file.

### Object Storage for Media (large media volume)

Synapse supports S3-compatible storage for media via the `media_storage_providers` config. For deployments with significant media (many users sharing files, images, video), moving media to S3/MinIO/Cloudflare R2 eliminates local disk constraints.

### Redis for Caching

Even without workers, Redis can improve Synapse performance for:

- Session caching
- Presence updates
- Push notification deduplication

Add a Redis container and configure Synapse's `redis:` config section.

### Bridge Clustering

For enterprise deployments bridging thousands of users, individual bridges can become bottlenecks. The mautrix bridges do not natively support clustering, but you can:

- Run multiple bridge instances with different namespace splits.
- Use Hungryserv (a bridge aggregator) to coordinate multiple bridge instances.

### What Does NOT Need to Change

Some parts of this architecture scale well without modification:

- **The init container pattern** works regardless of deployment size. Init containers still run once and exit.
- **The nginx reverse proxy** can handle thousands of requests per second; it will not be the bottleneck.
- **The shared bridge database** is fine even at moderate scale because bridge workloads are lightweight.
- **The volume architecture** remains the same; only the backing storage might change (local disk to NFS/S3).
- **The security model** (secrets via env vars, no ports exposed) applies at any scale.

### Scaling Decision Matrix

| Users | Recommended Changes |
|-------|-------------------|
| 1-50 | Current architecture is sufficient |
| 50-200 | Tune PostgreSQL settings (`shared_buffers`, `work_mem`), enable Synapse caching |
| 200-500 | Add Synapse workers (sync, federation, media), add Redis |
| 500-2000 | External PostgreSQL with PgBouncer, S3 media storage, monitoring stack |
| 2000+ | Multiple Synapse worker instances, dedicated database server, CDN for media, consider Dendrite |

---

## Appendix A: Quick Reference -- All Environment Variables

For completeness, here is every environment variable used in the deployment, grouped by purpose. See `.env.example` for placeholder values.

### Core Identity

| Variable | Example | Used By |
|----------|---------|---------|
| `SYNAPSE_SERVER_NAME` | `your.matrix.server.de` | synapse, all bridges, MAS |
| `SYNAPSE_FQDN` | `https://synapse.your.matrix.server.de` | synapse, nginx, sliding-sync |
| `SYNAPSE_SYNC_FQDN` | `https://sync.synapse.your.matrix.server.de` | nginx (.well-known) |
| `SYNAPSE_MAS_FQDN` | `https://mas.synapse.your.matrix.server.de` | synapse, MAS, nginx |
| `SYNAPSE_FRIENDLY_SERVER_NAME` | `"Your Matrix Server"` | synapse (email), MAS (email) |
| `ADMIN_EMAIL` | `admin@your.matrix.server.de` | synapse, MAS |

### Database Credentials

| Variable | Used By |
|----------|---------|
| `POSTGRES_SYNAPSE_DB`, `_USER`, `_PASSWORD` | postgres-synapse, synapse |
| `POSTGRES_SYNAPSE_MAS_DB`, `_USER`, `_PASSWORD` | postgres-synapse-mas, mas-config-init |
| `POSTGRES_SLIDING_SYNC_DB`, `_USER`, `_PASSWORD` | postgres-sliding-sync, sliding-sync |
| `POSTGRES_BRIDGES_USER`, `_PASSWORD` | postgres-bridges, all bridge inits |

### Authentication

| Variable | Used By |
|----------|---------|
| `SYNAPSE_MAS_SECRET` | synapse, mas-config-init |
| `SYNAPSE_API_ADMIN_TOKEN` | synapse, mas-config-init |
| `SLIDING_SYNC_SECRET` | sliding-sync |
| `AUTHENTICATION_ISSUER` | nginx (.well-known) |

### Keycloak (Upstream OAuth)

| Variable | Used By |
|----------|---------|
| `KEYCLOAK_FQDN` | synapse, mas-config-init |
| `KEYCLOAK_REALM_IDENTIFIER` | synapse, mas-config-init |
| `KEYCLOAK_CLIENT_ID` | synapse, mas-config-init |
| `KEYCLOAK_CLIENT_SECRET` | synapse, mas-config-init |
| `KEYCLOAK_UPSTREAM_OAUTH_PROVIDER_ID` | mas-config-init |

### SMTP

| Variable | Used By |
|----------|---------|
| `SMTP_HOST`, `SMTP_PORT` | synapse |
| `SMTP_USER`, `SMTP_PASSWORD` | synapse, mas-config-init |
| `SMTP_REQUIRE_TRANSPORT_SECURITY` | synapse |
| `SMTP_NOTIFY_FROM` | synapse |

### Bridges

| Variable | Used By |
|----------|---------|
| `BRIDGE_ADMIN_USER` | All bridge inits |
| `TELEGRAM_API_ID` | telegram-init |
| `TELEGRAM_API_HASH` | telegram-init |

---

## Appendix B: Service Image Registry Reference

| Service | Image | Registry |
|---------|-------|----------|
| PostgreSQL (all 4) | `postgres:15` | Docker Hub |
| Synapse | `matrixdotorg/synapse:latest` | Docker Hub |
| Sliding sync | `ghcr.io/matrix-org/sliding-sync:latest` | GitHub Container Registry |
| MAS | `ghcr.io/element-hq/matrix-authentication-service:latest` | GitHub Container Registry |
| MAS init | `ghcr.io/element-hq/matrix-authentication-service:latest-debug` | GitHub Container Registry |
| nginx | `nginx:latest` | Docker Hub |
| WhatsApp bridge | `dock.mau.dev/mautrix/whatsapp:latest` | mau.dev Registry |
| Telegram bridge | `dock.mau.dev/mautrix/telegram:latest` | mau.dev Registry |
| Discord bridge | `dock.mau.dev/mautrix/discord:latest` | mau.dev Registry |
| Slack bridge | `dock.mau.dev/mautrix/slack:latest` | mau.dev Registry |

Note the MAS init container uses the `-debug` tag variant, which includes busybox utilities (`/busybox/sh`, `sed`, etc.) that are not present in the production image. This is why the entrypoint uses `/busybox/sh` instead of `/bin/sh`.

# 06 - Operations, Monitoring, and Maintenance

This document covers the day-to-day reality of operating this Matrix deployment: how changes ship, how to tell if things are healthy, how to fix them when they are not, and how to keep the system running well over months and years. It assumes you have read the architecture overview in [04-deployment-architecture.md](04-deployment-architecture.md) and understand the service graph.

---

## Table of Contents

1. [Deployment Workflow](#1-deployment-workflow)
2. [Service Health Monitoring](#2-service-health-monitoring)
3. [Common Operations](#3-common-operations)
4. [Database Administration](#4-database-administration)
5. [Troubleshooting Guide](#5-troubleshooting-guide)
6. [Backup and Recovery](#6-backup-and-recovery)
7. [Updating Services](#7-updating-services)
8. [Log Analysis](#8-log-analysis)
9. [Security Operations](#9-security-operations)
10. [Capacity Planning](#10-capacity-planning)

---

## 1. Deployment Workflow

### How Changes Reach Production

This deployment follows a Git-driven workflow orchestrated by Coolify. The entire infrastructure is defined in a single `docker-compose.yaml` at the repository root, with secrets and environment variables managed through the Coolify UI. The server is a Hetzner VPS at `37.27.69.212`.

The deployment cycle works as follows:

```
Edit docker-compose.yaml or .env.example
        |
        v
  git commit && git push
        |
        v
  Coolify detects the push (webhook or polling)
        |
        v
  Coolify pulls the repository on 37.27.69.212
        |
        v
  Coolify runs: docker compose up -d
        |
        v
  Docker reconciles: unchanged services stay running,
  changed services are recreated
```

### Environment Variable Management

Environment variables are **not** stored in the repository. The `.env.example` file serves only as a template showing which variables are required and what format they expect. The actual `.env` values live in the Coolify UI under the project's environment configuration.

When you need to change a secret or configuration value:

1. Log into the Coolify dashboard on `37.27.69.212`.
2. Navigate to the project's environment variables section.
3. Update the value. Coolify writes these into the `.env` file on the server before running `docker compose up`.
4. Trigger a redeploy (or push a commit to trigger one automatically).

**Important**: Changing an environment variable in Coolify without redeploying does nothing. The containers read their environment at startup time. You must redeploy for changes to take effect.

### What Triggers a Container Restart

Docker Compose only recreates containers whose definition has changed. This means:

- Changing an environment variable that a service references will recreate that service (and anything that `depends_on` it, depending on the condition).
- Changing a volume mount or image tag recreates the affected service.
- Changing the entrypoint or command recreates the service.
- Adding or removing a service recreates only what is necessary.

Init containers (`whatsapp-init`, `telegram-init`, `discord-init`, `slack-init`, `mas-config-init`) run on every `docker compose up` invocation, but they contain idempotency guards. For example, `mas-config-init` checks `if [ -f /data/config.yaml ]` and exits immediately if the config already exists. The bridge init containers always regenerate their configs via `yq` (to pick up any environment variable changes) and always regenerate the registration file.

### Manual Deployment from the Server

If you need to deploy manually (Coolify is down, or you want to test something):

```bash
ssh root@37.27.69.212
cd /path/to/coolify/project/directory  # Coolify clones the repo here
git pull
docker compose up -d
```

To find where Coolify stores the project:

```bash
find /data/coolify -name "docker-compose.yaml" -path "*/matrix*" 2>/dev/null
```

---

## 2. Service Health Monitoring

### Quick Status Overview

```bash
docker compose ps
```

This shows every service, its current state, health status, and port mappings. A healthy deployment looks like this:

| Service | Expected State | Health |
|---------|---------------|--------|
| `postgres-synapse` | `running` | `healthy` |
| `postgres-sliding-sync` | `running` | `healthy` |
| `postgres-synapse-mas` | `running` | `healthy` |
| `postgres-bridges` | `running` | `healthy` |
| `synapse` | `running` | (no healthcheck defined) |
| `sliding-sync` | `running` | (no healthcheck defined) |
| `synapse-mass-authentication-service` | `running` | (no healthcheck defined) |
| `nginx` | `running` | (no healthcheck defined) |
| `mautrix-whatsapp` | `running` | (no healthcheck defined) |
| `mautrix-telegram` | `running` | (no healthcheck defined) |
| `mautrix-discord` | `running` | (no healthcheck defined) |
| `mautrix-slack` | `running` | (no healthcheck defined) |
| `whatsapp-init` | `exited (0)` | N/A |
| `telegram-init` | `exited (0)` | N/A |
| `discord-init` | `exited (0)` | N/A |
| `slack-init` | `exited (0)` | N/A |
| `mas-config-init` | `exited (0)` | N/A |

**Critical rule**: Every init container must show `exited (0)`. Any other exit code means the init failed, and downstream services that depend on `service_completed_successfully` will not have started.

### PostgreSQL Health

All four PostgreSQL instances use `pg_isready` healthchecks with a 5-second interval and 5 retries:

```yaml
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_SYNAPSE_USER} -d ${POSTGRES_SYNAPSE_DB}"]
  interval: 5s
  timeout: 5s
  retries: 5
```

To manually verify:

```bash
# Check each database instance
docker compose exec postgres-synapse pg_isready -U synapse_user -d synapse
docker compose exec postgres-sliding-sync pg_isready -U sliding_sync_user -d sync-v3
docker compose exec postgres-synapse-mas pg_isready -U synapse_mas_user -d synapse_mas
docker compose exec postgres-bridges pg_isready -U bridges_user -d mautrix_whatsapp
```

A healthy response is:
```
/var/run/postgresql:5432 - accepting connections
```

### Synapse Health

Synapse does not have a Docker healthcheck defined, so you must check it through logs and HTTP.

**Log verification**:
```bash
docker compose logs synapse --tail 50
```

Look for:
```
synapse.app.homeserver - Synapse now listening on TCP port 8008
```

This line confirms Synapse has completed startup, loaded its configuration, connected to PostgreSQL, and is accepting requests.

Also verify that all four appservice registrations loaded:
```
synapse.appservice.api - Loading appservice config from /bridges/whatsapp-registration.yaml
synapse.appservice.api - Loading appservice config from /bridges/telegram-registration.yaml
synapse.appservice.api - Loading appservice config from /bridges/discord-registration.yaml
synapse.appservice.api - Loading appservice config from /bridges/slack-registration.yaml
```

**HTTP verification** (from inside the Docker network):
```bash
docker compose exec nginx curl -s http://synapse:8008/_matrix/client/versions | python3 -m json.tool
```

Or from the public internet:
```bash
curl -s https://synapse.your.matrix.server.de/_matrix/client/versions | python3 -m json.tool
```

### MAS (Matrix Authentication Service) Health

```bash
docker compose logs synapse-mass-authentication-service --tail 30
```

Look for the service binding to port 8080 and accepting connections. You can also hit its OIDC discovery endpoint:

```bash
docker compose exec nginx curl -s http://synapse-mass-authentication-service:8080/.well-known/openid-configuration | python3 -m json.tool
```

### Bridge Health

Each bridge logs its startup progress:

```bash
docker compose logs mautrix-whatsapp --tail 30
docker compose logs mautrix-telegram --tail 30
docker compose logs mautrix-discord --tail 30
docker compose logs mautrix-slack --tail 30
```

**Healthy startup patterns to look for**:

For Go-based bridges (WhatsApp, Discord, Slack):
```
Starting mautrix-whatsapp ...
Starting bridge
Connected to homeserver
```

For the Python-based bridge (Telegram):
```
Starting mautrix-telegram ...
Starting bridge
Connecting to homeserver
```

**Warning signs**:
- `Failed to connect to homeserver` -- Synapse is not reachable at `http://synapse:8008`
- `Registration file not found` -- The init container did not produce the expected file
- `Database connection refused` -- `postgres-bridges` is not ready or credentials are wrong
- Repeated `Reconnecting...` messages -- Network instability or Synapse is rejecting the appservice

### Sliding Sync Health

```bash
docker compose logs sliding-sync --tail 20
```

Verify it connects to both PostgreSQL and Synapse:
```bash
docker compose exec nginx curl -s http://sliding-sync:8009/client/server.json
```

### Nginx Health

```bash
docker compose logs nginx --tail 20
```

Nginx should show no errors on startup. Test the proxy routing:

```bash
# Test Synapse routing
curl -s -o /dev/null -w "%{http_code}" https://synapse.your.matrix.server.de/_matrix/client/versions

# Test .well-known
curl -s https://synapse.your.matrix.server.de/.well-known/matrix/client
```

The `.well-known` response should contain the JSON with `m.homeserver`, `org.matrix.msc3575.proxy`, and `org.matrix.msc2965.authentication` keys.

---

## 3. Common Operations

### Adding a New User

Users are managed through Keycloak, not Synapse directly. Synapse has `enable_registration: false` and `password_config.enabled: false`.

1. Log into the Keycloak admin console at `https://keycloak.your.matrix.server.de/admin`.
2. Select the correct realm (the one matching `KEYCLOAK_REALM_IDENTIFIER`).
3. Navigate to Users > Add user.
4. Fill in username, email, first name, last name.
5. Under Credentials, set a temporary password.
6. The user logs into Element (or any Matrix client) and is redirected to Keycloak via MAS. On first login, MAS creates the corresponding Matrix account (`@username:your.matrix.server.de`) automatically.

**Note**: The `preferred_username` field in Keycloak becomes the Matrix localpart (the part before the colon). The `name` field becomes the display name. The `email` field is imported and marked as verified. See [03-authentication.md](03-authentication.md) for the full claims mapping.

### Resetting a Bridge Login

If a bridge connection becomes stale (e.g., WhatsApp session expired, Telegram logged out remotely):

**Option 1: Re-login through the bot** (preferred, no downtime):

Open a direct message with the bridge bot (e.g., `@whatsappbot:your.matrix.server.de`) and use the login command. For WhatsApp, this shows a QR code. For Telegram, this starts an interactive login flow.

**Option 2: Full reset** (when option 1 fails):

```bash
# Stop the bridge
docker compose stop mautrix-whatsapp

# Clear the bridge data volume (this removes ALL users' bridge connections)
docker volume rm matrix_mautrix-whatsapp-data

# Restart (init container will regenerate config and registration)
docker compose up -d mautrix-whatsapp
```

**Warning**: Clearing the data volume disconnects ALL users from that bridge, not just one. There is no per-user reset from the CLI. Per-user resets should be done through the bot commands (`logout`, then `login`).

### Restarting Individual Services Without Full Downtime

Docker Compose allows restarting individual services:

```bash
# Restart just the Telegram bridge
docker compose restart mautrix-telegram

# Restart Synapse (clients will briefly disconnect, bridges will reconnect)
docker compose restart synapse

# Restart nginx (brief interruption to all HTTP traffic)
docker compose restart nginx
```

For a zero-downtime config reload of nginx specifically:

```bash
docker compose exec nginx nginx -s reload
```

However, since the nginx config is generated at container startup via the entrypoint, a `reload` only helps if you manually edited the config inside the container. For config changes, you must recreate the container:

```bash
docker compose up -d nginx
```

### Managing Rooms via the Synapse Admin API

The Admin API requires the `SYNAPSE_API_ADMIN_TOKEN`. All requests go through the `/_synapse/admin` prefix.

**List all rooms**:
```bash
curl -s -H "Authorization: Bearer YOUR_ADMIN_TOKEN" \
  "https://synapse.your.matrix.server.de/_synapse/admin/v1/rooms?limit=100" | python3 -m json.tool
```

**Get details for a specific room**:
```bash
curl -s -H "Authorization: Bearer YOUR_ADMIN_TOKEN" \
  "https://synapse.your.matrix.server.de/_synapse/admin/v1/rooms/!roomid:your.matrix.server.de" | python3 -m json.tool
```

**List room members**:
```bash
curl -s -H "Authorization: Bearer YOUR_ADMIN_TOKEN" \
  "https://synapse.your.matrix.server.de/_synapse/admin/v1/rooms/!roomid:your.matrix.server.de/members" | python3 -m json.tool
```

**Delete a room** (purge all messages):
```bash
curl -s -X DELETE -H "Authorization: Bearer YOUR_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"purge": true}' \
  "https://synapse.your.matrix.server.de/_synapse/admin/v2/rooms/!roomid:your.matrix.server.de"
```

**List users**:
```bash
curl -s -H "Authorization: Bearer YOUR_ADMIN_TOKEN" \
  "https://synapse.your.matrix.server.de/_synapse/admin/v2/users?limit=100" | python3 -m json.tool
```

**Note on authentication**: Because MSC3861 is enabled, the Admin API uses the `admin_token` from the MAS configuration, not a regular user access token. This is the value of `SYNAPSE_API_ADMIN_TOKEN`. Regular user tokens cannot access admin endpoints regardless of the user's admin status. See [02-synapse-homeserver.md](02-synapse-homeserver.md) for details.

### Checking Bridge Connection Status

Each bridge bot responds to commands in a DM:

| Bridge | Bot User | Status Command | Login Command |
|--------|----------|---------------|---------------|
| WhatsApp | `@whatsappbot:...` | `ping` | `login` (QR code) |
| Telegram | `@telegrambot:...` | `ping` | `login` (interactive) |
| Discord | `@discordbot:...` | `ping` | `login` (token) |
| Slack | `@slackbot:...` | `ping` | `login` (token/OAuth) |

The `ping` command tells you whether your bridge session is active and connected to the remote service. If it responds with a successful pong, messages are flowing.

For WhatsApp specifically, `ping` will report the phone number connected and whether the WebSocket to WhatsApp's servers is active.

---

## 4. Database Administration

### Connecting to Each Database

There are four PostgreSQL instances. Each runs as a separate container with its own volume.

**Synapse database** (the largest, stores all Matrix events):
```bash
docker compose exec postgres-synapse psql -U synapse_user -d synapse
```

**MAS database** (stores authentication sessions, tokens, upstream provider mappings):
```bash
docker compose exec postgres-synapse-mas psql -U synapse_mas_user -d synapse_mas
```

**Sliding Sync database** (stores sync state for the sliding sync proxy):
```bash
docker compose exec postgres-sliding-sync psql -U sliding_sync_user -d "sync-v3"
```

**Bridges database** (shared PostgreSQL instance with four databases):
```bash
# WhatsApp
docker compose exec postgres-bridges psql -U bridges_user -d mautrix_whatsapp

# Telegram
docker compose exec postgres-bridges psql -U bridges_user -d mautrix_telegram

# Discord
docker compose exec postgres-bridges psql -U bridges_user -d mautrix_discord

# Slack
docker compose exec postgres-bridges psql -U bridges_user -d mautrix_slack
```

### Common Diagnostic Queries

**Synapse: Check total number of events** (growth indicator):
```sql
-- Connect to postgres-synapse
SELECT COUNT(*) FROM events;
```

**Synapse: Largest rooms by event count**:
```sql
SELECT room_id, COUNT(*) as event_count
FROM events
GROUP BY room_id
ORDER BY event_count DESC
LIMIT 20;
```

**Synapse: User count**:
```sql
SELECT COUNT(*) FROM users;
```

**Synapse: Check federation queue** (outgoing transactions that have not been delivered):
```sql
SELECT destination, COUNT(*) as pending
FROM federation_stream_position
GROUP BY destination
ORDER BY pending DESC;
```

**Synapse: Database size**:
```sql
SELECT pg_size_pretty(pg_database_size('synapse'));
```

**Synapse: Largest tables**:
```sql
SELECT relname AS table_name,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 15;
```

**Bridge: Check connected users** (WhatsApp example):
```sql
-- Connect to mautrix_whatsapp on postgres-bridges
SELECT mxid, phone, name FROM puppet WHERE phone IS NOT NULL;
```

**MAS: Check active sessions**:
```sql
-- Connect to postgres-synapse-mas
SELECT COUNT(*) FROM oauth2_sessions WHERE revoked_at IS NULL;
```

### Vacuuming and Maintenance

PostgreSQL auto-vacuum runs by default, but the Synapse database can accumulate bloat from high write volume (every Matrix message is an INSERT into the `events` table).

**Check auto-vacuum status**:
```sql
SELECT relname, last_vacuum, last_autovacuum, last_analyze, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY last_autovacuum DESC NULLS LAST
LIMIT 20;
```

**Manual vacuum** (if auto-vacuum is falling behind):
```sql
VACUUM (VERBOSE) events;
VACUUM (VERBOSE) state_events;
VACUUM (VERBOSE) event_json;
```

**Full vacuum** (reclaims disk space, but locks the table -- only do during maintenance windows):
```sql
VACUUM FULL events;
```

**Reindex** (if query performance degrades):
```sql
REINDEX DATABASE synapse;
```

### Backup Strategy

Each database should be backed up independently. See [Section 6: Backup and Recovery](#6-backup-and-recovery) for full details and commands.

---

## 5. Troubleshooting Guide

### Init Container Failures

**Symptom**: `docker compose ps` shows an init container with a non-zero exit code (e.g., `exited (1)`). Downstream services never start because they depend on `service_completed_successfully`.

**Diagnosis**:
```bash
docker compose logs whatsapp-init    # or telegram-init, discord-init, slack-init, mas-config-init
```

**Common causes**:

| Cause | Log Pattern | Fix |
|-------|-------------|-----|
| `yq` syntax error | `Error: bad expression` or `yq: command not found` | Check the entrypoint script. The Go bridges ship with `yq` built in, but the Telegram bridge (Python) uses the system `yq`. Verify the yq path is correct for the image. |
| Missing environment variable | `env(SYNAPSE_SERVER_NAME): null` or empty string substitution | Check that all required variables are defined in Coolify. |
| Volume permission error | `permission denied` when writing to `/data` or `/registrations` | The init containers run as `user: "0:0"` (root) specifically to avoid this. If you see permission errors, the volume may have been created with restrictive permissions by a previous run. Remove the volume and recreate. |
| Bridge binary not found | `/usr/bin/mautrix-whatsapp: no such file or directory` | The image tag may have changed the binary location. Check the image's Dockerfile. |
| Database not ready | `connection refused` to `postgres-bridges:5432` | The healthcheck on `postgres-bridges` has `retries: 10` (vs. 5 for others) because it needs time to create extra databases on first run. If it still fails, increase retries or check PostgreSQL logs. |

**Resolution pattern**: Fix the root cause, then:
```bash
docker compose up -d  # Re-runs init containers and starts dependent services
```

### Bridge Not Starting

**Symptom**: Bridge container keeps restarting or exits immediately after the init completes successfully.

**Check**:
```bash
docker compose logs mautrix-whatsapp --tail 50
```

**Common causes**:

**Registration file missing or malformed**:
```
Failed to load appservice config: open /data/registration.yaml: no such file or directory
```
The init container should produce this file. Check init logs. If the file exists but is malformed, the init's `-g` (generate) step may have failed silently.

**Database connection refused**:
```
failed to connect to database: dial tcp: lookup postgres-bridges: no such host
```
The bridge container does not depend on `postgres-bridges` directly (only the init does). If PostgreSQL restarts after the init but before the bridge reads its config, the bridge may fail to connect. Restart the bridge: `docker compose restart mautrix-whatsapp`.

**Config syntax error**:
```
yaml: unmarshal errors
```
The init container wrote invalid YAML. Check the init entrypoint for quoting issues, especially with passwords containing special characters. Dollar signs (`$`), backticks, and single quotes in passwords are common culprits.

**Wrong database path in config** (critical gotcha):

The Go-based bridges (WhatsApp, Discord, Slack) and the Python-based bridge (Telegram) use different config schemas:

| Bridge | Database Config Path |
|--------|---------------------|
| WhatsApp (Go) | `.database.type` and `.database.uri` |
| Discord (Go) | `.appservice.database.type` and `.appservice.database.uri` |
| Slack (Go) | `.database.type` and `.database.uri` |
| Telegram (Python) | `.appservice.database` (single string) |

If you see `"Legacy bridge config detected"` in bridge logs, it means `yq` wrote the database URI to the wrong path. For example, writing `.appservice.database` on a bridge that expects `.database.uri` creates a config that the bridge interprets as the legacy format.

### Synapse Crashes

**FileNotFoundError for registration files**:
```
FileNotFoundError: [Errno 2] No such file or directory: '/bridges/whatsapp-registration.yaml'
```

Synapse's `app_service_config_files` lists four registration files. All four must exist before Synapse starts. This is enforced by the `depends_on` conditions -- Synapse waits for all four init containers to complete successfully. If you see this error, an init container either failed or did not copy the registration file to the shared `bridge-registrations` volume.

Check:
```bash
docker compose exec synapse ls -la /bridges/
```

Expected contents:
```
whatsapp-registration.yaml
telegram-registration.yaml
discord-registration.yaml
slack-registration.yaml
```

**Database migration failures**:
```
synapse.storage - Error running database migration
```

Synapse runs database migrations automatically on startup. If a migration fails, it usually means the previous Synapse version was too old for a direct upgrade (skipping major versions), or the database is in an inconsistent state from a previous crash during migration. Check the Synapse upgrade notes for the version you are moving to. Restoring a database backup and upgrading incrementally may be necessary.

**Out of memory**:
```
Killed
```
or container exits with code 137 (SIGKILL from OOM killer).

Synapse is the most memory-hungry service in this stack. On a server with many rooms, federated connections, and active bridges, it can consume several GB. See [Section 10: Capacity Planning](#10-capacity-planning).

### Authentication Failures

**MAS not reachable** (Synapse cannot talk to MAS):
```
synapse - Failed to fetch openid-configuration from http://synapse-mass-authentication-service:8080
```

The MSC3861 configuration in Synapse references MAS by its Docker Compose service name (`synapse-mass-authentication-service`). If MAS has not started (check its logs), or if Docker's internal DNS is not resolving the name, Synapse cannot authenticate users. Synapse depends on MAS via `condition: service_started`, which only waits for the container to be created, not for MAS to be ready.

**Temporary fix**: Restart Synapse after MAS is confirmed running.

**Keycloak down** (MAS cannot talk to Keycloak):
```
upstream_oauth2 - Failed to discover issuer
```

MAS connects to Keycloak at `KEYCLOAK_FQDN/realms/KEYCLOAK_REALM_IDENTIFIER`. If Keycloak is unreachable, users cannot log in. Note that Keycloak runs **outside** this Docker Compose stack (it is a separate Coolify service). Verify Keycloak is running independently.

**Token expiry / OIDC discovery failure**:

If users can load the login page but authentication fails after entering credentials, check:
1. Clock skew between the server and Keycloak (JWT tokens are time-sensitive).
2. The `issuer` URL in MAS config matches Keycloak's actual issuer URL exactly (including trailing slashes).
3. The Keycloak client secret matches between the Coolify env vars and the actual Keycloak client configuration.

See [03-authentication.md](03-authentication.md) for the full authentication flow and detailed troubleshooting.

### Federation Issues

**`.well-known` not served correctly**:

Federation requires that `https://your.matrix.server.de/.well-known/matrix/server` returns the correct homeserver delegation. If your `SYNAPSE_SERVER_NAME` (the domain in user IDs) differs from the domain where Synapse actually runs, you need `.well-known` delegation on the server name domain.

This nginx configuration serves `.well-known/matrix/client` but does **not** serve `.well-known/matrix/server`. If you need federation, you must configure the server name domain to return:
```json
{"m.server": "synapse.your.matrix.server.de:443"}
```

**Testing federation**:
```bash
# Use the Matrix federation tester
curl -s "https://federationtester.matrix.org/api/report?server_name=your.matrix.server.de" | python3 -m json.tool
```

**Signing key problems**: If Synapse's signing key changes (e.g., you lost the `synapse-data` volume), other servers that previously federated with you will reject your messages until they fetch the new key. This can take time, and some servers may cache the old key aggressively.

### Telegram "Puppeting Privileges" Error

**Symptom**: A user tries to log into the Telegram bridge and gets:
```
You do not have the permissions to log in to this bridge.
```

**Cause**: The bridge permissions are set to `"user"` for the server domain, but Telegram requires `"full"` permission level for login (puppeting). This is because Telegram puppeting involves logging into a real Telegram account, which is a higher-privilege operation.

**Fix**: The Telegram init container correctly sets `"full"` for the server domain:
```yaml
'.bridge.permissions = {"*": "relaybot", env(SYNAPSE_SERVER_NAME): "full", env(BRIDGE_ADMIN_USER): "admin"}'
```

If you see this error, verify the init container ran correctly and the config was written. The other bridges (WhatsApp, Discord, Slack) use `"user"` permission, which is sufficient for their login flows.

### yq `to_number` Failure with `env()`

**Symptom**: The Telegram init container fails with:
```
Error: cannot convert env() to number
```

**Cause**: The `TELEGRAM_API_ID` needs to be an integer in the YAML config, but `env()` returns a string. The `to_number` function does not work with `env()` in some yq versions.

**Solution**: Use YAML tag assignment instead:
```bash
yq -i '.telegram.api_id = (env(TELEGRAM_API_ID) | tag = "!!int")' /data/config.yaml
```

This is how the Telegram init container in `docker-compose.yaml` already handles it. If you are writing new init scripts for other services that need numeric values from environment variables, use this same `tag = "!!int"` pattern instead of `to_number`.

---

## 6. Backup and Recovery

### What to Back Up

| Data | Volume | Criticality | Notes |
|------|--------|-------------|-------|
| Synapse database | `postgres-synapse` | **Critical** | All rooms, messages, state. Everything. |
| Synapse media store | `synapse-media` | **High** | Uploaded files, avatars, thumbnails. Cannot be reconstructed. |
| Synapse signing keys | `synapse-data` | **Critical** | Loss means federation identity is broken. Other servers will not trust you. |
| MAS database | `postgres-synapse-mas` | **High** | Auth sessions, user mappings. Loss means all users must re-authenticate. |
| MAS config | `mas-data` | **Medium** | Can be regenerated by the init container, but existing sessions would be invalidated because the generated config includes new encryption keys. |
| Sliding Sync database | `postgres-sliding-sync` | **Low** | Can be fully reconstructed from Synapse. Just causes a slow initial sync for clients. |
| Bridge databases | `postgres-bridges` | **High** | All bridge connections, room mappings, puppet mappings. Loss means all users must re-link their bridges. |
| Bridge data volumes | `mautrix-*-data` | **Medium** | Config files and registration files. Can be regenerated by init containers. But WhatsApp session data may be here. |
| Bridge registrations | `bridge-registrations` | **Low** | Regenerated on every `docker compose up` by init containers. |

### Database Backup Commands

**Back up all databases** (run from the host):

```bash
# Synapse (largest, do this first)
docker compose exec -T postgres-synapse \
  pg_dump -U synapse_user -d synapse --format=custom \
  > synapse_backup_$(date +%Y%m%d_%H%M%S).dump

# MAS
docker compose exec -T postgres-synapse-mas \
  pg_dump -U synapse_mas_user -d synapse_mas --format=custom \
  > mas_backup_$(date +%Y%m%d_%H%M%S).dump

# Sliding Sync
docker compose exec -T postgres-sliding-sync \
  pg_dump -U sliding_sync_user -d "sync-v3" --format=custom \
  > sliding_sync_backup_$(date +%Y%m%d_%H%M%S).dump

# All four bridge databases
for db in mautrix_whatsapp mautrix_telegram mautrix_discord mautrix_slack; do
  docker compose exec -T postgres-bridges \
    pg_dump -U bridges_user -d "$db" --format=custom \
    > "${db}_backup_$(date +%Y%m%d_%H%M%S).dump"
done
```

**Note**: The `-T` flag disables pseudo-TTY allocation, which is required when redirecting output to a file. Without it, the dump file will contain TTY control characters and be corrupt.

### Volume Backup

For non-database volumes (media, signing keys, bridge data):

```bash
# Synapse media store
docker run --rm -v matrix_synapse-media:/data -v $(pwd)/backups:/backup \
  alpine tar czf /backup/synapse_media_$(date +%Y%m%d).tar.gz -C /data .

# Synapse data (contains signing keys)
docker run --rm -v matrix_synapse-data:/data -v $(pwd)/backups:/backup \
  alpine tar czf /backup/synapse_data_$(date +%Y%m%d).tar.gz -C /data .

# MAS data
docker run --rm -v matrix_mas-data:/data -v $(pwd)/backups:/backup \
  alpine tar czf /backup/mas_data_$(date +%Y%m%d).tar.gz -C /data .

# Bridge data (all four)
for bridge in whatsapp telegram discord slack; do
  docker run --rm -v "matrix_mautrix-${bridge}-data:/data" -v "$(pwd)/backups:/backup" \
    alpine tar czf "/backup/mautrix_${bridge}_data_$(date +%Y%m%d).tar.gz" -C /data .
done
```

**Important**: Replace `matrix_` with your actual Docker Compose project name prefix. Check with `docker volume ls | grep synapse`.

### Automated Backup Script

```bash
#!/bin/bash
# backup_matrix.sh - Run daily via cron
set -euo pipefail

BACKUP_DIR="/backups/matrix/$(date +%Y%m%d)"
COMPOSE_DIR="/path/to/matrix/project"
RETENTION_DAYS=30

mkdir -p "$BACKUP_DIR"
cd "$COMPOSE_DIR"

echo "$(date): Starting Matrix backup..."

# Databases
docker compose exec -T postgres-synapse pg_dump -U synapse_user -d synapse --format=custom > "$BACKUP_DIR/synapse.dump"
docker compose exec -T postgres-synapse-mas pg_dump -U synapse_mas_user -d synapse_mas --format=custom > "$BACKUP_DIR/mas.dump"
docker compose exec -T postgres-sliding-sync pg_dump -U sliding_sync_user -d "sync-v3" --format=custom > "$BACKUP_DIR/sliding_sync.dump"
for db in mautrix_whatsapp mautrix_telegram mautrix_discord mautrix_slack; do
  docker compose exec -T postgres-bridges pg_dump -U bridges_user -d "$db" --format=custom > "$BACKUP_DIR/${db}.dump"
done

# Volumes
for vol in synapse-data synapse-media mas-data; do
  docker run --rm -v "matrix_${vol}:/data" -v "$BACKUP_DIR:/backup" \
    alpine tar czf "/backup/${vol}.tar.gz" -C /data .
done

# Cleanup old backups
find /backups/matrix -maxdepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} +

echo "$(date): Backup completed. Size: $(du -sh $BACKUP_DIR | cut -f1)"
```

### Recovery Procedure

**Full recovery from scratch** (new server, empty volumes):

1. **Create the volumes** (Docker Compose does this automatically on `up`).

2. **Restore the databases**:
```bash
# Start only the database containers
docker compose up -d postgres-synapse postgres-synapse-mas postgres-sliding-sync postgres-bridges

# Wait for healthy
docker compose exec postgres-synapse pg_isready -U synapse_user -d synapse

# Restore each database
docker compose exec -T postgres-synapse pg_restore -U synapse_user -d synapse --clean --if-exists < synapse.dump
docker compose exec -T postgres-synapse-mas pg_restore -U synapse_mas_user -d synapse_mas --clean --if-exists < mas.dump
docker compose exec -T postgres-sliding-sync pg_restore -U sliding_sync_user -d "sync-v3" --clean --if-exists < sliding_sync.dump
for db in mautrix_whatsapp mautrix_telegram mautrix_discord mautrix_slack; do
  docker compose exec -T postgres-bridges pg_restore -U bridges_user -d "$db" --clean --if-exists < "${db}.dump"
done
```

3. **Restore the volumes**:
```bash
# Stop all containers first
docker compose down

# Restore Synapse data (signing keys)
docker run --rm -v matrix_synapse-data:/data -v $(pwd)/backups:/backup \
  alpine sh -c "cd /data && tar xzf /backup/synapse_data.tar.gz"

# Restore media store
docker run --rm -v matrix_synapse-media:/data -v $(pwd)/backups:/backup \
  alpine sh -c "cd /data && tar xzf /backup/synapse_media.tar.gz"

# Restore MAS data
docker run --rm -v matrix_mas-data:/data -v $(pwd)/backups:/backup \
  alpine sh -c "cd /data && tar xzf /backup/mas_data.tar.gz"
```

4. **Start everything**:
```bash
docker compose up -d
```

5. **Verify** using the health checks described in [Section 2](#2-service-health-monitoring).

### What You Lose If Volumes Are Destroyed

| Lost Volume | Impact |
|-------------|--------|
| `postgres-synapse` | All rooms, messages, user accounts, room state. Total data loss. |
| `synapse-data` | Signing keys gone. Federation identity broken. Other servers will reject your messages until they re-fetch keys (if they do at all). |
| `synapse-media` | All uploaded images, files, avatars gone. Messages referencing them will show broken media. |
| `postgres-synapse-mas` | All authentication sessions invalidated. Users must log in again. User-to-Matrix-ID mappings must be recreated by MAS on next login. |
| `mas-data` | Config regenerated by init container, but new encryption keys mean all existing tokens are invalid. Users must re-authenticate. |
| `postgres-bridges` | All bridge connections lost. Every user must re-link their WhatsApp/Telegram/Discord/Slack accounts. Room mappings gone -- bridged rooms become orphaned Matrix rooms. |
| `mautrix-*-data` | Bridge config regenerated by init containers. WhatsApp session keys may be lost (requiring QR code re-scan). |
| `bridge-registrations` | Regenerated on next `docker compose up`. No permanent impact. |

---

## 7. Updating Services

### General Update Strategy

All services use container images. Updating means pulling a newer image and recreating the container.

**If you use `:latest` tags** (as this deployment does for most services):

```bash
# Pull all new images
docker compose pull

# Recreate containers that have new images
docker compose up -d
```

**If you want to pin a specific version** (recommended for Synapse):

Edit `docker-compose.yaml`:
```yaml
synapse:
  image: matrixdotorg/synapse:v1.100.0  # instead of :latest
```

Then commit, push, and let Coolify deploy.

### Synapse Upgrades

Synapse is the most critical service to upgrade carefully.

**Before upgrading**:
1. Check the [Synapse changelog](https://github.com/element-hq/synapse/releases) for breaking changes.
2. Note if there are database migrations (the changelog mentions them).
3. Back up the Synapse database (see [Section 6](#6-backup-and-recovery)).
4. Check if the upgrade requires skipping versions or has mandatory intermediate versions.

**Database migrations run automatically**: When Synapse starts with a newer version, it detects that the database schema is behind and runs migrations. This can take seconds or minutes depending on the migration. Synapse will not serve requests until migrations complete.

**Rollback**: If an upgrade goes wrong, you cannot simply downgrade the Synapse image because the database schema may have been migrated forward. You must restore the pre-upgrade database backup and then start the old Synapse version.

### MAS Upgrades

The Matrix Authentication Service (`ghcr.io/element-hq/matrix-authentication-service`) is also pinned to `:latest`. MAS has its own database migrations.

**Important**: The `mas-config-init` container checks `if [ -f /data/config.yaml ]` and skips config generation if the file exists. This means upgrading MAS does not overwrite your config. However, new MAS versions may introduce new required config fields. Check the MAS changelog before upgrading.

### Bridge Upgrades

Mautrix bridges are generally safe to upgrade. They handle database migrations automatically.

```bash
docker compose pull mautrix-whatsapp mautrix-telegram mautrix-discord mautrix-slack
docker compose up -d
```

**Watch for**:
- Config schema changes (the init containers regenerate config on every run, so new fields are usually handled).
- Registration file format changes (rare, but the init containers regenerate these too).
- Python version changes for the Telegram bridge (it runs on Python, unlike the Go bridges).

Check the [mautrix changelog](https://github.com/mautrix) for each bridge before upgrading.

### PostgreSQL Major Version Upgrades

All PostgreSQL instances run `postgres:15`. Upgrading to a new major version (e.g., 16) requires a dump-and-restore because PostgreSQL's on-disk format is not compatible across major versions.

**Procedure**:

1. Back up all databases using `pg_dump` (see [Section 6](#6-backup-and-recovery)).

2. Stop all services:
```bash
docker compose down
```

3. Remove the old PostgreSQL volumes:
```bash
docker volume rm matrix_postgres-synapse matrix_postgres-sliding-sync matrix_postgres-synapse-mas matrix_postgres-bridges
```

4. Update the image tag in `docker-compose.yaml`:
```yaml
image: postgres:16  # for all four postgres services
```

5. Start only the database containers:
```bash
docker compose up -d postgres-synapse postgres-synapse-mas postgres-sliding-sync postgres-bridges
```

6. Wait for them to initialize (they will create fresh databases).

7. Restore each backup using `pg_restore` (see recovery commands in [Section 6](#6-backup-and-recovery)).

8. Start the rest:
```bash
docker compose up -d
```

**Warning**: The `postgres-bridges` container creates additional databases (`mautrix_telegram`, `mautrix_discord`, `mautrix_slack`) via its entrypoint script that writes to `/docker-entrypoint-initdb.d/`. This only runs when the data directory is empty (fresh volume). On restore, these databases already exist in the dump, so the init script's `CREATE DATABASE` commands will emit non-fatal errors. This is safe to ignore.

---

## 8. Log Analysis

### Viewing Logs

```bash
# All services (noisy, useful for startup debugging)
docker compose logs --tail 100

# Follow logs in real time
docker compose logs -f synapse

# Specific service with timestamps
docker compose logs -t mautrix-whatsapp --tail 200

# Multiple services
docker compose logs synapse mautrix-whatsapp postgres-synapse --tail 50
```

### Synapse Log Levels

The Synapse configuration explicitly sets:
```yaml
logging:
  - module: synapse.storage.SQL
    level: INFO
```

This suppresses the extremely verbose DEBUG output from the SQL module while keeping everything else at the default level. Without this, every SQL query would be logged, generating enormous log volume.

**Key log patterns**:

| Pattern | Meaning |
|---------|---------|
| `Synapse now listening on TCP port 8008` | Successful startup |
| `Loading appservice config from /bridges/...` | Bridge registration files being loaded |
| `Received appservice transaction` | A bridge is sending events to Synapse |
| `Failed to send transaction to appservice` | Synapse cannot reach a bridge (bridge container down?) |
| `Error handling request` | HTTP request processing failed -- check the full traceback |
| `synapse.federation.transport.server` | Incoming federation request |
| `synapse.federation.sender` | Outgoing federation |
| `database connection pool exhausted` | Too many concurrent requests for the configured pool (`cp_min: 5, cp_max: 10`) |

### Bridge Log Levels

Mautrix bridges log at INFO level by default. Key patterns:

| Pattern | Service | Meaning |
|---------|---------|---------|
| `Starting bridge` | All bridges | Bridge process starting |
| `Connected to homeserver` | All bridges | Bridge connected to Synapse |
| `Websocket connected` | WhatsApp | Connected to WhatsApp servers |
| `Logged in as ...` | Telegram | Successfully authenticated to Telegram |
| `Failed to connect to homeserver` | All bridges | Cannot reach Synapse |
| `Disconnected from WhatsApp` | WhatsApp | Session lost, will attempt reconnect |
| `Handler error` | All bridges | Error processing an incoming message |
| `Database migration` | All bridges | Schema migration in progress |
| `Appservice websocket` | All bridges | If using websocket mode for appservice communication |

### Correlating Errors Across Services

When troubleshooting a message delivery failure, trace through the full stack:

1. **Bridge logs**: Did the bridge receive the message from the remote platform? Look for incoming message handling.
2. **Bridge logs**: Did the bridge successfully send the event to Synapse? Look for `Sending event to Matrix` or `Failed to send`.
3. **Synapse logs**: Did Synapse receive the appservice transaction? Look for `Received appservice transaction`.
4. **Synapse logs**: Did Synapse store the event? Look for any database errors.
5. **PostgreSQL logs**: If Synapse reports a database error, check PostgreSQL:
```bash
docker compose logs postgres-synapse --tail 50
```

**Example correlation**:

User reports WhatsApp message not appearing in Matrix:
```bash
# Step 1: Check if bridge received it
docker compose logs mautrix-whatsapp --tail 100 | grep -i "message"

# Step 2: Check if bridge sent it to Synapse
docker compose logs mautrix-whatsapp --tail 100 | grep -i "send\|error\|fail"

# Step 3: Check Synapse for appservice transactions
docker compose logs synapse --tail 100 | grep -i "appservice\|whatsapp"

# Step 4: Check database if needed
docker compose logs postgres-synapse --tail 50 | grep -i "error"
```

### Log Rotation

Docker's default logging driver (`json-file`) does not rotate logs by default. Over weeks, log files for active services (especially Synapse) can grow to multiple GB.

**Check log sizes**:
```bash
du -sh /var/lib/docker/containers/*/
```

**Configure log rotation** in `/etc/docker/daemon.json`:
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  }
}
```

Then restart Docker: `systemctl restart docker`. This only applies to newly created containers. Existing containers keep their old log configuration until recreated.

---

## 9. Security Operations

### Rotating Secrets

This deployment uses several secrets that should be rotated periodically:

**`SYNAPSE_MAS_SECRET`** (shared secret between Synapse and MAS):
1. Generate a new secret: `openssl rand -hex 32`
2. Update in Coolify environment variables.
3. Delete the MAS config file so the init container regenerates it:
```bash
docker compose down synapse-mass-authentication-service mas-config-init
docker volume rm matrix_mas-data  # Forces config regeneration
```
4. Redeploy: `docker compose up -d`

**`SYNAPSE_API_ADMIN_TOKEN`**:
1. Generate a new token: `openssl rand -hex 32`
2. Update in Coolify environment variables.
3. Same procedure as above (MAS config references this too).
4. Update any scripts or monitoring that use the old token.

**Database passwords** (`POSTGRES_SYNAPSE_PASSWORD`, `POSTGRES_SYNAPSE_MAS_PASSWORD`, etc.):

Changing database passwords is more involved because the password is stored both in the PostgreSQL instance and in the connecting service's configuration:

1. Connect to the PostgreSQL instance and change the password:
```sql
ALTER USER synapse_user WITH PASSWORD 'new_password';
```
2. Update the environment variable in Coolify.
3. Redeploy so the connecting services pick up the new password.

**Warning**: If you change the password in Coolify but forget to change it in PostgreSQL (or vice versa), services will fail to connect on the next restart.

### Monitoring for Unauthorized Access

**Check Synapse for unknown users**:
```bash
curl -s -H "Authorization: Bearer YOUR_ADMIN_TOKEN" \
  "https://synapse.your.matrix.server.de/_synapse/admin/v2/users?guests=false" | python3 -m json.tool
```

**Check for unexpected federation connections**:
```bash
curl -s -H "Authorization: Bearer YOUR_ADMIN_TOKEN" \
  "https://synapse.your.matrix.server.de/_synapse/admin/v1/federation/destinations" | python3 -m json.tool
```

**Check MAS for unknown sessions**:
```bash
docker compose exec postgres-synapse-mas psql -U synapse_mas_user -d synapse_mas \
  -c "SELECT user_id, created_at, last_active_at FROM oauth2_sessions ORDER BY created_at DESC LIMIT 20;"
```

### Keeping Images Updated

Check for security advisories:
- Synapse: [GitHub Security Advisories](https://github.com/element-hq/synapse/security/advisories)
- PostgreSQL: [PostgreSQL Security](https://www.postgresql.org/support/security/)
- Nginx: [Nginx Security Advisories](https://nginx.org/en/security_advisories.html)
- Mautrix bridges: Check each bridge's GitHub repository

**Automated vulnerability scanning**:
```bash
# Scan a specific image
docker scout cves matrixdotorg/synapse:latest

# Or use trivy
trivy image matrixdotorg/synapse:latest
```

### Federation Security

**Check what your server exposes**:
```bash
# Federation endpoint (should return server keys)
curl -s https://synapse.your.matrix.server.de/_matrix/key/v2/server | python3 -m json.tool

# Client-server version endpoint (should be accessible)
curl -s https://synapse.your.matrix.server.de/_matrix/client/versions | python3 -m json.tool
```

**Block specific servers** (if you receive spam from a federated server):

Add to the Synapse homeserver config in the entrypoint:
```yaml
federation_domain_whitelist: []  # Empty = allow all
# OR for a blocklist approach, you need to use Synapse's IP range blocking
```

Currently the Synapse configuration trusts `matrix.org` as a key server:
```yaml
trusted_key_servers:
  - server_name: "matrix.org"
suppress_key_server_warning: true
```

This is standard and safe for most deployments.

---

## 10. Capacity Planning

### Memory Usage by Service

Expected memory consumption for a small-to-medium deployment (under 50 users, a few hundred rooms):

| Service | Typical RAM | Notes |
|---------|-------------|-------|
| `synapse` | 500MB - 2GB | Heaviest. Grows with rooms, federation, and concurrent connections. |
| `postgres-synapse` | 200MB - 1GB | Depends on `shared_buffers` and query complexity. Default config. |
| `postgres-synapse-mas` | 50MB - 100MB | Very light usage. |
| `postgres-sliding-sync` | 50MB - 100MB | Light. |
| `postgres-bridges` | 100MB - 200MB | Four databases, moderate write load from bridges. |
| `synapse-mass-authentication-service` | 100MB - 200MB | Rust-based, efficient. |
| `sliding-sync` | 100MB - 300MB | Go-based, grows with concurrent sync connections. |
| `nginx` | 10MB - 50MB | Minimal. |
| `mautrix-whatsapp` | 50MB - 100MB | Go-based, efficient. |
| `mautrix-telegram` | 100MB - 200MB | Python-based, heavier than Go bridges. |
| `mautrix-discord` | 50MB - 100MB | Go-based. |
| `mautrix-slack` | 50MB - 100MB | Go-based. |

**Total baseline**: approximately 1.5GB - 4.5GB depending on activity level.

On the Hetzner server (12 cores, 128GB RAM), this deployment is well within capacity. The server also runs approximately 30 other Docker services via Coolify, so monitor aggregate memory usage.

### Database Growth Patterns

The Synapse database grows fastest. The primary growth drivers:

| Table | Growth Pattern | Notes |
|-------|---------------|-------|
| `events` | Fastest growing | One row per Matrix event (message, state change, etc.) |
| `event_json` | Matches `events` | Full JSON body of each event |
| `state_events` | Moderate | Current state of each room |
| `received_transactions` | Moderate (federated) | Transactions from other servers |
| `device_lists_stream` | Moderate | E2EE device tracking |
| `media_repository` | Moderate | Metadata for uploaded media |

**Estimate**: A moderately active deployment with bridges generates roughly 10MB-50MB of database growth per day, primarily from bridged messages. Heavy bridge usage (e.g., active WhatsApp groups) can push this to 100MB+ per day.

**Monitor database size**:
```bash
docker compose exec postgres-synapse psql -U synapse_user -d synapse \
  -c "SELECT pg_size_pretty(pg_database_size('synapse'));"
```

**Monitor per-table growth**:
```bash
docker compose exec postgres-synapse psql -U synapse_user -d synapse -c "
SELECT relname AS table_name,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       n_tup_ins AS rows_inserted,
       n_tup_upd AS rows_updated,
       n_tup_del AS rows_deleted
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 15;
"
```

### Media Storage Growth

The `synapse-media` volume stores all uploaded files, images, videos, avatars, and thumbnails. Bridged media (images sent on WhatsApp/Telegram/Discord/Slack) are downloaded and stored here.

**Monitor media volume size**:
```bash
docker run --rm -v matrix_synapse-media:/data alpine du -sh /data
```

**Media cleanup**: Synapse provides an Admin API endpoint to purge old remote media (media fetched from other federated servers):
```bash
# Purge remote media older than 30 days (timestamp in milliseconds)
BEFORE_TS=$(( $(date +%s) * 1000 - 30 * 86400 * 1000 ))
curl -s -X POST \
  -H "Authorization: Bearer YOUR_ADMIN_TOKEN" \
  "https://synapse.your.matrix.server.de/_synapse/admin/v1/purge_media_cache?before_ts=$BEFORE_TS"
```

This does **not** delete locally uploaded media, only cached copies of remote media.

### When to Consider Synapse Workers

Synapse supports a "worker" mode where different types of requests are handled by separate processes. This is relevant when:

- Synapse memory usage consistently exceeds 4GB.
- Client sync requests (the most expensive operation) cause slowdowns for other operations.
- Federation sends are delayed because the main process is overloaded.
- You have more than 100-200 concurrent users.

Worker mode requires significant configuration changes (a separate worker config, a Redis instance for inter-worker communication, and a reverse proxy that routes requests to the correct worker). For this deployment's scale, the monolithic Synapse process is almost certainly sufficient.

If you do reach this point, the Synapse documentation provides a comprehensive [workers guide](https://element-hq.github.io/synapse/latest/workers.html). The main workers to split off first are:
- `synapse.app.generic_worker` for sync requests
- `synapse.app.federation_sender` for outbound federation
- `synapse.app.media_repository` for media handling

### Disk Space Monitoring

```bash
# Overall disk usage
df -h /var/lib/docker

# Docker volume sizes
docker system df -v

# Specific volume
docker run --rm -v matrix_postgres-synapse:/data alpine du -sh /data
```

**Set up alerts** when disk usage exceeds 80%. Running out of disk space causes PostgreSQL to crash (it cannot write WAL segments), which can corrupt the database.

### Connection Pool Sizing

The Synapse database configuration uses:
```yaml
cp_min: 5
cp_max: 10
```

This means Synapse maintains 5 persistent connections to PostgreSQL and can grow to 10 under load. If you see `database connection pool exhausted` in Synapse logs, increase `cp_max`. Note that PostgreSQL's default `max_connections` is 100, and you have four services connecting to the bridges database, so keep the total pool sizes across all services well under 100.

---

## Cross-References

- [02-synapse-homeserver.md](02-synapse-homeserver.md) -- Synapse configuration details, MSC3861, and the entrypoint script that generates `homeserver.yaml`, `db.yaml`, and `email.yaml`.
- [03-authentication.md](03-authentication.md) -- The full Keycloak to MAS to Synapse authentication chain, OIDC claims mapping, and auth-specific troubleshooting.
- [04-deployment-architecture.md](04-deployment-architecture.md) -- The service dependency graph, volume layout, networking, and how init containers bootstrap the system.
- [05-bridges.md](05-bridges.md) -- Bridge-specific configuration, the init container entrypoint scripts, yq patterns, permission levels, and per-bridge setup instructions.

# Setup Guide: Matrix Server with Bridges

Complete step-by-step guide to deploying this Matrix server stack from scratch. By the end, you'll have a fully working Matrix homeserver with Keycloak SSO and 6 messaging bridges (WhatsApp, Telegram, Discord, Slack, Meta/Instagram, LinkedIn).

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Architecture Overview](#architecture-overview)
- [Step 1: Provision a Server](#step-1-provision-a-server)
- [Step 2: Install Coolify](#step-2-install-coolify)
- [Step 3: DNS Setup](#step-3-dns-setup)
- [Step 4: Deploy Keycloak](#step-4-deploy-keycloak)
- [Step 5: Configure Keycloak](#step-5-configure-keycloak)
- [Step 6: Deploy the Matrix Stack](#step-6-deploy-the-matrix-stack)
- [Step 7: Configure Environment Variables](#step-7-configure-environment-variables)
- [Step 8: Domain and Port Mapping](#step-8-domain-and-port-mapping)
- [Step 9: First Deployment](#step-9-first-deployment)
- [Step 10: Verify Services](#step-10-verify-services)
- [Step 11: Create Your First User](#step-11-create-your-first-user)
- [Step 12: Connect a Matrix Client](#step-12-connect-a-matrix-client)
- [Step 13: Set Up Bridges](#step-13-set-up-bridges)
- [Troubleshooting](#troubleshooting)
- [Environment Variable Reference](#environment-variable-reference)

---

## Prerequisites

**You need:**

- A Linux server (Ubuntu 22.04+ or Debian 12+ recommended) with at least 4 CPU cores, 8 GB RAM, and 40 GB disk
- A domain name you control (e.g. `example.com`) with access to DNS settings
- An SMTP server for sending emails (optional but recommended)
- For Telegram bridge: API credentials from https://my.telegram.org/apps

**Recommended server specs for all 6 bridges running:**

| Users | CPU | RAM | Disk |
|-------|-----|-----|------|
| 1-10 | 4 cores | 8 GB | 40 GB |
| 10-50 | 4 cores | 16 GB | 80 GB |
| 50-200 | 8 cores | 32 GB | 200 GB |

---

## Architecture Overview

This stack deploys 21 Docker containers:

```
Internet
   │
   ▼
Coolify (Traefik) ── TLS termination
   │
   ├─► nginx (:80)
   │     ├─► login/logout/refresh → MAS (:8080)
   │     └─► everything else → Synapse (:8008)
   │
   ├─► Synapse (homeserver)
   │     ├── postgres-synapse
   │     └── reads bridge registrations from /bridges/
   │
   ├─► MAS (authentication service)
   │     ├── postgres-synapse-mas
   │     └── delegates to Keycloak (upstream OIDC)
   │
   ├─► Sliding Sync proxy (:8009)
   │     └── postgres-sliding-sync
   │
   ├─► postgres-bridges (shared, 6 databases)
   │
   ├─► 6x bridge init containers (one-shot config generators)
   └─► 6x bridge runtime containers
         ├── mautrix-whatsapp (:29318)
         ├── mautrix-telegram (:29317)
         ├── mautrix-discord (:29334)
         ├── mautrix-slack (:29335)
         ├── mautrix-meta (:29319)
         └── mautrix-linkedin (:29341)
```

Keycloak runs as a separate Coolify service (not in this docker-compose).

---

## Step 1: Provision a Server

Get a VPS from Hetzner, DigitalOcean, OVH, or any provider. Minimum requirements: 4 cores, 8 GB RAM.

```bash
# After you can SSH in, update the system
ssh root@your-server-ip
apt update && apt upgrade -y
```

---

## Step 2: Install Coolify

Coolify is a self-hosted PaaS that handles Docker deployments, TLS certificates, and reverse proxying via Traefik.

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

After installation:

1. Open `http://your-server-ip:8000` in your browser
2. Create your admin account
3. Coolify will configure itself — wait for it to finish

> **Why Coolify?** It automates TLS certificates (Let's Encrypt), domain routing, environment variable management, and git-based deployments. You could do this with plain Docker Compose + Traefik, but Coolify handles the glue.

---

## Step 3: DNS Setup

You need 5 subdomains pointing to your server. In your DNS provider, create these A records:

| Subdomain | Type | Value |
|-----------|------|-------|
| `matrix.example.com` | A | `your-server-ip` |
| `synapse.example.com` | A | `your-server-ip` |
| `sync.synapse.example.com` | A | `your-server-ip` |
| `mas.synapse.example.com` | A | `your-server-ip` |
| `keycloak.example.com` | A | `your-server-ip` |

Replace `example.com` with your actual domain. Wait for DNS propagation (usually 1-5 minutes with most providers).

**What each domain does:**

- `matrix.example.com` — Main entry point for Matrix clients (nginx)
- `synapse.example.com` — Direct Synapse access (federation, admin API)
- `sync.synapse.example.com` — Sliding Sync proxy for fast client sync
- `mas.synapse.example.com` — Matrix Authentication Service (OIDC)
- `keycloak.example.com` — Identity provider (user management, SSO)

---

## Step 4: Deploy Keycloak

Keycloak is the identity provider where users are created and authenticated.

1. In Coolify, go to **Projects** → **Create New Project** (e.g. "Matrix")
2. Inside your project, click **Add Resource** → **Services** → search for **Keycloak with PostgreSQL**
3. Configure the service:
   - Set a strong admin username and password — **save these, you'll need them**
   - Set a database name (default is fine)
4. In the service settings, assign the domain `keycloak.example.com`
5. Click **Deploy**

Wait until the Keycloak service shows as healthy (green).

---

## Step 5: Configure Keycloak

### 5.1 Create a Realm

1. Open `https://keycloak.example.com` and log in with admin credentials
2. Click the dropdown in the top-left (shows "master") → **Create realm**
3. Enter a **Realm name** (e.g. `Matrix`) — remember this exactly, it becomes `KEYCLOAK_REALM_IDENTIFIER`
4. Click **Create**

### 5.2 Create an OIDC Client for Matrix

1. In your new realm, go to **Clients** → **Create client**
2. Configure:
   - **Client type**: OpenID Connect
   - **Client ID**: `synapse` (this becomes `KEYCLOAK_CLIENT_ID`)
   - Click **Next**
3. On the next screen:
   - **Client authentication**: ON
   - **Authorization**: OFF
   - **Authentication flow**: check "Standard flow" and "Direct access grants"
   - Click **Next**
4. Set the redirect URIs:
   - **Valid redirect URIs**: `https://mas.synapse.example.com/**`
   - **Web origins**: `https://mas.synapse.example.com`
   - Click **Save**
5. Go to the **Credentials** tab and copy the **Client secret** — this becomes `KEYCLOAK_CLIENT_SECRET`

### 5.3 Create Your First User

1. Go to **Users** → **Add user**
2. Fill in:
   - **Username**: your desired Matrix username (e.g. `alice`) — this becomes `@alice:example.com`
   - **Email**: your email address
   - **First name** / **Last name**: your display name
   - **Email verified**: ON
3. Click **Create**
4. Go to the **Credentials** tab → **Set password**
5. Enter a password, toggle **Temporary** to OFF, click **Save**

---

## Step 6: Deploy the Matrix Stack

### 6.1 Fork or Clone the Repository

If you want to customize, fork the repository on GitHub first. Otherwise you can use the repo directly.

### 6.2 Add as Coolify Resource

1. In Coolify, go to your project → **Add Resource** → **Public Repository** (or **Private Repository** if you forked)
2. Enter the repository URL
3. Set **Build Type** to **Docker Compose**
4. Leave other defaults and click **Continue**

> **Important**: Do NOT deploy yet. You need to configure environment variables and domain mappings first.

---

## Step 7: Configure Environment Variables

### 7.1 Generate Secrets

You need several random secrets. Generate them:

```bash
# Run this on your local machine or server
# Each command generates a random 32-character string
openssl rand -hex 16  # for POSTGRES_SYNAPSE_PASSWORD
openssl rand -hex 16  # for POSTGRES_SYNAPSE_MAS_PASSWORD
openssl rand -hex 16  # for POSTGRES_SLIDING_SYNC_PASSWORD
openssl rand -hex 16  # for POSTGRES_BRIDGES_PASSWORD
openssl rand -hex 16  # for SLIDING_SYNC_SECRET
openssl rand -hex 16  # for SYNAPSE_MAS_SECRET
openssl rand -hex 32  # for SYNAPSE_API_ADMIN_TOKEN (longer for admin token)
```

### 7.2 Set Variables in Coolify

In your Matrix docker-compose resource in Coolify:

1. Go to **Environment Variables**
2. Enable **Developer View** (toggle at the top)
3. Paste the following, replacing every value with your actual configuration:

```bash
# === Server Identity ===
SYNAPSE_SERVER_NAME=example.com
SYNAPSE_FRIENDLY_SERVER_NAME="My Matrix Server"
ADMIN_EMAIL=admin@example.com

# === URLs (must match your DNS setup) ===
SYNAPSE_FQDN=https://synapse.example.com
SYNAPSE_SYNC_FQDN=https://sync.synapse.example.com
SYNAPSE_MAS_FQDN=https://mas.synapse.example.com

# === Synapse Database ===
POSTGRES_SYNAPSE_DB=synapse
POSTGRES_SYNAPSE_USER=synapse_user
POSTGRES_SYNAPSE_PASSWORD=<generated-secret>

# === MAS Database ===
POSTGRES_SYNAPSE_MAS_DB=synapse_mas
POSTGRES_SYNAPSE_MAS_USER=synapse_mas_user
POSTGRES_SYNAPSE_MAS_PASSWORD=<generated-secret>

# === Sliding Sync Database ===
POSTGRES_SLIDING_SYNC_DB=sync-v3
POSTGRES_SLIDING_SYNC_USER=sliding_sync_user
POSTGRES_SLIDING_SYNC_PASSWORD=<generated-secret>
SLIDING_SYNC_SECRET=<generated-secret>

# === Keycloak / Authentication ===
KEYCLOAK_FQDN=https://keycloak.example.com
KEYCLOAK_REALM_IDENTIFIER=Matrix
KEYCLOAK_CLIENT_ID=synapse
KEYCLOAK_CLIENT_SECRET=<from-keycloak-step-5.2>
KEYCLOAK_UPSTREAM_OAUTH_PROVIDER_ID=01H8PKNWKKRPCBW4YGH1RWV279
AUTHENTICATION_ISSUER=https://example.com

# === Synapse <-> MAS Shared Secrets ===
SYNAPSE_MAS_SECRET=<generated-secret>
SYNAPSE_API_ADMIN_TOKEN=<generated-secret>

# === SMTP (optional, for email notifications) ===
SMTP_HOST=mail.example.com
SMTP_PORT=587
SMTP_USER=no-reply@example.com
SMTP_PASSWORD=your-smtp-password
SMTP_REQUIRE_TRANSPORT_SECURITY=true
SMTP_NOTIFY_FROM=no-reply@example.com

# === Bridges ===
POSTGRES_BRIDGES_USER=bridges_user
POSTGRES_BRIDGES_PASSWORD=<generated-secret>
BRIDGE_ADMIN_USER=@alice:example.com

# === Telegram (get from https://my.telegram.org/apps) ===
TELEGRAM_API_ID=12345678
TELEGRAM_API_HASH=your_telegram_api_hash
```

4. Click **Save**
5. Switch back to **Normal View** for easier future edits

### Key Configuration Notes

**`SYNAPSE_SERVER_NAME`** is the most important variable. It's the domain that appears in user IDs (e.g. `@alice:example.com`). This **cannot be changed** after the first deployment without losing all data.

**`AUTHENTICATION_ISSUER`** should be your base domain (e.g. `https://example.com`), not the Keycloak URL.

**`BRIDGE_ADMIN_USER`** should be the full Matrix ID of the user you created in Keycloak (e.g. `@alice:example.com`). This user gets admin access to all bridges.

**`KEYCLOAK_UPSTREAM_OAUTH_PROVIDER_ID`** — leave the default value (`01H8PKNWKKRPCBW4YGH1RWV279`) unless you have a specific reason to change it.

---

## Step 8: Domain and Port Mapping

In Coolify, go to your Matrix resource → **Settings** or **Network** and map domains to the internal service ports:

| Domain | Service | Port |
|--------|---------|------|
| `matrix.example.com` | nginx | 80 |
| `synapse.example.com` | synapse | 8008 |
| `sync.synapse.example.com` | sliding-sync | 8009 |
| `mas.synapse.example.com` | synapse-mass-authentication-service | 8080 |

Coolify handles TLS termination via Traefik/Let's Encrypt automatically.

**The primary client entry point is `matrix.example.com`** (nginx). This is the URL you give to Matrix clients. Nginx routes:
- `/_matrix/client/.../login`, `logout`, `refresh` → MAS
- Everything else (`/_matrix/*`, `/_synapse/*`) → Synapse
- `/.well-known/matrix/client` → JSON discovery document

---

## Step 9: First Deployment

1. In Coolify, click **Deploy**
2. Watch the logs. The startup sequence is:
   ```
   t=0s   4x PostgreSQL instances start, run healthchecks
   t=5s   mas-config-init generates MAS config (first run only)
   t=5s   6x bridge init containers generate configs + registrations
   t=10s  MAS starts (depends on mas-config-init + postgres)
   t=10s  Synapse starts (depends on all init containers + postgres + MAS)
   t=15s  Sliding Sync starts (depends on synapse + postgres)
   t=15s  nginx starts (depends on synapse + MAS)
   t=15s  6x bridge runtime containers start (depends on init + synapse)
   ```
3. All init containers should exit with code 0
4. All runtime services should show as "running" or "healthy"

**First deploy takes ~2 minutes** while images are pulled. Subsequent deploys are faster (~20s).

---

## Step 10: Verify Services

### Check from your browser

1. **Synapse**: Visit `https://synapse.example.com/_matrix/federation/v1/version`
   - Should return JSON with `server.name` and `server.version`

2. **Well-known**: Visit `https://matrix.example.com/.well-known/matrix/client/index.html`
   - Should return JSON with `m.homeserver.base_url` pointing to your Synapse URL

3. **MAS**: Visit `https://mas.synapse.example.com/.well-known/openid-configuration`
   - Should return OIDC discovery document

### Check from Coolify logs

```
# In Coolify UI, check logs for each service:

# Synapse should show:
#   "Synapse now listening on TCP port 8008"
#   "Loading appservice: /bridges/whatsapp-registration.yaml" (x6)

# Each bridge should show:
#   "Starting bridge" or similar startup message
#   No error lines in red

# Init containers should show exit code 0
```

### Check from server SSH

```bash
# List all running containers
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "(synapse|nginx|mas|sliding|bridge|mautrix|postgres)"

# Check init containers completed
docker ps -a --filter "status=exited" --format "table {{.Names}}\t{{.Status}}" | grep init

# Verify all 6 bridge databases exist
docker exec $(docker ps --filter name=postgres-bridges -q | head -1) \
  psql -U bridges_user -c '\l' | grep mautrix
```

---

## Step 11: Create Your First User

Users are managed in Keycloak, not Synapse. You already created a user in Step 5.3.

To create additional users:

1. Go to `https://keycloak.example.com`
2. Log in as admin
3. Switch to your realm (e.g. "Matrix")
4. Go to **Users** → **Add user**
5. Fill in username, email, name
6. Save, then go to **Credentials** → **Set password** (toggle Temporary to OFF)

The user can now log into Matrix. Their Matrix ID will be `@username:example.com`.

---

## Step 12: Connect a Matrix Client

### Recommended: Element Web/Desktop

1. Download Element from https://element.io/download (or use https://app.element.io)
2. Click **Sign In**
3. Click **Edit** next to the homeserver field
4. Enter: `https://matrix.example.com`
5. Click **Continue** — you'll be redirected to Keycloak
6. Log in with the credentials you set in Keycloak
7. You're in!

### Alternative Clients

| Client | Platform | Notes |
|--------|----------|-------|
| Element X | iOS, Android | Next-gen client, faster, uses Sliding Sync |
| FluffyChat | All platforms | Clean, simple UI |
| Cinny | Web | Discord-like interface |
| SchildiChat | All platforms | Element fork with extra features |

All clients should use `https://matrix.example.com` as the homeserver URL.

---

## Step 13: Set Up Bridges

All 6 bridges are already running. You interact with them by starting a DM with the bridge bot in your Matrix client.

### WhatsApp

1. Start a DM with `@whatsappbot:example.com`
2. Send `login`
3. The bot sends a QR code — scan it with WhatsApp on your phone (WhatsApp → Linked Devices → Link a Device)
4. Your WhatsApp chats appear as Matrix rooms

### Telegram

Requires `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` in env vars (from https://my.telegram.org/apps).

1. Start a DM with `@telegrambot:example.com`
2. Send `login`
3. Enter your phone number when prompted
4. Enter the verification code Telegram sends you
5. Your Telegram chats appear as Matrix rooms

### Discord

1. Start a DM with `@discordbot:example.com`
2. Send `login`
3. Follow the token-based login instructions the bot provides

### Slack

1. Start a DM with `@slackbot:example.com`
2. Send `login`
3. Follow the OAuth login flow

### Meta (Facebook Messenger + Instagram)

1. Start a DM with `@metabot:example.com`
2. Send `login`
3. The bridge supports both Facebook Messenger and Instagram — you'll be asked which service to connect
4. Follow the cookie-based login instructions

### LinkedIn

1. Start a DM with `@linkedinbot:example.com`
2. Send `login`
3. Follow the cookie-based login instructions

### Useful Bridge Commands

These work with all bridges:

| Command | Description |
|---------|-------------|
| `help` | Show available commands |
| `login` | Start login process |
| `logout` | Disconnect from the service |
| `ping` | Check connection status |
| `sync` | Force re-sync of chats |

---

## Troubleshooting

### Init container won't exit (stuck)

**Check logs:**
```bash
docker logs <container-name>  # e.g. docker logs whatsapp-init
```

Common causes:
- Missing environment variable → check Coolify env vars
- PostgreSQL not ready → `postgres-bridges` healthcheck failing, check its logs
- yq syntax error → check for typos in docker-compose.yaml entrypoint

### Synapse crashes with `FileNotFoundError: /bridges/xxx-registration.yaml`

An init container failed to generate its registration file. Check which bridge's init container has errors in its logs.

### "Legacy bridge config detected" in bridge logs

The bridge config was written with wrong YAML paths. This happens if you manually edited config.yaml. Fix: delete the bridge's data volume and let the init container regenerate it.

```bash
docker compose stop mautrix-whatsapp
docker volume rm <project>_mautrix-whatsapp-data
docker compose up -d mautrix-whatsapp
```

### Telegram: "That command is limited to users with puppeting privileges"

Telegram uses different permission levels than other bridges. The `user` level does NOT allow login. This repo already sets Telegram to `full` for your domain. If you see this error, check that your Matrix user domain matches `SYNAPSE_SERVER_NAME`.

### Login redirects to Keycloak but shows an error

1. Verify `KEYCLOAK_FQDN` matches your actual Keycloak URL
2. Verify `KEYCLOAK_REALM_IDENTIFIER` matches the realm name (case-sensitive)
3. Verify `KEYCLOAK_CLIENT_SECRET` matches the secret in Keycloak → Clients → synapse → Credentials
4. Verify the redirect URI in Keycloak includes `https://mas.synapse.example.com/**`

### Bridge bot doesn't respond

1. Check that the bridge runtime container is running: `docker ps | grep mautrix`
2. Check bridge logs: `docker logs mautrix-whatsapp`
3. Verify Synapse loaded the registration: check Synapse logs for "Loading appservice"
4. Try restarting the bridge: `docker restart mautrix-whatsapp`

### MAS shows "connection refused" or "issuer not reachable"

MAS uses an internal Docker URL (`http://synapse-mass-authentication-service:8080`). This only works within the Docker network. Verify:
1. MAS container is running
2. Container name matches exactly (check `docker ps`)
3. Both containers are on the same Docker network

### Database "already exists" errors on re-deploy

This is normal and harmless. The postgres-bridges init SQL runs `CREATE DATABASE` on every startup. If the databases already exist, PostgreSQL logs a notice but continues normally.

### How to completely reset a bridge

```bash
# Stop the bridge
docker compose stop mautrix-whatsapp

# Remove its data volume (DESTROYS ALL BRIDGE DATA for this bridge)
docker volume rm <project>_mautrix-whatsapp-data

# Restart — init container will regenerate everything
docker compose up -d
```

### How to reset MAS config (e.g. after changing Keycloak settings)

MAS config is only generated on first run (idempotent). To regenerate:

```bash
# Stop MAS
docker compose stop synapse-mass-authentication-service

# Remove MAS data volume
docker volume rm <project>_mas-data

# Restart — init container will regenerate config
docker compose up -d
```

---

## Environment Variable Reference

### Identity

| Variable | Description | Example | Can Change After Deploy? |
|----------|-------------|---------|--------------------------|
| `SYNAPSE_SERVER_NAME` | Domain in user IDs (`@user:this`) | `example.com` | **NO** |
| `SYNAPSE_FRIENDLY_SERVER_NAME` | Display name in emails/UI | `"My Matrix Server"` | Yes |
| `ADMIN_EMAIL` | Admin contact shown to users | `admin@example.com` | Yes |

### URLs

| Variable | Description | Example |
|----------|-------------|---------|
| `SYNAPSE_FQDN` | Full URL to Synapse | `https://synapse.example.com` |
| `SYNAPSE_SYNC_FQDN` | Full URL to Sliding Sync | `https://sync.synapse.example.com` |
| `SYNAPSE_MAS_FQDN` | Full URL to MAS | `https://mas.synapse.example.com` |

### Databases

| Variable | Default | Notes |
|----------|---------|-------|
| `POSTGRES_SYNAPSE_DB` | `synapse` | |
| `POSTGRES_SYNAPSE_USER` | `synapse_user` | |
| `POSTGRES_SYNAPSE_PASSWORD` | — | Generate random |
| `POSTGRES_SYNAPSE_MAS_DB` | `synapse_mas` | |
| `POSTGRES_SYNAPSE_MAS_USER` | `synapse_mas_user` | |
| `POSTGRES_SYNAPSE_MAS_PASSWORD` | — | Generate random |
| `POSTGRES_SLIDING_SYNC_DB` | `sync-v3` | |
| `POSTGRES_SLIDING_SYNC_USER` | `sliding_sync_user` | |
| `POSTGRES_SLIDING_SYNC_PASSWORD` | — | Generate random |
| `POSTGRES_BRIDGES_USER` | `bridges_user` | Shared for all bridges |
| `POSTGRES_BRIDGES_PASSWORD` | — | Generate random |

### Authentication

| Variable | Description | Notes |
|----------|-------------|-------|
| `KEYCLOAK_FQDN` | Keycloak URL | `https://keycloak.example.com` |
| `KEYCLOAK_REALM_IDENTIFIER` | Keycloak realm name | Case-sensitive |
| `KEYCLOAK_CLIENT_ID` | OIDC client ID | Usually `synapse` |
| `KEYCLOAK_CLIENT_SECRET` | OIDC client secret | From Keycloak UI |
| `KEYCLOAK_UPSTREAM_OAUTH_PROVIDER_ID` | MAS provider ID | Leave default |
| `AUTHENTICATION_ISSUER` | Shown as auth requester | Your base domain |
| `SYNAPSE_MAS_SECRET` | Synapse-MAS shared secret | Generate random |
| `SYNAPSE_API_ADMIN_TOKEN` | Synapse admin API token | Generate random, keep safe |
| `SLIDING_SYNC_SECRET` | Sliding Sync secret | Generate random |

### Email (SMTP)

| Variable | Description | Example |
|----------|-------------|---------|
| `SMTP_HOST` | SMTP server | `mail.example.com` |
| `SMTP_PORT` | SMTP port | `587` |
| `SMTP_USER` | SMTP username | `no-reply@example.com` |
| `SMTP_PASSWORD` | SMTP password | |
| `SMTP_REQUIRE_TRANSPORT_SECURITY` | Require TLS | `true` |
| `SMTP_NOTIFY_FROM` | From address | `no-reply@example.com` |

### Bridges

| Variable | Description | Notes |
|----------|-------------|-------|
| `BRIDGE_ADMIN_USER` | Matrix ID with admin on all bridges | `@alice:example.com` |
| `TELEGRAM_API_ID` | Telegram API ID | From my.telegram.org |
| `TELEGRAM_API_HASH` | Telegram API hash | From my.telegram.org |

---

## What's Next?

- **Read the user manual**: See [MANUAL.md](MANUAL.md) for day-to-day Matrix and bridge usage
- **Deep-dive docs**: See `01-matrix-fundamentals.md` through `06-operations.md` for detailed technical documentation
- **Add more bridges**: The init container pattern makes adding bridges straightforward — see [05-bridges.md](05-bridges.md) for a template
- **Monitor your server**: See [06-operations.md](06-operations.md) for log analysis, backups, and capacity planning

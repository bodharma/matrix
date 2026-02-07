# Matrix Server - User & Administration Manual

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Getting Started](#getting-started)
  - [Choosing a Client](#choosing-a-client)
  - [Logging In](#logging-in)
  - [Creating Rooms and Spaces](#creating-rooms-and-spaces)
  - [Inviting Users](#inviting-users)
  - [Direct Messages](#direct-messages)
  - [End-to-End Encryption](#end-to-end-encryption)
- [Bridges Overview](#bridges-overview)
- [WhatsApp Bridge](#whatsapp-bridge)
  - [Logging In to WhatsApp](#logging-in-to-whatsapp)
  - [WhatsApp Features](#whatsapp-features)
  - [WhatsApp Commands](#whatsapp-commands)
- [Telegram Bridge](#telegram-bridge)
  - [Logging In to Telegram](#logging-in-to-telegram)
  - [Telegram Features](#telegram-features)
  - [Telegram Commands](#telegram-commands)
- [Discord Bridge](#discord-bridge)
  - [Logging In to Discord](#logging-in-to-discord)
  - [Discord Features](#discord-features)
  - [Discord Commands](#discord-commands)
- [Slack Bridge](#slack-bridge)
  - [Logging In to Slack](#logging-in-to-slack)
  - [Slack Features](#slack-features)
  - [Slack Commands](#slack-commands)
- [Bridge Administration](#bridge-administration)
  - [Permission Levels](#permission-levels)
  - [Relay Mode](#relay-mode)
  - [Double Puppeting](#double-puppeting)
  - [Troubleshooting Bridges](#troubleshooting-bridges)
- [Additional Bridges Available](#additional-bridges-available)
  - [Signal](#signal)
  - [Facebook Messenger & Instagram](#facebook-messenger--instagram)
  - [Google Messages (RCS/SMS)](#google-messages-rcssms)
  - [Twitter/X](#twitterx)
  - [LinkedIn](#linkedin)
  - [Google Chat](#google-chat)
  - [IRC](#irc)
  - [Email](#email)
  - [GitHub/GitLab/JIRA (Hookshot)](#githubgitlabjira-hookshot)
- [Environment Variables Reference](#environment-variables-reference)
- [Server Administration](#server-administration)

---

## Architecture Overview

This Matrix deployment consists of:

| Component | Purpose | Internal Port |
|-----------|---------|---------------|
| **Synapse** | Matrix homeserver | 8008 |
| **MAS** | Matrix Authentication Service (OIDC via Keycloak) | 8080 |
| **Sliding Sync** | Fast room list sync for modern clients | 8009 |
| **nginx** | Reverse proxy and `.well-known` endpoint | 80 |
| **Keycloak** | Identity provider (SSO) | external |
| **PostgreSQL** (x4) | Databases for Synapse, MAS, Sliding Sync, Bridges | 5432 |
| **mautrix-whatsapp** | WhatsApp bridge | 29318 |
| **mautrix-telegram** | Telegram bridge | 29317 |
| **mautrix-discord** | Discord bridge | 29334 |
| **mautrix-slack** | Slack bridge | 29335 |

Authentication flows through Keycloak via MAS. nginx routes login/logout/refresh requests to MAS and everything else to Synapse. Bridge bots appear as regular Matrix users.

---

## Getting Started

### Choosing a Client

Matrix is an open protocol with many clients. Recommended options:

| Client | Platform | Best For |
|--------|----------|----------|
| **Element X** | iOS, Android | Mobile users (newest, fastest) |
| **Element Web** | Browser | Desktop web access |
| **Element Desktop** | Windows, macOS, Linux | Desktop power users |
| **FluffyChat** | All platforms | Simpler, friendlier UI |
| **Cinny** | Browser | Discord-like interface |
| **SchildiChat** | Android, Desktop | Element fork with chat bubbles |

When configuring your client, set the homeserver to your nginx domain (e.g., `https://matrix.your-domain.com`). The client will auto-discover Synapse and Sliding Sync via the `.well-known` endpoint.

### Logging In

1. Open your Matrix client
2. Enter the homeserver URL: `https://matrix.your-domain.com`
3. Click **Sign In** - you will be redirected to Keycloak
4. Authenticate with your Keycloak credentials
5. Approve the Matrix authorization request
6. You are now logged in

Registration is disabled by default. New accounts must be created in Keycloak by an administrator.

### Creating Rooms and Spaces

- **Room**: A single conversation (like a chat channel)
  - Click **+** or **Create Room** in your client
  - Set a name, topic, and choose encryption settings
  - Set visibility: private (invite-only) or public (discoverable)

- **Space**: A collection of rooms (like a Discord server or Slack workspace)
  - Create a Space from your client's menu
  - Add existing rooms or create new ones inside the Space

### Inviting Users

Invite users by their Matrix ID: `@username:your.matrix.server.de`

For users on other Matrix servers (federation), use their full ID: `@user:other-server.org`

### Direct Messages

Click the **Direct Message** or **DM** button in your client and enter the recipient's Matrix ID. DMs are just private rooms with two participants.

### End-to-End Encryption

- E2EE is available for all rooms and DMs
- Enable it when creating a room or in room settings
- **Back up your encryption keys** - if you lose them, you lose access to encrypted message history
- Most clients will prompt you to set up key backup and cross-signing on first login

---

## Bridges Overview

Bridges connect Matrix to other messaging platforms. Each bridge creates a **bot user** on your Matrix server. You interact with the bot to log in and manage your bridge connection.

**How it works:**
1. Start a DM with the bridge bot
2. Send a `login` command
3. Authenticate with your account on the other platform
4. Your contacts and conversations from that platform appear as Matrix rooms
5. Messages you send in those rooms are forwarded to the other platform and vice versa

**Bridge user types:**
- **Ghost users**: Virtual Matrix users representing people on the other platform (e.g., `@whatsapp_1234567:your.domain`)
- **Bridge bot**: The bot you interact with for management commands (e.g., `@whatsappbot:your.domain`)
- **Relay bot**: Optional bot that forwards messages for users who haven't logged into the bridge

---

## WhatsApp Bridge

The WhatsApp bridge uses the WhatsApp Web multidevice protocol. Your phone does NOT need to stay online after initial setup.

### Logging In to WhatsApp

1. Start a DM with `@whatsappbot:your.domain`
2. Send: `login`
3. The bot will send you a QR code image
4. Open WhatsApp on your phone > **Linked Devices** > **Link a Device**
5. Scan the QR code
6. Wait for the bridge to sync your contacts and recent chats

### WhatsApp Features

| Feature | Supported |
|---------|-----------|
| Send/receive text messages | Yes |
| Send/receive images, video, audio, files | Yes |
| Replies (quoting messages) | Yes |
| Reactions | Yes |
| Read receipts | Yes |
| Typing notifications | Yes |
| Group chats | Yes |
| Contact list sync | Yes |
| Location sharing | Yes |
| Stickers | Yes |
| Voice messages | Yes |
| Calls | No (WhatsApp Web limitation) |
| Status/Stories | No |

### WhatsApp Commands

Send these to the `@whatsappbot` DM:

| Command | Description |
|---------|-------------|
| `login` | Start login with QR code |
| `logout` | Disconnect from WhatsApp |
| `ping` | Check bridge connection status |
| `sync` | Force-sync contact list and chats |
| `set-relay` | Enable relay mode for current room |
| `unset-relay` | Disable relay mode for current room |
| `create <phone>` | Create a chat with a phone number (e.g., `create +491234567890`) |
| `open <phone>` | Open existing chat by phone number |
| `pm <phone>` | Alias for `create` |
| `disappearing-timer <time>` | Set disappearing message timer |
| `help` | Show all available commands |

---

## Telegram Bridge

The Telegram bridge connects your Telegram account to Matrix. It supports both personal chats and groups.

### Logging In to Telegram

1. Start a DM with `@telegrambot:your.domain`
2. Send: `login`
3. The bot will ask for your phone number
4. Enter your phone number (with country code, e.g., `+491234567890`)
5. Telegram will send you a verification code (via Telegram app or SMS)
6. Enter the code
7. If you have 2FA enabled, enter your password when prompted
8. Wait for the bridge to sync your chats

### Telegram Features

| Feature | Supported |
|---------|-----------|
| Send/receive text messages | Yes |
| Send/receive media (images, video, files) | Yes |
| Replies | Yes |
| Reactions | Yes |
| Read receipts | Yes |
| Typing notifications | Yes |
| Group chats | Yes |
| Supergroups | Yes |
| Channels (read-only) | Yes |
| Stickers | Yes |
| Polls | Yes |
| Location sharing | Yes |
| Contacts | Yes |
| Voice messages | Yes |
| Video messages (round) | Yes |
| Bot interactions | Yes |
| Calls | No |
| Secret chats | No (Telegram limitation - device-specific) |

### Telegram Commands

Send these to the `@telegrambot` DM:

| Command | Description |
|---------|-------------|
| `login` | Start Telegram login |
| `logout` | Disconnect from Telegram |
| `ping` | Check connection status |
| `sync` | Sync chat list |
| `search <query>` | Search for Telegram users/groups |
| `pm <username>` | Start a chat with a Telegram user |
| `group <name>` | Create a Telegram group |
| `upgrade` | Upgrade a Telegram group to supergroup |
| `set-relay` | Enable relay mode |
| `unset-relay` | Disable relay mode |
| `bridge <chat_id>` | Bridge a specific Telegram chat |
| `filter` | Manage chat filters for sync |
| `help` | Show all available commands |

**Telegram API credentials:** The bridge requires API credentials from https://my.telegram.org/apps - set `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` in your `.env` file.

---

## Discord Bridge

The Discord bridge connects your Discord account to Matrix. It bridges DMs, group DMs, and server channels.

### Logging In to Discord

1. Start a DM with `@discordbot:your.domain`
2. Send: `login`
3. The bot will provide a login URL or ask for your Discord token
4. **QR code method** (recommended): The bot sends a QR code to scan with the Discord mobile app
5. Wait for the bridge to sync your servers and DMs

> **Note:** Using a user token technically violates Discord's ToS (automated user accounts). Use at your own discretion. Discord bot accounts are not supported as they cannot access DMs.

### Discord Features

| Feature | Supported |
|---------|-----------|
| Send/receive text messages | Yes |
| Send/receive media | Yes |
| Replies | Yes |
| Reactions | Yes |
| Read receipts | Partial (marks as read in Discord) |
| Typing notifications | Yes |
| DMs and group DMs | Yes |
| Server channels | Yes |
| Threads | Yes |
| Embeds | Yes (rendered as formatted text) |
| Custom emoji | Yes |
| Stickers | Yes |
| Voice channels | No |
| Video/Screen share | No |

### Discord Commands

Send these to the `@discordbot` DM:

| Command | Description |
|---------|-------------|
| `login` | Start Discord login (QR code) |
| `login-token` | Login with a Discord user token |
| `logout` | Disconnect from Discord |
| `ping` | Check connection status |
| `guilds` | List your Discord servers |
| `guilds <server_id> [--entire]` | Bridge a Discord server |
| `set-relay` | Enable relay mode |
| `unset-relay` | Disable relay mode |
| `help` | Show all available commands |

---

## Slack Bridge

The Slack bridge connects your Slack workspaces to Matrix.

### Logging In to Slack

1. Start a DM with `@slackbot:your.domain`
2. Send: `login`
3. The bot will provide instructions - either:
   - **Token method**: Provide your Slack user token (`xoxc-...`)
   - **Cookie method**: Provide your Slack `d` cookie value
4. Follow the instructions to extract your token/cookie from your browser
5. Wait for the bridge to sync your workspace channels and DMs

> **How to get your Slack token/cookie:**
> 1. Open Slack in your web browser and log in
> 2. Open browser DevTools (F12) > Application/Storage > Cookies
> 3. Find the `d` cookie for your Slack workspace
> 4. Copy its value

### Slack Features

| Feature | Supported |
|---------|-----------|
| Send/receive text messages | Yes |
| Send/receive files | Yes |
| Replies (threads) | Yes |
| Reactions | Yes |
| Read receipts | Yes |
| Typing notifications | Yes |
| Channels | Yes |
| DMs | Yes |
| Group DMs | Yes |
| Custom emoji | Yes |
| Channel topics | Yes |
| Rich text formatting | Yes |
| Calls | No |
| Huddles | No |
| Slack Connect channels | Partial |

### Slack Commands

Send these to the `@slackbot` DM:

| Command | Description |
|---------|-------------|
| `login` | Start Slack login |
| `login-token <token>` | Login with Slack token directly |
| `login-cookie <cookie>` | Login with Slack `d` cookie |
| `logout` | Disconnect from Slack |
| `ping` | Check connection status |
| `sync` | Sync channel list |
| `set-relay` | Enable relay mode |
| `unset-relay` | Disable relay mode |
| `help` | Show all available commands |

---

## Bridge Administration

### Permission Levels

Bridges use a tiered permission system configured via `bridge.permissions` in each bridge's config:

| Level | Capabilities |
|-------|-------------|
| **relay** | Messages are relayed through the bridge bot (no personal login) |
| **user** | Can log in with their own account on the remote platform |
| **admin** | Full bridge control, can manage other users' connections |

The default configuration in this deployment:
- `*` (everyone): `relay`
- Users on your server domain: `user`
- `BRIDGE_ADMIN_USER`: `admin`

### Relay Mode

Relay mode allows users who haven't logged into a bridge to still participate in bridged conversations. Their messages are sent through the bridge bot (appearing as "Username: message" on the remote platform).

To enable relay mode in a bridged room, the bridge admin sends:
```
set-relay
```

### Double Puppeting

Double puppeting makes messages you send on the remote platform also appear as sent by your Matrix account (rather than a ghost user). This requires the bridge to have access to your Matrix account.

Most mautrix bridges support automatic double puppeting when the bridge is on the same server. It is enabled by default when using the Shared Secret method (configured via `SYNAPSE_API_ADMIN_TOKEN`).

### Troubleshooting Bridges

**Bridge bot not responding:**
```bash
# Check if the bridge container is running
docker compose logs mautrix-whatsapp --tail 50

# Check if the init container completed
docker compose logs whatsapp-init

# Restart a specific bridge
docker compose restart mautrix-whatsapp
```

**"Not logged in" errors:**
- Send `ping` to the bridge bot to check your session status
- Sessions can expire - send `login` again to reconnect

**Messages not syncing:**
- Check bridge logs: `docker compose logs mautrix-whatsapp --tail 100`
- Send `sync` to force re-sync
- Check database connectivity: `docker compose logs postgres-bridges --tail 20`

**Registration not loaded by Synapse:**
```bash
# Verify registration files exist
docker compose exec synapse ls -la /bridges/

# Check Synapse logs for appservice registration
docker compose logs synapse | grep -i appservice
```

**Reset a bridge completely:**
```bash
# Stop the bridge
docker compose stop mautrix-whatsapp

# Remove its data volume (THIS DELETES ALL BRIDGE DATA)
docker volume rm matrix_mautrix-whatsapp-data

# Restart (init container will regenerate config)
docker compose up -d mautrix-whatsapp
```

---

## Additional Bridges Available

The following bridges can be added to this deployment using the same init container pattern. They are not yet included in the repository.

### Signal

| | |
|---|---|
| **Image** | `dock.mau.dev/mautrix/signal` |
| **Port** | 29328 |
| **Status** | Actively maintained (Go) |
| **Login** | QR code (linked device) or phone number |
| **Features** | Text, media, reactions, replies, groups, voice messages, stickers, disappearing messages |
| **Limitations** | No calls; one bridge session per Signal account |
| **Notes** | Does not require a separate signald daemon (uses built-in libsignal) |

### Facebook Messenger & Instagram

| | |
|---|---|
| **Image** | `dock.mau.dev/mautrix/meta` |
| **Port** | 29319 |
| **Status** | Actively maintained (Go) |
| **Login** | Cookie-based (Facebook cookies from browser) |
| **Features** | Text, media, reactions, replies, group chats, typing indicators, read receipts |
| **Limitations** | No calls, no stories; login may break if Facebook detects automation |
| **Notes** | Single bridge handles BOTH Facebook Messenger and Instagram DMs. Replaces the deprecated `mautrix-facebook` and `mautrix-instagram` |

### Google Messages (RCS/SMS)

| | |
|---|---|
| **Image** | `dock.mau.dev/mautrix/gmessages` |
| **Port** | 29336 |
| **Status** | Actively maintained (Go) |
| **Login** | QR code (pair with Google Messages web) |
| **Features** | SMS/RCS text, media, reactions, read receipts, group chats (RCS) |
| **Limitations** | Requires an Android phone with Google Messages as default SMS app |
| **Notes** | Bridges both SMS and RCS conversations |

### Twitter/X

| | |
|---|---|
| **Image** | `dock.mau.dev/mautrix/twitter` |
| **Port** | 29327 |
| **Status** | Actively maintained (Go) |
| **Login** | Cookie-based (Twitter auth cookies from browser) |
| **Features** | DMs (text, media, reactions, read receipts) |
| **Limitations** | DMs only - no tweet bridging, no spaces, no calls |
| **Notes** | Twitter API changes may occasionally break the bridge |

### LinkedIn

| | |
|---|---|
| **Image** | `dock.mau.dev/mautrix/linkedin` |
| **Port** | 29337 |
| **Status** | Actively maintained (Go) |
| **Login** | Cookie-based |
| **Features** | Messaging (text, media, reactions) |
| **Limitations** | DMs only, no InMail or connection request bridging |

### Google Chat

| | |
|---|---|
| **Image** | `dock.mau.dev/mautrix/googlechat` |
| **Port** | 29320 |
| **Status** | Maintained (Python, Go rewrite planned) |
| **Login** | Google account OAuth or cookies |
| **Features** | Text, media, reactions, threads, spaces |
| **Limitations** | Google Workspace accounts only for some features |

### IRC

Two options available:

**heisenbridge** (recommended for personal use):

| | |
|---|---|
| **Image** | `hif1/heisenbridge` |
| **Status** | Actively maintained (Python) |
| **Login** | Commands to the bridge bot |
| **Features** | Bouncer-style IRC bridge, zero configuration, no database needed, SASL, multi-network |
| **Notes** | Personal IRC bouncer - each Matrix user manages their own IRC connections |

**matrix-appservice-irc** (for server-wide bridging):

| | |
|---|---|
| **Image** | `matrixdotorg/matrix-appservice-irc` |
| **Status** | Actively maintained (Node.js) |
| **Features** | Full server-wide IRC bridge, used by matrix.org to bridge Libera.Chat, OFTC, etc. |
| **Notes** | More complex setup, designed for bridging entire IRC networks |

### Email

**postmoogle** (recommended):

| | |
|---|---|
| **Image** | `registry.gitlab.com/etke.cc/postmoogle` |
| **Status** | Actively maintained (Go) |
| **Features** | Full SMTP server, 1 room = 1 mailbox, send/receive emails from Matrix rooms |
| **Notes** | Requires DNS MX records pointing to your server |

### GitHub/GitLab/JIRA (Hookshot)

| | |
|---|---|
| **Image** | `halfshot/matrix-hookshot` |
| **Status** | Actively maintained (Node.js, by matrix.org) |
| **Features** | GitHub/GitLab notifications (issues, PRs, commits), JIRA integration, generic webhook support, feed reader (RSS/Atom) |
| **Notes** | Not a chat bridge - it forwards events/notifications into Matrix rooms |

### Summary Table

| Bridge | Platform | Image | Status | In Repo |
|--------|----------|-------|--------|---------|
| mautrix-whatsapp | WhatsApp | `dock.mau.dev/mautrix/whatsapp` | Active | Yes |
| mautrix-telegram | Telegram | `dock.mau.dev/mautrix/telegram` | Active | Yes |
| mautrix-discord | Discord | `dock.mau.dev/mautrix/discord` | Active | Yes |
| mautrix-slack | Slack | `dock.mau.dev/mautrix/slack` | Active | Yes |
| mautrix-signal | Signal | `dock.mau.dev/mautrix/signal` | Active | No |
| mautrix-meta | FB Messenger + Instagram | `dock.mau.dev/mautrix/meta` | Active | No |
| mautrix-gmessages | Google Messages | `dock.mau.dev/mautrix/gmessages` | Active | No |
| mautrix-twitter | Twitter/X | `dock.mau.dev/mautrix/twitter` | Active | No |
| mautrix-linkedin | LinkedIn | `dock.mau.dev/mautrix/linkedin` | Active | No |
| mautrix-googlechat | Google Chat | `dock.mau.dev/mautrix/googlechat` | Active | No |
| heisenbridge | IRC | `hif1/heisenbridge` | Active | No |
| postmoogle | Email | `registry.gitlab.com/etke.cc/postmoogle` | Active | No |
| matrix-hookshot | GitHub/GitLab/JIRA | `halfshot/matrix-hookshot` | Active | No |

---

## Environment Variables Reference

### Core Server

| Variable | Description | Example |
|----------|-------------|---------|
| `SYNAPSE_SERVER_NAME` | Matrix server name (used in user IDs) | `your.matrix.server.de` |
| `SYNAPSE_FRIENDLY_SERVER_NAME` | Display name for emails and UI | `"Your Matrix Server"` |
| `SYNAPSE_FQDN` | Full URL to Synapse | `https://synapse.your.matrix.server.de` |
| `SYNAPSE_SYNC_FQDN` | Full URL to Sliding Sync | `https://sync.synapse.your.matrix.server.de` |
| `SYNAPSE_MAS_FQDN` | Full URL to MAS | `https://mas.synapse.your.matrix.server.de` |
| `ADMIN_EMAIL` | Admin contact email | `admin@your.matrix.server.de` |

### Databases

| Variable | Description | Example |
|----------|-------------|---------|
| `POSTGRES_SYNAPSE_DB` | Synapse database name | `synapse` |
| `POSTGRES_SYNAPSE_USER` | Synapse database user | `synapse_user` |
| `POSTGRES_SYNAPSE_PASSWORD` | Synapse database password | (generate a strong password) |
| `POSTGRES_SYNAPSE_MAS_DB` | MAS database name | `synapse_mas` |
| `POSTGRES_SYNAPSE_MAS_USER` | MAS database user | `synapse_mas_user` |
| `POSTGRES_SYNAPSE_MAS_PASSWORD` | MAS database password | (generate a strong password) |
| `POSTGRES_SLIDING_SYNC_DB` | Sliding Sync database name | `sync-v3` |
| `POSTGRES_SLIDING_SYNC_USER` | Sliding Sync database user | `sliding_sync_user` |
| `POSTGRES_SLIDING_SYNC_PASSWORD` | Sliding Sync database password | (generate a strong password) |
| `POSTGRES_BRIDGES_USER` | Bridges shared database user | `bridges_user` |
| `POSTGRES_BRIDGES_PASSWORD` | Bridges shared database password | (generate a strong password) |

### Authentication

| Variable | Description | Example |
|----------|-------------|---------|
| `KEYCLOAK_FQDN` | Full URL to Keycloak | `https://keycloak.your.matrix.server.de` |
| `KEYCLOAK_REALM_IDENTIFIER` | Keycloak realm name | `YourRealm` |
| `KEYCLOAK_CLIENT_ID` | OIDC client ID in Keycloak | `synapse` |
| `KEYCLOAK_CLIENT_SECRET` | OIDC client secret | (from Keycloak) |
| `KEYCLOAK_UPSTREAM_OAUTH_PROVIDER_ID` | MAS provider ID (leave default) | `01H8PKNWKKRPCBW4YGH1RWV279` |
| `AUTHENTICATION_ISSUER` | Displayed as auth requester | `https://server.de` |
| `SYNAPSE_MAS_SECRET` | Shared secret between Synapse and MAS | (generate a strong secret) |
| `SYNAPSE_API_ADMIN_TOKEN` | Synapse admin API token | (generate a strong token) |
| `SLIDING_SYNC_SECRET` | Sliding Sync shared secret | (generate a random string) |

### Email (SMTP)

| Variable | Description | Example |
|----------|-------------|---------|
| `SMTP_HOST` | SMTP server hostname | `mail.your.matrix.server.de` |
| `SMTP_PORT` | SMTP server port | `587` |
| `SMTP_USER` | SMTP username | `no-reply@your.matrix.server.de` |
| `SMTP_PASSWORD` | SMTP password | (your SMTP password) |
| `SMTP_REQUIRE_TRANSPORT_SECURITY` | Require TLS | `true` |
| `SMTP_NOTIFY_FROM` | Sender address for notifications | `no-reply@your.matrix.server.de` |

### Bridges

| Variable | Description | Example |
|----------|-------------|---------|
| `BRIDGE_ADMIN_USER` | Matrix user ID with bridge admin rights | `@admin:your.matrix.server.de` |
| `TELEGRAM_API_ID` | Telegram API ID from my.telegram.org | `12345678` |
| `TELEGRAM_API_HASH` | Telegram API hash from my.telegram.org | (from Telegram) |

---

## Server Administration

### Viewing Logs

```bash
# All services
docker compose logs -f --tail 50

# Specific service
docker compose logs -f mautrix-whatsapp --tail 100
docker compose logs -f synapse --tail 100

# Init container logs (for debugging first-run config generation)
docker compose logs whatsapp-init
docker compose logs telegram-init
```

### Restarting Services

```bash
# Restart a single bridge
docker compose restart mautrix-whatsapp

# Restart Synapse (will briefly disconnect all users)
docker compose restart synapse

# Restart everything
docker compose restart
```

### Updating Images

```bash
# Pull latest images
docker compose pull

# Recreate containers with new images
docker compose up -d
```

### Database Access

```bash
# Synapse database
docker compose exec postgres-synapse psql -U synapse_user -d synapse

# Bridge databases
docker compose exec postgres-bridges psql -U bridges_user -d mautrix_whatsapp
docker compose exec postgres-bridges psql -U bridges_user -d mautrix_telegram
docker compose exec postgres-bridges psql -U bridges_user -d mautrix_discord
docker compose exec postgres-bridges psql -U bridges_user -d mautrix_slack

# List all bridge databases
docker compose exec postgres-bridges psql -U bridges_user -c '\l'
```

### Synapse Admin API

The Synapse admin API is available for user management, room management, and server administration. Use `SYNAPSE_API_ADMIN_TOKEN` for authentication.

```bash
# List users
curl -s -H "Authorization: Bearer YOUR_ADMIN_TOKEN" \
  https://synapse.your.domain/_synapse/admin/v2/users

# Get server version
curl -s https://synapse.your.domain/_matrix/federation/v1/version
```

For full admin API documentation, see: https://element-hq.github.io/synapse/latest/usage/administration/admin_api/

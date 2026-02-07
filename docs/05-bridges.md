# Part 5: Bridges -- Connecting Matrix to the Outside World

> **Series**: Self-Hosted Matrix Deep Dive
> **Previous**: [04 -- Deployment Architecture](04-deployment-architecture.md)
> **Next**: [06 -- Operations](06-operations.md)

---

## Table of Contents

1. [The Application Service API](#1-the-application-service-api)
   - [What Is an Application Service?](#what-is-an-application-service)
   - [How Appservices Differ from Regular Clients](#how-appservices-differ-from-regular-clients)
   - [The Registration File](#the-registration-file)
   - [How Synapse Loads Appservices](#how-synapse-loads-appservices)
   - [The HTTP Callback Interface](#the-http-callback-interface)
   - [Namespaces and Regex Matching](#namespaces-and-regex-matching)
2. [Bridge Concepts](#2-bridge-concepts)
   - [What Bridging Means](#what-bridging-means)
   - [Ghost Users](#ghost-users)
   - [Portal Rooms](#portal-rooms)
   - [Types of Bridging](#types-of-bridging)
   - [Message Flow](#message-flow)
   - [Eventual Consistency Challenges](#eventual-consistency-challenges)
3. [The mautrix Ecosystem](#3-the-mautrix-ecosystem)
   - [Origin and Philosophy](#origin-and-philosophy)
   - [Go-Based vs Python-Based Bridges](#go-based-vs-python-based-bridges)
   - [Shared Architecture Patterns](#shared-architecture-patterns)
   - [The Megabridge Rewrite](#the-megabridge-rewrite)
   - [Config.yaml Structure Differences](#configyaml-structure-differences)
4. [Permission Levels](#4-permission-levels)
   - [Go Bridges: relay, user, admin](#go-bridges-relay-user-admin)
   - [Telegram (Python): relaybot, user, puppeting/full, admin](#telegram-python-relaybot-user-puppetingfull-admin)
   - [Permission Matching via Glob Patterns](#permission-matching-via-glob-patterns)
   - [The Telegram "user" Trap](#the-telegram-user-trap)
5. [WhatsApp Bridge (mautrix-whatsapp)](#5-whatsapp-bridge-mautrix-whatsapp)
6. [Telegram Bridge (mautrix-telegram)](#6-telegram-bridge-mautrix-telegram)
7. [Discord Bridge (mautrix-discord)](#7-discord-bridge-mautrix-discord)
8. [Slack Bridge (mautrix-slack)](#8-slack-bridge-mautrix-slack)
9. [Registration File Details](#9-registration-file-details)
10. [Bot Commands](#10-bot-commands)
11. [Troubleshooting](#11-troubleshooting)
12. [Additional Available Bridges](#12-additional-available-bridges)

---

## 1. The Application Service API

### What Is an Application Service?

The Matrix specification defines two ways for software to interact with a homeserver: the **Client-Server API** (used by Element, FluffyChat, and every normal Matrix client) and the **Application Service API** (used by bridges, bots, and integration services). The Application Service API, often shortened to "AS API" or "appservice API," is a privileged server-side interface that grants capabilities far beyond what any ordinary client can do.

An application service (appservice) is a process that registers itself with a homeserver and receives a firehose of events. It can create and control arbitrary users on the homeserver without needing passwords or tokens for each one. It can claim entire namespaces of user IDs, room aliases, and room IDs. It can impersonate any user within its claimed namespaces. Where a regular client logs in as one user and sees one user's view of the world, an appservice operates at the server level and can puppet hundreds or thousands of virtual users simultaneously.

The spec lives at `https://spec.matrix.org/latest/application-service-api/`. It was one of the earliest extensions to the Matrix protocol, designed specifically to solve the bridging problem: how do you make conversations on Slack, IRC, XMPP, or any other platform appear natively in Matrix?

### How Appservices Differ from Regular Clients

| Aspect | Regular Client | Application Service |
|--------|---------------|-------------------|
| Authentication | User logs in, gets an access token | Pre-shared tokens in a registration file |
| User identity | One user per session | Can act as any user in its namespace |
| User creation | Cannot create users (only register itself) | Can create "virtual" (ghost) users on demand |
| Event access | Only sees events in rooms it has joined | Receives ALL events for its registered namespaces |
| Room creation | Creates rooms as itself | Can create rooms on behalf of any virtual user |
| Connection model | Client polls or syncs from homeserver | Homeserver pushes events to appservice via HTTP |
| Registration | Standard `/register` endpoint | Out-of-band YAML registration file |

The key mental model: a regular client is a guest in the homeserver's house. An appservice is more like a wing of the house itself -- deeply integrated, trusted, and operating with elevated privileges.

### The Registration File

Every appservice must provide a YAML registration file. This file is the contract between the appservice and the homeserver. Here is the complete anatomy:

```yaml
# Unique identifier for this appservice. Synapse uses this internally
# to track which appservice is which. Must be unique across all
# registered appservices on the homeserver.
id: whatsapp

# The URL where the homeserver should send events via HTTP PUT.
# This is the appservice's callback endpoint. The homeserver will
# POST transactions to {url}/_matrix/app/v1/transactions/{txnId}
url: http://mautrix-whatsapp:29318

# The token the APPSERVICE uses when calling the homeserver's
# Client-Server API. Think of it as the appservice's password.
# The appservice includes this as a Bearer token in its requests
# to the homeserver.
as_token: random-secret-string-1

# The token the HOMESERVER uses when pushing events to the
# appservice. The homeserver includes this in its requests so
# the appservice can verify the caller is legitimate.
hs_token: random-secret-string-2

# The localpart of the "main bot" user for this appservice.
# Synapse will auto-create @whatsappbot:yourdomain.com and
# the appservice will use this user for management commands.
sender_localpart: whatsappbot

# Rate limiting is typically disabled for appservices because
# they need to send messages at high volume (imagine syncing
# 500 WhatsApp messages at once).
rate_limited: false

# Namespaces define which users, aliases, and rooms this
# appservice "owns." The homeserver will:
# 1. Route events involving these namespaces to this appservice
# 2. Allow this appservice to create/control users matching these patterns
# 3. Prevent OTHER appservices and clients from registering
#    users/aliases in these namespaces (exclusive: true)
namespaces:
  users:
    - regex: '@whatsapp_.*:yourdomain\.com'
      exclusive: true
    - regex: '@whatsappbot:yourdomain\.com'
      exclusive: true
  aliases:
    - regex: '#whatsapp_.*:yourdomain\.com'
      exclusive: true
  rooms: []
```

The two tokens (`as_token` and `hs_token`) form a bidirectional trust relationship:

```
Appservice ---[as_token in Authorization header]---> Homeserver
Homeserver ---[hs_token in Authorization header]---> Appservice
```

Both tokens are typically generated as random hex strings or UUIDs. In our deployment, they are regenerated on every init container run (more on this in Section 9).

### How Synapse Loads Appservices

Synapse reads appservice registrations at startup via the `app_service_config_files` configuration key. In our deployment's `homeserver.yaml`:

```yaml
app_service_config_files:
  - /bridges/whatsapp-registration.yaml
  - /bridges/telegram-registration.yaml
  - /bridges/discord-registration.yaml
  - /bridges/slack-registration.yaml
```

When Synapse starts, it:

1. Reads each YAML file listed in `app_service_config_files`
2. Validates the schema (id, url, as_token, hs_token, sender_localpart, namespaces)
3. Compiles the namespace regex patterns
4. Registers the appservice in its internal data structures
5. Creates the `sender_localpart` user if it does not already exist
6. Begins routing matching events to the appservice's URL

**Critical implication**: If the registration file changes (new tokens, new namespaces), Synapse must be restarted to pick up the changes. It does NOT hot-reload registration files. This is why our deployment uses init containers that run before Synapse starts -- the registration files must be in place and final before Synapse reads them.

The files are shared through a Docker volume called `bridge-registrations`. Init containers write to it, and Synapse mounts it read-only:

```yaml
# In docker-compose.yaml
synapse:
  volumes:
    - bridge-registrations:/bridges:ro    # read-only mount

whatsapp-init:
  volumes:
    - bridge-registrations:/registrations  # read-write mount
```

### The HTTP Callback Interface

Once registered, the homeserver pushes events to the appservice over HTTP. The appservice must expose an HTTP server implementing these endpoints:

**`PUT /_matrix/app/v1/transactions/{txnId}`** -- The primary endpoint. The homeserver batches events into transactions and pushes them. Each transaction has a unique `txnId` to allow idempotent retries. The body looks like:

```json
{
  "events": [
    {
      "type": "m.room.message",
      "room_id": "!abc:yourdomain.com",
      "sender": "@alice:yourdomain.com",
      "content": {
        "msgtype": "m.text",
        "body": "Hello from Matrix!"
      },
      "event_id": "$event123",
      "origin_server_ts": 1706000000000
    }
  ]
}
```

The appservice must respond with HTTP 200 to acknowledge receipt. If it returns an error, the homeserver will retry the transaction.

**`GET /_matrix/app/v1/users/{userId}`** -- Called when someone tries to interact with a user in the appservice's namespace that does not yet exist. The appservice can create the user on the fly (lazy creation of ghost users).

**`GET /_matrix/app/v1/rooms/{roomAlias}`** -- Called when someone tries to access a room alias in the appservice's namespace. The appservice can create the room on demand.

In practice, bridges listen on a specific port (29318 for WhatsApp, 29317 for Telegram, etc.) and the homeserver connects to them over the Docker network.

### Namespaces and Regex Matching

Namespaces are how an appservice tells the homeserver "these users are mine, these aliases are mine." They use regular expressions to define ownership.

There are three namespace categories:

**Users**: Ghost users created by the bridge. For WhatsApp, the pattern `@whatsapp_.*:yourdomain\.com` claims all user IDs starting with `@whatsapp_`. When someone on WhatsApp sends you a message, the bridge creates `@whatsapp_15551234567:yourdomain.com` (a ghost) and sends the message from that user.

**Aliases**: Room aliases created by the bridge. For WhatsApp, `#whatsapp_.*:yourdomain\.com` claims aliases like `#whatsapp_groupname:yourdomain.com`.

**Rooms**: Raw room ID patterns. Rarely used because room IDs are opaque strings (`!randomchars:domain`), making regex matching impractical.

The `exclusive` flag controls whether the namespace is "reserved":
- `exclusive: true` -- Only this appservice can create/control users/aliases matching the pattern. Other clients and appservices are blocked.
- `exclusive: false` -- The appservice receives events for matching entities but does not block others from creating them.

The regex patterns use standard regular expressions and are matched against the full identifier (including the `@` prefix and `:domain` suffix for users). Each bridge uses a distinct prefix (`whatsapp_`, `telegram_`, `discord_`, `slack_`) to avoid namespace collisions.

---

## 2. Bridge Concepts

### What Bridging Means

Bridging is the act of connecting two separate communication networks so that a message sent on one network appears on the other, and vice versa. In the Matrix context, bridging means making WhatsApp chats, Telegram groups, Discord servers, and Slack workspaces appear as native Matrix rooms.

The ideal bridge is invisible. A user on the Matrix side should feel like they are chatting with a normal Matrix user. A user on the WhatsApp side should see responses appearing as if the person is using WhatsApp. The bridge sits in the middle, translating protocols, formats, and conventions.

This is fundamentally different from a bot that "relays" messages. A true bridge creates individual virtual users for each person on the remote platform, preserves threading and reactions, handles media conversion, and maintains presence information. The goal is protocol-level interoperability, not just text forwarding.

### Ghost Users

Ghost users (also called "puppet users" or "virtual users") are Matrix accounts created and controlled by the bridge to represent people on the remote platform. They are the heart of the bridging mechanism.

When your WhatsApp contact "Alice" sends you a message, the bridge:

1. Creates a Matrix user `@whatsapp_15551234567:yourdomain.com` if it does not already exist
2. Sets the display name to "Alice" (pulled from WhatsApp)
3. Sets the avatar to Alice's WhatsApp profile picture
4. Sends the message into the appropriate Matrix room as that ghost user

From the Matrix side, it looks like a real person sent the message. The ghost user has a profile, an avatar, and sends messages like any other user. But behind the scenes, it is entirely controlled by the bridge appservice.

Ghost users are created lazily -- they appear only when needed (when someone on the remote platform sends a message or is part of a group being bridged). A busy WhatsApp bridge might create hundreds of ghost users over time.

The naming convention varies by bridge:
- WhatsApp: `@whatsapp_<phone_number>:domain`
- Telegram: `@telegram_<user_id>:domain`
- Discord: `@discord_<user_id>:domain`
- Slack: `@slack_<team_id>_<user_id>:domain`

### Portal Rooms

Portal rooms are Matrix rooms that correspond 1:1 to a conversation on the remote platform. Each WhatsApp chat, Telegram group, Discord channel, or Slack channel gets its own Matrix room.

When the bridge creates a portal room, it:

1. Creates the Matrix room
2. Sets the room name and avatar to match the remote conversation
3. Invites the appropriate ghost users (representing remote participants)
4. Invites you (the Matrix user who logged into the bridge)
5. Begins relaying messages bidirectionally

Portal rooms are the bridge's mapping layer. The bridge maintains a database table that maps `(remote_chat_id) <-> (matrix_room_id)`. When a message arrives from WhatsApp chat `12345`, the bridge looks up which Matrix room corresponds to that chat and delivers the message there.

You can recognize portal rooms by their naming patterns and the presence of ghost users. They typically have room aliases like `#whatsapp_12345:domain` (though direct-message portals may not have aliases).

### Types of Bridging

There are several bridging modes, each offering different trade-offs between fidelity, privacy, and complexity:

**Puppeting (also called "login bridging")**

This is the primary and most powerful mode. You log into the remote platform through the bridge using your actual credentials. The bridge then acts as you on that platform -- seeing your conversations, contacts, and sending messages on your behalf.

How it works:
- You provide your WhatsApp/Telegram/Discord/Slack credentials to the bridge
- The bridge maintains a persistent session to the remote platform
- Incoming messages from the remote platform are delivered to Matrix rooms
- Messages you send in Matrix rooms are forwarded to the remote platform as you
- Your contacts on the remote platform appear as ghost users in Matrix

Pros: Full access to your conversations, messages appear as coming from you, highest fidelity.
Cons: You must trust the bridge with your credentials. The bridge has full access to your remote account.

**Double Puppeting**

Double puppeting is an enhancement to regular puppeting that solves a specific annoyance: when you send a message on the remote platform directly (for example, by opening WhatsApp on your phone), that message appears in the Matrix room as coming from a ghost user representing you, rather than from your actual Matrix account.

With double puppeting enabled, the bridge also has access to your Matrix account. When it detects that you sent a message on the remote platform, it sends the corresponding Matrix message using your real Matrix identity instead of a ghost. This makes the conversation look natural on the Matrix side -- all your messages appear under your real name regardless of where you typed them.

Double puppeting requires the bridge to authenticate as your Matrix user. In our deployment, this can be automated using the Synapse admin API token (`SYNAPSE_API_ADMIN_TOKEN`), which allows the bridge to generate access tokens for local users without their passwords. This is sometimes called "double puppeting with shared secret."

**Relaying**

Relay mode is for users who have NOT logged into the bridge. Their messages are sent through the bridge bot user rather than through a personal account on the remote platform.

Example: Bob has not logged into the WhatsApp bridge, but he is in a Matrix room that is bridged to a WhatsApp group. When Bob sends a message in that Matrix room, the bridge bot sends it to WhatsApp as:

```
Bob: Hey everyone, meeting at 3pm
```

The message shows the sender's name as a prefix but comes from the bridge bot's account on the remote platform. It is functional but lower fidelity -- people on the WhatsApp side see all relayed messages coming from one account.

Relay mode must be explicitly enabled per room by a bridge admin using the `set-relay` command.

### Message Flow

Understanding the complete path a message takes helps debug issues and set expectations:

**Matrix to Remote Platform (outgoing):**

```
1. User types message in Element (Matrix client)
2. Client sends message to Synapse via Client-Server API
3. Synapse persists the event and resolves room membership
4. Synapse sees the room contains ghost users from a bridge namespace
5. Synapse pushes the event to the bridge via the AS API transaction endpoint
6. Bridge receives the event, looks up the portal room mapping
7. Bridge translates the message format (Matrix -> remote protocol)
8. Bridge sends the message to the remote platform using stored credentials
9. Remote platform delivers the message to recipients
```

**Remote Platform to Matrix (incoming):**

```
1. Someone sends a message on WhatsApp/Telegram/Discord/Slack
2. The bridge's persistent connection to the remote platform receives it
3. Bridge looks up or creates the portal room for this conversation
4. Bridge looks up or creates the ghost user for the sender
5. Bridge translates the message format (remote protocol -> Matrix)
6. Bridge calls the Synapse Client-Server API, authenticated with as_token,
   using the ?user_id= parameter to impersonate the ghost user
7. Synapse persists the event in the room
8. Synapse pushes the event to all room members via sync
9. Your Matrix client displays the message from the ghost user
```

### Eventual Consistency Challenges

Bridging introduces inherent consistency challenges because you are synchronizing state across two independent systems that have different models:

**Message ordering**: Matrix uses a DAG (directed acyclic graph) for event ordering. WhatsApp, Telegram, Discord, and Slack all use different ordering models. Messages that arrive "simultaneously" on the remote platform may end up in a different order on Matrix.

**Edit/delete propagation**: If someone edits a message on WhatsApp, the bridge must detect the edit event and send a corresponding Matrix edit. There is always a propagation delay, and some operations may not have equivalent semantics (for example, Telegram allows editing messages indefinitely; Matrix edits are supported but some clients display them differently).

**Presence and typing indicators**: These are ephemeral and best-effort. The bridge can forward typing notifications, but network latency means they may appear late or not at all.

**Media transcoding**: Each platform has different supported media formats, size limits, and thumbnail requirements. The bridge must handle conversion, and some loss is inevitable (video quality may decrease, GIF animations may be converted to static images on some platforms).

**Membership sync**: Group membership changes on the remote platform must be reflected on Matrix (inviting/kicking ghost users) and vice versa. During initial sync, a large group may take significant time to fully populate.

**Eventual consistency of the bridge database**: The bridge maintains its own database mapping remote entities to Matrix entities. If this database is lost or corrupted, the bridge loses its mappings and may create duplicate rooms or ghost users. This is why database backups are critical (see [06 -- Operations](06-operations.md)).

---

## 3. The mautrix Ecosystem

### Origin and Philosophy

The mautrix bridge ecosystem is primarily the work of Tulir Asokan (GitHub: tulir, often referred to as "tulir" in the Matrix community). What started as individual bridge projects has grown into the most comprehensive and actively maintained collection of Matrix bridges available.

The mautrix bridges share several design principles:

- **One bridge, one protocol**: Each bridge handles exactly one remote platform
- **Puppeting first**: The primary mode is always login-based puppeting, with relay as a secondary option
- **Appservice-based**: All bridges use the Application Service API rather than acting as regular clients
- **Database-backed**: All state is persisted in a database (PostgreSQL or SQLite)
- **Config-file driven**: Configuration via a single `config.yaml` file
- **Container-friendly**: Official Docker images published to `dock.mau.dev`
- **Self-contained**: Each bridge image includes all its dependencies (no external daemons required for most bridges)

The project lives at `https://github.com/mautrix/` and `https://mau.dev/mautrix/`.

### Go-Based vs Python-Based Bridges

The mautrix ecosystem contains bridges written in two languages, and this distinction has real consequences for deployment and configuration:

**Go-based bridges** (current generation):
- WhatsApp (`mautrix-whatsapp`)
- Discord (`mautrix-discord`)
- Slack (`mautrix-slack`)
- Signal (`mautrix-signal`)
- Meta/Instagram (`mautrix-meta`)
- Google Messages (`mautrix-gmessages`)
- Twitter (`mautrix-twitter`)
- LinkedIn (`mautrix-linkedin`)

Characteristics:
- Compiled to a single static binary
- Lower memory footprint
- Config generation via `-e` flag: `/usr/bin/mautrix-whatsapp -c /data/config.yaml -e`
- Registration generation via `-g` flag: `/usr/bin/mautrix-whatsapp -g -c /data/config.yaml -r /data/registration.yaml`
- Built on the `mautrix-go` library (`github.com/mautrix/go`)
- Use the newer "megabridge" config format (more on this below)

**Python-based bridges** (legacy generation):
- Telegram (`mautrix-telegram`)
- Google Chat (`mautrix-googlechat`)

Characteristics:
- Require a Python runtime
- Higher memory footprint
- Config generation via `cp /opt/mautrix-telegram/example-config.yaml /data/config.yaml`
- Registration generation via `python3 -m mautrix_telegram -g -c /data/config.yaml -r /data/registration.yaml`
- Built on the `mautrix-python` library
- Use the older config format with different database configuration nesting
- Telegram in particular has a large feature set that has kept it on Python

The Go rewrite trend is clear: newer bridges are always written in Go, and some older Python bridges (like `mautrix-facebook` and `mautrix-instagram`) have been rewritten as Go bridges (`mautrix-meta`). Telegram remains on Python due to its complexity, though a Go rewrite is discussed periodically.

### Shared Architecture Patterns

Despite language differences, all mautrix bridges follow the same structural pattern:

```
                    +------------------+
                    |  Remote Platform |
                    | (WhatsApp, etc.) |
                    +--------+---------+
                             |
                    protocol-specific connection
                    (WebSocket, HTTP long-poll, etc.)
                             |
                    +--------+---------+
                    |   Bridge Process |
                    |                  |
                    | +-- Connector    | <-- protocol-specific code
                    | +-- Portal Mgr   | <-- room mapping logic
                    | +-- Puppet Mgr   | <-- ghost user management
                    | +-- AS Server    | <-- HTTP server for AS API
                    | +-- DB Layer     | <-- PostgreSQL/SQLite
                    | +-- Config       | <-- config.yaml parser
                    +--------+---------+
                             |
                    Matrix Client-Server API
                    (authenticated with as_token)
                             |
                    +--------+---------+
                    |     Synapse      |
                    +------------------+
```

Each bridge has:
- A **connector** module that understands the remote platform's protocol
- A **portal manager** that maintains the mapping between remote chats and Matrix rooms
- A **puppet manager** that creates and updates ghost users
- An **AS server** that receives events from Synapse
- A **database layer** for persistence
- A **command handler** that processes `!commands` sent to the bridge bot

### The Megabridge Rewrite

In 2023-2024, Tulir undertook a significant refactoring called the "megabridge" rewrite. The goal was to extract the common bridge logic (portal management, puppet management, command handling, double-puppeting, config structure) into a shared library, reducing code duplication across bridges.

Key changes in the megabridge format:

1. **Unified config structure**: Go bridges now share a more consistent config layout
2. **Shared command system**: Bridge bot commands are standardized
3. **Improved double-puppeting**: Automatic double-puppeting works more reliably
4. **Better error handling**: Standardized error reporting and logging
5. **Unified database schema**: Common tables for portals, puppets, users

The megabridge rewrite is why newer Go bridges have a different config structure than the Python bridges and even differs from the earliest Go bridges. If you compare the config files of mautrix-whatsapp (megabridge format) and mautrix-telegram (legacy Python format), the differences are immediately visible.

### Config.yaml Structure Differences

This is one of the most practically important details, because getting the config structure wrong means the bridge will not start. The database configuration path differs between bridges:

**WhatsApp and Slack (Go, megabridge format) -- Top-level database config:**

```yaml
# config.yaml
homeserver:
  address: http://synapse:8008
  domain: yourdomain.com

appservice:
  address: http://mautrix-whatsapp:29318
  hostname: 0.0.0.0
  port: 29318

database:                    # <-- TOP LEVEL
  type: postgres             # <-- .database.type
  uri: postgres://user:pass@host:5432/db?sslmode=disable  # <-- .database.uri

bridge:
  permissions:
    "*": relay
    "yourdomain.com": user
    "@admin:yourdomain.com": admin
```

**Discord (Go, transitional format) -- Nested under appservice:**

```yaml
# config.yaml
homeserver:
  address: http://synapse:8008
  domain: yourdomain.com

appservice:
  address: http://mautrix-discord:29334
  hostname: 0.0.0.0
  port: 29334
  database:                  # <-- UNDER appservice
    type: postgres           # <-- .appservice.database.type
    uri: postgres://user:pass@host:5432/db?sslmode=disable  # <-- .appservice.database.uri

bridge:
  permissions:
    "*": relay
    "yourdomain.com": user
    "@admin:yourdomain.com": admin
```

**Telegram (Python, legacy format) -- Direct string under appservice:**

```yaml
# config.yaml
homeserver:
  address: http://synapse:8008
  domain: yourdomain.com

appservice:
  address: http://mautrix-telegram:29317
  hostname: 0.0.0.0
  port: 29317
  database: postgres://user:pass@host:5432/db?sslmode=disable  # <-- DIRECT STRING
  # No .type field, no .uri field. Just a bare connection string.

telegram:
  api_id: 12345678           # <-- Must be an integer
  api_hash: 0123456789abcdef

bridge:
  permissions:
    "*": relaybot
    "yourdomain.com": full
    "@admin:yourdomain.com": admin
```

These differences are not cosmetic. They determine the exact `yq` commands needed in the init containers. Getting the path wrong means the bridge reads the default (SQLite) database config instead of PostgreSQL, and it silently creates a local SQLite file that works but is not what you want in production.

---

## 4. Permission Levels

### Go Bridges: relay, user, admin

The Go-based bridges (WhatsApp, Discord, Slack, Signal, Meta, and others) use a three-tier permission system:

| Level | What It Allows |
|-------|---------------|
| `relay` | The user's messages are relayed through the bridge bot. The user cannot log in to the remote platform through the bridge. Messages appear on the remote side as "Username: message text" sent by the bridge bot account. |
| `user` | The user can log in to the remote platform with their own credentials. Full puppeting is available -- messages are sent as the user's own account on the remote platform. The user can also use relay rooms. |
| `admin` | Everything `user` can do, plus administrative commands: managing other users' bridge sessions, setting relay mode in rooms, viewing bridge status, and performing maintenance operations. |

### Telegram (Python): relaybot, user, puppeting/full, admin

The Python-based Telegram bridge uses a different, more granular permission system:

| Level | What It Allows |
|-------|---------------|
| `relaybot` | Equivalent to `relay` in Go bridges. Messages are forwarded through the relay bot. The user cannot log in. |
| `user` | The user can interact with the bridge bot and use basic commands, BUT **cannot log in to Telegram**. This is the critical gotcha. |
| `puppeting` / `full` | The user can log in to Telegram with their phone number and use full puppeting. `puppeting` and `full` are synonyms. This is the level needed for actual bridge usage. |
| `admin` | Everything `full` can do, plus administrative commands. |

### The Telegram "user" Trap

This is one of the most common sources of confusion when deploying mautrix-telegram. If you set your domain's permission to `user` (copying the pattern from Go bridges), your users will be able to talk to the bridge bot but will receive a permission error when they try to `login`.

**Wrong** (will not allow login):
```yaml
bridge:
  permissions:
    "*": relaybot
    "yourdomain.com": user        # Users CANNOT log in!
    "@admin:yourdomain.com": admin
```

**Correct** (allows login):
```yaml
bridge:
  permissions:
    "*": relaybot
    "yourdomain.com": full        # Users CAN log in
    "@admin:yourdomain.com": admin
```

In our deployment's `docker-compose.yaml`, the Telegram init container correctly uses `full`:

```bash
yq -i '.bridge.permissions = {
  "*": "relaybot",
  env(SYNAPSE_SERVER_NAME): "full",
  env(BRIDGE_ADMIN_USER): "admin"
}' /data/config.yaml
```

While the Go bridges use `user`:

```bash
yq -i '.bridge.permissions = {
  "*": "relay",
  env(SYNAPSE_SERVER_NAME): "user",
  env(BRIDGE_ADMIN_USER): "admin"
}' /data/config.yaml
```

### Permission Matching via Glob Patterns

Permission keys are matched against user IDs using a simple priority system. The bridge checks keys from most specific to least specific:

1. **Exact user match**: `@alice:yourdomain.com` -- matches only this specific user
2. **Domain match**: `yourdomain.com` -- matches all users on this domain
3. **Wildcard**: `*` -- matches everyone (including federated users from other servers)

Example:

```yaml
bridge:
  permissions:
    "*": relay                           # Default for everyone
    "yourdomain.com": user               # All users on your server
    "otherdomain.org": user              # All users from a federated server
    "@alice:yourdomain.com": admin       # One specific user is admin
```

When user `@bob:yourdomain.com` interacts with the bridge, it checks:
1. Is there an exact match for `@bob:yourdomain.com`? No.
2. Is there a match for `yourdomain.com`? Yes -> `user` permission.

When user `@eve:random.org` interacts:
1. Exact match? No.
2. Domain match for `random.org`? No.
3. Wildcard `*`? Yes -> `relay` permission.

The `*` wildcard is a catch-all and should typically be set to `relay` (or `relaybot` for Telegram) so that unknown users have minimal access.

---

## 5. WhatsApp Bridge (mautrix-whatsapp)

### Overview

| Property | Value |
|----------|-------|
| **Language** | Go |
| **Image** | `dock.mau.dev/mautrix/whatsapp:latest` |
| **Default Port** | 29318 |
| **Protocol** | WhatsApp Web multidevice (whatsmeow library) |
| **Login Method** | QR code scanning |
| **Config Format** | Megabridge (`.database.type` / `.database.uri` at top level) |
| **Bot User** | `@whatsappbot:yourdomain.com` |

### How It Works

mautrix-whatsapp uses the WhatsApp Web multidevice protocol, implemented via the `whatsmeow` library (also written by Tulir). This is the same protocol that WhatsApp Web uses in your browser.

Key points about the WhatsApp Web multidevice protocol:

- **No phone dependency**: After the initial QR code scan, the bridge maintains its own session with WhatsApp's servers. Your phone does NOT need to stay online (unlike the old WhatsApp Web protocol).
- **Linked device model**: The bridge registers as a "linked device" on your WhatsApp account, just like WhatsApp Web or WhatsApp Desktop. You can see it in WhatsApp's "Linked Devices" settings.
- **End-to-end encryption**: WhatsApp uses the Signal protocol for E2E encryption. The bridge must participate in the encryption, meaning it has access to your decrypted messages (this is inherent to any WhatsApp bridge).
- **Device limit**: WhatsApp allows a limited number of linked devices (currently 4, plus your phone). The bridge occupies one slot.

### Linking Process

1. User starts a DM with `@whatsappbot:yourdomain.com`
2. User sends `login`
3. The bridge generates a QR code and sends it as an image in the DM
4. User opens WhatsApp on their phone, navigates to Settings > Linked Devices > Link a Device
5. User scans the QR code with their phone
6. WhatsApp's servers establish a session between the bridge and the user's account
7. The bridge begins syncing: contacts, recent chats, group memberships
8. Portal rooms are created for each conversation
9. Ghost users are created for each contact

The QR code has a timeout (usually about 60 seconds). If it expires, send `login` again.

### Features

| Category | Details |
|----------|---------|
| **Text** | Full bidirectional text with formatting (bold, italic, monospace, strikethrough) |
| **Media** | Images, video, audio files, documents, voice messages, stickers |
| **Reactions** | Full support (emoji reactions sync both ways) |
| **Replies** | Quote-replies with reference to the original message |
| **Read receipts** | Bidirectional read receipt sync |
| **Typing indicators** | Bidirectional |
| **Presence** | Online/offline status forwarding |
| **Groups** | Full group chat support with membership sync |
| **Contacts** | Contact list sync with display names and avatars |
| **Location** | Location sharing (rendered as a map link on Matrix) |
| **Disappearing messages** | Configurable, synced from WhatsApp settings |
| **Calls** | NOT supported (WhatsApp Web protocol does not support calls) |
| **Status/Stories** | NOT supported |

### Config Structure

The WhatsApp bridge uses the megabridge config format with database at the top level:

```yaml
homeserver:
  address: http://synapse:8008
  domain: yourdomain.com

appservice:
  address: http://mautrix-whatsapp:29318
  hostname: 0.0.0.0
  port: 29318

database:
  type: postgres
  uri: postgres://bridges_user:password@postgres-bridges:5432/mautrix_whatsapp?sslmode=disable

bridge:
  permissions:
    "*": relay
    "yourdomain.com": user
    "@admin:yourdomain.com": admin
```

Init container yq commands (from `docker-compose.yaml`):

```bash
yq -i '.database.type = "postgres"' /data/config.yaml
yq -i '.database.uri = "postgres://" + env(POSTGRES_BRIDGES_USER) + ":" + env(POSTGRES_BRIDGES_PASSWORD) + "@postgres-bridges:5432/mautrix_whatsapp?sslmode=disable"' /data/config.yaml
```

### Limitations

- **No voice/video calls**: This is a protocol limitation of WhatsApp Web. Calls are handled separately from messaging and are not accessible to linked devices.
- **History limit**: On first sync, the bridge only retrieves recent messages (not your entire chat history). The exact amount depends on WhatsApp's servers.
- **One bridge per account**: You cannot bridge the same WhatsApp number through multiple bridge instances simultaneously.
- **Session expiry**: WhatsApp may occasionally invalidate linked device sessions (usually after about 14 days of inactivity). You will need to re-scan the QR code.
- **Broadcast lists**: Not supported as Matrix rooms.

---

## 6. Telegram Bridge (mautrix-telegram)

### Overview

| Property | Value |
|----------|-------|
| **Language** | Python |
| **Image** | `dock.mau.dev/mautrix/telegram:latest` |
| **Default Port** | 29317 |
| **Protocol** | Telegram MTProto (via Telethon library) |
| **Login Method** | Phone number + verification code |
| **Config Format** | Legacy Python (`.appservice.database` as direct string) |
| **Bot User** | `@telegrambot:yourdomain.com` |

### Prerequisites: Telegram API Credentials

Unlike the Go bridges which connect to their respective platforms without explicit API keys, mautrix-telegram requires Telegram API credentials. This is because Telegram's client protocol (MTProto) requires all client applications to register with Telegram and obtain an `api_id` and `api_hash`.

To obtain these:

1. Go to `https://my.telegram.org/apps`
2. Log in with your Telegram phone number
3. Create a new application (the name and description do not matter much)
4. Note the `api_id` (integer) and `api_hash` (hex string)

These are set as environment variables (`TELEGRAM_API_ID` and `TELEGRAM_API_HASH`) and injected into the config via the init container.

**Important yq handling**: The `api_id` is an integer, but yq may interpret environment variables as strings by default. The init container uses a special yq syntax to force integer typing:

```bash
yq -i '.telegram.api_id = (env(TELEGRAM_API_ID) | tag = "!!int")' /data/config.yaml
```

The `| tag = "!!int"` part tells yq to emit the YAML integer tag instead of a string. Without this, the config file would contain `api_id: "12345678"` (string) instead of `api_id: 12345678` (integer), and the Python Telethon library would reject it.

### Login Process

1. User starts a DM with `@telegrambot:yourdomain.com`
2. User sends `login`
3. Bridge asks for the phone number (with country code, e.g., `+491234567890`)
4. Bridge sends an authentication request to Telegram's servers
5. Telegram sends a verification code via the Telegram app (or SMS as fallback)
6. User enters the code in the bridge DM
7. If 2FA is enabled on the Telegram account, the bridge asks for the 2FA password
8. Session is established, bridge begins syncing chats

### Puppeting vs Relay Mode

mautrix-telegram has a particularly full-featured relay mode compared to other bridges:

**Puppeting mode** (requires `full` permission): The bridge logs in as the user's actual Telegram account. Messages are sent from the user's Telegram identity. All personal chats, groups, and channels are accessible.

**Relay mode** (requires only `relaybot` permission): A separate Telegram bot account is used to bridge messages. The bridge creates a Telegram bot (via `@BotFather`) and uses it to relay messages from Matrix users who have not logged in. On the Telegram side, all relayed messages come from the bot with a "Username:" prefix.

Relay mode in Telegram is more capable than in Go bridges because Telegram bots can be added to groups and have a rich API. The Go bridges' relay mode is simpler and more limited.

### Config Structure

The Telegram bridge uses the legacy Python config format:

```yaml
homeserver:
  address: http://synapse:8008
  domain: yourdomain.com

appservice:
  address: http://mautrix-telegram:29317
  hostname: 0.0.0.0
  port: 29317
  database: postgres://bridges_user:password@postgres-bridges:5432/mautrix_telegram?sslmode=disable

telegram:
  api_id: 12345678
  api_hash: 0123456789abcdef0123456789abcdef

bridge:
  permissions:
    "*": relaybot
    "yourdomain.com": full
    "@admin:yourdomain.com": admin
```

Note the critical differences from Go bridges:
- `.appservice.database` is a direct connection string, not a sub-object with `.type` and `.uri`
- `telegram` section at the top level for API credentials
- Permission levels use `relaybot` and `full` instead of `relay` and `user`

Init container yq commands:

```bash
yq -i '.appservice.database = "postgres://" + env(POSTGRES_BRIDGES_USER) + ":" + env(POSTGRES_BRIDGES_PASSWORD) + "@postgres-bridges:5432/mautrix_telegram?sslmode=disable"' /data/config.yaml
yq -i '.telegram.api_id = (env(TELEGRAM_API_ID) | tag = "!!int")' /data/config.yaml
yq -i '.telegram.api_hash = env(TELEGRAM_API_HASH)' /data/config.yaml
```

### Features

| Category | Details |
|----------|---------|
| **Text** | Full bidirectional with rich formatting (Markdown and HTML) |
| **Media** | Images, video, audio, documents, voice messages, video notes (round) |
| **Stickers** | Full support (converted to images on Matrix) |
| **Reactions** | Supported |
| **Replies** | Quote-reply threading |
| **Read receipts** | Bidirectional |
| **Typing indicators** | Bidirectional |
| **Groups** | Regular groups and supergroups |
| **Channels** | Bridged as read-only rooms |
| **Polls** | Supported |
| **Location** | Supported |
| **Bot interactions** | Telegram bot buttons and inline queries work through the bridge |
| **Contacts** | Contact sharing |
| **Calls** | NOT supported |
| **Secret chats** | NOT supported (Telegram secret chats are device-specific by design) |

### Special Considerations

- **Python memory usage**: The Telegram bridge typically uses more memory than the Go bridges due to the Python runtime. Expect 150-300 MB for a moderately active account.
- **Telethon sessions**: The bridge creates a Telethon session file in its data directory. If this file is lost, the user must re-login.
- **Telegram rate limits**: Telegram has aggressive rate limiting. If the bridge sends too many messages too quickly (for example, during initial sync of a large group), Telegram may temporarily restrict the account. The bridge handles this with automatic retry/backoff.
- **Config generation**: Unlike Go bridges which use `-e` to generate a config, the Telegram bridge uses `cp /opt/mautrix-telegram/example-config.yaml /data/config.yaml` to copy an example config file.

---

## 7. Discord Bridge (mautrix-discord)

### Overview

| Property | Value |
|----------|-------|
| **Language** | Go |
| **Image** | `dock.mau.dev/mautrix/discord:latest` |
| **Default Port** | 29334 |
| **Protocol** | Discord Gateway (WebSocket) |
| **Login Method** | QR code scan or user token |
| **Config Format** | Transitional (`.appservice.database.type` / `.appservice.database.uri` nested) |
| **Bot User** | `@discordbot:yourdomain.com` |

### How Discord Bridging Works

mautrix-discord connects to Discord using a **user account session**, not a Discord bot token. This is an important distinction:

**Discord Bot Tokens** are official API tokens for registered bot applications. Bots have limited access: they can only see servers they have been explicitly invited to, cannot access DMs (unless the user initiates), and have various other restrictions. They display a "BOT" badge.

**User Tokens** (what mautrix-discord uses) provide the same access as the Discord desktop/web client. The bridge can see all your DMs, all your servers, all your channels. It connects via Discord's Gateway WebSocket exactly like a regular Discord client would.

The bridge supports two login methods:
- **QR code**: The bridge displays a QR code that you scan with the Discord mobile app (similar to Discord desktop login). This is the recommended method.
- **User token**: You manually extract your Discord user token from your browser's developer tools and provide it to the bridge. This is more fragile as Discord may rotate tokens.

**Terms of Service note**: Using automated access with a user token technically violates Discord's Terms of Service (their ToS prohibits "self-bots" and unauthorized automation of user accounts). Discord could potentially disable accounts that are detected using bridges. Use at your own discretion.

### Guild Bridging

Discord's structure differs from other platforms. Conversations are organized into servers (guilds) containing channels, and separately there are DMs and group DMs. The bridge handles these differently:

**DMs and Group DMs**: Automatically bridged when someone messages you. Each DM or group DM becomes a portal room.

**Server channels**: Must be explicitly bridged using the `guilds` command:

```
guilds                       # List all your Discord servers
guilds <server_id>           # Bridge specific channels from a server
guilds <server_id> --entire  # Bridge ALL channels in a server
```

When you bridge a server, each Discord channel becomes a separate Matrix room. The bridge creates ghost users for members of those channels.

### Config Structure

The Discord bridge uses a transitional config format where the database config is nested under `appservice`:

```yaml
homeserver:
  address: http://synapse:8008
  domain: yourdomain.com

appservice:
  address: http://mautrix-discord:29334
  hostname: 0.0.0.0
  port: 29334
  database:
    type: postgres
    uri: postgres://bridges_user:password@postgres-bridges:5432/mautrix_discord?sslmode=disable

bridge:
  permissions:
    "*": relay
    "yourdomain.com": user
    "@admin:yourdomain.com": admin
```

Init container yq commands:

```bash
yq -i '.appservice.database.type = "postgres"' /data/config.yaml
yq -i '.appservice.database.uri = "postgres://" + env(POSTGRES_BRIDGES_USER) + ":" + env(POSTGRES_BRIDGES_PASSWORD) + "@postgres-bridges:5432/mautrix_discord?sslmode=disable"' /data/config.yaml
```

Note: The Discord bridge's config is generated by copying the example config, not by using `-e`:

```bash
if [ ! -f /data/config.yaml ]; then
  cp /opt/mautrix-discord/example-config.yaml /data/config.yaml
fi
```

### Features

| Category | Details |
|----------|---------|
| **Text** | Full bidirectional with Discord markdown formatting |
| **Media** | Images, video, audio, files |
| **Embeds** | Discord embeds are rendered as formatted text on Matrix |
| **Reactions** | Full support including custom emoji |
| **Replies** | Supported |
| **Read receipts** | Partial (marks messages as read on Discord) |
| **Typing indicators** | Bidirectional |
| **DMs** | Automatic bridging |
| **Group DMs** | Automatic bridging |
| **Server channels** | Manual bridging via `guilds` command |
| **Threads** | Supported (mapped to Matrix threads) |
| **Custom emoji** | Supported (rendered as images) |
| **Stickers** | Supported |
| **Voice channels** | NOT supported |
| **Video/screen share** | NOT supported |
| **Stage channels** | NOT supported |

---

## 8. Slack Bridge (mautrix-slack)

### Overview

| Property | Value |
|----------|-------|
| **Language** | Go |
| **Image** | `dock.mau.dev/mautrix/slack:latest` |
| **Default Port** | 29335 |
| **Protocol** | Slack RTM / Events API |
| **Login Method** | Token or cookie-based |
| **Config Format** | Megabridge (`.database.type` / `.database.uri` at top level) |
| **Bot User** | `@slackbot:yourdomain.com` |

### How Slack Bridging Works

mautrix-slack bridges your Slack workspace to Matrix by connecting as your Slack user account. The bridge maintains a real-time connection to Slack's servers and translates messages between the two platforms.

Login is typically done via one of these methods:

**Token method**: You provide your Slack user token (a `xoxc-` prefixed token) extracted from your browser session. The token is combined with the `d` cookie value for authentication.

**Cookie method**: You provide the value of the `d` cookie from your browser's Slack session.

To extract credentials:
1. Open your Slack workspace in a web browser
2. Open Developer Tools (F12)
3. Go to Application/Storage > Cookies
4. Find the cookie named `d` for your Slack workspace domain
5. Copy its value

### Workspace Bridging

Once logged in, the bridge syncs your Slack workspace:

- **Channels you are a member of** are bridged as Matrix rooms
- **DMs** are bridged as private Matrix rooms
- **Group DMs** (multi-party DMs) are bridged as private Matrix rooms
- **Channels you are not a member of** are NOT automatically bridged

Each Slack channel becomes a portal room on Matrix with ghost users for each Slack participant.

### Config Structure

The Slack bridge uses the same megabridge format as WhatsApp -- database config at the top level:

```yaml
homeserver:
  address: http://synapse:8008
  domain: yourdomain.com

appservice:
  address: http://mautrix-slack:29335
  hostname: 0.0.0.0
  port: 29335

database:
  type: postgres
  uri: postgres://bridges_user:password@postgres-bridges:5432/mautrix_slack?sslmode=disable

bridge:
  permissions:
    "*": relay
    "yourdomain.com": user
    "@admin:yourdomain.com": admin
```

Init container yq commands:

```bash
yq -i '.database.type = "postgres"' /data/config.yaml
yq -i '.database.uri = "postgres://" + env(POSTGRES_BRIDGES_USER) + ":" + env(POSTGRES_BRIDGES_PASSWORD) + "@postgres-bridges:5432/mautrix_slack?sslmode=disable"' /data/config.yaml
```

### Features

| Category | Details |
|----------|---------|
| **Text** | Full bidirectional with Slack mrkdwn formatting |
| **Media** | Images, video, audio, files |
| **Reactions** | Full support including custom workspace emoji |
| **Replies/Threads** | Slack threads are bridged (mapped to Matrix threads or reply chains) |
| **Read receipts** | Bidirectional |
| **Typing indicators** | Bidirectional |
| **Channels** | Bridged for channels you are a member of |
| **DMs** | Automatic bridging |
| **Group DMs** | Automatic bridging |
| **Custom emoji** | Supported |
| **Channel topics** | Synced to Matrix room topics |
| **Rich text** | Slack Block Kit formatting preserved where possible |
| **Calls** | NOT supported |
| **Huddles** | NOT supported |
| **Slack Connect** | Partial support |
| **Workflows/Apps** | NOT supported |

---

## 9. Registration File Details

### What Each Field Means

Let us walk through a complete registration file with detailed explanations:

```yaml
id: whatsapp
```
A unique identifier string. Synapse uses this internally to track the appservice in its database. If you change this after initial setup, Synapse will treat it as a completely new appservice and re-process namespace claims.

```yaml
url: http://mautrix-whatsapp:29318
```
The base URL where Synapse should send HTTP requests. In Docker, this uses the container name as the hostname. The bridge's AS API server must be listening on this address. If this is wrong, Synapse will log errors about failing to reach the appservice.

```yaml
as_token: <random-string>
```
Application Service token. Generated randomly (typically a hex string or UUID). The bridge uses this to authenticate its requests to Synapse's Client-Server API. When the bridge calls Synapse to send a message as a ghost user, it includes this token in the `Authorization: Bearer <as_token>` header. If this does not match what Synapse has on file, the request is rejected with a 403.

```yaml
hs_token: <random-string>
```
Homeserver token. Also generated randomly. Synapse includes this in requests it makes to the bridge (event transactions). The bridge verifies this token to ensure the request is legitimately from the homeserver and not from a random attacker. If someone tries to push fake events to the bridge without the correct `hs_token`, the bridge rejects them.

```yaml
sender_localpart: whatsappbot
```
The localpart (the part before the `:domain`) of the bridge's main bot user. Synapse creates `@whatsappbot:yourdomain.com` automatically. This user serves as the bridge's "face" -- users DM it to issue commands, and it sends status messages and notifications.

```yaml
rate_limited: false
```
Tells Synapse not to apply rate limiting to this appservice. Bridges need to send many messages in bursts (initial sync, busy group chats) and would hit rate limits quickly. This is standard for all bridges.

```yaml
namespaces:
  users:
    - regex: '@whatsapp_.*:yourdomain\.com'
      exclusive: true
  aliases:
    - regex: '#whatsapp_.*:yourdomain\.com'
      exclusive: true
  rooms: []
```
Namespace claims (discussed in detail in Section 1).

### How Tokens Are Generated

When the bridge generates a registration file (via `-g` flag for Go bridges or `python3 -m mautrix_telegram -g` for Telegram), it:

1. Generates two cryptographically random strings for `as_token` and `hs_token`
2. Uses the configured `sender_localpart` from the bridge's `config.yaml`
3. Constructs the namespace regex patterns based on the bridge's user prefix and the homeserver domain
4. Writes the complete YAML file

The tokens are typically 64-character hex strings generated using the language's secure random number generator.

### Why We Regenerate on Every Init

In our deployment, every init container run deletes and regenerates the registration file:

```bash
rm -f /data/registration.yaml
/usr/bin/mautrix-whatsapp -g -c /data/config.yaml -r /data/registration.yaml
mkdir -p /registrations
cp /data/registration.yaml /registrations/whatsapp-registration.yaml
```

This ensures:

1. **Token consistency**: The `as_token` in the registration file always matches what the bridge expects. If the config changes (for example, the homeserver domain), the old registration would be out of sync.
2. **Namespace accuracy**: If the bridge is reconfigured to use different user prefixes, the namespace regexes are regenerated.
3. **Clean state**: Eliminates any possibility of a stale or corrupt registration file causing startup failures.

The downside is that tokens change on every deployment. But because Synapse also restarts (and re-reads the registration files), this is not a problem -- both sides always have matching tokens.

### The Shared bridge-registrations Volume

The Docker volume `bridge-registrations` is the critical link between bridges and Synapse:

```yaml
volumes:
  bridge-registrations:    # Named Docker volume

# Init containers write to it:
whatsapp-init:
  volumes:
    - bridge-registrations:/registrations

# Synapse reads from it (read-only):
synapse:
  volumes:
    - bridge-registrations:/bridges:ro
```

The init containers write their registration files to `/registrations/` (which maps to the volume). Synapse mounts the same volume at `/bridges/` in read-only mode and reads the files listed in its `app_service_config_files` config.

The container startup order ensures init containers complete before Synapse starts:

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

This guarantees that all four registration files exist in the volume before Synapse attempts to read them.

---

## 10. Bot Commands

### Universal Commands (All Bridges)

These commands are available across all mautrix bridges. Send them as a DM to the respective bridge bot:

| Command | Description |
|---------|-------------|
| `help` | Show all available commands and their descriptions |
| `login` | Begin the login process for the remote platform |
| `logout` | Disconnect your account from the bridge |
| `ping` | Check the bridge's connection status and your login status |
| `set-relay` | Enable relay mode in the current room (admin only) |
| `unset-relay` | Disable relay mode in the current room (admin only) |
| `sync` | Force-sync your contact/channel list from the remote platform |

### WhatsApp-Specific Commands

| Command | Description |
|---------|-------------|
| `login` | Generates a QR code to scan with your phone |
| `create <phone>` | Create a DM portal with a phone number (e.g., `create +491234567890`) |
| `open <phone>` | Open an existing chat by phone number |
| `pm <phone>` | Alias for `create` |
| `disappearing-timer <duration>` | Set disappearing message timer for the current chat |
| `toggle <setting>` | Toggle various bridge settings (receipts, presence, etc.) |

### Telegram-Specific Commands

| Command | Description |
|---------|-------------|
| `login` | Start phone-number-based login flow |
| `search <query>` | Search for Telegram users, groups, or channels |
| `pm <username>` | Start a DM with a Telegram user by username |
| `group <name>` | Create a new Telegram group |
| `upgrade` | Upgrade a Telegram basic group to a supergroup |
| `bridge <chat_id>` | Bridge a specific Telegram chat by its numeric ID |
| `unbridge` | Unbridge the current room from Telegram |
| `filter` | Manage which chats are synced |
| `delete-portal` | Delete the current portal room |

### Discord-Specific Commands

| Command | Description |
|---------|-------------|
| `login` | Start QR code login |
| `login-token` | Login using a Discord user token from browser DevTools |
| `guilds` | List your Discord servers and their bridge status |
| `guilds <id>` | Bridge select channels from a Discord server |
| `guilds <id> --entire` | Bridge all channels from a Discord server |

### Slack-Specific Commands

| Command | Description |
|---------|-------------|
| `login` | Start the login flow |
| `login-token <token>` | Login directly with a Slack user token |
| `login-cookie <cookie>` | Login with the Slack `d` cookie value |

---

## 11. Troubleshooting

### "Not Configured" or "Bridge Not Running" Errors

**Symptom**: Sending a message to the bridge bot gets no response, or the bridge bot user does not exist.

**Causes and fixes**:

1. **Registration not loaded by Synapse**: Check that the registration file exists and Synapse has read it.
   ```bash
   # Verify registration files are in the shared volume
   docker compose exec synapse ls -la /bridges/
   # Expected: whatsapp-registration.yaml, telegram-registration.yaml, etc.

   # Check Synapse logs for appservice loading
   docker compose logs synapse 2>&1 | grep -i "appservice"
   ```

2. **Init container failed**: If the init container did not complete successfully, no registration file was generated.
   ```bash
   docker compose logs whatsapp-init
   docker compose logs telegram-init
   docker compose logs discord-init
   docker compose logs slack-init
   ```

3. **Bridge container not running**: The bridge process itself may have crashed.
   ```bash
   docker compose ps
   docker compose logs mautrix-whatsapp --tail 50
   ```

### Permission Errors ("Not Allowed" or "Insufficient Permissions")

**Symptom**: User can talk to the bridge bot but gets an error when trying to `login`.

**For Go bridges**: Ensure the user's domain is mapped to `user` (not just `relay`):
```yaml
bridge:
  permissions:
    "yourdomain.com": user    # Must be "user" or "admin", not "relay"
```

**For Telegram**: Remember the permission level trap. You need `full`, not `user`:
```yaml
bridge:
  permissions:
    "yourdomain.com": full    # "user" will NOT allow login on Telegram
```

**Checking current permissions**: Look at the bridge config:
```bash
docker compose exec mautrix-whatsapp cat /data/config.yaml | grep -A 5 "permissions"
```

### Database Connection Failures

**Symptom**: Bridge logs show errors connecting to PostgreSQL.

**Common causes**:

1. **postgres-bridges not ready**: The init container depends on the healthcheck, but if PostgreSQL is slow to initialize its databases, the bridge may try to connect before the specific database exists.
   ```bash
   # Check if all databases exist
   docker compose exec postgres-bridges psql -U bridges_user -c '\l'
   # Should show: mautrix_whatsapp, mautrix_telegram, mautrix_discord, mautrix_slack
   ```

2. **Wrong connection string**: The yq command in the init container may have failed silently.
   ```bash
   # Check what the bridge thinks its database config is
   docker compose exec mautrix-whatsapp cat /data/config.yaml | grep -A 3 "database"
   ```

3. **Credential mismatch**: The `POSTGRES_BRIDGES_USER` and `POSTGRES_BRIDGES_PASSWORD` env vars must match between the postgres-bridges container and the bridge init containers.

### Registration Mismatch (Token Errors)

**Symptom**: Bridge logs show "M_UNKNOWN_TOKEN" or "Invalid appservice token" errors when trying to communicate with Synapse.

**Cause**: The `as_token` in the registration file that Synapse loaded does not match what the bridge is using.

**Fix**: Restart everything to regenerate tokens consistently:
```bash
docker compose down
docker volume rm matrix_bridge-registrations  # Force clean regeneration
docker compose up -d
```

### Ghost User Conflicts

**Symptom**: Messages from the remote platform show up from the wrong user, or the bridge logs errors about user creation conflicts.

**Cause**: Another appservice has claimed the same namespace, or a manual user account was created with a username matching the bridge's ghost user pattern.

**Fix**: Check for namespace overlaps across all registration files:
```bash
docker compose exec synapse cat /bridges/whatsapp-registration.yaml | grep regex
docker compose exec synapse cat /bridges/telegram-registration.yaml | grep regex
docker compose exec synapse cat /bridges/discord-registration.yaml | grep regex
docker compose exec synapse cat /bridges/slack-registration.yaml | grep regex
```

Each bridge should use a distinct prefix (`whatsapp_`, `telegram_`, `discord_`, `slack_`). If there is overlap, one bridge's init container needs its config adjusted.

### WhatsApp Session Expired

**Symptom**: WhatsApp bridge was working, then suddenly stops syncing. `ping` returns "not logged in."

**Cause**: WhatsApp periodically requires linked devices to reconnect. If the bridge was offline for an extended period, or WhatsApp's servers decide to invalidate the session, you lose the link.

**Fix**: Simply `login` again and scan a new QR code.

### Telegram Rate Limiting

**Symptom**: Bridge logs show "FLOOD_WAIT" errors. Some messages are delayed or lost.

**Cause**: Telegram has strict rate limits, especially for new sessions. Bridging a large group or syncing many chats at once can trigger this.

**Fix**: Wait for the flood timer to expire (the bridge will automatically retry). For future large syncs, bridge channels gradually rather than all at once.

### Bridge Bot Not Responding After Synapse Restart

**Symptom**: Synapse was restarted, and now bridge bots do not respond.

**Cause**: The bridge containers may still be running but have lost their connection state.

**Fix**: Restart the bridge containers:
```bash
docker compose restart mautrix-whatsapp mautrix-telegram mautrix-discord mautrix-slack
```

### Complete Bridge Reset

If a bridge is in an unrecoverable state, you can reset it entirely:

```bash
# Stop the bridge
docker compose stop mautrix-whatsapp

# Remove its data volume (DESTROYS ALL BRIDGE DATA including login sessions)
docker volume rm matrix_mautrix-whatsapp-data

# The database still exists in postgres-bridges. To also reset the database:
docker compose exec postgres-bridges psql -U bridges_user -c 'DROP DATABASE mautrix_whatsapp;'
docker compose exec postgres-bridges psql -U bridges_user -c 'CREATE DATABASE mautrix_whatsapp;'

# Restart (init container will regenerate config and registration)
docker compose up -d
```

---

## 12. Additional Available Bridges

The mautrix ecosystem includes many more bridges that can be added to this deployment using the same init container pattern. Here is a catalog of notable options:

### Signal (mautrix-signal)

| Property | Value |
|----------|-------|
| **Image** | `dock.mau.dev/mautrix/signal` |
| **Language** | Go |
| **Port** | 29328 |
| **Login** | QR code (linked device) or phone number registration |
| **Protocol** | Signal protocol via built-in libsignal |
| **Key features** | Text, media, reactions, replies, groups, voice messages, stickers, disappearing messages |
| **Limitations** | No calls. One bridge session per Signal number. |
| **Notes** | Self-contained -- does not require a separate signald daemon. Uses the same linked device model as the Signal desktop app. |

### Google Chat (mautrix-googlechat)

| Property | Value |
|----------|-------|
| **Image** | `dock.mau.dev/mautrix/googlechat` |
| **Language** | Python |
| **Port** | 29320 |
| **Login** | Google account OAuth or cookie extraction |
| **Key features** | Text, media, reactions, threads, Google Chat Spaces |
| **Limitations** | Some features require Google Workspace accounts |
| **Notes** | Python-based like Telegram; uses legacy config format. Go rewrite is planned. |

### Meta (Facebook Messenger + Instagram) (mautrix-meta)

| Property | Value |
|----------|-------|
| **Image** | `dock.mau.dev/mautrix/meta` |
| **Language** | Go |
| **Port** | 29319 |
| **Login** | Cookie-based (Facebook/Instagram cookies from browser) |
| **Key features** | Text, media, reactions, replies, group chats, typing indicators, read receipts |
| **Limitations** | No calls, no stories. Facebook may detect and block automated access. |
| **Notes** | Single bridge handles BOTH Facebook Messenger and Instagram DMs. Replaces the deprecated `mautrix-facebook` and `mautrix-instagram` Python bridges. |

### iMessage (mautrix-imessage)

| Property | Value |
|----------|-------|
| **Image** | N/A (requires macOS host or Beeper cloud connector) |
| **Language** | Go |
| **Login** | Apple ID or local macOS integration |
| **Key features** | Text, media, reactions, replies, tapbacks, group chats |
| **Limitations** | Requires a Mac running at all times or a Beeper cloud connector. Cannot run in a standard Docker setup on Linux. |
| **Notes** | The most complex bridge to deploy due to Apple's closed ecosystem. |

### Google Messages (mautrix-gmessages)

| Property | Value |
|----------|-------|
| **Image** | `dock.mau.dev/mautrix/gmessages` |
| **Language** | Go |
| **Port** | 29336 |
| **Login** | QR code (pair with Google Messages web) |
| **Key features** | SMS and RCS text, media, reactions, read receipts, group chats (RCS) |
| **Limitations** | Requires an Android phone with Google Messages as the default SMS app |
| **Notes** | Bridges both SMS and RCS conversations. Uses the same pairing mechanism as Google Messages for Web. |

### LinkedIn (mautrix-linkedin)

| Property | Value |
|----------|-------|
| **Image** | `dock.mau.dev/mautrix/linkedin` |
| **Language** | Go |
| **Port** | 29337 |
| **Login** | Cookie-based |
| **Key features** | Messaging (text, media, reactions) |
| **Limitations** | DMs only. No InMail or connection request bridging. |

### Twitter/X (mautrix-twitter)

| Property | Value |
|----------|-------|
| **Image** | `dock.mau.dev/mautrix/twitter` |
| **Language** | Go |
| **Port** | 29327 |
| **Login** | Cookie-based (Twitter auth cookies from browser) |
| **Key features** | DMs with text, media, reactions, read receipts |
| **Limitations** | DMs only. No tweet bridging, spaces, or calls. |
| **Notes** | Twitter/X API changes may occasionally break the bridge. |

### Adding a New Bridge

To add any of these bridges to the deployment, follow the established pattern:

1. Add a PostgreSQL database for the bridge (in the postgres-bridges init SQL)
2. Create an init container that generates config and registration
3. Create the bridge service container
4. Add the registration file path to Synapse's `app_service_config_files`
5. Add the init container to Synapse's `depends_on`
6. Add the bridge's data volume

The init container pattern is identical for all Go megabridge-format bridges:

```yaml
new-bridge-init:
  image: dock.mau.dev/mautrix/newbridge:latest
  user: "0:0"
  restart: "no"
  depends_on:
    postgres-bridges:
      condition: service_healthy
  environment:
    SYNAPSE_SERVER_NAME: ${SYNAPSE_SERVER_NAME}
    POSTGRES_BRIDGES_USER: ${POSTGRES_BRIDGES_USER}
    POSTGRES_BRIDGES_PASSWORD: ${POSTGRES_BRIDGES_PASSWORD}
    BRIDGE_ADMIN_USER: ${BRIDGE_ADMIN_USER}
  entrypoint: ["/bin/bash", "-c", "
    if [ ! -f /data/config.yaml ]; then
      /usr/bin/mautrix-newbridge -c /data/config.yaml -e
    fi
    yq -i '.homeserver.address = \"http://synapse:8008\"' /data/config.yaml
    yq -i '.homeserver.domain = env(SYNAPSE_SERVER_NAME)' /data/config.yaml
    yq -i '.appservice.address = \"http://mautrix-newbridge:PORT\"' /data/config.yaml
    yq -i '.appservice.hostname = \"0.0.0.0\"' /data/config.yaml
    yq -i '.database.type = \"postgres\"' /data/config.yaml
    yq -i '.database.uri = \"postgres://\" + env(POSTGRES_BRIDGES_USER) + \":\" + env(POSTGRES_BRIDGES_PASSWORD) + \"@postgres-bridges:5432/mautrix_newbridge?sslmode=disable\"' /data/config.yaml
    yq -i '.bridge.permissions = {\"*\": \"relay\", env(SYNAPSE_SERVER_NAME): \"user\", env(BRIDGE_ADMIN_USER): \"admin\"}' /data/config.yaml
    rm -f /data/registration.yaml
    /usr/bin/mautrix-newbridge -g -c /data/config.yaml -r /data/registration.yaml
    mkdir -p /registrations
    cp /data/registration.yaml /registrations/newbridge-registration.yaml
    chown -R 1337:1337 /data
  "]
  volumes:
    - mautrix-newbridge-data:/data
    - bridge-registrations:/registrations
```

Adjust the database path (`.database.type`/`.database.uri` vs `.appservice.database.type`/`.appservice.database.uri` vs `.appservice.database`) based on whether the bridge uses megabridge format, transitional format, or legacy Python format.

---

## Summary: Quick Reference Table

| Bridge | Language | Port | DB Config Path | Permission for Login | Login Method | Config Generation |
|--------|----------|------|---------------|---------------------|-------------|-------------------|
| WhatsApp | Go | 29318 | `.database.type` / `.database.uri` | `user` | QR code | `-e` flag |
| Telegram | Python | 29317 | `.appservice.database` (string) | `full` | Phone + code | `cp example-config.yaml` |
| Discord | Go | 29334 | `.appservice.database.type` / `.appservice.database.uri` | `user` | QR code or token | `cp example-config.yaml` |
| Slack | Go | 29335 | `.database.type` / `.database.uri` | `user` | Token or cookie | `-e` flag |

---

## Cross-References

- **Matrix protocol fundamentals, events, and rooms**: [01 -- Matrix Fundamentals](01-matrix-fundamentals.md)
- **Synapse homeserver configuration, database, and admin API**: [02 -- Synapse Homeserver](02-synapse-homeserver.md)
- **Docker Compose structure, init containers, volumes, and networking**: [04 -- Deployment Architecture](04-deployment-architecture.md)
- **Monitoring, backups, log management, and operational procedures**: [06 -- Operations](06-operations.md)

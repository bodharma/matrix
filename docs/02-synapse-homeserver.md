# 02 -- Synapse Homeserver: Deep Dive

> Part 2 of 6 in the self-hosted Matrix documentation suite.
> Previous: [01 -- Matrix Fundamentals](01-matrix-fundamentals.md) | Next: [03 -- Authentication](03-authentication.md)

---

## Table of Contents

1. [What is Synapse](#1-what-is-synapse)
2. [Core Architecture](#2-core-architecture)
3. [Configuration Deep-Dive](#3-configuration-deep-dive)
4. [Database](#4-database)
5. [Federation](#5-federation)
6. [Performance Tuning](#6-performance-tuning)
7. [Admin API](#7-admin-api)
8. [MSC3861 / OIDC Native](#8-msc3861--oidc-native)

---

## 1. What is Synapse

### Origin and Purpose

Synapse is the **reference homeserver implementation** for the Matrix protocol. It was created by the Matrix.org Foundation team (originally at Amdocs, then the startup New Vector, now Element) alongside the Matrix specification itself. Development began in 2014, and the first public release landed in late 2014 / early 2015. For the first several years of Matrix's existence, Synapse was the only viable homeserver -- it was the proving ground where protocol ideas were tested, debated, and hardened before being written into the spec.

Because Synapse and the spec co-evolved, Synapse occupies a unique position: it is simultaneously the most complete implementation of the Matrix spec and the codebase where experimental Matrix Spec Changes (MSCs) are prototyped before ratification. When you see `experimental_features` in a Synapse config, you are looking at this dual role in action.

### Language and Runtime

Synapse is written in **Python 3** (originally Python 2, fully ported by 2019) and runs on the **Twisted** asynchronous networking framework. Twisted is an event-driven networking engine that predates Python's `asyncio` -- Synapse uses a compatibility layer to bridge the two. The result is a single-process, event-loop-based server where all I/O (HTTP, database, federation) is non-blocking.

Key runtime characteristics:

- **Single-threaded by default.** The Twisted reactor runs on one thread. CPU-bound work (JSON serialization, state resolution) blocks the reactor unless explicitly deferred to a thread pool.
- **Multi-process via workers.** Synapse supports splitting workloads across multiple processes (see [Performance Tuning](#6-performance-tuning)). Each worker is its own Twisted process communicating over Redis or TCP replication.
- **Memory-hungry.** Python's object overhead and Synapse's extensive in-memory caching mean a small-to-medium server easily consumes 500MB--1GB of RAM. Large servers can consume many gigabytes.

### Relationship to the Matrix Spec

The Matrix spec (at spec.matrix.org) defines:

- The **Client-Server API** (how clients talk to homeservers)
- The **Server-Server (Federation) API** (how homeservers talk to each other)
- The **Application Service API** (how bridges and bots integrate)
- The **Identity Service API**, **Push Gateway API**, etc.

Synapse implements all of these. When the spec says "the homeserver MUST...", that behavior lives in Synapse's codebase. When you read Synapse's source code, you are reading a concrete implementation of the abstract spec.

Importantly, Synapse is **not** the spec. Other homeservers (Dendrite in Go, Conduit/Conduwuit in Rust) implement the same spec independently. But because Synapse came first and is maintained by the same organization that stewards the spec, it has the most complete coverage of both stable and unstable features.

### Alternatives

| Homeserver | Language | Status | Notes |
|---|---|---|---|
| **Synapse** | Python/Twisted | Production | Reference implementation, most complete |
| **Dendrite** | Go | Production | Second-generation, designed for efficiency |
| **Conduit** | Rust | Beta | Lightweight, single-binary |
| **Conduwuit** | Rust | Active dev | Conduit hard-fork with more features |

For this deployment, we use Synapse because it has the most complete MSC3861 support (required for MAS integration) and the widest bridge compatibility.

---

## 2. Core Architecture

### The Event Graph (DAG)

At the heart of Matrix -- and therefore at the heart of Synapse -- is the **event graph**. Every room in Matrix is a Directed Acyclic Graph (DAG) of events. Each event references one or more previous events via their `prev_events` field, forming a graph rather than a simple linear log.

```
    [create] ---- [join:alice] ---- [msg:hello] ---- [msg:world]
                        \                                /
                         [join:bob] ---- [msg:hi] ------
```

This DAG structure is what makes Matrix federated and conflict-free. Two servers can independently produce events, and when they sync up, the events merge into the graph. There is no single "master" -- every server's contribution is woven into the same DAG.

Synapse stores every event it knows about. When you send a message, Synapse:

1. Creates an event JSON blob
2. Checks authorization rules (power levels, room membership, etc.)
3. Assigns a `prev_events` list (the current "tips" of the DAG)
4. Signs the event with the server's Ed25519 signing key
5. Persists it to the database
6. Sends it to all federated servers in the room
7. Notifies local clients via `/sync`

### Room State and State Resolution

Not all events are equal. **State events** have a `state_key` and define the persistent state of a room -- membership, power levels, room name, topic, join rules, etc. **Timeline events** (messages, reactions) do not have a `state_key` and are ephemeral in the sense that they do not define "current state."

The **current state** of a room is the set of state events at the tips of the DAG. When the DAG has a single linear tip, state is trivial. When the DAG forks (because two servers produced events concurrently), Synapse must run the **state resolution algorithm** to determine the "true" state.

Matrix has two versions of state resolution:

- **State Resolution v1** (room versions 1--2): Simpler, but had known issues with state resets (a malicious or buggy server could "reset" the room state).
- **State Resolution v2** (room versions 3+): More robust, uses a topological sort of authorization events and lexicographic ordering of event IDs to break ties deterministically. Every server running v2 on the same inputs produces the same result.

State resolution is one of the most CPU-intensive operations in Synapse. When a room has thousands of state events and a complex DAG, resolution can take significant time and memory.

### State Groups

To avoid running state resolution for every single query, Synapse uses **state groups**. A state group is a snapshot of the room state at a particular point in the DAG. When an event is persisted, Synapse calculates the state at that point and either reuses an existing state group or creates a new one.

State groups are stored as deltas -- a state group references a "previous" state group and a set of changes. This is an optimization to avoid storing the full state (which can be hundreds of entries for a large room) for every single event.

The `state_groups`, `state_groups_state`, and `state_group_edges` tables are among the largest in a Synapse database. More on this in the [Database section](#4-database).

### Federation Transaction Queues

When an event is created locally, Synapse must send it to every remote server that has users in that room. This is handled by the **federation sender**, which maintains per-destination transaction queues.

The flow:

1. Event is persisted locally.
2. The federation sender is notified.
3. For each remote destination, the event is added to an outbound queue.
4. Synapse batches events into **transactions** (up to 50 events per transaction by default).
5. Transactions are sent via `PUT /_matrix/federation/v1/send/{txnId}`.
6. If the remote server is unreachable, Synapse uses exponential backoff (up to days) before retrying.

The federation sender can be split into a dedicated worker process in large deployments. Our single-process deployment handles this in the main process.

### Media Repository

Synapse has a built-in media repository that handles:

- **Upload**: Clients upload media via `POST /_matrix/media/v3/upload`
- **Download**: Media is served via `GET /_matrix/media/v3/download/{serverName}/{mediaId}`
- **Thumbnailing**: Synapse generates thumbnails on-the-fly or on upload
- **Remote media caching**: When a user requests media from a remote server, Synapse fetches it, caches it locally, and serves it

Media is stored on the filesystem by default (our deployment mounts `synapse-media` as a Docker volume at `/media_store`). The database stores metadata (media ID, uploader, content type, size) but not the file contents.

For large deployments, Synapse supports pluggable storage providers (e.g., S3-compatible backends) and a separate media_repository worker.

### Push Notification Gateway

Synapse implements the Matrix Push Gateway protocol. When a user has registered a push key (via a mobile app), Synapse sends HTTP notifications to the push gateway (typically Element's `sygnal` or a self-hosted instance) whenever an event arrives that should generate a push notification.

The push evaluation logic checks:

- Is the user in the room?
- Does the event match any of the user's push rules?
- Does the user have a registered pusher?

If all conditions are met, Synapse POSTs the notification to the configured push gateway URL.

---

## 3. Configuration Deep-Dive

### How Config Works in Synapse

Synapse's configuration is YAML-based. The primary entrypoint is:

```bash
python -m synapse.app.homeserver -c /path/to/homeserver.yaml --keys-directory /data
```

The critical detail is that the `-c` flag can be specified **multiple times**:

```bash
python -m synapse.app.homeserver \
    -c /data/config/homeserver.yaml \
    -c /data/config/db.yaml \
    -c /data/config/email.yaml \
    --keys-directory /data
```

When multiple config files are provided, Synapse **merges them in order**. Later files override earlier ones for top-level keys. This is not a deep merge -- if both files define `database:`, the second file's `database:` completely replaces the first.

This is exactly what our deployment does. The entrypoint script in docker-compose.yaml generates three config fragments at startup and passes all three with `-c`:

| Fragment | Purpose | Contents |
|---|---|---|
| `homeserver.yaml` | Core server config | server_name, listeners, logging, auth, experimental features, appservice registrations |
| `db.yaml` | Database config | PostgreSQL connection parameters |
| `email.yaml` | Email/SMTP config | SMTP host, credentials, notification settings |

**Why split the config?** Separation of concerns. The database credentials and SMTP credentials come from different environment variables and change independently from the core server config. Splitting also makes it easier to template -- each fragment is a small, focused heredoc in the entrypoint script.

### Our Actual Configuration

Here is the complete homeserver.yaml as generated by the entrypoint (with template variables shown for clarity):

```yaml
# /data/config/homeserver.yaml
server_name: ${SYNAPSE_SERVER_NAME}

listeners:
  - port: 8008
    type: http
    bind_addresses: ['0.0.0.0']
    x_forwarded: true
    resources:
      - names: [client, federation]

report_stats: False

logging:
  - module: synapse.storage.SQL
    level: INFO

trusted_key_servers:
  - server_name: "matrix.org"
suppress_key_server_warning: true

enable_registration: false
password_config:
  enabled: false

admin_contact: 'mailto:${ADMIN_EMAIL}'

experimental_features:
  msc3861:
    enabled: true
    issuer: http://synapse-mass-authentication-service:8080
    client_id: 0000000000000000000SYNAPSE
    client_auth_method: client_secret_basic
    client_secret: "${SYNAPSE_MAS_SECRET}"
    admin_token: "${SYNAPSE_API_ADMIN_TOKEN}"
    account_management_url: "${KEYCLOAK_FQDN}/realms/${KEYCLOAK_REALM_IDENTIFIER}/account"

app_service_config_files:
  - /bridges/whatsapp-registration.yaml
  - /bridges/telegram-registration.yaml
  - /bridges/discord-registration.yaml
  - /bridges/slack-registration.yaml
```

```yaml
# /data/config/db.yaml
database:
  name: psycopg2
  args:
    user: ${POSTGRES_SYNAPSE_USER}
    password: ${POSTGRES_SYNAPSE_PASSWORD}
    database: ${POSTGRES_SYNAPSE_DB}
    host: postgres-synapse
    port: 5432
    cp_min: 5
    cp_max: 10
  allow_unsafe_locale: true
```

```yaml
# /data/config/email.yaml
email:
  smtp_host: "${SMTP_HOST}"
  smtp_port: ${SMTP_PORT}
  smtp_user: "${SMTP_USER}"
  smtp_pass: "${SMTP_PASSWORD}"
  require_transport_security: ${SMTP_REQUIRE_TRANSPORT_SECURITY}
  notif_from: "${SMTP_NOTIFY_FROM}"
  app_name: "${SYNAPSE_FRIENDLY_SERVER_NAME}"
```

### Key Configuration Options Explained

#### `server_name`

The domain that appears in Matrix IDs: `@user:server_name`. This is set once at first startup and **can never be changed**. It does not need to be the hostname where Synapse actually runs -- federation discovery (`.well-known`, SRV records) handles the mapping from `server_name` to the actual network address. See [Federation](#5-federation).

#### `listeners`

Defines what HTTP endpoints Synapse exposes:

```yaml
listeners:
  - port: 8008
    type: http
    bind_addresses: ['0.0.0.0']
    x_forwarded: true       # Trust X-Forwarded-For headers (required behind a reverse proxy)
    resources:
      - names: [client, federation]
        compress: false      # Default; do not gzip responses
```

- `client` enables the Client-Server API (`/_matrix/client/...`)
- `federation` enables the Server-Server API (`/_matrix/federation/...`)
- `compress` is off by default. Enabling it can reduce bandwidth but adds CPU overhead; typically the reverse proxy handles compression.

You can also define separate listeners on different ports for client and federation traffic. This is useful for restricting federation to a specific interface or applying different rate limits. In our deployment, both share port 8008 behind nginx.

Additional resource types:

- `consent` -- the user consent/terms page
- `metrics` -- Prometheus metrics endpoint (add `metrics` to names and set `type: metrics` on a separate listener)
- `replication` -- for worker-based deployments (inter-process communication)
- `health` -- a simple health check endpoint

#### `x_forwarded: true`

This tells Synapse to trust the `X-Forwarded-For` header to determine the client's real IP address. **This must be `true` when Synapse is behind a reverse proxy** (nginx in our case), and **must be `false` when Synapse is directly exposed** (otherwise clients can spoof their IP).

#### `report_stats`

Whether to send anonymous usage statistics to matrix.org. We set this to `False`.

#### `logging`

Our config uses the simplified inline logging format:

```yaml
logging:
  - module: synapse.storage.SQL
    level: INFO
```

This sets the SQL storage module's log level to INFO. For more granular control, you can point Synapse at a full Python `logging.config` file:

```yaml
log_config: "/data/log.config"
```

The log config file uses Python's `dictConfig` format and can route different modules to different files, set formatters, add handlers, etc. The default Synapse log config writes to stdout (which Docker captures).

Common modules to adjust:

| Module | What it logs |
|---|---|
| `synapse.storage.SQL` | Database queries |
| `synapse.federation` | Federation traffic |
| `synapse.handlers.federation` | Federation event handling |
| `synapse.state` | State resolution |
| `synapse.http.server` | Incoming HTTP requests |
| `synapse.access` | Access log (request/response pairs) |

#### `trusted_key_servers`

When Synapse encounters a signing key from a remote server that it does not already have cached, it needs to verify that key. Rather than fetching it directly from the remote server (which could be compromised), it can ask a **trusted key server** -- a notary -- to vouch for the key.

```yaml
trusted_key_servers:
  - server_name: "matrix.org"
suppress_key_server_warning: true
```

`matrix.org` is the default notary. `suppress_key_server_warning` silences the startup warning about trusting matrix.org as a key notary. If you want to run fully independent of matrix.org, you can remove this, but you lose a layer of key verification.

#### `password_config`

```yaml
password_config:
  enabled: false
```

This disables Synapse's built-in password authentication entirely. In our deployment, **all authentication is delegated to MAS via MSC3861**. If password auth were enabled alongside MSC3861, you would have two conflicting authentication systems. See [MSC3861 / OIDC Native](#8-msc3861--oidc-native) and [03 -- Authentication](03-authentication.md).

#### `app_service_config_files`

Lists the registration YAML files for each Application Service (bridge). These files are generated by the bridges at init time and mounted into Synapse's container via the `bridge-registrations` shared volume. See [05 -- Bridges](05-bridges.md) for the full story.

```yaml
app_service_config_files:
  - /bridges/whatsapp-registration.yaml
  - /bridges/telegram-registration.yaml
  - /bridges/discord-registration.yaml
  - /bridges/slack-registration.yaml
```

Each registration file defines:
- The bridge's unique ID and token
- The URL where Synapse can reach the bridge
- Namespace reservations (which user IDs, room aliases, and room IDs the bridge "owns")

#### Caching

Synapse relies heavily on in-memory caches. The key settings (not in our minimal config, but important for tuning):

```yaml
# Global cache factor: multiplier for all cache sizes. Default is 0.5.
# Setting to 1.0 doubles all caches; 2.0 quadruples them.
caches:
  global_factor: 0.5
  per_cache_factors:
    get_event_cache: 2.0       # Events cache is the most impactful
    get_users_in_room: 1.5     # Room membership lookups
  expire_caches: true
  cache_entry_ttl: 30m         # How long entries stay in cache
  sync_response_cache_duration: 2m

# Legacy setting (still works, but `caches` section is preferred):
event_cache_size: 10K
```

The event cache is the single most important cache in Synapse. It stores deserialized event objects and is hit on virtually every operation. If your server feels slow, increasing `event_cache_size` or the `get_event_cache` factor is the first thing to try -- at the cost of more RAM.

Common per-cache factors to tune:

| Cache | Impact | Default Size |
|---|---|---|
| `get_event_cache` | Every event lookup | 10K * global_factor |
| `_get_state_groups_from_groups` | State resolution | Varies |
| `get_users_in_room` | Presence, push evaluation | Varies |
| `get_room_summary` | Room directory, space hierarchy | Varies |
| `_get_joined_profile_from_event_id` | Display name/avatar in events | Varies |

Synapse exposes cache hit/miss rates via Prometheus metrics (`synapse_util_caches_cache_*`). Monitoring these is the best way to decide what to tune.

---

## 4. Database

### PostgreSQL vs SQLite

Synapse supports two database backends:

- **SQLite** -- Zero-config, single-file database. Used for development and tiny personal servers. **Not suitable for any real deployment.**
- **PostgreSQL** -- Full relational database. Required for any deployment with more than one or two users, and mandatory for worker-based deployments.

Our deployment uses PostgreSQL 15 (`postgres:15` Docker image) with a dedicated container (`postgres-synapse`).

The database backend is configured in `db.yaml`:

```yaml
database:
  name: psycopg2          # PostgreSQL via psycopg2 driver
  args:
    user: synapse_user
    password: secret
    database: synapse
    host: postgres-synapse
    port: 5432
    cp_min: 5              # Minimum connection pool size
    cp_max: 10             # Maximum connection pool size
  allow_unsafe_locale: true
```

`name: psycopg2` tells Synapse to use the `psycopg2` Python library for PostgreSQL. The alternative is `name: sqlite3` for SQLite.

`allow_unsafe_locale: true` suppresses Synapse's check that the PostgreSQL database is using a `C` locale. Synapse prefers `C` locale for deterministic string ordering (important for pagination). If your database uses a different locale (common in default Postgres Docker images), this flag tells Synapse to proceed anyway. For a self-hosted deployment this is usually fine, but be aware that pagination ordering might be locale-dependent.

### Schema and Migrations

Synapse manages its own database schema. On first startup, it creates all tables. On upgrades, it runs **delta migrations** automatically. These are SQL scripts and Python migration scripts stored in `synapse/storage/schema/` in the Synapse source tree.

Migrations are versioned. The current schema version is stored in the `schema_version` table. When Synapse starts, it checks the current version and runs any pending deltas.

**Important operational note:** Synapse upgrades can trigger schema migrations that take significant time on large databases. Always check the release notes before upgrading. Some migrations (e.g., adding indexes to the `events` table) can lock tables and cause downtime.

### Key Tables

Understanding Synapse's database schema helps you reason about storage growth and performance.

#### `events`

The most important table. Every Matrix event (messages, state changes, reactions, redactions) is a row in `events`.

| Column | Purpose |
|---|---|
| `event_id` | Globally unique event identifier |
| `room_id` | Which room this event belongs to |
| `type` | Event type (e.g., `m.room.message`, `m.room.member`) |
| `sender` | User who created the event |
| `origin_server_ts` | Timestamp from the originating server |
| `depth` | Depth in the DAG |
| `stream_ordering` | Monotonically increasing sequence for this server's ordering |

The actual JSON content is in the `event_json` table (joined by `event_id`). This split is a performance optimization -- the `events` table has many indexes for querying, while `event_json` stores the potentially large JSON blobs.

#### `state_groups` and `state_groups_state`

As discussed in [Core Architecture](#2-core-architecture), state groups are snapshots of room state.

- `state_groups` -- One row per state group (id, room_id, event_id)
- `state_groups_state` -- The actual state entries (state_group, type, state_key, event_id)
- `state_group_edges` -- Parent-child relationships for delta encoding

These tables grow very quickly and are often the largest in the database. The `state_groups_state` table in particular can be many times larger than the `events` table. The Synapse project has a tool called `synapse_auto_compressor` that compresses state group chains to reduce this table's size.

#### `room_memberships`

Tracks which users are in which rooms:

| Column | Purpose |
|---|---|
| `event_id` | The `m.room.member` event |
| `user_id` | The user |
| `room_id` | The room |
| `membership` | One of: `join`, `invite`, `leave`, `ban`, `knock` |

#### `room_stats_current` and `room_stats_historical`

Aggregate statistics about rooms (member count, event count). Used by the admin API and room directory.

#### `devices` and `e2e_device_keys_json`

End-to-end encryption key storage. Each user's device keys are stored here. The `e2e_room_keys` table stores server-side key backups.

#### `receipts_linearized` and `receipts_graph`

Read receipts. `receipts_linearized` stores them in stream order (for efficient `/sync` responses); `receipts_graph` stores them in DAG order (for federation).

### How Data Grows Over Time

Growth patterns for a typical deployment:

1. **Early life (0--6 months):** Database is small (under 1GB). Most storage is media.
2. **Active bridges (6--12 months):** If bridges are active, event volume accelerates. WhatsApp and Telegram groups can generate thousands of events per day. The `events` and `state_groups_state` tables grow fastest.
3. **Mature deployment (1+ years):** The database can reach tens of gigabytes. `state_groups_state` is typically 40--60% of the total. `event_json` is 20--30%. Indexes are 10--20%.

Mitigation strategies:

- **Purge history** -- Use the Admin API to delete old events from rooms you control. See [Admin API](#7-admin-api).
- **State compressor** -- Run `synapse_auto_compressor` to reduce `state_groups_state` bloat.
- **Regular VACUUM** -- PostgreSQL needs periodic `VACUUM ANALYZE` to reclaim dead tuples and update query planner statistics.
- **Media cleanup** -- Purge remote media cache periodically.

---

## 5. Federation

Federation is what makes Matrix decentralized. Any homeserver can communicate with any other homeserver, and users on different servers can participate in the same rooms. This section explains how that works under the hood.

### Server Discovery

When Synapse needs to contact another Matrix server (e.g., `example.com`), it needs to figure out what host and port to actually connect to. The discovery process follows a specific order:

#### Step 1: .well-known

Synapse makes an HTTPS request to:

```
https://example.com/.well-known/matrix/server
```

If this returns a JSON response:

```json
{
    "m.server": "matrix.example.com:8448"
}
```

...then Synapse connects to `matrix.example.com` on port `8448`.

#### Step 2: SRV Records

If `.well-known` is not available, Synapse looks up the DNS SRV record:

```
_matrix-fed._tcp.example.com
```

(Historically `_matrix._tcp.example.com`, but `_matrix-fed` is the current standard.)

If an SRV record exists, Synapse connects to the specified host and port.

#### Step 3: Direct Connection

If neither `.well-known` nor SRV records exist, Synapse attempts to connect to `example.com` on port `8448` directly.

#### Our Deployment

In our deployment, the external reverse proxy (Coolify/nginx on the Hetzner server -- see [04 -- Deployment Architecture](04-deployment-architecture.md)) handles TLS termination. The `.well-known/matrix/server` response points to wherever our Synapse is externally reachable. Inside the Docker network, services communicate directly (e.g., `http://synapse:8008`).

### Signing Keys

Every Matrix homeserver has an **Ed25519 signing key**. This key is used to sign every event the server produces. When another server receives an event, it verifies the signature to confirm the event actually came from the claimed origin.

Key management:

- The signing key is stored in `${server_name}.signing.key` in the keys directory (`--keys-directory /data` in our deployment).
- Synapse generates the key on first startup.
- The key can be rotated, but the old key must be kept in `old_signing_keys` in the config so that previously signed events can still be verified.
- **Losing the signing key is catastrophic.** All events signed by it become unverifiable. This is why `synapse-data` is a persistent Docker volume.

The public part of the signing key is served at:

```
GET /_matrix/key/v2/server
```

Other servers fetch this to verify signatures. The response includes the key, its validity period, and is itself signed by the key.

### Event Authorization Rules

When a federated event arrives, Synapse does not just blindly accept it. Every event is checked against **authorization rules** defined by the spec. These rules depend on the event type:

- **`m.room.create`** -- Must be the first event in the room.
- **`m.room.member`** -- The most complex rules. Whether a user can join, invite, kick, or ban depends on power levels, join rules, membership status, and more.
- **`m.room.power_levels`** -- Can only be changed by someone with sufficient power level.
- **Generic state events** -- Sender must have the required power level for that event type.
- **Generic events** -- Sender must be joined to the room.

If an event fails authorization, Synapse rejects it. This is how the protocol enforces access control in a decentralized system -- every server independently enforces the same rules.

### Backfill

When a user joins a room that already exists on other servers, Synapse needs to fetch historical events to display a reasonable amount of history. This process is called **backfill**.

Synapse sends a request to a server already in the room:

```
GET /_matrix/federation/v1/backfill/{roomId}?v={eventId}&limit=100
```

The remote server responds with up to `limit` events going backwards from the specified event. Synapse persists these events and their state, making them available to local clients.

Backfill is lazy -- Synapse only fetches history as clients scroll back. It does not eagerly download the entire room history.

### State Resolution v2

When two servers produce events concurrently, the DAG forks. When the fork is resolved (a new event references both tips), Synapse must determine the "correct" state using the state resolution algorithm.

State Resolution v2 (used in room versions 3 and above, which is all modern rooms) works in these phases:

1. **Unconflicted state** -- Any state event present in all forks with the same event ID is accepted without question.
2. **Auth difference** -- Compute the set of auth events (power levels, membership, etc.) that differ between forks.
3. **Topological sort of auth events** -- Order auth events by their position in the auth chain. Events that are "more authoritative" (earlier in the chain) take precedence.
4. **Mainline ordering** -- For each conflicted state event, determine which fork is "closest" to the power level event's mainline (the chain of power level events). This is the key innovation of v2 -- it uses the power level event chain as an anchor.
5. **Lexicographic tiebreaker** -- If all else is equal, the event with the lexicographically smaller event ID wins. This ensures determinism.

The result is that every server, given the same DAG, computes the same state. No coordination required.

---

## 6. Performance Tuning

### Caching Strategies

Synapse's in-memory caches are the first line of defense against slow performance. The key levers:

```yaml
caches:
  global_factor: 1.0           # Default is 0.5. Doubling this doubles all caches.
  per_cache_factors:
    get_event_cache: 2.0       # Events are the most frequently accessed objects
  expire_caches: true
  cache_entry_ttl: 30m
```

**Monitoring cache effectiveness** is essential. If you enable Prometheus metrics:

```yaml
listeners:
  - port: 9090
    type: metrics
    bind_addresses: ['0.0.0.0']
```

Then scrape `synapse_util_caches_cache_hits` and `synapse_util_caches_cache_misses` to compute hit rates. Caches with low hit rates may need larger sizes; caches with very high hit rates may be overprovisioned.

The environment variable `SYNAPSE_CACHE_FACTOR` is an alternative way to set `global_factor`. This is useful in Docker deployments where you want to tune without changing config files:

```yaml
environment:
  SYNAPSE_CACHE_FACTOR: "1.0"
```

### Database Tuning

#### Connection Pools

Our config uses:

```yaml
database:
  args:
    cp_min: 5    # Minimum connections kept open
    cp_max: 10   # Maximum connections allowed
```

These are Twisted's `adbapi.ConnectionPool` parameters. Guidelines:

- `cp_min` should be high enough that normal workload does not need to open new connections (connection setup has overhead).
- `cp_max` should be high enough to handle peak load without queuing, but not so high that it overwhelms PostgreSQL. PostgreSQL's `max_connections` (default 100) must be higher than the sum of all `cp_max` values across all Synapse processes.
- For a single-process Synapse, `cp_min: 5` and `cp_max: 10` is a solid starting point.

#### PostgreSQL Configuration

On the PostgreSQL side, key settings to tune (in `postgresql.conf` or as Docker environment variables):

```
# Memory
shared_buffers = 256MB          # 25% of available RAM, up to ~1GB
effective_cache_size = 768MB    # 75% of available RAM
work_mem = 16MB                 # Per-sort/hash operation
maintenance_work_mem = 128MB    # For VACUUM, CREATE INDEX

# WAL
wal_buffers = 16MB
checkpoint_completion_target = 0.9
max_wal_size = 1GB

# Query planner
random_page_cost = 1.1          # For SSD storage
effective_io_concurrency = 200  # For SSD storage

# Connections
max_connections = 100           # Must be > sum of all cp_max values
```

For Docker deployments, pass these via the Postgres container's command:

```yaml
postgres-synapse:
  image: postgres:15
  command: >
    postgres
    -c shared_buffers=256MB
    -c effective_cache_size=768MB
    -c work_mem=16MB
    -c maintenance_work_mem=128MB
    -c random_page_cost=1.1
```

#### Periodic Maintenance

```sql
-- Run weekly or after heavy activity:
VACUUM ANALYZE;

-- For heavily bloated tables, full vacuum (locks table):
VACUUM FULL state_groups_state;

-- Reindex if performance degrades over time:
REINDEX DATABASE synapse;
```

### Media Storage

Media is stored on the filesystem under `/media_store` (mounted as `synapse-media` Docker volume in our deployment). Growth is driven by:

- **Local uploads** -- Media uploaded by local users
- **Remote media cache** -- Media from federated servers, cached locally

To manage growth:

```yaml
# In homeserver.yaml (not in our minimal config, but available):
max_upload_size: 50M            # Maximum upload size
media_store_path: /media_store  # Where to store files

# Remote media cache retention:
media_retention:
  remote_media_lifetime: 90d    # Purge remote media older than 90 days
```

You can also use the Admin API to purge remote media on demand. See [Admin API](#7-admin-api).

### Synapse Workers

For deployments that outgrow a single process, Synapse can split into multiple **worker** processes. Each worker handles a subset of the workload, and they communicate via a Redis pub/sub channel (or TCP replication in older setups).

Worker types and what they offload:

| Worker Type | What It Does | When You Need It |
|---|---|---|
| `synapse.app.generic_worker` | Handles any HTTP endpoint (configurable) | When a single process cannot keep up with client requests |
| `federation_sender` | Sends events to remote servers | When federation sending creates backpressure |
| `media_repository` | Handles media upload/download/thumbnailing | When media requests consume too much CPU/memory |
| `pusher` | Sends push notifications | When push evaluation is slow |
| `appservice` | Sends events to application services (bridges) | When bridge traffic is heavy |
| `background_worker` | Runs background database tasks | When background tasks interfere with request handling |
| `stream_writer` | Handles specific write streams (events, typing, receipts, etc.) | Advanced: for very high write throughput |

A typical worker deployment:

```
                    +--> generic_worker (client API)
                    |
Load Balancer ----> +--> generic_worker (federation API)
                    |
                    +--> media_repository

Main process (synapse.app.homeserver)
    |
    +--> federation_sender
    +--> pusher
    +--> appservice
    +--> background_worker

All connected via Redis
```

**Our deployment does not use workers.** We run a single `synapse.app.homeserver` process. For a small-to-medium self-hosted server (dozens of users, a few active bridges), this is sufficient. Workers add significant operational complexity -- each worker needs its own config, its own listener, and the load balancer must route requests correctly.

If you find you need workers, the migration path is:

1. Set up Redis
2. Configure the main process with `instance_map` and `stream_writers`
3. Create worker config files
4. Configure your reverse proxy to route specific endpoints to specific workers
5. Monitor and adjust

---

## 7. Admin API

Synapse exposes a powerful Admin API under `/_synapse/admin/`. These endpoints require authentication with an admin user's access token or (in our MSC3861 setup) the `admin_token` configured in the MAS integration.

### Authentication for Admin API

In our deployment (MSC3861), the admin token is set via:

```yaml
experimental_features:
  msc3861:
    admin_token: "${SYNAPSE_API_ADMIN_TOKEN}"
```

Use it in requests:

```bash
curl -H "Authorization: Bearer ${SYNAPSE_API_ADMIN_TOKEN}" \
    "https://your-server/_synapse/admin/v2/users"
```

See [06 -- Operations](06-operations.md) for practical admin recipes.

### Key Endpoints

#### User Management

```bash
# List all users (paginated)
GET /_synapse/admin/v2/users?from=0&limit=100&guests=false

# Get details for a specific user
GET /_synapse/admin/v2/users/@alice:example.com

# Create or modify a user
PUT /_synapse/admin/v2/users/@alice:example.com
{
    "displayname": "Alice",
    "admin": false,
    "deactivated": false
}

# Deactivate a user (irreversible without database intervention)
POST /_synapse/admin/v1/deactivate/@alice:example.com
{
    "erase": true    # Also remove display name and avatar
}

# List a user's joined rooms
GET /_synapse/admin/v1/users/@alice:example.com/joined_rooms

# List a user's devices
GET /_synapse/admin/v2/users/@alice:example.com/devices

# Query a user's media uploads
GET /_synapse/admin/v1/users/@alice:example.com/media

# Reset rate limiting for a user
DELETE /_synapse/admin/v1/users/@alice:example.com/override_ratelimit
```

#### Room Management

```bash
# List all rooms (paginated, sortable)
GET /_synapse/admin/v1/rooms?from=0&limit=100&order_by=joined_members

# Get room details
GET /_synapse/admin/v1/rooms/{room_id}

# Get room members
GET /_synapse/admin/v1/rooms/{room_id}/members

# Get room state
GET /_synapse/admin/v1/rooms/{room_id}/state

# Delete a room (kicks all local users, optionally blocks re-creation)
DELETE /_synapse/admin/v2/rooms/{room_id}
{
    "block": true,           # Prevent room from being re-created
    "purge": true,           # Delete all events from the database
    "force_purge": true      # Purge even if Synapse has failed to reach remote servers
}

# Make a user join a room (admin force-join)
POST /_synapse/admin/v1/join/{room_id}
{
    "user_id": "@admin:example.com"
}
```

#### Purging History

Purging removes old events from the database to reclaim storage. This is one of the most important admin operations for long-running servers.

```bash
# Purge history up to a specific event (keeps that event and newer)
POST /_synapse/admin/v1/purge_history/{room_id}
{
    "purge_up_to_event_id": "$event_id"
}

# Purge history up to a specific timestamp
POST /_synapse/admin/v1/purge_history/{room_id}
{
    "purge_up_to_ts": 1672531200000,     # Unix timestamp in milliseconds
    "delete_local_events": true           # Also delete events sent by local users
}

# Check purge status (returns a purge_id from the above call)
GET /_synapse/admin/v1/purge_history_status/{purge_id}
```

**Note:** Purging is an asynchronous operation. Large purges can take minutes to hours and generate significant database I/O. Run purges during low-activity periods and monitor database performance.

After purging, run `VACUUM ANALYZE` on PostgreSQL to reclaim disk space.

#### Server Notices

Server notices are messages from the server itself to users, appearing in a special room.

```bash
# Send a server notice to a user
POST /_synapse/admin/v1/send_server_notice
{
    "user_id": "@alice:example.com",
    "content": {
        "msgtype": "m.text",
        "body": "Server maintenance scheduled for tonight at 22:00 UTC."
    }
}
```

Server notices require additional configuration in `homeserver.yaml`:

```yaml
server_notices:
  system_mxid_localpart: notices     # Creates @notices:example.com
  system_mxid_display_name: "Server Notices"
  room_name: "Server Notices"
```

#### Media Admin

```bash
# List media in a room
GET /_synapse/admin/v1/room/{room_id}/media

# Delete a specific media item
DELETE /_synapse/admin/v1/media/{server_name}/{media_id}

# Delete media uploaded by a specific user
DELETE /_synapse/admin/v1/users/@alice:example.com/media

# Purge remote media cache (older than specified timestamp)
POST /_synapse/admin/v1/purge_media_cache?before_ts=1672531200000
```

#### Registration Tokens

If you need to allow limited registration without open registration:

```bash
# Create a registration token
POST /_synapse/admin/v1/registration_tokens/new
{
    "token": "my_secret_token",
    "uses_allowed": 10,
    "expiry_time": 1703980800000
}

# List all tokens
GET /_synapse/admin/v1/registration_tokens

# Delete a token
DELETE /_synapse/admin/v1/registration_tokens/{token}
```

#### Background Updates

After Synapse upgrades, schema migrations run as background updates. You can check their status:

```bash
# Check background update status
GET /_synapse/admin/v1/background_updates/status

# Response includes which updates are running and their progress
```

#### Federation Admin

```bash
# List all destinations (federated servers)
GET /_synapse/admin/v1/federation/destinations

# Get details for a specific destination (retry timing, failure count)
GET /_synapse/admin/v1/federation/destinations/{destination}

# Reset the retry timing for a destination (force immediate retry)
POST /_synapse/admin/v1/federation/destinations/{destination}/reset_connection
```

---

## 8. MSC3861 / OIDC Native

### What is MSC3861?

MSC3861 ("Delegating authentication to an OIDC provider") is a Matrix Spec Change that fundamentally reimagines how authentication works in Matrix. Instead of the homeserver managing passwords, tokens, and sessions directly, all authentication is delegated to an external OpenID Connect (OIDC) provider.

This is labeled as an **experimental feature** in Synapse (under `experimental_features`), but it is the strategic direction for Matrix authentication and is required for using MAS (Matrix Authentication Service).

### How Traditional Auth Works (Without MSC3861)

In traditional Synapse:

1. Client calls `POST /_matrix/client/v3/login` with username and password.
2. Synapse checks the password against its internal database (or an LDAP backend, or SSO).
3. Synapse generates an access token and returns it.
4. Client uses the access token for all subsequent requests.
5. Refresh is handled by Synapse internally (or not at all -- many clients use long-lived tokens).

The homeserver is the identity provider. It owns the password database, the session state, and the token lifecycle.

### How MSC3861 Changes Everything

With MSC3861 enabled:

1. Client discovers that the homeserver delegates auth (via `.well-known` or `GET /_matrix/client/v3/login`).
2. Client performs an OAuth 2.0 / OIDC flow with the **external OIDC provider** (MAS in our case).
3. MAS authenticates the user (which itself may delegate to Keycloak -- see [03 -- Authentication](03-authentication.md)).
4. MAS issues an access token and a refresh token.
5. Client uses the access token with Synapse.
6. **Synapse validates the token by calling MAS** (introspection) rather than checking its own database.
7. Token refresh is handled by the client calling MAS directly.

The critical change: **Synapse no longer owns authentication.** It becomes a "resource server" in OAuth 2.0 terminology, and MAS becomes the "authorization server."

### Our Configuration

```yaml
experimental_features:
  msc3861:
    enabled: true
    issuer: http://synapse-mass-authentication-service:8080
    client_id: 0000000000000000000SYNAPSE
    client_auth_method: client_secret_basic
    client_secret: "${SYNAPSE_MAS_SECRET}"
    admin_token: "${SYNAPSE_API_ADMIN_TOKEN}"
    account_management_url: "${KEYCLOAK_FQDN}/realms/${KEYCLOAK_REALM_IDENTIFIER}/account"
```

Breaking this down:

| Field | Purpose |
|---|---|
| `enabled: true` | Activates MSC3861 delegation |
| `issuer` | The OIDC issuer URL. Synapse fetches `{issuer}/.well-known/openid-configuration` to discover endpoints. Uses the internal Docker network URL because Synapse and MAS are in the same compose stack. |
| `client_id` | Synapse's client ID as registered with MAS. The `0000000000000000000SYNAPSE` value is MAS's conventional ID for the homeserver. |
| `client_auth_method` | How Synapse authenticates to MAS when making backend calls. `client_secret_basic` means HTTP Basic auth. |
| `client_secret` | The shared secret between Synapse and MAS. |
| `admin_token` | A token that grants Synapse admin access to MAS's compatibility API. This is the `matrix.secret` in MAS's config. |
| `account_management_url` | URL advertised to clients where users can manage their account. We point this directly to Keycloak's account management page. |

### What Gets Disabled

When MSC3861 is enabled, several Synapse features are automatically disabled or modified:

- **Password login** -- `/_matrix/client/v3/login` with `type: m.login.password` is rejected. (We also explicitly set `password_config.enabled: false` for clarity.)
- **Registration** -- `/_matrix/client/v3/register` is disabled. User provisioning happens through MAS/Keycloak.
- **Token management** -- Synapse's internal token tables are no longer used. Token validation goes through MAS's introspection endpoint.
- **Account management endpoints** -- Password change, email/phone binding, etc. are redirected to the `account_management_url`.
- **SSO endpoints** -- `/_matrix/client/v3/login/sso/*` are no longer served by Synapse.

### The Login/Logout/Refresh Flow

#### Login

```
Client                          nginx                   MAS                    Synapse
  |                               |                      |                       |
  |  GET /.well-known/matrix/client                      |                       |
  |------------------------------>|                      |                       |
  |  { "m.homeserver": ...,      |                      |                       |
  |    "org.matrix.msc2965.authentication":              |                       |
  |      { "issuer": "..." } }   |                      |                       |
  |<------------------------------|                      |                       |
  |                               |                      |                       |
  |  OIDC Authorization Code Flow with PKCE              |                       |
  |------------------------------------------------------>|                      |
  |                               |                      |                       |
  |  (MAS may redirect to Keycloak for actual login)     |                       |
  |                               |                      |                       |
  |  Access Token + Refresh Token |                      |                       |
  |<------------------------------------------------------|                      |
  |                               |                      |                       |
  |  API requests with Bearer token                      |                       |
  |------------------------------>|---------------------------------------------->|
  |                               |                      |                       |
  |                               |            Synapse introspects token with MAS |
  |                               |                      |<----------------------|
  |                               |                      |---------------------->|
  |                               |                      |                       |
  |  Response                     |                      |                       |
  |<------------------------------|<----------------------------------------------|
```

#### Logout

```bash
# Client calls the standard Matrix logout endpoint
POST /_matrix/client/v3/logout

# nginx routes this to MAS (not Synapse!) based on the routing rule:
# location ~ ^/_matrix/client/(.*)/(login|logout|refresh)
#     proxy_pass $mas_upstream;

# MAS revokes the token
```

This is why our nginx config routes `/login`, `/logout`, and `/refresh` to MAS instead of Synapse. MAS owns the token lifecycle.

#### Refresh

```bash
# Client calls the Matrix refresh endpoint
POST /_matrix/client/v3/refresh
{
    "refresh_token": "..."
}

# Also routed to MAS by nginx
# MAS validates the refresh token and issues a new access token
```

### The nginx Routing Pattern

The nginx configuration in our deployment is critical to MSC3861 working correctly:

```nginx
# Route login/logout/refresh to MAS
location ~ ^/_matrix/client/(.*)/(login|logout|refresh) {
    proxy_pass $mas_upstream;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}

# Route everything else to Synapse
location ~ ^(/|/_matrix|/_synapse/client) {
    proxy_pass $synapse_upstream;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Host $host;
    client_max_body_size 50M;
    proxy_http_version 1.1;
}
```

The order matters. The more specific `/login|logout|refresh` rule matches first, sending those requests to MAS. Everything else goes to Synapse. Without this routing, MSC3861 does not work -- clients would try to log in against Synapse, which would reject them.

### The .well-known Discovery for OIDC

Clients that support MSC2965 (OIDC-aware Matrix clients, like Element X) discover the auth configuration from `.well-known/matrix/client`:

```json
{
    "m.homeserver": {
        "base_url": "https://matrix.example.com"
    },
    "org.matrix.msc3575.proxy": {
        "url": "https://syncv3.example.com"
    },
    "org.matrix.msc2965.authentication": {
        "issuer": "https://auth.example.com/",
        "account": "https://auth.example.com/account"
    }
}
```

The `org.matrix.msc2965.authentication` block tells the client:

- `issuer` -- The OIDC issuer. The client fetches `{issuer}/.well-known/openid-configuration` to discover the authorization endpoint, token endpoint, etc.
- `account` -- Where to redirect the user for account management.

Our nginx config generates this `.well-known` response as a static HTML file at startup.

### Why Password Auth Must Be Disabled

If `password_config.enabled` were `true` alongside MSC3861, there would be a conflict:

- Synapse would advertise `m.login.password` as a supported login flow.
- Clients would attempt password login against Synapse.
- Synapse would try to validate passwords against its local database.
- But no local passwords exist (users are provisioned via MAS/Keycloak).
- Login would fail confusingly.

Setting `password_config.enabled: false` ensures Synapse only advertises OIDC-based login flows, which clients handle by redirecting to MAS.

### Implications for Bridges and Application Services

Bridges (WhatsApp, Telegram, Discord, Slack) use the **Application Service API**, which has its own authentication mechanism: the `as_token` and `hs_token` defined in the registration YAML files. This is unaffected by MSC3861.

When a bridge sends events to Synapse, it uses its `as_token` in the `Authorization` header. Synapse validates this against the registered application services, not against MAS. So bridges continue to work exactly as before.

However, if a bridge needs to make requests **on behalf of a user** (e.g., the bridge's puppet users), the user provisioning flow changes. With MSC3861, the bridge cannot create users via the old Synapse registration API. Instead, user provisioning happens through MAS's admin API, or (more commonly) through the application service API's ability to create virtual users in its reserved namespace.

### Operational Considerations

1. **MAS must be reachable.** If MAS goes down, Synapse cannot validate tokens. Existing requests will fail. This is a hard dependency.

2. **Internal vs. external URLs.** Our Synapse config uses the internal Docker URL for the issuer (`http://synapse-mass-authentication-service:8080`), while the `.well-known` advertises the external URL (`https://auth.example.com`). This is correct -- Synapse talks to MAS internally, clients talk to MAS externally.

3. **Admin API access.** The `admin_token` in the MSC3861 config gives Synapse the ability to call MAS's compatibility endpoints. It is also the token you use to call Synapse's own Admin API. Guard it carefully.

4. **Debugging auth issues.** If a user cannot log in, check:
   - Is MAS running? (`docker compose logs synapse-mass-authentication-service`)
   - Can Synapse reach MAS internally? (`curl http://synapse-mass-authentication-service:8080/.well-known/openid-configuration` from inside the Synapse container)
   - Does the `.well-known/matrix/client` response have the correct `issuer`?
   - Is the nginx routing sending `/login` to MAS?
   - Check MAS logs for OIDC flow errors.

---

## Quick Reference: File Paths in This Deployment

| Path | Container | Purpose |
|---|---|---|
| `/data/config/homeserver.yaml` | synapse | Core config (generated at startup) |
| `/data/config/db.yaml` | synapse | Database config (generated at startup) |
| `/data/config/email.yaml` | synapse | Email/SMTP config (generated at startup) |
| `/data/${server_name}.signing.key` | synapse | Ed25519 signing key |
| `/data/${server_name}.log.config` | synapse | Logging configuration (if present) |
| `/media_store/` | synapse | Uploaded and cached media files |
| `/bridges/*.yaml` | synapse | Bridge registration files (read-only mount) |
| `/data/config.yaml` | MAS | MAS configuration |

## Quick Reference: Synapse Startup Command

```bash
exec python -m synapse.app.homeserver \
    -c /data/config/homeserver.yaml \
    -c /data/config/db.yaml \
    -c /data/config/email.yaml \
    --keys-directory /data
```

---

> **Next:** [03 -- Authentication (MAS and Keycloak)](03-authentication.md) covers the authentication stack in depth -- how MAS works, how Keycloak integrates as an upstream IdP, and the full OIDC token lifecycle.
>
> **See also:**
> - [04 -- Deployment Architecture](04-deployment-architecture.md) for the Docker Compose setup, networking, and volume management
> - [05 -- Bridges](05-bridges.md) for how mautrix bridges register with Synapse
> - [06 -- Operations](06-operations.md) for day-to-day admin tasks, backup procedures, and troubleshooting

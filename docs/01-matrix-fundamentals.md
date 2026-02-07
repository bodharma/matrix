# Matrix Protocol Fundamentals

A deep-dive technical reference for understanding the Matrix protocol from the ground up. This document covers the protocol's design philosophy, core abstractions, federation model, encryption, APIs, and the broader ecosystem. It is written for experienced developers and system administrators who want to understand not just *what* Matrix does, but *why* it was designed the way it was.

**Document series:**

| # | Document | Scope |
|---|----------|-------|
| **01** | **Matrix Fundamentals** (this document) | Protocol concepts, federation, encryption, ecosystem |
| 02 | [Synapse Homeserver](02-synapse-homeserver.md) | Synapse internals, configuration, tuning, admin API |
| 03 | [Authentication](03-authentication.md) | MAS, Keycloak OIDC, token lifecycle, SSO flows |
| 04 | [Deployment Architecture](04-deployment-architecture.md) | Docker Compose topology, nginx routing, DNS, TLS |
| 05 | [Bridges](05-bridges.md) | mautrix bridges, appservice protocol, double puppeting |
| 06 | [Operations](06-operations.md) | Monitoring, backups, upgrades, troubleshooting |

---

## Table of Contents

- [1. What is Matrix](#1-what-is-matrix)
  - [1.1 Origin Story](#11-origin-story)
  - [1.2 The Problem Matrix Solves](#12-the-problem-matrix-solves)
  - [1.3 The Email Analogy](#13-the-email-analogy)
  - [1.4 The Matrix.org Foundation](#14-the-matrixorg-foundation)
- [2. Core Protocol Concepts](#2-core-protocol-concepts)
  - [2.1 Events: The Fundamental Unit](#21-events-the-fundamental-unit)
  - [2.2 Event Types](#22-event-types)
  - [2.3 State Events vs Timeline Events](#23-state-events-vs-timeline-events)
  - [2.4 Rooms: The Central Abstraction](#24-rooms-the-central-abstraction)
  - [2.5 Room IDs vs Room Aliases](#25-room-ids-vs-room-aliases)
  - [2.6 The Event DAG](#26-the-event-dag)
- [3. Federation](#3-federation)
  - [3.1 What Federation Means](#31-what-federation-means)
  - [3.2 Server Discovery](#32-server-discovery)
  - [3.3 Server-to-Server API](#33-server-to-server-api)
  - [3.4 Anatomy of a Federated Message](#34-anatomy-of-a-federated-message)
  - [3.5 Eventually Consistent Replication](#35-eventually-consistent-replication)
  - [3.6 State Resolution](#36-state-resolution)
- [4. Identity](#4-identity)
  - [4.1 User IDs](#41-user-ids)
  - [4.2 Device IDs](#42-device-ids)
  - [4.3 Access Tokens](#43-access-tokens)
  - [4.4 Identity Across Federation](#44-identity-across-federation)
  - [4.5 Identity Servers](#45-identity-servers)
- [5. Rooms Deep-Dive](#5-rooms-deep-dive)
  - [5.1 Room Creation](#51-room-creation)
  - [5.2 Room Versions](#52-room-versions)
  - [5.3 Join Rules](#53-join-rules)
  - [5.4 Power Levels](#54-power-levels)
  - [5.5 Room State](#55-room-state)
  - [5.6 State Resolution When Servers Disagree](#56-state-resolution-when-servers-disagree)
- [6. End-to-End Encryption (E2EE)](#6-end-to-end-encryption-e2ee)
  - [6.1 Olm and Megolm](#61-olm-and-megolm)
  - [6.2 Key Management](#62-key-management)
  - [6.3 Device Verification](#63-device-verification)
  - [6.4 Cross-Signing](#64-cross-signing)
  - [6.5 Key Backup](#65-key-backup)
  - [6.6 Why E2EE Makes Bridges Complex](#66-why-e2ee-makes-bridges-complex)
- [7. Client-Server API](#7-client-server-api)
  - [7.1 REST API Overview](#71-rest-api-overview)
  - [7.2 The Sync Endpoint](#72-the-sync-endpoint)
  - [7.3 Room Listing and Sending Messages](#73-room-listing-and-sending-messages)
  - [7.4 Pagination](#74-pagination)
  - [7.5 Lazy-Loading Members](#75-lazy-loading-members)
- [8. Sliding Sync (MSC3575)](#8-sliding-sync-msc3575)
  - [8.1 Why /sync is Slow at Scale](#81-why-sync-is-slow-at-scale)
  - [8.2 How Sliding Sync Works](#82-how-sliding-sync-works)
  - [8.3 The Sliding Sync Proxy](#83-the-sliding-sync-proxy)
  - [8.4 Native Sliding Sync](#84-native-sliding-sync)
- [9. Matrix Clients](#9-matrix-clients)
  - [9.1 Element: The Reference Client Family](#91-element-the-reference-client-family)
  - [9.2 Alternative Clients](#92-alternative-clients)
  - [9.3 Client Feature Comparison](#93-client-feature-comparison)
- [10. The Matrix Ecosystem](#10-the-matrix-ecosystem)
  - [10.1 Homeserver Implementations](#101-homeserver-implementations)
  - [10.2 Bridges](#102-bridges)
  - [10.3 Bots](#103-bots)
  - [10.4 Widgets and Integration Managers](#104-widgets-and-integration-managers)
  - [10.5 The Spec Process: MSCs](#105-the-spec-process-mscs)

---

## 1. What is Matrix

### 1.1 Origin Story

Matrix was born in 2014 inside Amdocs, an Israeli-American telecommunications software company. A team led by Matthew Hodgson and Amandine Le Pape had been working on communications technology and grew frustrated with the state of messaging. Every platform was a silo. Every protocol was proprietary. If you wanted to talk to someone on WhatsApp, you needed WhatsApp. If they moved to Signal, you needed Signal. There was no interoperability, no user choice, and no data sovereignty.

The team initially operated under the name Vector Creations (later renamed to New Vector, and eventually Element). They released the first Matrix specification and the first homeserver implementation -- Synapse, written in Python on the Twisted async framework -- in September 2014, as a fully open project from day one. The spec was published under the Apache 2.0 license. The reference implementations were open-source. The goal was explicit: create an open, decentralized communication standard that anyone could implement, just as HTTP is a standard that anyone can implement for the web.

The pace of adoption was steady. By 2018, the protocol had matured enough that the French government adopted it (under the name Tchap) for secure governmental communication. The German military (Bundeswehr) followed with BwMessenger. NATO evaluated it. The protocol had proven itself not just as an interesting academic exercise but as a production-grade system trusted by nation-states for sensitive communications.

Matrix reached version 1.0 of its specification in June 2019, marking its first stable release. Development has continued through spec versions 1.1 through 1.12 (as of early 2026), each bundling improvements that went through the MSC (Matrix Spec Change) proposal process.

### 1.2 The Problem Matrix Solves

Matrix addresses three interrelated problems:

**Fragmentation.** Real-time communication is balkanized across dozens of incompatible platforms -- WhatsApp, Signal, Telegram, Slack, Discord, Teams, iMessage, and countless others. Each one owns your social graph, your message history, and your identity. Switching platforms means losing everything. This is not an accident; it is the deliberate product of network effects leveraged as competitive moats. Matrix breaks this by defining an open standard that any server and any client can implement, allowing interoperability across implementations. Where the standard alone is not enough, bridges (covered in [Section 10.2](#102-bridges) and in detail in [Bridges](05-bridges.md)) connect Matrix to these siloed platforms, concentrating your conversations in one place.

**Vendor lock-in.** When your communication depends on a single provider, that provider has enormous power over you. They can change terms of service, raise prices, shut down, get acquired, or be compelled by a government to hand over your data. With Matrix, you can run your own server. Your data lives on your infrastructure. If you dislike your client software, switch to a different client -- there are dozens. If you dislike your server software, migrate to a different homeserver implementation. The protocol, not any single company, is the constant.

**Surveillance and data sovereignty.** Centralized communication platforms are high-value targets for surveillance, whether by governments, corporations, or malicious actors. Even platforms that claim end-to-end encryption often control the key distribution mechanism, creating a potential point of compromise. Matrix provides end-to-end encryption with keys controlled by users, not servers. And because you can run your own server, your metadata -- who talks to whom, when, from where -- stays under your control.

These are the reasons we run our own deployment rather than relying on the public matrix.org homeserver. Our infrastructure, as documented in [Deployment Architecture](04-deployment-architecture.md), gives us full control over our data, our authentication (via Keycloak -- see [Authentication](03-authentication.md)), and our integrations.

### 1.3 The Email Analogy

The most useful mental model for understanding Matrix is email. Consider how email works:

- You choose a provider (Gmail, Fastmail, your own Postfix server -- it does not matter).
- Your address includes both your name and your server: `alice@example.com`.
- You can send messages to anyone on any server. Gmail users can email Fastmail users.
- Servers communicate using standardized protocols (SMTP for sending, IMAP for retrieval).
- No single entity controls email. There is no "email company."

Matrix works the same way:

- You choose a homeserver (matrix.org, your own Synapse instance -- it does not matter).
- Your address includes both your name and your server: `@alice:example.com`.
- You can join rooms and message users on any server.
- Servers communicate using the Matrix federation protocol (the Server-to-Server API over HTTPS).
- No single entity controls Matrix.

The analogy is deliberately imperfect in one crucial way: email is fundamentally a point-to-point message delivery system, while Matrix is a **conversation replication system**. In email, messages are delivered and then live on the recipient's server. In Matrix, events are replicated across all servers whose users participate in a room. Every server with at least one member in a room holds a complete copy of that room's history. This is closer to how Git repositories work than how email works -- every participant has a full clone -- and it is a fundamental design decision that shapes everything about how federation, state resolution, and consistency work.

### 1.4 The Matrix.org Foundation

In 2018, the Matrix.org Foundation was established as a UK Community Interest Company (CIC) -- a legal structure that exists to serve the community rather than shareholders. The Foundation is the neutral custodian of the Matrix specification. Its responsibilities include:

- **Maintaining the spec.** The Foundation owns the Matrix specification and governs changes to it through the MSC (Matrix Spec Change) process (detailed in [Section 10.5](#105-the-spec-process-mscs)).
- **Guarding the protocol's openness.** The Foundation ensures Matrix remains an open standard that no single company can co-opt.
- **Operating matrix.org.** The Foundation runs the matrix.org homeserver, which serves as the default for users who do not run their own server. This is a convenience, not a requirement -- matrix.org has no special status in the protocol.
- **Managing the Spec Core Team (SCT).** The SCT reviews and approves changes to the spec, holds the matrix.org domain and trademarks, and publishes the server's signing keys.

It is important to distinguish between Element (the company, which employs most Matrix core developers and builds commercial products like Element Web, Element X, and Synapse) and the Matrix.org Foundation (the nonprofit that owns the spec). They are separate entities with aligned but distinct interests. Element funds much of Matrix development, but the spec belongs to the Foundation. This separation is intentional -- it prevents any single company from controlling the protocol, just as the IETF is separate from any company that implements its RFCs.

---

## 2. Core Protocol Concepts

### 2.1 Events: The Fundamental Unit

Everything in Matrix is an event. A message is an event. Joining a room is an event. Changing a room's name is an event. Kicking a user is an event. Setting encryption on a room is an event. Reacting with an emoji is an event. If something happens in Matrix, it is represented as a JSON object called an event.

Here is a concrete example:

```json
{
  "type": "m.room.message",
  "room_id": "!jEsUZKDJdhlrceRyVU:example.org",
  "sender": "@alice:example.org",
  "event_id": "$YUwRidLecu:example.org",
  "origin_server_ts": 1432735824653,
  "content": {
    "msgtype": "m.text",
    "body": "Hello, world!"
  },
  "unsigned": {
    "age": 1234
  }
}
```

Key fields:

| Field | Purpose |
|-------|---------|
| `type` | Classifies the event (what kind of thing happened). Determines how the `content` is interpreted. |
| `room_id` | The room this event belongs to. Format: `!opaque_id:originating_server`. |
| `sender` | The user who created the event. Format: `@localpart:server`. |
| `event_id` | A globally unique identifier. In room versions 1-3: `$opaque:server`. In v4+: `$url_safe_base64_hash`. |
| `origin_server_ts` | Timestamp from the originating server (milliseconds since Unix epoch). |
| `content` | The payload, whose structure depends on the `type`. |
| `unsigned` | Metadata added by the local server, not part of the signed event. Contains things like `age` (milliseconds since the event) and `transaction_id`. |

**Immutability is the core design principle.** Once created and signed by the originating server, an event cannot be modified. You cannot edit a message in the traditional sense -- instead, you send a new event that references the original (an `m.room.message` with an `m.relates_to` field of relation type `m.replace`). You cannot delete a message -- you send a *redaction* event (`m.room.redaction`) that instructs servers and clients to strip the content from the original event while preserving the event's structural presence in the DAG.

This immutability is not an implementation limitation; it is a deliberate design choice that enables:
- **Cryptographic verification.** Events are signed by the originating server and (in room versions 4+) their event ID is derived from a SHA-256 hash of their content. Tampering with any field would change the hash, invalidating the event ID and the signature.
- **Independent validation.** Any server can verify the integrity of any event without trusting the server that relayed it.
- **Merkle-like history integrity.** Because each event references its parents by their content-hash-derived IDs, the entire event DAG forms a tamper-evident chain, similar to a blockchain but without the consensus overhead.

### 2.2 Event Types

Event types are namespaced strings. The `m.` prefix is reserved for events defined in the Matrix specification. Custom event types should use reverse-domain notation (e.g., `com.example.custom_event`).

**Core event types you will encounter frequently:**

| Event Type | Purpose | State Event? |
|-----------|---------|:---:|
| `m.room.message` | A message (text, image, file, video, audio, location) | No |
| `m.room.member` | User membership change (join, leave, invite, ban, knock) | Yes |
| `m.room.create` | Room creation (always the first event in any room) | Yes |
| `m.room.name` | Room display name | Yes |
| `m.room.topic` | Room topic/description | Yes |
| `m.room.avatar` | Room avatar image | Yes |
| `m.room.power_levels` | Who can do what in the room | Yes |
| `m.room.join_rules` | How users can join (invite, public, knock, restricted) | Yes |
| `m.room.history_visibility` | Who can see history (joined, invited, shared, world_readable) | Yes |
| `m.room.canonical_alias` | The "official" human-readable alias for the room | Yes |
| `m.room.encryption` | Enables E2EE for the room (irreversible once set) | Yes |
| `m.room.redaction` | Removes content from another event | No |
| `m.reaction` | Emoji reaction to another event | No |
| `m.room.pinned_events` | List of pinned event IDs | Yes |
| `m.room.server_acl` | Server-level access control list (block servers from participating) | Yes |
| `m.room.third_party_invite` | Invitation via third-party identifier (e.g., email) | Yes |
| `m.room.tombstone` | Marks a room as replaced (used in room upgrades) | Yes |
| `m.space.child` | Declares a room as a child of a Space | Yes |
| `m.space.parent` | Declares a Space as the parent of a room | Yes |

The `m.room.message` type further differentiates through the `msgtype` field in its content:

| msgtype | Content |
|---------|---------|
| `m.text` | Plain text or formatted (HTML) message |
| `m.emote` | An emote (like IRC's `/me`) |
| `m.notice` | A bot notification (clients may render differently -- typically de-emphasized) |
| `m.image` | An image (with thumbnail, dimensions, file info) |
| `m.file` | A generic file attachment |
| `m.audio` | An audio clip or voice message |
| `m.video` | A video |
| `m.location` | A geographic location (geo: URI) |

### 2.3 State Events vs Timeline Events

This is one of the most important distinctions in the Matrix protocol, and understanding it deeply is essential for reasoning about room behavior.

**Timeline events** (also called "message events" or "non-state events") are the stream of messages and actions in a room. They are ordered, they accumulate, and they form the chat history. Think of them as the rows in a conversation log. Each one is a discrete happening. Examples: `m.room.message`, `m.reaction`, `m.room.redaction`.

**State events** define the current configuration of a room. Each state event has a `state_key` field (in addition to its `type`), and the combination of `(type, state_key)` acts as a unique key in the room's state dictionary. Only the most recent event for each `(type, state_key)` pair matters for the room's current state. When you change a room's name, the old `m.room.name` event is superseded -- it still exists in the DAG (history), but the room's "current state" reflects only the latest one.

The `state_key` enables a single event type to track multiple entities. For `m.room.member`, the `state_key` is the user's Matrix ID. This means each user's membership is tracked independently:

```
(m.room.member, @alice:example.org) -> {"membership": "join"}
(m.room.member, @bob:example.org)   -> {"membership": "invite"}
(m.room.member, @carol:other.org)   -> {"membership": "leave"}
```

For event types that do not need multiple instances, the `state_key` is an empty string:

```
(m.room.name, "")         -> {"name": "General Discussion"}
(m.room.topic, "")        -> {"topic": "Off-topic chat"}
(m.room.join_rules, "")   -> {"join_rule": "invite"}
```

Think of the room's current state as a key-value store where the key is `(type, state_key)` and the value is the event content. When a new user joins a room, the server sends them the current state so they know the room's name, who else is in it, what the power levels are, whether encryption is enabled, and so on.

A room with 200 members has at least 200 state events just for membership, plus the creation event, power levels, join rules, history visibility, name, topic, and potentially many more. This state accumulation is one of the reasons the `/sync` endpoint can become expensive at scale -- a problem addressed by Sliding Sync ([Section 8](#8-sliding-sync-msc3575)).

### 2.4 Rooms: The Central Abstraction

Rooms are the single unifying concept in Matrix. Everything happens in a room. There is no concept of a "channel" or a "thread" or a "direct message" that exists outside of a room. Instead:

- **Group chats** are rooms with many members.
- **Direct messages** are rooms with two members. There is no separate "DM" primitive in the protocol. A DM is just a room with a hint in the user's account data (`m.direct`) indicating it should be rendered as a direct message in the client UI.
- **Spaces** are rooms whose state events declare parent-child relationships with other rooms (using `m.space.child` and `m.space.parent` events). A Space is to Matrix what a Discord "server" or a Slack "workspace" is -- an organizational container -- but under the hood it is just a room with a special `type` field in its `m.room.create` event.
- **Threads** are implemented as events within a room that use `m.relates_to` with a `rel_type` of `m.thread`, pointing back to a root event. They are not separate rooms.

A room is not owned by any single server. It is a shared, replicated data structure. Every server with at least one member in the room holds a complete copy of the room's event history and current state. If the server that created the room goes offline permanently, the room continues to function on all other participating servers. This is fundamentally different from platforms like Discord or Slack, where rooms (channels) exist on a single server -- if that server goes down, the rooms are inaccessible.

### 2.5 Room IDs vs Room Aliases

Every room has an immutable **room ID** that looks like this:

```
!OGEhHVWSdvArJzumhm:matrix.org
```

The format is `!<opaque_id>:<originating_server>`. The server portion indicates which server created the room, but this does not grant that server any special authority over the room after creation. The opaque ID is randomly generated and globally unique.

Rooms can optionally have one or more **aliases**, which are human-readable:

```
#general:example.org
```

The format is `#<localpart>:<server>`. The server portion indicates which server *hosts* this alias (is authoritative for resolving it), not which server created the room. Aliases are pointers -- they resolve to a room ID. They can be created, changed, or deleted without affecting the underlying room. One room can have many aliases across many servers. One alias is designated as the **canonical alias** (via the `m.room.canonical_alias` state event), which is the "official" display name.

This two-layer system exists because:

1. Room IDs must be immutable (they are referenced in event signatures and in the DAG) and globally unique, so they use opaque identifiers.
2. Humans need readable names, but those names need to be changeable and should not require global coordination, so aliases are separate.

The analogy is DNS: an IP address (room ID) is the stable, routable identifier, while a domain name (alias) is the human-friendly pointer. Just as multiple domain names can point to one IP, multiple aliases can point to one room. And just as a domain name can be re-pointed to a different IP, an alias could theoretically be re-pointed to a different room (though this is uncommon in practice).

To resolve an alias across federation, a server queries the alias's hosting server:

```
GET /_matrix/federation/v1/query/directory?room_alias=%23general%3Aexample.org
```

The hosting server returns the room ID and a list of servers that can be used to join the room.

### 2.6 The Event DAG

This is where Matrix becomes architecturally distinctive. Events in a room do not form a simple linear sequence. They form a **Directed Acyclic Graph** (DAG).

When a server creates a new event, that event includes references to the most recent events the server knows about. These referenced events are called **parent events** and are listed in the `prev_events` field. If only one server is active in the room, this produces a simple chain: each event has one parent, forming a linear history. But when multiple servers are sending events concurrently, the graph branches and then merges:

```
    [Event A] (from server1)
       |    \
       |     \
       v      v
  [Event B]  [Event C] (B from server1, C from server2 -- concurrent)
       \      /
        \    /
         v  v
       [Event D] (sees both B and C as parents)
```

In this diagram:
- Event A has one child on each server.
- Event B's `prev_events` is `[A]` -- server1 had not yet received C.
- Event C's `prev_events` is `[A]` -- server2 had not yet received B.
- Event D's `prev_events` is `[B, C]` -- the server that created D had received both, so it merges the fork.

This is directly analogous to how Git commits reference parent commits and how branches and merges create a DAG. The Matrix team explicitly drew inspiration from distributed version control systems.

**Why a DAG and not a linear log?**

Because Matrix is a distributed system operating across multiple independent servers with no central coordinator. Two servers can create events at the same time without knowing about each other's events. A linear log would require a total ordering, which would require either a leader (centralization) or a consensus algorithm (latency). The DAG allows concurrent events to coexist and be ordered deterministically after the fact.

**How are events ordered?**

The DAG defines a *partial order*: if event A is an ancestor of event B (reachable by following `prev_events` links), then A causally precedes B. But concurrent events (like B and C above) have no inherent causal ordering. For display purposes, clients typically use `origin_server_ts` (the originating server's timestamp) to sort concurrent events, but this is a best-effort heuristic -- server clocks are not perfectly synchronized. The authoritative ordering for state resolution purposes uses a more sophisticated deterministic algorithm (discussed in [Section 3.6](#36-state-resolution)).

**Forward extremities:**

The "forward extremities" of the DAG are the events that no other event references yet. They represent the leaf nodes -- the "tips" of the conversation. When a server creates a new event, it sets `prev_events` to the current forward extremities it knows about, thereby merging any forks. In a healthy room with low latency between servers, there is usually only one forward extremity (a linear chain). In a busy room with many servers creating events concurrently, you might temporarily have several forward extremities.

**Event references and integrity:**

In room versions 4+, each event's ID is a SHA-256 hash of the event's content, encoded as URL-safe base64 with a `$` prefix. This means the DAG is a Merkle-like structure: tampering with any event changes its hash, which changes its event ID, which invalidates all descendant events that reference it. This provides cryptographic integrity of the room's entire history without requiring a blockchain or any central authority.

---

## 3. Federation

### 3.1 What Federation Means

Federation is the mechanism by which independent Matrix homeservers communicate to give users the illusion of a single unified network. Each server is autonomous -- it has its own users, its own database, its own administrator, its own policies. But when users on different servers participate in the same room, those servers must exchange events.

Federation in Matrix means three specific things:

1. **Full room replication.** When a server joins a room, it receives a copy of the room's current state (and can backfill its history). From that point on, all participating servers maintain independent, eventually consistent copies of the room.

2. **Peer-to-peer event propagation.** When a user on server A sends a message, server A pushes that event to all other servers with members in the room. Each receiving server independently validates the event (checking signatures, verifying authorization against power levels, confirming auth events) before accepting it into its own copy of the room.

3. **No hierarchy.** There is no "primary" or "master" server for a room. All participating servers are equal peers. If server A goes down, users on servers B and C continue chatting. When server A comes back, it catches up by receiving the events it missed. The server that originally created the room has no ongoing special authority.

```
+-----------------+                  +-----------------+
|  server-a.org   |  <-- events -->  |  server-b.net   |
|  (Alice's home) |    federation    |  (Bob's home)   |
+-----------------+                  +-----------------+
        \                                   /
         \         +----------------+      /
          +------> |  server-c.io   | <---+
            events |  (Carol's home)| events
                   +----------------+
```

Federation is optional. You can run a Matrix server with federation disabled (`m.federate: false` on room creation, or by firewalling the federation port entirely), which means your users can only talk to each other. This is useful for organizations that want the Matrix protocol's features -- structured rooms, E2EE, rich media, bots, bridges -- without cross-server communication. Our deployment supports both modes (see [Deployment Architecture](04-deployment-architecture.md) for details).

### 3.2 Server Discovery

When server A needs to contact server B, it must first discover server B's actual network address. The server name in a Matrix ID (the part after the colon in `@alice:example.org`) is a *logical* name, not necessarily a hostname. This is a deliberate decoupling: it lets you use a clean domain like `example.org` in your user IDs while running your actual Matrix server on `matrix.example.org:8448` or any other host.

The discovery process has three steps, tried in order:

**Step 1: .well-known lookup**

Server A makes an HTTPS GET request to:

```
https://example.org/.well-known/matrix/server
```

If this returns a JSON document, it contains the actual server address:

```json
{
  "m.server": "matrix.example.org:8448"
}
```

This is the most common and recommended discovery method. It is simple to set up (just a static JSON file on your main domain) and works with any hosting configuration.

Our deployment uses `.well-known` for client discovery. The nginx container serves the `.well-known/matrix/client` endpoint, which tells clients where to find Synapse, the Sliding Sync proxy, and the authentication issuer:

```json
{
  "m.homeserver": {
    "base_url": "https://synapse.your.matrix.server.de"
  },
  "org.matrix.msc3575.proxy": {
    "url": "https://sync.synapse.your.matrix.server.de"
  },
  "org.matrix.msc2965.authentication": {
    "issuer": "https://server.de",
    "account": "https://mas.synapse.your.matrix.server.de/account"
  }
}
```

**Step 2: SRV DNS records (fallback)**

If `.well-known` is not available, server A queries DNS for:

```
_matrix-fed._tcp.example.org
```

(In older implementations, this was `_matrix._tcp.example.org`.) The SRV record points to the actual hostname and port.

**Step 3: Direct connection (final fallback)**

If neither `.well-known` nor SRV records exist, server A connects directly to `example.org` on port 8448 (the default Matrix federation port).

**Server identity verification:**

Federation traffic uses HTTPS, but server identity is verified not through TLS certificates alone but through **Ed25519 signing keys**. Each server has a signing key pair. The public key is published at `GET /_matrix/key/v2/server`:

```json
{
  "server_name": "example.org",
  "verify_keys": {
    "ed25519:auto": {
      "key": "Noi6WqcDj0QmPxCNQqgezwTlBKrfqehY1u2FyWP9uYw"
    }
  },
  "old_verify_keys": {},
  "valid_until_ts": 1735689600000,
  "signatures": {
    "example.org": {
      "ed25519:auto": "signature_base64_here..."
    }
  }
}
```

When server A sends an event, it signs the event JSON with its private key. Server B verifies the signature against server A's public key. Keys can be rotated; old keys are listed with a `valid_until_ts` timestamp. Servers can also fetch keys through notary servers (trusted third parties that vouch for key validity), adding a layer of key distribution redundancy.

The combination of TLS (transport security) and event signing (content integrity and authenticity) means that even if a man-in-the-middle intercepted federation traffic, they could not forge events from another server.

### 3.3 Server-to-Server API

The Server-to-Server (S2S) API, also called the Federation API, uses HTTPS with JSON payloads. Requests are authenticated using HTTP signatures -- the sending server signs the request with its Ed25519 key, and the receiving server verifies the signature against the sender's published key.

The `Authorization` header for S2S requests uses a custom scheme:

```
Authorization: X-Matrix origin="server-a.org",destination="server-b.net",key="ed25519:auto",sig="signature_base64..."
```

Key endpoints:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/_matrix/federation/v2/send/{txnId}` | PUT | Send a batch of events (PDUs) and ephemeral data (EDUs) |
| `/_matrix/federation/v1/make_join/{roomId}/{userId}` | GET | Request a join event template |
| `/_matrix/federation/v2/send_join/{roomId}/{eventId}` | PUT | Submit a signed join event, receive room state |
| `/_matrix/federation/v1/make_leave/{roomId}/{userId}` | GET | Request a leave event template |
| `/_matrix/federation/v2/send_leave/{roomId}/{eventId}` | PUT | Submit a signed leave event |
| `/_matrix/federation/v1/state/{roomId}` | GET | Request a room's current state at a given event |
| `/_matrix/federation/v1/backfill/{roomId}` | GET | Request historical events (walk backward through the DAG) |
| `/_matrix/federation/v1/event/{eventId}` | GET | Fetch a specific event by ID |
| `/_matrix/federation/v1/query/directory` | GET | Resolve a room alias to a room ID |
| `/_matrix/federation/v1/query/profile` | GET | Query a user's profile on a remote server |
| `/_matrix/key/v2/server` | GET | Fetch the server's signing keys |

Events sent via federation are called **PDUs** (Persistent Data Units) -- they are stored permanently in the room's DAG. Ephemeral data (typing notifications, presence updates, device list updates, read receipts) is sent as **EDUs** (Ephemeral Data Units). EDUs are transient: they are not stored in the DAG and are not replicated to servers that were offline when they were sent. If you were offline when someone was typing, you simply never learn about that typing indicator, which is fine -- ephemeral data is inherently time-sensitive.

### 3.4 Anatomy of a Federated Message

Let us trace exactly what happens when `@alice:server-a.org` sends "Hello!" in a room that also contains `@bob:server-b.net`:

**Step 1: Alice's client sends the message via the Client-Server API.**

```
PUT /_matrix/client/v3/rooms/!room:server-a.org/send/m.room.message/txn1
Authorization: Bearer <alice_access_token>

{
  "msgtype": "m.text",
  "body": "Hello!"
}
```

The client sends only the message content. It does not set the event ID, timestamp, parent references, or signatures -- the server handles all of that.

**Step 2: Server A builds the full event.**

The homeserver:
- Assigns `origin_server_ts` to the current time.
- Sets `prev_events` to the event IDs of the current forward extremities of the room's DAG (the most recent events it knows about).
- Sets `auth_events` to the event IDs that authorize this action: the room creation event, Alice's current `m.room.member` event, and the current `m.room.power_levels` event.
- Computes the content hash, which becomes the event ID (in room versions 4+).
- Signs the event with its Ed25519 signing key.
- Persists the event to its PostgreSQL database.
- Adds the event to Alice's next `/sync` response.
- Notifies any interested application services (bridges -- see [Bridges](05-bridges.md)).

**Step 3: Server A sends the event to Server B via the Federation API.**

```
PUT /_matrix/federation/v2/send/{txnId}

{
  "origin": "server-a.org",
  "origin_server_ts": 1706140800000,
  "pdus": [
    {
      "type": "m.room.message",
      "room_id": "!room:server-a.org",
      "sender": "@alice:server-a.org",
      "content": {"msgtype": "m.text", "body": "Hello!"},
      "prev_events": ["$prev_event_id"],
      "auth_events": ["$create_event", "$power_levels_event", "$membership_event"],
      "origin_server_ts": 1706140800000,
      "depth": 42,
      "signatures": {
        "server-a.org": {
          "ed25519:auto": "signature..."
        }
      },
      "hashes": {
        "sha256": "content_hash..."
      }
    }
  ],
  "edus": []
}
```

Note the federation-specific fields that clients never see: `prev_events`, `auth_events`, `depth`, `signatures`, `hashes`. These are the machinery of the DAG and integrity verification system.

**Step 4: Server B validates the event.**

The receiving server:
- Verifies the HTTP request signature (X-Matrix auth header).
- Verifies the event signature against server A's published Ed25519 key.
- Verifies the content hash matches the event ID.
- Checks that the `prev_events` are known. If any are missing, it fetches them via backfill -- this ensures the DAG is complete.
- Checks the event against the room's authorization rules: Is Alice in the room? Does she have sufficient power level to send this event type? Are the `auth_events` valid?
- Runs state resolution if needed (if there are concurrent events that create state conflicts).
- Persists the event to its own PostgreSQL database.

**Step 5: Server B notifies Bob.**

- The event appears in Bob's next `/sync` response (or Sliding Sync update).
- If Bob has push notifications configured and is not actively syncing, server B sends a notification to the push gateway, which forwards it to Bob's mobile device via APNs or FCM.

The entire flow -- from Alice pressing "send" to Bob seeing the message -- typically takes under one second for well-connected servers. But because federation is eventually consistent, there is no hard guarantee. If server B is temporarily unreachable, server A queues the event and retries with exponential backoff. When server B comes back, it receives all queued events.

### 3.5 Eventually Consistent Replication

Matrix uses **eventual consistency** rather than strong consistency. This means:

- All servers will *eventually* converge on the same state, but at any given instant, different servers may have slightly different views of a room.
- There is no global clock or total ordering of events across servers.
- Events can be received out of order, and servers must handle this gracefully.
- After a network partition heals, there may be a burst of events that "arrive late."

This design choice is fundamental and deliberate. Strong consistency (as provided by Raft, Paxos, or similar consensus algorithms) requires a majority of participating nodes to agree on each operation before it is committed. For a global, federated system where any server in the world can participate, this is unacceptable: you do not want a temporarily unreachable server in Tokyo to block or delay a conversation between two servers in Berlin.

The trade-off is that you can occasionally see effects that would be impossible in a strongly consistent system:

- Two users on different servers might briefly see messages in different orders.
- A user might be kicked and simultaneously send a message (from different servers' perspectives), creating a temporary fork that state resolution later resolves.
- After a network partition, messages "appear" that were sent during the partition.

The DAG structure handles all of these cases naturally: concurrent events are simply branches in the graph, and state resolution (next section) deterministically resolves any conflicts. Clients can display concurrent events in whatever order they choose (typically by `origin_server_ts`) because the display order of concurrent events is a UI concern, not a protocol correctness concern.

### 3.6 State Resolution

State resolution is the mechanism by which Matrix servers deterministically agree on the current state of a room, even when they have processed events in different orders. It is arguably the most intellectually demanding part of the Matrix protocol.

**The problem:**

Suppose server A and server B both have users in a room, and both process state-changing events concurrently:

```
           [Power levels: Alice=100, Bob=50]
                    /              \
                   /                \
  [Alice kicks Carol]    [Bob changes room name]
  (Server A sees this)   (Server B sees this)
```

Both events are valid based on the state they were created against. But what is the "current" state after both servers exchange these events? If authorization depends on the order of application, different orders could produce different results.

**State Resolution v1 (Room Version 1):**

The v1 algorithm was relatively simple: for conflicting state, prefer the event from the sender with the highest power level, breaking ties by timestamp and then by event ID. This was gameable -- an attacker who could manipulate timestamps or who had a high power level could win state conflicts even if their event was causally "wrong." The most serious vulnerability was the "state reset" bug, where a carefully crafted fork could reset room state to an earlier point, effectively undoing bans and permission changes.

**State Resolution v2 (Room Versions 2+):**

The current algorithm, introduced in room version 2 and refined in subsequent versions, is a complete rewrite. It works roughly as follows:

1. **Identify conflicts.** For each `(type, state_key)` pair, check if all branches of the DAG agree on the same event. If they do, that state is "unconflicted" and accepted as-is. If they disagree, that state is "conflicted" and needs resolution.

2. **Separate auth-related state.** Power levels (`m.room.power_levels`), membership events (`m.room.member`), join rules (`m.room.join_rules`), and third-party invite events are resolved first, because they determine who is authorized to do what. Getting these right is a prerequisite for resolving everything else.

3. **Compute the auth difference.** For each conflicting event, compute its full auth chain (the transitive closure of its `auth_events`). The "auth difference" is the set of auth events that are NOT common to all branches. These are the events that caused the divergence.

4. **Sort and apply auth events.** The auth difference events are sorted by a deterministic ordering: power level of the sender (descending), then `origin_server_ts` (ascending), then event ID (lexicographic) as a final tiebreaker. Events are applied one at a time in this order. At each step, the event is checked against the state accumulated so far. If it fails authorization, it is discarded.

5. **Resolve remaining state.** Non-auth state events (room name, topic, etc.) are resolved using the same authorization-check approach against the now-resolved auth state.

The key design insight is that this algorithm is **deterministic** and depends only on the events themselves, not on the order in which any particular server received them. Two servers with the same set of events will always arrive at the same resolved state. This is what guarantees convergence.

The practical consequence: if an admin (power level 100) and a moderator (power level 50) make conflicting changes simultaneously, the admin's change takes precedence. If a user is kicked simultaneously from two different servers, state resolution determines the final membership status based on the senders' power levels and the auth rules.

---

## 4. Identity

### 4.1 User IDs

A Matrix user ID (also called an MXID) has the form:

```
@localpart:server_name
```

For example: `@alice:example.org`, `@admin:your.matrix.server.de`, `@whatsappbot:your.matrix.server.de`

Formal rules:
- The localpart can contain lowercase ASCII letters, digits, and the characters `._=-/`.
- The server name is the logical name of the homeserver (not necessarily its hostname -- see [Section 3.2](#32-server-discovery) on server discovery).
- The total length must not exceed 255 characters.
- User IDs are case-sensitive, but homeservers typically normalize to lowercase at registration time.

The user ID is **permanent and immutable**. You cannot change it. You cannot migrate it to a different server. There is no "account portability" in the protocol as of 2026, though it is an active area of work in the community. This is one of Matrix's most significant current limitations and a direct consequence of the federated trust model: your server name is part of your identity, and other servers trust that server to be authoritative about you.

In our deployment, user IDs take the form `@username:your.matrix.server.de`, where `your.matrix.server.de` is the value of the `SYNAPSE_SERVER_NAME` environment variable. Accounts are created through Keycloak (see [Authentication](03-authentication.md)), and the username in the Matrix ID matches the Keycloak username.

### 4.2 Device IDs

Each client login session is identified by a device ID. When you log in from your phone, that creates one device. When you log in from your laptop, that creates another device. When you log in from your browser, yet another. Device IDs are opaque strings generated by the server (e.g., `ABCDEFGHIJ`).

Devices matter primarily for encryption. Each device has its own set of encryption keys:
- A Curve25519 identity key (for key agreement in Olm sessions).
- An Ed25519 signing key (for signing the device's own keys and for cross-signing).
- A pool of one-time Curve25519 keys (consumed during Olm session establishment).

When someone sends you an encrypted message, it is encrypted separately for each of your devices using Megolm (with session keys distributed via per-device Olm channels). This is why logging in on a new device triggers verification prompts -- other users' clients need to know that this new device is legitimately yours and not an attacker's.

Devices are also used for:
- **To-device messaging**: Sending data directly to a specific device (used for key sharing, verification, call signaling).
- **Push notifications**: Each device registers separately for push notifications via its own push token.
- **Read receipts and read markers**: Different devices may have read up to different points in a conversation.

### 4.3 Access Tokens

Access tokens are the credentials that authenticate Client-Server API requests. When you log in, the server (or, in our deployment, MAS via Keycloak) issues an access token. Every API request includes this token:

```
Authorization: Bearer syt_dGVzdA_XKFPHnwZfsmOkhBCol_1abCdE
```

Token characteristics:
- They are opaque strings (no required format, though Synapse uses a recognizable prefix convention starting with `syt_`).
- Each token is tied to a specific user and device.
- They can be revoked (logging out invalidates the token).
- They have a configurable lifetime.

In our deployment, authentication is delegated to MAS (Matrix Authentication Service) via the experimental MSC3861 support in Synapse. MAS in turn delegates to Keycloak as the upstream OIDC identity provider. This means Synapse never handles passwords directly -- it trusts MAS to issue access tokens. The nginx reverse proxy routes login/logout/refresh requests to MAS, while all other Client-Server API requests go directly to Synapse. See [Authentication](03-authentication.md) for the complete flow.

Modern clients and MAS support a **refresh token** mechanism where short-lived access tokens are paired with longer-lived refresh tokens. When the access token expires, the client uses the refresh token to obtain a new one without requiring the user to re-authenticate. This limits the damage window if an access token is leaked.

### 4.4 Identity Across Federation

When `@alice:server-a.org` joins a room on `server-b.net`, server B does not create a local account for Alice. Instead, it trusts that server A is the authority for Alice's identity. Server B stores Alice's events as coming from `@alice:server-a.org` and verifies server A's signature on those events.

This trust model has important implications:

- **Your homeserver is your identity provider.** The server named in your MXID is the sole authority on your identity within the Matrix federation.
- **Other servers trust your server's signatures.** If server A signs an event from `@alice:server-a.org`, other servers accept that Alice sent it. There is no independent verification of Alice's identity beyond trusting server A's signing key.
- **Compromising a server compromises its users' identities.** If an attacker gains control of server A's signing key, they can impersonate any user on server A. This is why running your own server (and securing it properly) matters for security-sensitive deployments.

This is identical to how email works: if you receive an email from `alice@example.org`, you are trusting `example.org`'s mail server to be authoritative about who `alice` is. SPF, DKIM, and DMARC add verification layers for email. Matrix uses Ed25519 event signatures for a similar purpose.

### 4.5 Identity Servers

Matrix defines an **Identity Service API** that maps third-party identifiers (email addresses, phone numbers) to Matrix user IDs. The purpose is discovery: you might know someone's email address but not their Matrix ID.

The flow:
1. A user associates their email with their Matrix account via their homeserver.
2. The homeserver (or client) contacts the identity server to validate the email (sends a verification email).
3. The user clicks the verification link.
4. The identity server stores the mapping: `alice@example.com` -> `@alice:example.org`.
5. When someone searches for `alice@example.com`, the identity server returns the Matrix ID.

Identity server lookups use hashed identifiers (since Identity Service API v2) to prevent the server from learning the full set of identifiers being queried. Still, identity servers are a privacy trade-off: using one means a third party knows you are looking up email-to-MXID mappings.

The canonical identity server is `matrix.org` (operated by the Foundation), but identity servers are entirely optional and separate from homeservers. You can:
- Run your own identity server (e.g., Sydent, the reference implementation).
- Use `matrix.org`'s identity server.
- Use no identity server at all.

Our deployment does not include a dedicated identity server. Users find each other by sharing their Matrix IDs directly, through room directories, or through Spaces.

---

## 5. Rooms Deep-Dive

### 5.1 Room Creation

When a user creates a room, their homeserver performs the following atomic sequence:

1. **Generates a unique room ID** (e.g., `!abcdef1234:example.org`).

2. **Creates the `m.room.create` event** -- always the first event in any room. This event records:
   - The room creator's user ID.
   - The room version.
   - An optional `type` field (e.g., `"m.space"` for Spaces).
   - An optional `m.federate` flag (`true` by default; if `false`, federation is disabled for this room).

3. **Creates the creator's `m.room.member` event** (`membership: "join"`).

4. **Creates the initial `m.room.power_levels` event**, giving the creator the highest power level (100 in room versions 11+).

5. **Creates additional state events** as specified in the creation request or implied by the preset: `m.room.join_rules`, `m.room.history_visibility`, `m.room.guest_access`, and optionally `m.room.name`, `m.room.topic`, `m.room.encryption`, etc.

6. **Processes invites** if the creation request included an `invite` list.

The `m.room.create` event is special: it cannot be redacted, it must be the first event in the room, and it permanently determines the room version.

The Client-Server API provides presets for common room configurations:

| Preset | Join Rule | History Visibility | Encryption |
|--------|-----------|-------------------|------------|
| `private_chat` | `invite` | `shared` | Off (unless requested) |
| `trusted_private_chat` | `invite` | `shared` | Off (unless requested) |
| `public_chat` | `public` | `shared` | Off |

### 5.2 Room Versions

Room versions are a mechanism for upgrading the protocol's room-level algorithms without breaking existing rooms. Each room is created with a specific version, and that version is **immutable for the life of the room**. To "upgrade" a room's version, you create a new room with the new version and set a tombstone (`m.room.tombstone`) in the old room pointing to the new one.

| Version | Key Changes | Release |
|---------|-------------|---------|
| **v1** | Original room version. State resolution v1. Event IDs are `$opaque:server` (assigned by the server, including the server name). | June 2019 |
| **v2** | State resolution v2 -- a complete rewrite of the conflict resolution algorithm, fixing critical security vulnerabilities including the "state reset" bug. | June 2019 |
| **v3** | Event IDs derived from SHA-256 content hash (no server name in event IDs). Prevents event ID spoofing and stops leaking the originating server name in the ID. | June 2019 |
| **v4** | Event IDs use URL-safe base64 encoding of the content hash. | June 2019 |
| **v5** | Enforces `valid_until_ts` on server signing keys, preventing old compromised keys from being used to forge events. Enforced that `m.room.create` must be the first event. | June 2019 |
| **v6** | Stricter canonical JSON validation. Rejects events with non-canonical JSON encoding. Restricts `join_rules` and `membership` values to known enums. | June 2019 |
| **v7** | Introduced `knock` join rule (the ability to request an invitation to an invite-only room). | May 2021 |
| **v8** | Introduced `restricted` join rule (join if you are a member of certain other rooms). This powers Spaces-based access control. | September 2021 |
| **v9** | Introduced `knock_restricted` join rule (combination of knock and restricted). Fixed edge cases in restricted join handling. | September 2021 |
| **v10** | Enforced integer-only power levels (no floats). Required `content` hash to cover the entire event. | February 2023 |
| **v11** | Default power level for room creator is explicitly 100. Clarified creator handling and redaction behavior. Updated redaction algorithm to preserve additional fields. | December 2023 |

**Why room versions exist at all:**

Changing the state resolution algorithm on an existing room would cause servers that had processed events under the old rules to disagree with servers processing under the new rules, potentially breaking consensus. Room versions solve this by making the algorithm a property of the room itself, not of the server software.

**Room upgrades in practice:**

To upgrade a room, an admin sends an `m.room.tombstone` event in the old room:

```json
{
  "type": "m.room.tombstone",
  "state_key": "",
  "content": {
    "body": "This room has been replaced",
    "replacement_room": "!new_room_id:server.org"
  }
}
```

A new room is created with the desired version, and clients that understand tombstone events prompt users to join the new room. The old room becomes read-only (by convention, though not enforced by the protocol).

New rooms should use the latest stable version (v11 as of early 2026). Synapse's default version is configurable (see [Synapse Homeserver](02-synapse-homeserver.md)).

### 5.3 Join Rules

Join rules govern how users can enter a room. They are set via the `m.room.join_rules` state event.

| Join Rule | Behavior | Min Room Version |
|-----------|----------|:----------------:|
| `public` | Anyone can join without an invitation. The room may appear in the public room directory. | v1 |
| `invite` | A user must be invited by a current member with sufficient power level. This is the default for most rooms. | v1 |
| `knock` | A user can "knock" (request to join). A member with sufficient power level can then accept or reject the knock. | v7 |
| `restricted` | A user can join if they are a member of one of the rooms specified in the `allow` list. This is the mechanism that powers Space-based access control: "anyone who is a member of Space X can join this room." | v8 |
| `knock_restricted` | Combines `knock` and `restricted`: users can join if they are in an allowed room, OR they can knock to request access if they are not. | v9 |

A `restricted` join rule looks like this:

```json
{
  "type": "m.room.join_rules",
  "state_key": "",
  "content": {
    "join_rule": "restricted",
    "allow": [
      {
        "type": "m.room_membership",
        "room_id": "!parent_space:example.org"
      }
    ]
  }
}
```

This means: "anyone who is a member of `!parent_space:example.org` can join this room without an explicit invite." This is how Spaces work as organizational containers with access control.

### 5.4 Power Levels

Power levels are Matrix's authorization mechanism. They determine who can perform what actions in a room. The `m.room.power_levels` state event contains a numeric power level for each user and threshold power levels for various actions.

A typical power levels event:

```json
{
  "type": "m.room.power_levels",
  "state_key": "",
  "content": {
    "users": {
      "@alice:example.org": 100,
      "@bob:example.org": 50,
      "@carol:other.org": 0
    },
    "users_default": 0,
    "events": {
      "m.room.name": 50,
      "m.room.power_levels": 100,
      "m.room.history_visibility": 100,
      "m.room.canonical_alias": 50,
      "m.room.avatar": 50,
      "m.room.tombstone": 100,
      "m.room.server_acl": 100,
      "m.room.encryption": 100,
      "m.space.child": 50
    },
    "events_default": 0,
    "state_default": 50,
    "ban": 50,
    "kick": 50,
    "redact": 50,
    "invite": 0,
    "notifications": {
      "room": 50
    }
  }
}
```

**How authorization works:**

Every time a server receives an event (either from a local client or from federation), it checks the sender's power level against the required level for that action:

| Action | Required Level | Notes |
|--------|---------------|-------|
| Send a timeline event (message, reaction, etc.) | `events_default` (or specific level in `events` for that type) | Default 0 -- anyone can send messages |
| Send a state event | `state_default` (or specific level in `events` for that type) | Default 50 -- moderator action |
| Change the room name or topic | `events["m.room.name"]` / `events["m.room.topic"]` | Typically 50 |
| Change power levels | `events["m.room.power_levels"]` | Typically 100 -- admin only |
| Enable encryption | `events["m.room.encryption"]` | Typically 100 -- irreversible |
| Kick a user | `kick` AND sender's level > target's level | Default 50 |
| Ban a user | `ban` AND sender's level > target's level | Default 50 |
| Invite a user | `invite` | Default 0 |
| Redact another user's event | `redact` | Default 50 |
| @room notification | `notifications["room"]` | Default 50 |

**Common power level conventions:**

| Level | Role | Typical Capabilities |
|-------|------|---------------------|
| 0 | Default user | Send messages, react, invite (if `invite` threshold is 0) |
| 50 | Moderator | Kick/ban users, change room name/topic/avatar, delete others' messages |
| 100 | Admin | Change power levels, change join rules, enable encryption, upgrade room |

These numbers are conventions, not protocol requirements. You could use 7, 42, and 99 if you wanted. The protocol only cares about the relative ordering and the comparison with thresholds.

**Important constraints:**
- You can only modify the power level of users with a power level *strictly lower* than your own.
- You cannot raise someone's power level above your own.
- You cannot change the required level for an action to be higher than your own power level (preventing self-lockout from further changes).
- If the only admin leaves a room, the room becomes "unmanageable" -- no one can perform admin actions. This is by design (there is no backdoor), so always maintain at least two admins.

### 5.5 Room State

The "room state" at any point is the accumulated set of current state events -- the snapshot of the room's entire configuration at that moment. Think of it as a key-value store:

- **Key**: `(event_type, state_key)` -- e.g., `("m.room.name", "")` or `("m.room.member", "@alice:example.org")`
- **Value**: The most recent event for that key

The state includes:
- Room metadata: name, topic, avatar, canonical alias.
- Membership of every user who has ever interacted with the room (join, invite, leave, ban, knock).
- Power levels.
- Join rules and history visibility.
- Encryption configuration.
- Space parent/child relationships.
- Server ACLs.
- Any custom state events.

When a new user joins a room (whether via the Client-Server API or via federation), the server sends them the current state so they know the room's name, who else is in it, what the power levels are, whether encryption is enabled, and so on. In federation, the `send_join` response includes the complete room state.

**State at an event:**

Each event in the DAG has an associated "state at that event" -- the state that was current when the event was created. This is crucial for authorization: an event's validity is judged against the state at its parent events, not against the current state. This prevents retroactive invalidation -- if Bob sends a message, and then Alice changes the power levels to prevent Bob from messaging, Bob's already-sent message remains valid because it was authorized at the time.

### 5.6 State Resolution When Servers Disagree

(Expanding on [Section 3.6](#36-state-resolution) with practical examples.)

State conflicts arise in normal operation whenever two servers process state-changing events concurrently. Consider:

**Example 1: Conflicting room names**

Server A and Server B each have a moderator who changes the room name simultaneously (before the other server's event arrives):

- Server A: Moderator Alice sets name to "Engineering"
- Server B: Moderator Bob sets name to "Dev Team"

When the events are exchanged, both servers have two conflicting `m.room.name` events. State resolution v2 resolves this deterministically: if Alice and Bob have the same power level, the event with the earlier `origin_server_ts` wins (with event ID as a final tiebreaker). Both servers arrive at the same winner.

**Example 2: Power level race condition**

This is where state resolution gets interesting:

1. Alice (power level 100) and Bob (power level 50) are on different servers.
2. Alice demotes Bob to power level 0.
3. Simultaneously (before Alice's demotion arrives at Bob's server), Bob kicks Carol (which requires power level 50, which Bob still had from his server's perspective).
4. Both events are "valid" against the state each server knew at the time.

After federation sync, state resolution must decide: is Carol kicked or not?

The v2 algorithm resolves auth-related state first. Alice's power level change takes precedence (she has the higher power level). In the resolved state, Bob has power level 0. Bob's kick of Carol is then re-evaluated against this resolved state -- and it fails authorization because Bob no longer has power level 50. Carol stays in the room.

Both servers independently arrive at this same conclusion. This is the power of deterministic state resolution: no coordination needed, no leader election, no consensus protocol, just an algorithm that produces the same result from the same inputs regardless of the order in which those inputs were received.

---

## 6. End-to-End Encryption (E2EE)

### 6.1 Olm and Megolm

Matrix uses two cryptographic protocols for E2EE, both developed by the Matrix team and both based on the Signal Protocol's design principles:

**Olm** is used for one-to-one communication between specific devices. It implements the Double Ratchet algorithm (the same core algorithm used by Signal). Key properties:
- Provides **forward secrecy**: compromising a current key does not reveal past messages.
- Provides **break-in recovery**: after a ratchet step, compromising the old key does not reveal future messages.
- Uses X25519 for Diffie-Hellman key exchange and Ed25519 for signatures.
- Each pair of devices has its own independent Olm session.

**Megolm** is used for group communication (rooms with multiple members). It exists because using pure Olm for group messages is prohibitively expensive. The efficiency trick:

- Instead of encrypting a message N times (once per recipient device), the sender encrypts it **once** with a Megolm session key.
- The session key is distributed to each recipient device via Olm (per-device encrypted channels).
- Megolm provides forward secrecy within a session: the ratchet only advances forward, so a compromised key cannot decrypt past messages within that session.
- Megolm does **not** provide break-in recovery within a session. If a Megolm session key is compromised, all subsequent messages in that session are readable until the session is rotated.
- Session rotation happens periodically -- by default, every 100 messages or every week, whichever comes first.

```
Encryption architecture:

Alice's Device
    |
    |-- Olm session --> Bob's Device 1    (1:1 encrypted channel)
    |-- Olm session --> Bob's Device 2    (1:1 encrypted channel)
    |-- Olm session --> Carol's Device 1  (1:1 encrypted channel)
    |
    +-- Megolm session key shared to all devices above via Olm
    |
    |== Message encrypted ONCE with Megolm ==========================>
        (all devices with the session key can decrypt)
```

**Why two protocols?**

Pure scalability. In a room with 1,000 members, each having an average of 3 devices, there are 3,000 devices. Using pure Olm would require encrypting every single message 3,000 times. Megolm reduces this to 1 encryption (with the session key) plus 3,000 one-time Olm-encrypted key distributions when the session rotates. Since session rotation happens every 100 messages or so, the key distribution cost is amortized across many messages.

The encryption algorithm used for Megolm is `m.megolm.v1.aes-sha2`, which is specified in the room's `m.room.encryption` state event:

```json
{
  "type": "m.room.encryption",
  "state_key": "",
  "content": {
    "algorithm": "m.megolm.v1.aes-sha2",
    "rotation_period_ms": 604800000,
    "rotation_period_msgs": 100
  }
}
```

Once this state event is set, encryption is **permanent and irreversible** for that room. The spec forbids removing the `m.room.encryption` state event.

### 6.2 Key Management

Key management in Matrix involves several types of keys at different levels:

**Device keys (long-lived per device):**
- **Ed25519 signing key**: Signs the device's other keys and device information.
- **Curve25519 identity key**: Used for Diffie-Hellman key agreement in Olm sessions.

These are generated when a device first logs in and uploaded to the homeserver. Other devices can fetch them via `POST /_matrix/client/v3/keys/query`.

**One-time keys (consumable, per device):**
- Curve25519 keys pre-generated in batches and uploaded to the homeserver.
- When another device wants to establish an Olm session, it *claims* one of these keys via `POST /_matrix/client/v3/keys/claim`.
- Each key is single-use (preventing replay attacks). Devices periodically check their remaining one-time key count and upload more when the pool is low.
- A **fallback key** is used when one-time keys are exhausted, ensuring sessions can always be established.

**Megolm session keys (per room, per sender, rotated periodically):**
- Generated by the sending device when it creates a new Megolm session for a room.
- Distributed to all room members' devices via Olm-encrypted to-device messages.
- Rotated after `rotation_period_msgs` messages or `rotation_period_ms` milliseconds.

**The sending flow:**

1. Client checks if it has an active Megolm session for the room.
2. If not (or if rotation is needed), it creates a new session and distributes the key to all member devices via Olm.
3. Client encrypts the message content with the Megolm session key.
4. Client sends the encrypted event as type `m.room.encrypted` (instead of `m.room.message`).

**The receiving flow:**

1. Client receives an `m.room.encrypted` event via `/sync`.
2. Client looks up the Megolm session key for the session ID specified in the event.
3. If the key is available, it decrypts the message.
4. If the key is not available (e.g., the client was offline when keys were distributed), it shows "Unable to decrypt" and may request the key from other devices via `m.room_key_request`.

### 6.3 Device Verification

Encryption is only as strong as your confidence that you are encrypting to the right devices. Without verification, a malicious homeserver could inject fake devices into a user's device list, creating man-in-the-middle decryption sessions.

Device verification lets users confirm that a device really belongs to who it claims to be. The primary method is:

**SAS (Short Authentication String):**
1. User A initiates verification with User B (via a special verification room or in-room verification).
2. Both devices perform a Diffie-Hellman key agreement.
3. Both devices derive the same short string from the shared secret and display it as a sequence of emoji (e.g., "Dog, Clock, Scissors, Heart, Moon, Cat, Rocket") or as a numeric code.
4. Both users compare the displayed values out-of-band (reading them to each other in person, over a phone call, etc.).
5. If they match, each device signs the other's device keys and uploads the signatures.
6. Both devices are now mutually verified.

**QR code scanning:**
One device displays a QR code containing key material and the other scans it. This is faster than comparing emoji strings and is supported by Element X and other modern clients.

### 6.4 Cross-Signing

Verifying every device individually does not scale. If Alice has 3 devices and Bob has 4 devices, that is 12 potential verification interactions. Cross-signing solves this by introducing a hierarchical key structure.

Each user generates three signing keys:

```
Master Signing Key (MSK) -- the root of trust for a user
    |
    |-- Self-Signing Key (SSK) -- signs the user's own device keys
    |       |
    |       |-- Device A key (signed by SSK)
    |       |-- Device B key (signed by SSK)
    |       |-- Device C key (signed by SSK)
    |
    |-- User-Signing Key (USK) -- signs other users' master keys
            |
            |-- Bob's MSK (signed by Alice's USK)
            |-- Carol's MSK (signed by Alice's USK)
```

**How it works in practice:**

1. When Alice sets up cross-signing (typically during the "security setup" flow on first login), her client generates the MSK, SSK, and USK.
2. The SSK automatically signs all of Alice's device keys. Any new device Alice adds is also signed by the SSK.
3. When Alice verifies Bob (once, through SAS or QR code), Alice's USK signs Bob's MSK.
4. From that point on, Alice's client trusts **all** of Bob's current and future devices -- because they are signed by Bob's SSK, which is signed by Bob's MSK, which Alice has verified.

This reduces the verification burden to one interaction per user pair, regardless of how many devices each has.

### 6.5 Key Backup

If you lose all your devices (phone destroyed, laptop stolen, etc.), you lose your Megolm session keys, which means you lose access to your entire encrypted message history. The encrypted events still exist on the server, but without the session keys, they are indecipherable.

Key backup solves this by encrypting your session keys and storing them on the homeserver:

1. The user creates a recovery passphrase (or receives a recovery key -- a random string).
2. An AES-256 encryption key is derived from the recovery passphrase via PBKDF2.
3. All Megolm session keys, cross-signing keys, and other secrets are encrypted with this derived key.
4. The encrypted blobs are stored on the homeserver as account data.
5. When the user sets up a new device, they enter their recovery passphrase, the client downloads the encrypted backup from the server, decrypts it, and restores all session keys.

**Security trade-off:** Key backup deliberately weakens forward secrecy. Without backup, losing your devices means the messages are gone forever -- the encrypted blobs exist on the server, but no one has the keys. That is the purest form of forward secrecy. With backup, if an attacker obtains both the encrypted backup (from the server) and your recovery passphrase, they can decrypt your entire message history. The trade-off is usability vs. perfect forward secrecy, and for most users, the ability to recover their messages outweighs the theoretical risk.

The backup mechanism is sometimes called **SSSS (Secure Secret Storage and Sharing)** and stores data in `m.megolm_backup.v1` account data events.

### 6.6 Why E2EE Makes Bridges Complex

Bridges connect Matrix rooms to external platforms (WhatsApp, Telegram, Discord, Slack -- see [Bridges](05-bridges.md)). In an E2EE room, the bridge needs to **decrypt** Matrix messages in order to relay them to the external platform, and **encrypt** external messages before sending them into the Matrix room.

This means the bridge is, cryptographically, another "device" in the room. It holds Megolm session keys. It can read every message. The implications:

1. **The bridge is a trust boundary.** If the bridge is compromised, all encrypted message content it has access to is exposed. Users must trust the bridge operator. In a self-hosted deployment like ours, the bridge operator is the same person running the homeserver, which is the natural trust boundary anyway.

2. **Device verification warnings.** The bridge's devices appear in room member device lists. Users may see "unverified device" warnings for bridge bot accounts or ghost users. This can be confusing, and some clients allow per-user trust overrides to suppress these warnings.

3. **E2EE rooms may not work with bridges by default.** The bridge must be explicitly configured to support encryption (all mautrix bridges support this, but it is not always enabled out of the box). Synapse must allow bridge appservice users to participate in encrypted rooms.

4. **Key sharing complexity.** When a bridge joins an existing encrypted room, it needs the current Megolm session key. The session creator's device may or may not automatically share keys with the bridge's device, depending on trust settings. This can result in "Unable to decrypt" messages from the bridge's perspective.

5. **Double puppeting interaction.** When double puppeting is active (the bridge sends messages as the user's actual Matrix account rather than a ghost user), the bridge operates under the user's own device, simplifying the trust model. See [Bridges](05-bridges.md) for details on double puppeting configuration.

The pragmatic reality is that E2EE and bridges are in fundamental tension. Bridges exist to read and relay messages, which contradicts E2EE's goal of restricting who can read messages. Our deployment handles this by running bridges as trusted first-party infrastructure -- the bridge code runs on the same server as Synapse, with direct access to the homeserver's appservice API (see [Deployment Architecture](04-deployment-architecture.md)).

---

## 7. Client-Server API

### 7.1 REST API Overview

The Client-Server (C-S) API is how Matrix clients communicate with their homeserver. It is a RESTful HTTPS API with JSON request and response bodies. All endpoints are under the `/_matrix/client/` path prefix.

The API is versioned. Current stable endpoints use `v3`:

```
/_matrix/client/v3/...
```

Older versions (`r0`, `v1`) are still supported by most servers for backward compatibility.

**Authentication:** Most endpoints require an access token, sent as a Bearer token:

```
GET /_matrix/client/v3/sync
Authorization: Bearer syt_dGVzdA_XKFPHnwZfsmOkhBCol_1abCdE
```

In our deployment, nginx routes most C-S API requests to Synapse on port 8008, but routes `/login`, `/logout`, and `/refresh` to MAS (the Matrix Authentication Service). See the nginx routing rules in [Deployment Architecture](04-deployment-architecture.md).

**Key API categories:**

| Category | Example Endpoints | Purpose |
|----------|------------------|---------|
| Authentication | `/login`, `/logout`, `/register`, `/refresh` | Session management |
| Sync | `/sync` | Retrieve new events since last check |
| Room management | `/createRoom`, `/join/{roomIdOrAlias}`, `/leave` | Room lifecycle |
| Messaging | `/rooms/{roomId}/send/{eventType}/{txnId}` | Send events |
| State | `/rooms/{roomId}/state/{eventType}/{stateKey}` | Read/write room state |
| Room directory | `/publicRooms` | Discover public rooms |
| Room history | `/rooms/{roomId}/messages` | Paginate through room history |
| User data | `/profile/{userId}`, `/account/whoami` | User profiles |
| Device management | `/devices`, `/delete_devices` | Manage logged-in devices |
| Encryption | `/keys/upload`, `/keys/query`, `/keys/claim` | E2EE key management |
| Push | `/pushers`, `/pushrules` | Push notification configuration |
| Media | `/_matrix/media/v3/upload`, `/download` | Upload/download files |
| Account data | `/user/{userId}/account_data/{type}` | Per-user settings |

**Error format:**

```json
{
  "errcode": "M_FORBIDDEN",
  "error": "You are not allowed to perform this action"
}
```

Standard error codes include `M_FORBIDDEN`, `M_NOT_FOUND`, `M_UNKNOWN_TOKEN` (expired or invalid access token), `M_LIMIT_EXCEEDED` (rate limiting -- response includes `retry_after_ms`), `M_BAD_JSON`, `M_MISSING_TOKEN`, and many more.

### 7.2 The Sync Endpoint

The `/sync` endpoint is the heart of the Client-Server API. It is how clients receive new events from the server. Understanding its behavior -- and its limitations -- is essential for understanding the Matrix client experience.

**Basic flow:**

1. The client calls `GET /_matrix/client/v3/sync` with no `since` parameter. This is the **initial sync**: the server returns all rooms the user is in, their current state, and recent timeline events.
2. The response includes a `next_batch` token.
3. The client calls `/sync?since=<next_batch>&timeout=30000` to get only events that happened since the last sync.
4. If nothing has happened, the server **long-polls**: it holds the connection open until either a new event arrives or the timeout expires (30 seconds in this example).
5. Repeat from step 3 indefinitely.

**Response structure (simplified):**

```json
{
  "next_batch": "s72595_4483_1934",
  "rooms": {
    "join": {
      "!room1:example.org": {
        "state": {
          "events": [...]
        },
        "timeline": {
          "events": [...],
          "prev_batch": "t47409-4357353_219380_26003_2265",
          "limited": false
        },
        "ephemeral": {
          "events": [...]
        },
        "account_data": {
          "events": [...]
        },
        "unread_notifications": {
          "highlight_count": 0,
          "notification_count": 2
        }
      }
    },
    "invite": {
      "!room2:example.org": {
        "invite_state": {
          "events": [...]
        }
      }
    },
    "leave": {}
  },
  "presence": {
    "events": [...]
  },
  "account_data": {
    "events": [...]
  },
  "to_device": {
    "events": [...]
  }
}
```

Each room in the `join` section includes:
- **state**: State events that changed since the last sync.
- **timeline**: New message events, with a `prev_batch` token for backward pagination.
- **ephemeral**: Typing notifications, read receipts.
- **account_data**: Per-room user settings (e.g., notification preferences, tags).
- **unread_notifications**: Counts of unread messages and highlights.

The `to_device` section carries device-to-device messages (key sharing, verification, etc.) that are not associated with any room.

**The limitations of /sync:**

The initial sync is where `/sync` breaks down at scale. A user in 1,000 rooms needs to download the state of all 1,000 rooms on first login. This can mean:
- 30+ seconds of wait time.
- 50+ MB of JSON to download, parse, and process.
- Significant server CPU and database load to compute the response.
- High memory usage on both server and client during processing.

Even incremental syncs can be slow if the user has been offline for a while -- the server must scan all rooms for new events since the last sync token.

This is not a bug in Synapse; it is inherent to the `/sync` API design, which was optimized for simplicity and correctness over performance at scale. The solution is Sliding Sync ([Section 8](#8-sliding-sync-msc3575)).

### 7.3 Room Listing and Sending Messages

**Listing rooms:**

The client's joined rooms come from the `/sync` response. For a quick list without full room data:

```
GET /_matrix/client/v3/joined_rooms
```

Returns a simple array of room IDs. Public rooms can be discovered via:

```
POST /_matrix/client/v3/publicRooms
```

Which supports filtering by search term, server (for federated directory queries), and third-party network (for bridged room directories).

**Sending messages:**

Messages are sent as events using a PUT request with a client-generated transaction ID for idempotency:

```
PUT /_matrix/client/v3/rooms/!room:example.org/send/m.room.message/txn1
Content-Type: application/json
Authorization: Bearer <token>

{
  "msgtype": "m.text",
  "body": "Hello, world!"
}
```

The server responds with the event ID:

```json
{
  "event_id": "$YUwRidLecu:example.org"
}
```

The transaction ID (`txn1`) is crucial for idempotency: if the client retries the request (due to a network timeout where the response was lost but the server processed the request), the server recognizes the duplicate `txnId` and returns the same event ID without creating a duplicate event.

**Setting state:**

State events are set with:

```
PUT /_matrix/client/v3/rooms/!room:example.org/state/m.room.name/
Content-Type: application/json

{
  "name": "New Room Name"
}
```

The state key is the last path component (empty string for most state events, a user ID for `m.room.member`, etc.).

### 7.4 Pagination

Room history is paginated using opaque tokens. You never request "page 2" by number. Instead, you request "events before token X."

The `/sync` response includes a `prev_batch` token in each room's timeline. To load older messages:

```
GET /_matrix/client/v3/rooms/{roomId}/messages?from={prev_batch}&dir=b&limit=50
```

Parameters:
- `from`: The pagination token (from a previous sync or messages response).
- `dir`: Direction. `b` for backward (older messages), `f` for forward (newer messages).
- `limit`: Maximum number of events to return.

The response includes `start` and `end` tokens. To load more history, use the `end` token as the next `from` value. When you reach the beginning of the room's history (or the oldest event you have access to based on history visibility), the `end` token will be absent.

There is also a context endpoint for jumping to a specific event:

```
GET /_matrix/client/v3/rooms/{roomId}/context/{eventId}?limit=20
```

This returns the specified event plus surrounding events (before and after), useful for "jump to message" features and notification handling.

Token-based pagination is more robust than offset-based pagination: it works correctly even when new events are being inserted concurrently (no skipped or duplicated items), and it is efficient for servers to implement (tokens can map directly to database cursors).

### 7.5 Lazy-Loading Members

A room with 10,000 members has 10,000 `m.room.member` state events. Sending all of these in the initial sync is wasteful -- the client does not need to know about every member until their messages actually appear on screen.

Lazy-loading members is enabled via a sync filter:

```json
{
  "room": {
    "state": {
      "lazy_load_members": true
    }
  }
}
```

With lazy-loading enabled, the server only includes `m.room.member` events for users who sent messages in the returned timeline chunk. When the client paginates backward and encounters messages from new senders, it receives their member events at that point.

This optimization dramatically reduces initial sync size for large rooms -- instead of 10,000 member events, you might receive 20 (for the 20 most recent message senders). It is enabled by default in most modern clients.

The trade-off is that the client cannot display a complete member list without explicitly fetching it:

```
GET /_matrix/client/v3/rooms/{roomId}/members
```

---

## 8. Sliding Sync (MSC3575)

### 8.1 Why /sync is Slow at Scale

The traditional `/sync` endpoint has a fundamental architectural problem: it treats all rooms equally. Whether you have 10 rooms or 10,000, the initial sync attempts to return data for all of them. For incremental syncs, the server must check all rooms for new events since the last sync token.

Real-world performance at scale:
- **Initial sync for a user in 2,000 rooms**: 30+ seconds, 50+ MB of JSON.
- **Memory usage**: Both server and client must hold the entire response in memory during processing.
- **Battery drain**: On mobile devices, processing large sync responses burns significant CPU.
- **Server load**: Computing sync responses is one of Synapse's most resource-intensive operations, involving complex database queries across many rooms.

These are not implementation bugs -- they are inherent to the API design, which was created for simplicity and correctness before scale became a concern.

### 8.2 How Sliding Sync Works

Sliding Sync (originally MSC3575, now incorporated into the Matrix spec) reimagines sync with a fundamentally different model: instead of "give me everything," the client says "give me exactly what I need right now."

**Core concepts:**

**Sorted room lists.** The client requests a list of rooms sorted by some criterion (typically most recent activity). The server maintains this sorted list and can efficiently update it.

**Sliding window.** The client specifies a range within the sorted list (e.g., rooms 0-19 -- the 20 most recently active rooms). The server returns data only for rooms within the window. As the user scrolls, the client slides the window, and the server sends data for newly visible rooms while cleaning up data for rooms that left the window.

**Room subscriptions.** For rooms the user has explicitly opened (clicked on, is actively viewing), the client creates a subscription. Subscribed rooms receive full real-time updates regardless of their position in the window.

**Sticky parameters.** The client only sends parameters that have changed since the last request. The server remembers previous parameters. This minimizes request payload size for incremental updates.

**Delta responses.** The server only sends changes since the last response. If 3 of your 1,000 rooms had new messages, you receive data for those 3 rooms plus list reordering operations (e.g., "room X moved from position 47 to position 0").

**Example flow:**

1. Client connects and requests:
   - A room list sorted by recency.
   - Window: rooms 0-19 (the 20 most recently active).
   - For each room: name, avatar, latest message, unread count.

2. Server responds with data for those 20 rooms. Initial load: under 1 second, regardless of total room count.

3. User opens room #5. Client adds a subscription for that room, requesting full timeline and state updates.

4. A new message arrives in room #47 (outside the window). The server responds with:
   - Room #47 moves to position 0 (most recent activity).
   - All other rooms shift down by 1.
   - The room that was at position 19 falls out of the window (position 20 now).
   - Client receives the new message and room metadata for room #47 (now visible in the window).

5. User scrolls down. Client changes window to rooms 10-29. Server sends data for rooms 20-29 (newly visible), and indicates rooms 0-9 are no longer in the window.

The result: initial load drops from 30+ seconds to under 1 second. Bandwidth drops from 50+ MB to a few KB. Server load drops proportionally. The user experience is fundamentally transformed.

### 8.3 The Sliding Sync Proxy

Before native Sliding Sync support was added to Synapse, the Matrix team built a separate proxy server (`sliding-sync`, also known as `syncv3-proxy`) that translates between the traditional `/sync` API and the Sliding Sync API:

1. The proxy connects to Synapse as a "super client" using the traditional `/sync` endpoint.
2. It maintains its own database with pre-computed room lists and indexes.
3. It exposes the Sliding Sync API to actual clients.
4. It translates client requests into the data it has already synced from Synapse.

Our deployment includes this proxy as the `sliding-sync` service with its own PostgreSQL database (`postgres-sliding-sync`). Configuration:

- `SYNCV3_SERVER`: Points to the Synapse URL (so the proxy can sync from Synapse).
- `SYNCV3_DB`: PostgreSQL connection string for the proxy's own database.
- `SYNCV3_SECRET`: A shared secret for signing tokens.
- The proxy listens on port 8009.

Clients discover the proxy via the `.well-known/matrix/client` response, which includes:

```json
{
  "org.matrix.msc3575.proxy": {
    "url": "https://sync.synapse.your.matrix.server.de"
  }
}
```

### 8.4 Native Sliding Sync

Starting with Synapse 1.114 (late 2024), native Sliding Sync support (called "Simplified Sliding Sync" or SSS) was added directly to Synapse, eliminating the need for the external proxy.

Advantages of native over proxy:
- **Simpler infrastructure.** No separate service, no separate database, no separate PostgreSQL instance to maintain.
- **Lower latency.** Events go directly from Synapse to the client with no intermediary.
- **Better resource efficiency.** No duplication of data between Synapse's database and the proxy's database.
- **Simpler deployment.** One less service to monitor, upgrade, and debug.

To use native Sliding Sync, Synapse must be configured with the appropriate experimental feature flag. Clients then use the Synapse server URL directly for both traditional and Sliding Sync, rather than connecting to a separate proxy URL.

Our deployment currently uses the external proxy. Migration to native Sliding Sync would allow removing the `sliding-sync` service and `postgres-sliding-sync` database from the Docker Compose stack, simplifying operations. This is documented in [Synapse Homeserver](02-synapse-homeserver.md).

---

## 9. Matrix Clients

### 9.1 Element: The Reference Client Family

Element is the primary client family for Matrix, developed by Element (the company). There are currently two generations:

**Element Web / Desktop (legacy generation):**
- Built on React and the `matrix-js-sdk`.
- Full-featured: rooms, spaces, threads, E2EE, voice/video calls (via Jitsi or Element Call), widgets, custom themes, sticker packs.
- Uses the traditional `/sync` endpoint.
- Mature and battle-tested, but showing its age -- large JavaScript bundle, slow startup for users in many rooms, high memory usage.
- Element Desktop is Element Web wrapped in Electron.
- Still the most feature-complete Matrix client available.

**Element X (next generation):**
- Completely rewritten from scratch.
- iOS version uses Swift; Android version uses Kotlin.
- Built on the `matrix-rust-sdk`, a Rust library compiled to native code via UniFFI.
- Uses Sliding Sync exclusively -- requires either the proxy or native SSS.
- Dramatically faster startup, lower memory usage, better battery life on mobile.
- Feature set is still catching up with legacy Element but covers all core functionality for daily use.
- No web version yet (the Rust SDK can compile to WASM, but a web client is not yet released).

**Element Call:**
- Dedicated voice/video conferencing application built on Matrix.
- Uses Matrix rooms for signaling and either peer-to-peer WebRTC or an SFU (Selective Forwarding Unit) called LiveKit for media.
- Can be embedded as a widget inside Element Web or used standalone.

For our deployment, clients connect via the nginx entry point at `https://matrix.your.matrix.server.de`. Client auto-discovery uses the `.well-known/matrix/client` endpoint served by nginx, which provides the Synapse URL, Sliding Sync proxy URL, and authentication issuer URL. Element X users benefit from the sliding-sync proxy for fast initial loads; legacy Element Web users use the traditional `/sync` endpoint against Synapse directly.

### 9.2 Alternative Clients

One of Matrix's strengths is client diversity. Because the protocol is fully open and documented, anyone can build a client. Notable alternatives:

**FluffyChat:**
- Built with Flutter (truly cross-platform: Android, iOS, Linux, macOS, Windows, Web).
- Simpler, friendlier UI aimed at less technical users. More WhatsApp-like than Slack-like.
- Good E2EE support via the `matrix_dart_sdk`.
- Built-in support for stories (a social media-like feature).
- Lighter weight than Element.

**Nheko:**
- Native desktop client written in C++ with Qt/QML.
- Focuses on performance and native look-and-feel (integrates with system themes).
- Excellent E2EE support.
- Advanced features: custom sticker packs, rich replies, Spaces, room directory.
- Primary development focus on Linux, but builds on macOS and Windows.

**Cinny:**
- Web-based client with a Discord-inspired interface.
- Built with React and `matrix-js-sdk`.
- Appeals strongly to users coming from Discord who want a familiar layout.
- Clean, modern design with good attention to visual detail.
- Desktop version available via Tauri (lighter than Electron).

**SchildiChat:**
- Fork of Element (both Web/Desktop and Android versions).
- Adds chat bubbles (like WhatsApp/Telegram), unified chat list, and other UI improvements.
- Stays close to upstream Element with cherry-picked UI changes.
- Good choice for users who want Element's full feature set with a more messenger-style feel.

**Fractal:**
- GNOME desktop client written in Rust with GTK4.
- Follows GNOME Human Interface Guidelines.
- On track to become the default Matrix client for the GNOME desktop environment.
- Uses `matrix-rust-sdk` under the hood.

**gomuks:**
- Terminal-based Matrix client written in Go.
- For users who live in the terminal.
- Supports E2EE.
- Minimal resource usage.

### 9.3 Client Feature Comparison

| Feature | Element Web | Element X | FluffyChat | Nheko | Cinny | SchildiChat |
|---------|:-----------:|:---------:|:----------:|:-----:|:-----:|:-----------:|
| E2EE | Yes | Yes | Yes | Yes | Yes | Yes |
| Cross-signing | Yes | Yes | Yes | Yes | Yes | Yes |
| Spaces | Yes | Yes | Yes | Yes | Yes | Yes |
| Threads | Yes | Yes | Partial | Yes | Yes | Yes |
| Voice/Video Calls | Yes | Yes | No | Yes | No | Yes |
| Sliding Sync | No | Required | Optional | Optional | No | No |
| Reactions | Yes | Yes | Yes | Yes | Yes | Yes |
| Rich replies | Yes | Yes | Yes | Yes | Yes | Yes |
| File upload | Yes | Yes | Yes | Yes | Yes | Yes |
| Custom themes | Yes | No | Yes | Yes | Yes | Yes |
| Multiple accounts | No | No | Yes | Yes | No | No |
| Widgets | Yes | No | No | No | No | Yes |
| SSO/OIDC login | Yes | Yes | Yes | Yes | Yes | Yes |
| Platforms | Web, Desktop | iOS, Android | All | Desktop | Web, Desktop | Web, Desktop, Android |
| SDK | matrix-js-sdk | matrix-rust-sdk | matrix-dart-sdk | mtxclient (C++) | matrix-js-sdk | matrix-js-sdk / Android SDK |

All clients listed here support SSO/OIDC login, which is required for our deployment since we use MAS with Keycloak. The client connects to `https://matrix.your.matrix.server.de`, discovers the auth issuer via `.well-known`, and redirects to Keycloak for authentication.

---

## 10. The Matrix Ecosystem

### 10.1 Homeserver Implementations

The Matrix specification is implementation-agnostic. Anyone can write a homeserver that passes the spec compliance tests. The main implementations:

**Synapse (Python/Twisted):**
- The original and most mature homeserver. Developed by Element.
- Full spec compliance: supports the complete Client-Server, Server-to-Server, Application Service, and Identity Service APIs.
- The most widely deployed homeserver. Powers matrix.org (the largest public homeserver).
- Supports horizontal scaling via **workers** -- separate processes that handle specific tasks (federation sending, media processing, sync handling, push notifications).
- Extensive admin API for user management, room management, media management, and server administration.
- Known for higher memory usage (Python overhead, aggressive caching) and CPU-intensive sync operations.
- This is what our deployment runs. See [Synapse Homeserver](02-synapse-homeserver.md) for deep configuration and tuning details.

**Dendrite (Go):**
- Second-generation homeserver, also developed by Element.
- Written in Go for better performance and lower resource usage.
- Component architecture with separate internal components for different API surfaces.
- Reached production-ready status but development has slowed as Element has focused investment on Synapse optimizations (workers, native Sliding Sync, Rust-based hot paths).
- Suitable for smaller deployments and experimentation.
- Not yet feature-complete compared to Synapse (missing some admin APIs, some federation edge cases).

**Conduit / Conduwuit (Rust):**
- Community-developed homeserver written in Rust.
- Conduit was the original project; **Conduwuit** is an actively maintained fork with more features and fixes.
- Focuses on simplicity, low resource usage, and easy deployment (single binary, embedded database).
- Uses RocksDB or SQLite (no PostgreSQL required).
- Impressively efficient: can run a small homeserver on a Raspberry Pi.
- Not yet fully spec-compliant, but improving rapidly and suitable for personal or small-group use.

**Comparison:**

| Property | Synapse | Dendrite | Conduwuit |
|----------|---------|----------|-----------|
| Language | Python (Twisted) | Go | Rust |
| Maturity | Production (since 2014) | Production-ready | Beta |
| Spec compliance | Full | High | Medium |
| Memory (idle, small server) | 300-500 MB | 50-100 MB | 20-50 MB |
| Database | PostgreSQL (recommended), SQLite (dev only) | PostgreSQL | RocksDB, SQLite |
| Horizontal scaling | Yes (workers) | Partial (components) | No |
| Admin API | Extensive | Partial | Partial |
| E2EE support | Full | Full | Full |
| Bridge support (appservice API) | Full | Full | Partial |
| Community size | Largest | Medium | Growing |

### 10.2 Bridges

Bridges connect Matrix to external communication platforms. They use the **Application Service (AS) API**, a privileged server-side protocol between the homeserver and the bridge. The AS API allows bridges to:

- Register **ghost users** on the homeserver (e.g., `@whatsapp_491234567890:your.matrix.server.de` representing a WhatsApp contact).
- Declare interest in events via namespace patterns (user ID regexes, room alias regexes).
- Send events on behalf of ghost users (making it look like the remote user sent a Matrix message).
- Receive events pushed from the homeserver (rather than polling `/sync`).

Bridges are registered via YAML registration files placed on the homeserver's filesystem. Our deployment generates these in init containers and mounts them into Synapse via the `bridge-registrations` shared volume. See [Bridges](05-bridges.md) for the complete details.

The bridge ecosystem is dominated by **mautrix bridges**, developed by Tulir Asokan. Our deployment includes four:

| Bridge | Platform | Image | Internal Port |
|--------|----------|-------|:------------:|
| mautrix-whatsapp | WhatsApp | `dock.mau.dev/mautrix/whatsapp` | 29318 |
| mautrix-telegram | Telegram | `dock.mau.dev/mautrix/telegram` | 29317 |
| mautrix-discord | Discord | `dock.mau.dev/mautrix/discord` | 29334 |
| mautrix-slack | Slack | `dock.mau.dev/mautrix/slack` | 29335 |

Additional mautrix bridges available but not yet deployed in our stack:

| Bridge | Platform | Notes |
|--------|----------|-------|
| mautrix-signal | Signal | Built-in libsignal, QR code pairing |
| mautrix-meta | Facebook Messenger + Instagram | Single bridge for both Meta platforms |
| mautrix-gmessages | Google Messages (SMS/RCS) | Pairs with Google Messages web |
| mautrix-twitter | Twitter/X | DMs only |
| mautrix-linkedin | LinkedIn | Messaging only |
| mautrix-googlechat | Google Chat | Workspace messaging |

Non-mautrix bridges of note:

| Bridge | Purpose |
|--------|---------|
| **matrix-hookshot** | GitHub/GitLab/JIRA notifications and generic webhooks |
| **heisenbridge** | Personal IRC bouncer (per-user IRC connections) |
| **matrix-appservice-irc** | Server-wide IRC network bridging |
| **postmoogle** | Email (SMTP) to Matrix rooms |

### 10.3 Bots

Matrix bots are regular Matrix users that respond to events programmatically. They can use either the standard Client-Server API (like any other client) or the Application Service API (for more privileged access).

**maubot (Python):**
- Plugin-based bot framework by Tulir Asokan (the mautrix bridge developer).
- Plugins are distributed as `.mbp` files (ZIP archives).
- Has a web-based management UI for installing, configuring, and managing plugins.
- Large library of existing plugins: RSS feeds, reminders, polls, dice rolling, translation, echo, sed-style message editing, and more.
- Uses the Client-Server API.

**matrix-bot-sdk (TypeScript):**
- SDK for building custom Matrix bots in TypeScript/JavaScript.
- Supports E2EE.
- Used by many community bots and by matrix-hookshot.

**matrix-rust-sdk (Rust):**
- Can be used to build high-performance bots.
- Best performance profile of any SDK.

Bots interact with the homeserver through the standard Client-Server API. They authenticate with access tokens, join rooms (or are invited), listen for events via `/sync`, and send responses. From the protocol's perspective, there is no difference between a bot and a human user -- the distinction is entirely in the client software.

### 10.4 Widgets and Integration Managers

**Widgets** are web applications embedded inside Matrix rooms. They are displayed in an iframe within the client UI. Examples include:
- Jitsi or Element Call video conferencing.
- Collaborative document editors (Etherpad, HedgeDoc).
- Poll widgets.
- Calendars and planning tools.
- Custom dashboards.

Widgets are declared via `im.vector.modular.widgets` (or `m.widget`) state events in the room. The widget URL can include template variables like `$matrix_user_id` and `$matrix_room_id` that the client substitutes before loading the iframe. A Widget API (postMessage-based) allows the embedded web application to interact with the Matrix room (send events, read state, etc.).

**Integration managers** (like Dimension or the legacy Scalar) provide a UI for discovering and adding bots, bridges, and widgets to rooms. They are entirely optional -- you can configure everything manually via state events and bot accounts. Our deployment does not include an integration manager; bridges are configured at the infrastructure level in Docker Compose.

### 10.5 The Spec Process: MSCs

The Matrix specification evolves through **Matrix Spec Changes (MSCs)**. The process is designed for transparency, community input, and careful deliberation -- changes to a federated protocol affect every implementation and cannot be easily rolled back.

**The MSC lifecycle:**

1. **Proposal.** Anyone can write an MSC as a pull request against the [matrix-spec-proposals](https://github.com/matrix-org/matrix-spec-proposals) GitHub repository. It is a Markdown document that includes motivation, detailed design, alternatives considered, security considerations, and backward compatibility analysis.

2. **Discussion.** The MSC is discussed on the GitHub PR and in the `#matrix-spec:matrix.org` room. The Spec Core Team (SCT) and community provide feedback. Authors iterate on the design.

3. **Implementation.** Implementations can (and often do) implement MSCs before they are merged, using **unstable prefixes**. For example, Sliding Sync used `org.matrix.msc3575` prefixes before being stabilized as part of the spec. This allows real-world testing.

4. **FCP (Final Comment Period).** When the SCT believes the MSC is ready, they initiate a 5-day Final Comment Period. This is the last chance for blocking objections.

5. **Merge.** If no blocking objections arise during FCP, the MSC is accepted and the spec text is incorporated.

6. **Spec release.** The Matrix spec is released periodically (v1.1, v1.2, ... v1.12 as of early 2026). Each release bundles all MSCs accepted since the previous release.

**MSCs relevant to our deployment:**

| MSC | Title | Status | Relevance |
|-----|-------|--------|-----------|
| MSC3575 | Sliding Sync | Merged | Powers our `sliding-sync` proxy and Element X support |
| MSC3861 | Delegating auth to OIDC (MAS) | Merged | Our entire auth flow: MAS + Keycloak |
| MSC1772 | Spaces | Merged | Room organization via hierarchical Spaces |
| MSC2675 | Event relationships (aggregations) | Merged | Powers reactions, edits, threads |
| MSC3440 | Threading | Merged | Thread support in rooms |
| MSC3245 | Voice messages | Merged | Used by bridge audio messages |
| MSC3916 | Authenticated media | Merged | Prevents unauthorized media access |
| MSC2716 | Importing history | In progress | Relevant for bridge history backfill |
| MSC1767 | Extensible events | In progress | Future-proofing the event format |

---

## Further Reading

- [Matrix Specification](https://spec.matrix.org/) -- The authoritative reference for all protocol details.
- [Matrix.org Blog](https://matrix.org/blog/) -- Announcements, deep-dives, and ecosystem updates from the Foundation.
- [Matrix Spec Change Proposals](https://github.com/matrix-org/matrix-spec-proposals) -- All proposed and accepted MSCs.
- [Synapse Documentation](https://element-hq.github.io/synapse/latest/) -- Official Synapse administration and configuration docs.
- [Are We Matrix Yet?](https://areweyet.matrix.org/) -- Community tracker of Matrix clients, servers, bridges, and tools.
- [Matrix Clients Directory](https://matrix.org/ecosystem/clients/) -- Comprehensive client comparison.
- [Olm/Megolm Specification](https://gitlab.matrix.org/matrix-org/olm/-/blob/master/docs/megolm.md) -- Encryption protocol technical details.
- [State Resolution v2 Specification](https://spec.matrix.org/latest/rooms/v2/) -- The algorithm that makes decentralized consensus work.

---

**Next in the series:** [02 - Synapse Homeserver](02-synapse-homeserver.md) -- Deep-dive into Synapse internals, configuration, performance tuning, workers, the admin API, and our specific deployment choices.

# Part 3: The Authentication Stack

> **Series:** Self-Hosted Matrix Deep Dive
> **Previous:** [02 - Synapse Homeserver](./02-synapse-homeserver.md) | **Next:** [04 - Deployment Architecture](./04-deployment-architecture.md)

This document covers everything about how users prove their identity in our Matrix deployment. Authentication is arguably the most complex subsystem in a modern Matrix setup, spanning three distinct services -- Keycloak, MAS, and Synapse -- each with precisely defined responsibilities. We will work from first principles up through the actual running configuration.

---

## Table of Contents

1. [Authentication in Matrix: A History](#1-authentication-in-matrix-a-history)
2. [OIDC Fundamentals](#2-oidc-fundamentals)
3. [Matrix Authentication Service (MAS)](#3-matrix-authentication-service-mas)
4. [Keycloak as the Upstream Identity Provider](#4-keycloak-as-the-upstream-identity-provider)
5. [The Authentication Flow in Our Deployment](#5-the-authentication-flow-in-our-deployment)
6. [MAS Configuration Deep-Dive](#6-mas-configuration-deep-dive)
7. [The MAS Init Container Pattern](#7-the-mas-init-container-pattern)
8. [Synapse MSC3861 Integration](#8-synapse-msc3861-integration)
9. [Token Lifecycle](#9-token-lifecycle)
10. [Security Considerations](#10-security-considerations)

---

## 1. Authentication in Matrix: A History

### The Original Model: Passwords and Access Tokens

When Matrix launched, authentication was simple. A client would POST credentials (username and password) to the `/_matrix/client/v3/login` endpoint on the homeserver. If the credentials were valid, the homeserver would return an **access token** -- a long-lived opaque string that the client would include in subsequent requests as a Bearer token. That was the entire story.

This design had several properties worth noting:

- **The homeserver was the identity provider.** It stored password hashes (bcrypt) in its own database and performed all credential validation internally.
- **Access tokens were long-lived.** There was no expiry by default. A token lived until the user explicitly logged out or an admin revoked it.
- **There were no refresh tokens.** If your access token leaked, the attacker had access until someone noticed and revoked it manually.
- **No standard for third-party identity.** Synapse bolted on SSO support later (first SAML, then CAS, then a native OIDC provider integration), but each was a homeserver-specific implementation, not a protocol-level standard.

This model worked for small deployments but created real problems at scale:

1. **Every homeserver reinvented authentication.** Dendrite, Conduit, and Synapse each had their own password storage, rate limiting, and brute-force protection.
2. **No token rotation.** Long-lived tokens are a security liability.
3. **SSO was bolted on.** The `oidc_providers` config in Synapse (visible in our repo as the commented-out `template.oidc.yaml`) worked but required Synapse to manage OIDC state, token exchange, and user mapping -- concerns that do not belong in a messaging server.
4. **Clients had no standard way to discover authentication.** Each homeserver's SSO integration worked slightly differently.

### The Road to MSC3861

The Matrix spec team recognized that authentication needed to be extracted from the homeserver entirely. The result was a series of Matrix Spec Changes (MSCs):

- **MSC2964** defined how Matrix clients should use OIDC for authentication, replacing the legacy login/password flow.
- **MSC2965** specified how clients discover the OIDC issuer via `.well-known`.
- **MSC3861** is the critical one for server operators. It defines a new experimental feature where Synapse **delegates all authentication decisions to an external OIDC-compliant authentication service.** Synapse stops managing passwords, stops issuing tokens, and instead validates tokens issued by the external service.

This is the model our deployment uses. Synapse has `password_config.enabled: false` and `enable_registration: false`. It cannot authenticate anyone on its own. All authentication flows through the Matrix Authentication Service (MAS), which in turn delegates to Keycloak.

### The Legacy Configuration (For Reference)

Our repository contains `configurations/synapse/template.oidc.yaml`, which shows the **old** approach -- commented out, preserved as a historical artifact:

```yaml
#oidc_providers:
#  - idp_id: keycloak
#    idp_name: "{{SYNAPSE_FRIENDLY_SERVER_NAME}}"
#    issuer: "{{KEYCLOAK_FQDN}}/realms/{{KEYCLOAK_REALM_IDENTIFIER}}"
#    client_id: "{{KEYCLOAK_CLIENT_ID}}"
#    client_secret: "{{KEYCLOAK_CLIENT_SECRET}}"
#    scopes: ["openid", "profile"]
#    user_mapping_provider:
#      config:
#        localpart_template: "{{ user.preferred_username }}"
#        display_name_template: "{{ user.given_name }}"
#    backchannel_logout_enabled: true
```

In this old model, Synapse itself was an OIDC Relying Party, talking directly to Keycloak. This worked, but it meant Synapse had to understand OIDC flows, manage sessions, and handle token exchange. MSC3861 moves all of that into MAS, leaving Synapse to do what it does best: federate messages.

---

## 2. OIDC Fundamentals

Before we can understand how MAS and Keycloak work together, we need a solid foundation in OpenID Connect. If you already know OIDC well, skip to [Section 3](#3-matrix-authentication-service-mas).

### OAuth 2.0: The Foundation

OAuth 2.0 is an **authorization** framework. It answers the question: "Can this application access this resource on behalf of this user?" It does NOT answer: "Who is this user?" That distinction matters.

OAuth 2.0 defines several roles:

| Role | Description | In Our Stack |
|------|-------------|--------------|
| **Resource Owner** | The user who owns the data | The Matrix user |
| **Client** | The application requesting access | Element (web/mobile), or Synapse itself |
| **Authorization Server** | Issues tokens after authenticating the user | MAS (with Keycloak upstream) |
| **Resource Server** | Hosts the protected resources | Synapse (the homeserver) |

OAuth 2.0 alone gives you **access tokens** but no standard way to identify the user. That is where OpenID Connect comes in.

### OpenID Connect: Identity on Top of OAuth 2.0

OIDC is a thin identity layer built on OAuth 2.0. It adds:

1. **ID Tokens** -- JWTs (JSON Web Tokens) that contain claims about the user's identity. An ID token tells the client who the user is.
2. **A UserInfo endpoint** -- A standard API endpoint where clients can fetch additional user information.
3. **A Discovery mechanism** -- The `/.well-known/openid-configuration` endpoint that publishes the authorization server's capabilities.
4. **Standard scopes and claims** -- `openid`, `profile`, `email`, etc.

### The Three Token Types

OIDC flows produce up to three tokens, each with a distinct purpose:

**ID Token**
- A JWT signed by the authorization server.
- Contains **claims** about the user: `sub` (subject identifier), `name`, `email`, `preferred_username`, etc.
- Consumed by the **client** to know who the user is.
- Short-lived (minutes to hours). Never sent to resource servers.

**Access Token**
- Authorizes API requests to resource servers.
- Can be opaque (a random string the resource server validates by calling the authorization server) or a JWT (self-contained, verifiable without a network call).
- In Matrix's MSC3861 model, MAS issues access tokens that Synapse validates.
- Has a defined expiry (typically 5-30 minutes in modern deployments).

**Refresh Token**
- A long-lived credential used to obtain new access tokens without re-authenticating.
- Stored securely by the client (never sent to resource servers).
- Enables **token rotation**: the client regularly exchanges a refresh token for a fresh access token, limiting the damage window if an access token leaks.

### Scopes and Claims

**Scopes** are permissions the client requests. In our deployment, MAS requests three scopes from Keycloak:

```
openid profile email
```

- `openid` -- Required. Signals this is an OIDC request (not plain OAuth 2.0). Returns the `sub` claim.
- `profile` -- Grants access to profile claims: `name`, `preferred_username`, `given_name`, etc.
- `email` -- Grants access to `email` and `email_verified` claims.

**Claims** are key-value pairs in the ID token (or UserInfo response) that carry user information. The claims our deployment uses:

| Claim | Source | Used For |
|-------|--------|----------|
| `preferred_username` | Keycloak user profile | Matrix localpart (the `alice` in `@alice:server.de`) |
| `name` | Keycloak user profile | Matrix display name |
| `email` | Keycloak user profile | Matrix email address |

### Authorization Code Flow

Our deployment uses the **Authorization Code flow**, the most secure standard OIDC flow. Here is how it works in the abstract (we will map it to our concrete services in Section 5):

```
1. Client redirects user to Authorization Server's /authorize endpoint
   with: response_type=code, client_id, redirect_uri, scope, state, nonce

2. Authorization Server authenticates the user (login form, MFA, etc.)

3. Authorization Server redirects user back to Client's redirect_uri
   with: code (a short-lived authorization code), state

4. Client sends the code to Authorization Server's /token endpoint
   (server-to-server, with client credentials)

5. Authorization Server returns: access_token, id_token, refresh_token

6. Client uses access_token to call Resource Server APIs
```

The critical security property: **the access token is never exposed to the user's browser.** The browser only sees the authorization code (which is single-use and short-lived). The token exchange happens server-to-server.

### How OIDC Differs From Plain OAuth 2.0

| Aspect | OAuth 2.0 | OpenID Connect |
|--------|-----------|----------------|
| Purpose | Authorization (can this app access this?) | Authentication + Authorization (who is this user AND can this app access this?) |
| ID Token | No | Yes (JWT with identity claims) |
| UserInfo Endpoint | No standard | Yes (`/userinfo`) |
| Discovery | No standard | Yes (`/.well-known/openid-configuration`) |
| Standard Scopes | No standard set | `openid`, `profile`, `email`, `address`, `phone` |
| Session Management | Not defined | Defined (front-channel/back-channel logout) |

---

## 3. Matrix Authentication Service (MAS)

### What It Is

The Matrix Authentication Service (MAS) is a standalone authentication server built by Element (the company behind the reference Matrix clients and the primary Synapse developers). It implements the OIDC-based authentication model defined by MSC2964, MSC2965, and MSC3861.

MAS sits **between** Matrix clients and your identity provider. It speaks OIDC to both sides:

- **Downstream** (toward clients and Synapse): MAS acts as an **OIDC Provider (OP)**. It has its own `/.well-known/openid-configuration` discovery document, its own `/authorize` and `/token` endpoints, and it issues its own tokens.
- **Upstream** (toward Keycloak): MAS acts as an **OIDC Relying Party (RP)**. It redirects users to Keycloak for actual credential verification, then processes the tokens Keycloak returns.

### Why Element Created It

The motivation was to decouple authentication from homeserver implementation:

1. **Homeserver agnosticism.** MAS works with Synapse today, but could work with Dendrite, Conduit, or any future homeserver. Authentication should not be a homeserver concern.
2. **Correctness.** OIDC is complex. Rather than every homeserver implementing it (with inevitable inconsistencies), one purpose-built service handles it.
3. **Modern token management.** MAS implements proper token rotation, refresh tokens with expiry, and session management out of the box.
4. **Upstream IdP flexibility.** MAS can delegate to any OIDC-compliant identity provider (Keycloak, Authentik, Azure AD, Google Workspace, etc.) through its `upstream_oauth2` configuration.

### What It Replaces

MAS replaces the following Synapse functionality:

- Password authentication (`/_matrix/client/*/login` with `type: m.login.password`)
- SSO/OIDC integration (`oidc_providers` in homeserver.yaml)
- User registration
- Token issuance and management
- Session management

With MAS in the picture, Synapse's `password_config.enabled` is set to `false` and `enable_registration` is `false`. Synapse becomes a pure resource server.

### Architecture

MAS is written in **Rust**, which gives it several operational advantages:

- **Small binary, low resource usage.** In our deployment, it runs with minimal memory overhead compared to Synapse (Python) or Keycloak (Java).
- **Fast startup.** Relevant for the init container pattern we use (Section 7).
- **No runtime dependencies beyond PostgreSQL.** No JVM, no Python interpreter, no Node.js.

The runtime architecture:

```
                          PostgreSQL
                         (postgres-synapse-mas)
                              |
                              v
  Clients <----> nginx <----> MAS (port 8080) <----> Keycloak (external)
                   |
                   v
                 Synapse (port 8008)
```

MAS stores its state in a dedicated PostgreSQL database (`postgres-synapse-mas` in our deployment). This database holds:

- Registered OIDC clients
- Active sessions
- Token records (access tokens, refresh tokens)
- User-to-upstream-provider mappings
- Compatibility layer data (for legacy Matrix clients)

### Container Images

MAS publishes two container images:

| Image | Contents | Use Case |
|-------|----------|----------|
| `ghcr.io/element-hq/matrix-authentication-service:latest` | Distroless image with only the MAS binary | Production runtime |
| `ghcr.io/element-hq/matrix-authentication-service:latest-debug` | Same binary + busybox shell + common utilities | Config generation, debugging |

Our deployment uses both: the `-debug` image for the init container (needs a shell to run `sed`), and the standard image for the runtime service. More on this in [Section 7](#7-the-mas-init-container-pattern).

---

## 4. Keycloak as the Upstream Identity Provider

### What Keycloak Is

Keycloak is an open-source Identity and Access Management (IAM) server, originally developed by Red Hat. It is a full-featured identity provider that handles:

- User storage and management (its own database of users, or federation with LDAP/Active Directory)
- Authentication flows (username/password, MFA, WebAuthn, social login)
- Authorization policies
- Identity brokering (acting as a proxy to other identity providers)
- Session management
- Account self-service (password reset, profile management, MFA enrollment)

Keycloak is written in Java, runs on Quarkus (formerly WildFly/JBoss), and is one of the most widely deployed open-source identity solutions.

### Core Concepts

**Realm**

A realm is a tenant in Keycloak -- an isolated namespace with its own users, clients, roles, and configuration. In our deployment, the realm is configured via `KEYCLOAK_REALM_IDENTIFIER` (e.g., `matrix` or `YourRealm`). Everything Matrix-related lives in this realm.

The realm's OIDC discovery URL is:

```
${KEYCLOAK_FQDN}/realms/${KEYCLOAK_REALM_IDENTIFIER}/.well-known/openid-configuration
```

For example: `https://keycloak.lesiv.dev/realms/matrix/.well-known/openid-configuration`

**Clients**

A client in Keycloak is an application that can request authentication. In our deployment, MAS is registered as a client in the Keycloak realm with:

- **Client ID**: `${KEYCLOAK_CLIENT_ID}` (e.g., `synapse`)
- **Client Secret**: `${KEYCLOAK_CLIENT_SECRET}`
- **Authentication method**: `client_secret_basic` (client ID and secret sent as HTTP Basic auth in the token request)

This client is configured with:
- **Standard flow enabled** (Authorization Code flow)
- **Valid redirect URIs** pointing back to MAS's callback endpoint
- **Scopes**: `openid`, `profile`, `email`

**Users**

Users are created in the Keycloak realm. Each user has:
- A unique `sub` (subject) identifier
- A `preferred_username` (which becomes the Matrix localpart)
- A `name` (display name)
- An `email` address
- Credentials (password, OTP, WebAuthn keys, etc.)

When a user authenticates, Keycloak packages these attributes into claims in the ID token, which MAS then uses to create or update the corresponding Matrix user.

**Identity Brokering**

Keycloak can itself delegate authentication to other identity providers (Google, GitHub, SAML providers, etc.). This is called identity brokering. In our deployment, Keycloak is the terminal identity provider (it stores users directly), but the architecture supports adding upstream providers in Keycloak without changing anything in MAS or Synapse.

### Keycloak's Role in Our Stack

Keycloak's responsibilities are strictly limited to:

1. **User credential storage and verification.** Keycloak stores password hashes, manages MFA devices, and handles account lockout policies.
2. **User profile management.** Users can update their display name, email, and password through Keycloak's account console at `${KEYCLOAK_FQDN}/realms/${KEYCLOAK_REALM_IDENTIFIER}/account`.
3. **OIDC token issuance to MAS.** When a user authenticates, Keycloak issues tokens to MAS, which MAS uses to extract identity claims.

Keycloak does NOT:
- Know anything about Matrix
- Issue tokens that Synapse or Matrix clients consume directly
- Manage Matrix sessions or devices

### Realm Configuration for Matrix

To set up the Keycloak realm for this deployment, the following must be configured:

1. **Create the realm** (e.g., `matrix`).
2. **Create a client** for MAS:
   - Client ID: matches `KEYCLOAK_CLIENT_ID`
   - Client authentication: ON (confidential client)
   - Authentication flow: Standard flow (Authorization Code)
   - Valid redirect URIs: `${SYNAPSE_MAS_FQDN}/upstream/callback/*`
   - Client secret: matches `KEYCLOAK_CLIENT_SECRET`
3. **Create users** with `preferred_username` set to the desired Matrix localpart.
4. **Ensure the following scopes are available**: `openid`, `profile`, `email`.
5. **Optionally configure MFA**, password policies, and brute-force protection.

---

## 5. The Authentication Flow in Our Deployment

This is the full end-to-end flow when a user opens Element and signs in. Every HTTP request, every redirect, every token exchange.

### The Flow Diagram

```mermaid
sequenceDiagram
    participant U as User (Browser)
    participant E as Element Web
    participant N as nginx
    participant M as MAS
    participant K as Keycloak
    participant S as Synapse

    Note over U,E: Step 1: Client Discovery
    E->>N: GET /.well-known/matrix/client
    N-->>E: {"m.homeserver": {...}, "org.matrix.msc2965.authentication": {"issuer": "..."}}

    Note over U,K: Step 2: OIDC Discovery
    E->>M: GET {issuer}/.well-known/openid-configuration
    M-->>E: OIDC metadata (authorize_endpoint, token_endpoint, etc.)

    Note over U,K: Step 3: Authorization Request
    E->>M: GET /authorize?response_type=code&client_id=...&scope=openid+profile+email&redirect_uri=...&state=...&nonce=...
    M->>M: No active session, need upstream auth
    M-->>U: 302 Redirect to Keycloak /authorize

    Note over U,K: Step 4: User Authentication
    U->>K: GET /realms/{realm}/protocol/openid-connect/auth?...
    K-->>U: Login page (username/password, optional MFA)
    U->>K: POST credentials
    K->>K: Validate credentials
    K-->>U: 302 Redirect to MAS callback with code

    Note over U,M: Step 5: MAS Processes Keycloak Callback
    U->>M: GET /upstream/callback?code=...&state=...
    M->>K: POST /realms/{realm}/protocol/openid-connect/token (exchange code for tokens)
    K-->>M: {access_token, id_token, refresh_token}
    M->>M: Extract claims (preferred_username, name, email)
    M->>M: Create/update Matrix user, create MAS session

    Note over U,E: Step 6: MAS Redirects Back to Element
    M-->>U: 302 Redirect to Element with MAS authorization code

    Note over E,M: Step 7: Element Exchanges Code for Tokens
    E->>M: POST /oauth2/token (code + client credentials)
    M-->>E: {access_token, refresh_token, id_token}

    Note over E,S: Step 8: Authenticated Matrix Requests
    E->>N: GET /_matrix/client/v3/sync (Authorization: Bearer <access_token>)
    N->>S: Proxy request to Synapse
    S->>M: Validate token (introspection or JWKS)
    M-->>S: Token valid, user = @alice:server.de
    S-->>N: Sync response
    N-->>E: Sync response
```

### Step-by-Step Walkthrough

#### Step 1: Client Discovery via .well-known

When a user enters their Matrix server address in Element, the client fetches:

```
GET https://synapse.your.matrix.server.de/.well-known/matrix/client
```

nginx serves this as a static file (generated in the nginx entrypoint). The response:

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

The critical field is `org.matrix.msc2965.authentication.issuer`. This tells the client: "Authentication is handled by an OIDC provider at this URL." The client now knows to use OIDC instead of the legacy password login flow.

#### Step 2: OIDC Discovery

The client fetches the OIDC discovery document from the issuer:

```
GET https://server.de/.well-known/openid-configuration
```

This returns MAS's OIDC metadata: the authorization endpoint, token endpoint, supported scopes, signing keys, etc. The client now has everything it needs to initiate an OIDC flow.

#### Step 3: Authorization Request

Element constructs an authorization URL and redirects the user's browser:

```
https://mas.synapse.your.matrix.server.de/authorize
  ?response_type=code
  &client_id=<element_client_id>
  &redirect_uri=https://element.your.server.de/callback
  &scope=openid profile email
  &state=<random>
  &nonce=<random>
  &code_challenge=<PKCE_challenge>
  &code_challenge_method=S256
```

MAS receives this request. Since the user has no active MAS session, MAS needs to authenticate them.

#### Step 4: MAS Redirects to Keycloak

MAS knows it has an upstream OIDC provider (Keycloak) configured. It constructs a new authorization request to Keycloak:

```
https://keycloak.lesiv.dev/realms/matrix/protocol/openid-connect/auth
  ?response_type=code
  &client_id=synapse
  &redirect_uri=https://mas.synapse.your.matrix.server.de/upstream/callback/01H8PKNWKKRPCBW4YGH1RWV279
  &scope=openid profile email
  &state=<mas_state>
  &nonce=<mas_nonce>
```

The user sees Keycloak's login page. They enter their username and password (and complete MFA if configured).

#### Step 5: Keycloak Authenticates and Redirects Back to MAS

After successful authentication, Keycloak redirects the user back to MAS's callback URL with an authorization code:

```
https://mas.synapse.your.matrix.server.de/upstream/callback/01H8PKNWKKRPCBW4YGH1RWV279
  ?code=<keycloak_auth_code>
  &state=<mas_state>
```

MAS now performs a **back-channel** (server-to-server) token exchange with Keycloak:

```http
POST https://keycloak.lesiv.dev/realms/matrix/protocol/openid-connect/token
Authorization: Basic base64(synapse:KEYCLOAK_CLIENT_SECRET)
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=<keycloak_auth_code>
&redirect_uri=https://mas.synapse.your.matrix.server.de/upstream/callback/01H8PKNWKKRPCBW4YGH1RWV279
```

Keycloak returns tokens. MAS extracts the claims from the ID token according to its `claims_imports` configuration:

- `preferred_username` becomes the Matrix localpart (e.g., `alice`)
- `name` becomes the display name (e.g., `Alice Smith`)
- `email` becomes the Matrix email (e.g., `alice@example.com`)

MAS creates or updates the corresponding Matrix user in its database and establishes a MAS session.

#### Step 6: MAS Completes the Original Authorization Request

MAS now has an authenticated user. It completes the original authorization request from Element by redirecting back to Element's redirect URI with a MAS-issued authorization code:

```
https://element.your.server.de/callback
  ?code=<mas_auth_code>
  &state=<original_state>
```

#### Step 7: Element Exchanges the Code for Tokens

Element performs its own back-channel token exchange with MAS:

```http
POST https://mas.synapse.your.matrix.server.de/oauth2/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=<mas_auth_code>
&redirect_uri=https://element.your.server.de/callback
&code_verifier=<PKCE_verifier>
```

MAS returns:
- An **access token** for calling Synapse APIs
- A **refresh token** for obtaining new access tokens
- An **ID token** with the user's identity claims

#### Step 8: Authenticated Matrix API Calls

Element includes the access token in all subsequent requests:

```http
GET /_matrix/client/v3/sync
Authorization: Bearer <mas_access_token>
```

### nginx Routing: The Critical Detail

Look at the nginx configuration in our `docker-compose.yaml`:

```nginx
location ~ ^/_matrix/client/(.*)/(login|logout|refresh) {
    proxy_http_version 1.1;
    proxy_pass $mas_upstream;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}

location ~ ^(/|/_matrix|/_synapse/client) {
    proxy_pass $synapse_upstream;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Host $host;
    client_max_body_size 50M;
    proxy_http_version 1.1;
}
```

This is a regex-priority routing setup. nginx evaluates `location` blocks in a specific order: exact matches first, then regex blocks in definition order, then prefix matches.

The first regex matches any URL path containing `/login`, `/logout`, or `/refresh` as the last path segment under `/_matrix/client/*/`. These are the **authentication-related endpoints** that MAS handles. They are routed to `http://synapse-mass-authentication-service:8080`.

Everything else under `/_matrix` or `/_synapse/client` goes to Synapse at `http://synapse:8008`.

This routing is essential because Matrix clients expect authentication endpoints to be at the homeserver's base URL (under `/_matrix/client/`). The nginx proxy transparently forwards auth requests to MAS while keeping everything else on Synapse. From the client's perspective, it is all one server.

The DNS resolver directive (`resolver 127.0.0.11 valid=10s`) uses Docker's built-in DNS, and the `$mas_upstream` / `$synapse_upstream` variables are resolved at request time (not at config load), which prevents nginx from crashing if a backend is temporarily unavailable.

---

## 6. MAS Configuration Deep-Dive

MAS is configured via a single `config.yaml` file. In our deployment, this file is generated by the init container (Section 7) and stored in the `mas-data` volume at `/data/config.yaml`. Let us examine each section.

### Database

```yaml
database:
  uri: postgresql://synapse_mas_user:PASSWORD@postgres-synapse-mas:5432/synapse_mas
```

MAS uses its own dedicated PostgreSQL database, separate from Synapse's. This database stores:
- OIDC client registrations
- User sessions
- Access and refresh token records
- Upstream provider mappings
- Compatibility session data

The connection string uses the Docker service name `postgres-synapse-mas` as the hostname, which resolves within the Docker network.

### HTTP Configuration

```yaml
http:
  public_base: https://mas.synapse.your.matrix.server.de/
  issuer: https://mas.synapse.your.matrix.server.de/
  listeners:
    - name: web
      resources:
        - name: discovery
        - name: human
        - name: oauth
        - name: compat
        - name: graphql
        - name: assets
      binds:
        - address: "[::]:8080"
```

Two critical URLs here:

- **`public_base`**: The externally-accessible URL for MAS. Used to construct redirect URIs and discovery documents.
- **`issuer`**: The OIDC issuer identifier. This MUST match what clients receive in the `.well-known/matrix/client` response and what Synapse has configured in its `msc3861.issuer`.

Note: The init container generates the default config with `http://[::]:8080/` for both values, then `sed` replaces them with the actual FQDN from `SYNAPSE_MAS_FQDN`.

The listener serves multiple resource types:
- `discovery` -- The `/.well-known/openid-configuration` endpoint
- `human` -- Login/consent pages for browser-based flows
- `oauth` -- The `/authorize`, `/token`, and `/introspect` endpoints
- `compat` -- Compatibility endpoints for legacy Matrix clients that do not support OIDC
- `graphql` -- Admin API for managing MAS programmatically
- `assets` -- Static assets (CSS, JS) for the login/consent UI

### Clients

```yaml
clients:
  - client_id: 0000000000000000000SYNAPSE
    client_auth_method: client_secret_basic
    client_secret: "SYNAPSE_MAS_SECRET_VALUE"
```

This registers Synapse as an OIDC client of MAS. The values must match exactly what is in Synapse's `msc3861` configuration:

- **`client_id: 0000000000000000000SYNAPSE`** -- A well-known client ID that Synapse uses when communicating with MAS. The string `0000000000000000000SYNAPSE` is a convention (19 zeros + "SYNAPSE") used in the MAS documentation and examples.
- **`client_auth_method: client_secret_basic`** -- Synapse authenticates to MAS using HTTP Basic authentication, with the client ID as username and client secret as password.
- **`client_secret`** -- A shared secret between MAS and Synapse, provided via the `SYNAPSE_MAS_SECRET` environment variable.

This client registration enables Synapse to:
1. Introspect (validate) access tokens that clients present
2. Exchange authorization codes (for the compatibility layer)

### Upstream OAuth2 Providers

```yaml
upstream_oauth2:
  providers:
    - id: "01H8PKNWKKRPCBW4YGH1RWV279"
      issuer: "https://keycloak.lesiv.dev/realms/matrix"
      token_endpoint_auth_method: client_secret_basic
      client_id: "synapse"
      client_secret: "KEYCLOAK_CLIENT_SECRET_VALUE"
      scope: "openid profile email"
      claims_imports:
        localpart:
          action: require
          template: "{{ user.preferred_username }}"
        displayname:
          action: suggest
          template: "{{ user.name }}"
        email:
          action: suggest
          template: "{{ user.email }}"
          set_email_verification: always
```

This is where MAS is configured as an OIDC Relying Party to Keycloak. Let us break down every field:

**`id`**: A unique identifier for this upstream provider. The value `01H8PKNWKKRPCBW4YGH1RWV279` is a ULID (Universally Unique Lexicographically Sortable Identifier). This ID is used in callback URLs: `/upstream/callback/01H8PKNWKKRPCBW4YGH1RWV279`.

**`issuer`**: The OIDC issuer URL for the Keycloak realm. MAS uses this to fetch the `/.well-known/openid-configuration` discovery document from Keycloak, which tells it where the authorize, token, and userinfo endpoints are.

**`token_endpoint_auth_method: client_secret_basic`**: MAS authenticates to Keycloak's token endpoint using HTTP Basic auth with the client credentials.

**`client_id` / `client_secret`**: The OIDC client credentials MAS uses to authenticate to Keycloak. These must match the client registered in the Keycloak realm.

**`scope: "openid profile email"`**: The scopes MAS requests from Keycloak. This determines which claims are included in the ID token.

**`claims_imports`**: This is how MAS maps Keycloak's OIDC claims to Matrix user attributes. The templates use Jinja2 syntax:

| Matrix Attribute | Keycloak Claim | Action | Meaning |
|-----------------|----------------|--------|---------|
| `localpart` | `preferred_username` | `require` | **Must** be present. If missing, authentication fails. This becomes the Matrix user ID. |
| `displayname` | `name` | `suggest` | Used if available, but not required. Sets the Matrix display name. |
| `email` | `email` | `suggest` | Used if available. The `set_email_verification: always` flag tells MAS to mark the email as verified (trusting Keycloak's verification). |

The distinction between `require` and `suggest` is important. A `require` action means the claim MUST be present in the upstream token or the login will fail. This prevents accidentally creating Matrix users with empty localparts.

### Matrix Section

```yaml
matrix:
  homeserver: your.matrix.server.de
  secret: "SYNAPSE_API_ADMIN_TOKEN_VALUE"
  endpoint: https://synapse.your.matrix.server.de
```

This configures MAS's relationship with the Synapse homeserver:

- **`homeserver`**: The Matrix server name (used in Matrix IDs like `@user:your.matrix.server.de`).
- **`secret`**: A shared admin token that MAS uses to perform privileged operations on Synapse (like creating users, provisioning devices). This must match Synapse's `msc3861.admin_token`.
- **`endpoint`**: The URL where MAS can reach Synapse's client-server API.

### Passwords Section

```yaml
passwords:
  enabled: false
```

Passwords are explicitly disabled in MAS. All authentication is delegated upstream to Keycloak. This means:
- MAS does not store any password hashes
- Users cannot set a password in MAS
- The only way to authenticate is through the Keycloak upstream provider

This is a deliberate security choice: Keycloak is purpose-built for credential management (with bcrypt/argon2 hashing, brute-force protection, password policies, MFA). There is no reason to duplicate that in MAS.

### Email Configuration

```yaml
email:
  from: '"Your Matrix Server" <no-reply@your.matrix.server.de>'
  reply_to: '"Your Matrix Server" <admin@your.matrix.server.de>'
  transport: smtp
  # SMTP configuration...
```

MAS can send emails for account verification and notifications. The init container patches the default `from` and `reply_to` fields using `SYNAPSE_FRIENDLY_SERVER_NAME`, `SMTP_USER`, and `ADMIN_EMAIL`.

---

## 7. The MAS Init Container Pattern

One of the more interesting deployment patterns in our stack is how MAS configuration is generated. Let us examine it in detail.

### The Problem

MAS expects a `config.yaml` file that contains database URIs, secrets, upstream provider configuration, client registrations, and various URLs. These values come from environment variables, but MAS does not support environment variable substitution in its config file (unlike, say, Synapse's Jinja2 templates). The config must be a complete, valid YAML file.

Additionally, `mas-cli config generate` produces a config with sensible defaults (including generated secrets, encryption keys, and key pairs), but it uses placeholder values for things like database URIs and URLs. We need to run the generator for the crypto material, then patch in our actual values.

### The Solution: A Two-Phase Init Container

From `docker-compose.yaml`:

```yaml
mas-config-init:
  image: ghcr.io/element-hq/matrix-authentication-service:latest-debug
  user: "0:0"
  restart: "no"
  environment:
    # ... (all the MAS-related env vars)
  entrypoint: ["/busybox/sh", "-c", "..."]
  volumes:
    - mas-data:/data
```

Let us trace through the entrypoint script:

#### Phase 1: Idempotency Check

```sh
if [ -f /data/config.yaml ]; then
  echo 'Config already exists, skipping generation'
  exit 0
fi
```

If the config already exists (from a previous deployment), the init container does nothing and exits immediately. This is critical:
- It prevents regenerating secrets and encryption keys on every restart.
- It preserves any manual adjustments made to the config.
- It makes `docker compose up` idempotent.

#### Phase 2: Generate Base Config

```sh
mas-cli config generate --output /data/config.yaml
```

`mas-cli config generate` produces a complete config file with:
- Randomly generated secrets and signing keys
- Default listener configuration
- Placeholder database URI, URLs, and email settings

#### Phase 3: Patch with sed

A series of `sed` commands replace the placeholder values with actual deployment values from environment variables:

```sh
# Database connection
sed -i "s|uri: postgresql://.*|uri: postgresql://${POSTGRES_SYNAPSE_MAS_USER}:${POSTGRES_SYNAPSE_MAS_PASSWORD}@postgres-synapse-mas:5432/${POSTGRES_SYNAPSE_MAS_DB}|" /data/config.yaml

# Email settings
sed -i "s|from: .*Authentication Service.*|from: '\"${SYNAPSE_FRIENDLY_SERVER_NAME}\" <${SMTP_USER}>'|" /data/config.yaml
sed -i "s|reply_to: .*Authentication Service.*|reply_to: '\"${SYNAPSE_FRIENDLY_SERVER_NAME}\" <${ADMIN_EMAIL}>'|" /data/config.yaml

# Matrix homeserver
sed -i "s|homeserver: localhost:8008|homeserver: ${SYNAPSE_SERVER_NAME}|" /data/config.yaml
sed -i "s|endpoint: http://localhost:8008/|endpoint: ${SYNAPSE_FQDN}|" /data/config.yaml

# Admin token (matrix.secret)
sed -i '/^matrix:/,/^[^ ]/{/^  secret:/s|secret: .*|secret: '"${SYNAPSE_API_ADMIN_TOKEN}"'|}' /data/config.yaml

# Public URLs
sed -i "s|public_base: http://\[::]:8080/|public_base: ${SYNAPSE_MAS_FQDN}/|" /data/config.yaml
sed -i "s|issuer: http://\[::]:8080/|issuer: ${SYNAPSE_MAS_FQDN}/|" /data/config.yaml

# Disable passwords
sed -i '/^passwords:/{n;s/enabled: true/enabled: false/}' /data/config.yaml
```

Note the `matrix.secret` sed command. It uses a range pattern (`/^matrix:/,/^[^ ]/`) to find the `secret:` key within the `matrix:` block, avoiding accidental matches elsewhere in the file.

#### Phase 4: Append Client and Upstream Config

```sh
cat >> /data/config.yaml <<ENDAPPEND
clients:
  - client_id: 0000000000000000000SYNAPSE
    client_auth_method: client_secret_basic
    client_secret: "${SYNAPSE_MAS_SECRET}"
upstream_oauth2:
  providers:
    - id: "${KEYCLOAK_UPSTREAM_OAUTH_PROVIDER_ID}"
      issuer: "${KEYCLOAK_FQDN}/realms/${KEYCLOAK_REALM_IDENTIFIER}"
      token_endpoint_auth_method: client_secret_basic
      client_id: "${KEYCLOAK_CLIENT_ID}"
      client_secret: "${KEYCLOAK_CLIENT_SECRET}"
      scope: "openid profile email"
      claims_imports:
        localpart:
          action: require
          template: "{{ user.preferred_username }}"
        displayname:
          action: suggest
          template: "{{ user.name }}"
        email:
          action: suggest
          template: "{{ user.email }}"
          set_email_verification: always
ENDAPPEND
```

The client and upstream provider blocks are appended rather than patched because the generated config does not contain them. This is cleaner than trying to inject YAML blocks via sed.

#### Phase 5: Fix Permissions

```sh
chown -R 65532:65532 /data
```

UID 65532 is the `nonroot` user in distroless containers. The runtime MAS container (which uses the standard distroless image) runs as this user and needs read access to the config file.

### Why the Debug Image

The standard MAS image (`ghcr.io/element-hq/matrix-authentication-service:latest`) is a **distroless** container. Distroless images contain only the application binary and its runtime dependencies -- no shell, no `sed`, no `cat`, no `ls`. This is excellent for security (reduced attack surface) but means you cannot run shell scripts.

The debug image (`-debug` tag) adds a busybox shell and common utilities. The init container invocation uses `/busybox/sh` as the shell:

```yaml
entrypoint: ["/busybox/sh", "-c", "..."]
```

This is a common pattern in distroless ecosystems: use the debug variant for init/setup containers, and the standard variant for runtime.

### The Service Dependency Chain

```yaml
synapse-mass-authentication-service:
  depends_on:
    mas-config-init:
      condition: service_completed_successfully
    postgres-synapse-mas:
      condition: service_healthy
```

The runtime MAS service waits for:
1. The init container to complete successfully (config is generated).
2. The PostgreSQL database to be healthy (ready to accept connections).

This ensures MAS never starts without a valid config and a reachable database.

---

## 8. Synapse MSC3861 Integration

With MAS running and configured, Synapse needs to know how to delegate authentication to it. This is configured via the `experimental_features.msc3861` block in `homeserver.yaml`.

### The Configuration

From our Synapse entrypoint (in `docker-compose.yaml`):

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

Let us examine each field:

### `enabled: true`

Activates MSC3861 delegation. When this is enabled, Synapse:
- Stops accepting password-based login.
- Stops issuing access tokens.
- Validates all incoming access tokens against the configured OIDC issuer (MAS).
- Relies entirely on MAS for user authentication and token management.

### `issuer: http://synapse-mass-authentication-service:8080`

This is the OIDC issuer URL that Synapse uses to discover MAS's OIDC endpoints. Notice something important: this is an **internal Docker network URL**, not the public FQDN.

Synapse calls `{issuer}/.well-known/openid-configuration` to discover:
- The JWKS (JSON Web Key Set) URI for validating token signatures.
- The token introspection endpoint.
- The userinfo endpoint.

Using the internal Docker hostname (`synapse-mass-authentication-service`) means this communication never leaves the Docker network. This is both faster (no external DNS/TLS roundtrip) and more secure (no exposure to the internet).

The commented-out line in `template.homeserver.yaml` shows the alternative:
```yaml
#issuer: {{SYNAPSE_MAS_FQDN}}
```
This would use the external URL. The internal URL was chosen deliberately.

### `client_id: 0000000000000000000SYNAPSE`

Must exactly match the `client_id` in MAS's `clients` configuration. This is how MAS identifies Synapse when Synapse calls MAS's token introspection or other OIDC endpoints.

### `client_auth_method: client_secret_basic`

Synapse authenticates to MAS's endpoints using HTTP Basic authentication, sending `0000000000000000000SYNAPSE` as the username and `SYNAPSE_MAS_SECRET` as the password. Must match MAS's `client_auth_method` for this client.

### `client_secret`

The shared secret between Synapse and MAS. Provided via the `SYNAPSE_MAS_SECRET` environment variable. Used in the HTTP Basic auth header when Synapse calls MAS.

### `admin_token`

A privileged token that MAS presents when making admin-level calls to Synapse (creating users, managing devices, etc.). This is the reverse of the `client_secret`: where `client_secret` is Synapse authenticating to MAS, `admin_token` is MAS authenticating to Synapse.

This value must match `matrix.secret` in MAS's config.

### `account_management_url`

```yaml
account_management_url: "https://keycloak.lesiv.dev/realms/matrix/account"
```

This URL is advertised to clients as the place where users can manage their account (change password, configure MFA, update profile). It points directly to Keycloak's account console -- bypassing MAS entirely, since account management is Keycloak's responsibility.

When a user clicks "Manage account" in Element, they are sent to this URL.

### The Paired Configuration

For everything to work, certain values must match across MAS and Synapse. Here is the mapping:

| Synapse `msc3861` field | MAS config field | Must Match? |
|------------------------|------------------|-------------|
| `client_id` | `clients[].client_id` | Exact match |
| `client_auth_method` | `clients[].client_auth_method` | Exact match |
| `client_secret` | `clients[].client_secret` | Exact match |
| `admin_token` | `matrix.secret` | Exact match |
| `issuer` | Must resolve to MAS's OIDC discovery | MAS must serve OIDC at this URL |

A mismatch in any of these will cause authentication to fail, typically with opaque error messages. The use of shared environment variables (`SYNAPSE_MAS_SECRET`, `SYNAPSE_API_ADMIN_TOKEN`) in our deployment ensures they stay in sync.

---

## 9. Token Lifecycle

### Access Token Lifecycle

```
                      MAS issues access token
                              |
                              v
         Element stores token in memory/storage
                              |
                              v
         Element sends token with each API request
                              |
                              v
         Synapse receives request with Bearer token
                              |
                              v
         Synapse validates token against MAS
         (JWKS verification or token introspection)
                              |
                    +---------+---------+
                    |                   |
                    v                   v
              Token valid          Token expired/invalid
                    |                   |
                    v                   v
             Process request      Return 401 Unauthorized
                                        |
                                        v
                              Client uses refresh token
                              to get new access token
```

**Access token expiry**: MAS issues access tokens with a relatively short lifetime (typically 5 minutes). This is a deliberate security measure. If an access token leaks (via logs, network interception, or a compromised client), the window of exposure is limited.

**Token validation**: When Synapse receives a request with a Bearer token, it validates the token by one of two methods:
1. **JWKS verification**: If the access token is a JWT, Synapse can verify the signature using MAS's published JWKS (JSON Web Key Set), fetched from the URL discovered via `/.well-known/openid-configuration`. This is fast (no network call per request after caching the keys) but requires the token to be a JWT.
2. **Token introspection**: Synapse calls MAS's `/oauth2/introspect` endpoint, presenting the token and its client credentials. MAS responds with the token's validity, the associated user, and the token's scopes. This requires a network call per request but works with opaque tokens.

### Refresh Token Rotation

When an access token expires, the client does not re-authenticate the user. Instead, it uses the refresh token:

```http
POST https://mas.synapse.your.matrix.server.de/oauth2/token
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token
&refresh_token=<current_refresh_token>
&client_id=<element_client_id>
```

MAS responds with:
- A new access token (with a fresh expiry)
- A new refresh token (the old one is invalidated)

This is **refresh token rotation**. Each refresh token is single-use. If an attacker steals a refresh token and the legitimate client uses it first, the attacker's stolen token becomes invalid. If the attacker uses it first, the legitimate client's next refresh will fail, signaling a potential token theft (MAS can then invalidate the entire session).

### Session Management

MAS maintains sessions in its database. A session represents a user's authenticated state and encompasses:
- One or more access tokens (only the most recent is valid)
- One or more refresh tokens (only the most recent is valid)
- The upstream provider session (link to the Keycloak authentication event)
- Session metadata (creation time, last activity, client info)

Sessions can be terminated by:
1. **User logout**: Element calls `/_matrix/client/v3/logout`, which nginx routes to MAS. MAS invalidates the session and all associated tokens.
2. **Admin action**: Via MAS's GraphQL admin API.
3. **Upstream session expiry**: If the Keycloak session expires and back-channel logout is configured, MAS is notified and terminates the corresponding session.

### How Synapse Validates Tokens Against MAS

The internal communication flow:

```
Element --[access_token]--> nginx --> Synapse
                                        |
                                        | POST /oauth2/introspect
                                        | Authorization: Basic base64(0000000000000000000SYNAPSE:secret)
                                        | Body: token=<access_token>
                                        |
                                        v
                                       MAS
                                        |
                                        | Response: {active: true, sub: "@alice:server.de", scope: "..."}
                                        |
                                        v
                                     Synapse
                                        |
                                        | Process request as @alice:server.de
                                        v
                                     Response --> nginx --> Element
```

This happens over the Docker internal network (Synapse connects to `synapse-mass-authentication-service:8080`), so the latency is minimal (sub-millisecond network time).

Synapse caches introspection results to avoid calling MAS on every single request. The cache TTL is typically short (seconds) to balance performance with token revocation responsiveness.

---

## 10. Security Considerations

### Defense in Depth: Passwords Disabled Everywhere

Passwords are disabled at every layer that could potentially accept them:

| Layer | Setting | Effect |
|-------|---------|--------|
| Synapse | `password_config.enabled: false` | Synapse will not accept password login requests at all |
| Synapse | `enable_registration: false` | Synapse will not create new accounts via its own registration flow |
| MAS | `passwords.enabled: false` | MAS will not accept password-based authentication |

The ONLY place where passwords exist is Keycloak. This gives us a single point of credential management with Keycloak's full suite of security features:
- Bcrypt/Argon2 password hashing
- Configurable password policies (length, complexity, history)
- Brute-force detection and account lockout
- Multi-factor authentication (TOTP, WebAuthn, recovery codes)
- Password reset via email
- Account lockout and suspicious activity detection

### Transport Security

**External traffic**: All external communication uses HTTPS. The FQDNs (`SYNAPSE_FQDN`, `SYNAPSE_MAS_FQDN`, `KEYCLOAK_FQDN`) are all `https://` URLs. TLS termination happens at the reverse proxy / Coolify layer before reaching the Docker network, as discussed in [04 - Deployment Architecture](./04-deployment-architecture.md).

**Internal traffic**: Communication within the Docker network (Synapse to MAS, services to PostgreSQL) uses plain HTTP/TCP. This is acceptable because:
- Docker's internal network is isolated. Only containers in the same compose project can communicate.
- There is no routing through untrusted networks.
- The Docker network bridge provides namespace isolation.

However, the connection from MAS to Keycloak **does** traverse the external network (Keycloak runs at `keycloak.lesiv.dev`, external to this Docker compose project). This connection uses HTTPS, as the `KEYCLOAK_FQDN` is an `https://` URL.

### Secret Management

Secrets are managed via environment variables defined in a `.env` file (not committed to version control). The deployment uses this approach:

| Secret | Environment Variable | Used By |
|--------|---------------------|---------|
| MAS client secret | `SYNAPSE_MAS_SECRET` | MAS config (client secret), Synapse (msc3861.client_secret) |
| Admin token | `SYNAPSE_API_ADMIN_TOKEN` | MAS config (matrix.secret), Synapse (msc3861.admin_token) |
| Keycloak client secret | `KEYCLOAK_CLIENT_SECRET` | MAS config (upstream_oauth2 client_secret) |
| MAS DB password | `POSTGRES_SYNAPSE_MAS_PASSWORD` | MAS config (database URI), PostgreSQL |
| Synapse DB password | `POSTGRES_SYNAPSE_PASSWORD` | Synapse config, PostgreSQL |

The `.env.example` file in the repository provides a template with placeholder values. The actual `.env` file must be created manually with real secrets and is excluded from version control.

**Important**: The init container script uses `$$` (double dollar sign) in the Docker Compose entrypoint to prevent Docker Compose from interpolating the variables at compose-file parse time. Instead, the shell inside the container expands them at runtime. This is a subtle but critical detail -- without `$$`, Docker Compose would try to substitute the variables before the shell runs, which would fail for variables referenced inside heredocs and sed commands.

### The Upstream Provider ID

```
KEYCLOAK_UPSTREAM_OAUTH_PROVIDER_ID=01H8PKNWKKRPCBW4YGH1RWV279
```

This ULID is used as the provider ID in MAS and appears in callback URLs. The `.env.example` notes "leave it as is" because:
1. It is embedded in MAS's database (linking upstream identities to local accounts).
2. Changing it after initial setup would orphan existing user-to-upstream mappings.
3. It is not a secret -- it is an identifier, not a credential.

### Token Security Properties

| Property | Implementation |
|----------|---------------|
| Short-lived access tokens | MAS issues tokens with ~5 minute expiry |
| Refresh token rotation | Each refresh produces new refresh + access tokens; old refresh token is invalidated |
| Token binding | Tokens are bound to the client that requested them |
| Revocation | Logout invalidates all tokens for the session |
| No token in URL | Authorization Code flow ensures tokens are never in browser URLs or server logs |
| PKCE | Clients use Proof Key for Code Exchange to prevent authorization code interception |

### Attack Surface Analysis

| Attack Vector | Mitigation |
|---------------|------------|
| Credential stuffing | Keycloak brute-force protection; no password endpoints in MAS or Synapse |
| Token theft | Short-lived access tokens; refresh token rotation detects replay |
| Man-in-the-middle | HTTPS for all external traffic; HSTS headers |
| Session hijacking | Tokens bound to client; refresh rotation invalidates stolen tokens |
| Compromised init container | Only runs once (idempotent); runs as root only to set permissions, then exits |
| Database exposure | Each service has its own database with unique credentials |
| Internal network sniffing | Docker network isolation; no sensitive data exposed to other containers not in the project |

---

## Summary: The Three-Layer Authentication Architecture

```
+------------------------------------------------------------------+
|                        External (HTTPS)                          |
|                                                                  |
|   Element/Client                         Keycloak                |
|       |                                   ^                      |
|       | .well-known                       | OIDC (Authorization  |
|       | discovery                         | Code flow)           |
|       v                                   |                      |
+-------+-----------------------------------+----------------------+
|                   Docker Network (HTTP)                          |
|                                                                  |
|   nginx (:80)                                                    |
|     |         \                                                  |
|     |          \  login/logout/refresh                           |
|     |           \                                                |
|     v            v                                               |
|   Synapse      MAS (:8080)                                       |
|   (:8008)        |                                               |
|     |            |  token introspection                          |
|     +<-----------+                                               |
|     |            |                                               |
|     v            v                                               |
|   postgres     postgres                                          |
|   -synapse     -synapse-mas                                      |
+------------------------------------------------------------------+
```

The authentication stack is intentionally layered:

1. **Keycloak** -- Owns user identities and credentials. The ultimate source of truth for "who is this person?"
2. **MAS** -- Translates between the OIDC world and the Matrix world. Issues Matrix-compatible tokens. Maps OIDC claims to Matrix user attributes.
3. **Synapse** -- Consumes tokens. Trusts MAS as its authentication authority. Focuses on message federation and storage.

Each layer has a single, well-defined responsibility. No layer stores credentials it should not (Synapse stores no passwords, MAS stores no passwords), and the communication between layers is secured by shared secrets and network isolation.

---

## Cross-References

- **[01 - Matrix Fundamentals](./01-matrix-fundamentals.md)** -- Covers the Matrix protocol itself: rooms, events, federation, and how user IDs work.
- **[02 - Synapse Homeserver](./02-synapse-homeserver.md)** -- Details Synapse's configuration beyond authentication: database, federation, media storage, and worker architecture.
- **[04 - Deployment Architecture](./04-deployment-architecture.md)** -- Covers the Docker Compose structure, nginx routing in full detail, volume management, and the Coolify hosting layer.
- **[05 - Bridges](./05-bridges.md)** -- Explains how mautrix bridges (WhatsApp, Telegram, Discord, Slack) authenticate to Synapse via appservice registration files.
- **[06 - Operations](./06-operations.md)** -- Covers day-to-day operations: adding users in Keycloak, debugging auth failures, rotating secrets, and monitoring token health.

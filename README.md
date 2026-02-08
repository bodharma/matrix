# Matrix Server with Bridges

A self-hosted Matrix homeserver stack with Keycloak SSO and 6 messaging bridges, deployed via Docker Compose on Coolify.

## What's Included

- **Synapse** — Matrix homeserver
- **MAS** — Matrix Authentication Service (OIDC via Keycloak)
- **Sliding Sync** — Fast sync proxy for modern clients
- **nginx** — Reverse proxy with auth routing and .well-known discovery
- **6 bridges** — WhatsApp, Telegram, Discord, Slack, Meta (Facebook/Instagram), LinkedIn

All configuration is generated at runtime from environment variables. No config files to manage — just set your `.env` and deploy.

## Quick Start

1. Install [Coolify](https://coolify.io) on your server
2. Deploy Keycloak (available as a Coolify one-click service)
3. Add this repo as a Docker Compose resource in Coolify
4. Set environment variables (copy from `.env.example`)
5. Map domains to service ports
6. Deploy

**Full step-by-step guide: [docs/00-setup-guide.md](docs/00-setup-guide.md)**

## Documentation

| Document | Description |
|----------|-------------|
| [00-setup-guide.md](docs/00-setup-guide.md) | Complete setup from zero to running server |
| [MANUAL.md](docs/MANUAL.md) | Day-to-day usage guide for Matrix and all bridges |
| [01-matrix-fundamentals.md](docs/01-matrix-fundamentals.md) | Matrix protocol deep-dive |
| [02-synapse-homeserver.md](docs/02-synapse-homeserver.md) | Synapse architecture and configuration |
| [03-authentication.md](docs/03-authentication.md) | OIDC, MAS, and Keycloak auth flow |
| [04-deployment-architecture.md](docs/04-deployment-architecture.md) | Docker services, init containers, volumes |
| [05-bridges.md](docs/05-bridges.md) | Appservice API, mautrix ecosystem, per-bridge details |
| [06-operations.md](docs/06-operations.md) | Monitoring, backups, troubleshooting, maintenance |

## Architecture

```
21 containers, 15 volumes

  4x PostgreSQL (synapse, MAS, sliding-sync, bridges)
  7x Init containers (MAS + 6 bridges) — one-shot config generators
 10x Runtime services (synapse, MAS, sliding-sync, nginx, 6 bridges)
```

## Environment Variables

Copy `.env.example` and fill in your values. See the [setup guide](docs/00-setup-guide.md#step-7-configure-environment-variables) for details on each variable.

## License

See repository license.

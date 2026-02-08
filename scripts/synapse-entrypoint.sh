#!/bin/sh
set -e

mkdir -p /data/config

cat > /data/config/homeserver.yaml <<ENDCONF
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
  - /bridges/meta-registration.yaml
  - /bridges/linkedin-registration.yaml
  - /bridges/maubot-registration.yaml
  - /bridges/hookshot-registration.yaml
ENDCONF

cat > /data/config/db.yaml <<ENDCONF
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
ENDCONF

cat > /data/config/email.yaml <<ENDCONF
email:
  smtp_host: "${SMTP_HOST}"
  smtp_port: ${SMTP_PORT}
  smtp_user: "${SMTP_USER}"
  smtp_pass: "${SMTP_PASSWORD}"
  require_transport_security: ${SMTP_REQUIRE_TRANSPORT_SECURITY}
  notif_from: "${SMTP_NOTIFY_FROM}"
  app_name: "${SYNAPSE_FRIENDLY_SERVER_NAME}"
ENDCONF

exec python -m synapse.app.homeserver \
  -c /data/config/homeserver.yaml \
  -c /data/config/db.yaml \
  -c /data/config/email.yaml \
  --keys-directory /data

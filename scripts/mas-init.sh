#!/busybox/sh
set -e

if [ -f /data/config.yaml ]; then
  echo 'Config already exists, skipping generation'
  exit 0
fi

echo 'Generating MAS config...'
mas-cli config generate --output /data/config.yaml

sed -i "s|uri: postgresql://.*|uri: postgresql://${POSTGRES_SYNAPSE_MAS_USER}:${POSTGRES_SYNAPSE_MAS_PASSWORD}@postgres-synapse-mas:5432/${POSTGRES_SYNAPSE_MAS_DB}|" /data/config.yaml
sed -i "s|from: .*Authentication Service.*|from: '\"${SYNAPSE_FRIENDLY_SERVER_NAME}\" <${SMTP_USER}>'|" /data/config.yaml
sed -i "s|reply_to: .*Authentication Service.*|reply_to: '\"${SYNAPSE_FRIENDLY_SERVER_NAME}\" <${ADMIN_EMAIL}>'|" /data/config.yaml
sed -i "s|homeserver: localhost:8008|homeserver: ${SYNAPSE_SERVER_NAME}|" /data/config.yaml
sed -i "s|endpoint: http://localhost:8008/|endpoint: ${SYNAPSE_FQDN}|" /data/config.yaml
sed -i '/^matrix:/,/^[^ ]/{/^  secret:/s|secret: .*|secret: '"${SYNAPSE_API_ADMIN_TOKEN}"'|}' /data/config.yaml
sed -i "s|public_base: http://\[::]:8080/|public_base: ${SYNAPSE_MAS_FQDN}/|" /data/config.yaml
sed -i "s|issuer: http://\[::]:8080/|issuer: ${SYNAPSE_MAS_FQDN}/|" /data/config.yaml
sed -i '/^passwords:/{n;s/enabled: true/enabled: false/}' /data/config.yaml

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

chown -R 65532:65532 /data
echo 'MAS config generated successfully'

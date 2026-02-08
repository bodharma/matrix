#!/bin/bash
set -e

if [ ! -f /data/config.yaml ]; then
  cp /opt/maubot/example-config.yaml /data/config.yaml
fi

yq -i '.database = "postgresql://" + env(POSTGRES_BRIDGES_USER) + ":" + env(POSTGRES_BRIDGES_PASSWORD) + "@postgres-bridges:5432/maubot"' /data/config.yaml
yq -i '.plugin_databases.postgres = "postgresql://" + env(POSTGRES_BRIDGES_USER) + ":" + env(POSTGRES_BRIDGES_PASSWORD) + "@postgres-bridges:5432/maubot"' /data/config.yaml
yq -i '.server.hostname = "0.0.0.0"' /data/config.yaml
yq -i '.server.port = 29316' /data/config.yaml
yq -i '.server.public_url = env(SYNAPSE_FQDN)' /data/config.yaml
yq -i '.server.ui_base_path = "/_matrix/maubot"' /data/config.yaml
yq -i '.homeservers = {env(SYNAPSE_SERVER_NAME): {"url": "http://synapse:8008", "secret": null}}' /data/config.yaml
yq -i '.admins.root = env(MAUBOT_ADMIN_PASSWORD)' /data/config.yaml
yq -i '.api_features.login = true' /data/config.yaml

mkdir -p /data/plugins /data/trash /data/dbs

if [ ! -f /data/registration.yaml ]; then
  ESCAPED_DOMAIN=$(echo "$SYNAPSE_SERVER_NAME" | sed 's/\./\\./g')
  python3 -c "
import yaml, secrets
reg = {
  'id': 'maubot',
  'url': 'http://maubot:29316',
  'as_token': secrets.token_hex(32),
  'hs_token': secrets.token_hex(32),
  'sender_localpart': 'maubot',
  'namespaces': {'users': [{'regex': '@maubot_.*:${ESCAPED_DOMAIN}', 'exclusive': True}], 'rooms': [], 'aliases': []},
  'rate_limited': False,
  'de.sorunome.msc2409.push_ephemeral': True,
  'push_ephemeral': True
}
with open('/data/registration.yaml', 'w') as f:
  yaml.dump(reg, f)
"
fi

mkdir -p /registrations
cp /data/registration.yaml /registrations/maubot-registration.yaml
chown -R 1337:1337 /data

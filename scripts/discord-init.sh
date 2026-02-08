#!/bin/bash
set -e

if [ ! -f /data/config.yaml ]; then
  cp /opt/mautrix-discord/example-config.yaml /data/config.yaml
fi

yq -i '.homeserver.address = "http://synapse:8008"' /data/config.yaml
yq -i '.homeserver.domain = env(SYNAPSE_SERVER_NAME)' /data/config.yaml
yq -i '.appservice.address = "http://mautrix-discord:29334"' /data/config.yaml
yq -i '.appservice.hostname = "0.0.0.0"' /data/config.yaml
yq -i '.appservice.database.type = "postgres"' /data/config.yaml
yq -i '.appservice.database.uri = "postgres://" + env(POSTGRES_BRIDGES_USER) + ":" + env(POSTGRES_BRIDGES_PASSWORD) + "@postgres-bridges:5432/mautrix_discord?sslmode=disable"' /data/config.yaml
yq -i '.bridge.permissions = {"*": "relay", env(SYNAPSE_SERVER_NAME): "user", env(BRIDGE_ADMIN_USER): "admin"}' /data/config.yaml

rm -f /data/registration.yaml
/usr/bin/mautrix-discord -g -c /data/config.yaml -r /data/registration.yaml

mkdir -p /registrations
cp /data/registration.yaml /registrations/discord-registration.yaml
chown -R 1337:1337 /data

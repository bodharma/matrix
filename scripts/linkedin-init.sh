#!/bin/bash
set -e

if [ ! -f /data/config.yaml ]; then
  /usr/bin/mautrix-linkedin -c /data/config.yaml -e
fi

yq -i '.homeserver.address = "http://synapse:8008"' /data/config.yaml
yq -i '.homeserver.domain = env(SYNAPSE_SERVER_NAME)' /data/config.yaml
yq -i '.appservice.address = "http://mautrix-linkedin:29341"' /data/config.yaml
yq -i '.appservice.hostname = "0.0.0.0"' /data/config.yaml
yq -i '.database.type = "postgres"' /data/config.yaml
yq -i '.database.uri = "postgres://" + env(POSTGRES_BRIDGES_USER) + ":" + env(POSTGRES_BRIDGES_PASSWORD) + "@postgres-bridges:5432/mautrix_linkedin?sslmode=disable"' /data/config.yaml
yq -i '.bridge.permissions = {"*": "relay", env(SYNAPSE_SERVER_NAME): "user", env(BRIDGE_ADMIN_USER): "admin"}' /data/config.yaml

rm -f /data/registration.yaml
/usr/bin/mautrix-linkedin -g -c /data/config.yaml -r /data/registration.yaml

mkdir -p /registrations
cp /data/registration.yaml /registrations/linkedin-registration.yaml
chown -R 1337:1337 /data

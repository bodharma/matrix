#!/bin/bash

apk add --update nodejs

node ./scripts/index.js

# Copy generated configs to persistent host path for volume mounts
mkdir -p /data/matrix/configurations/synapse
mkdir -p /data/matrix/configurations/synapse-mas
mkdir -p /data/matrix/configurations/nginx
mkdir -p /data/matrix/synapse/data/config
mkdir -p /data/matrix/synapse/media

cp ./configurations/synapse/homeserver.yaml /data/matrix/configurations/synapse/
cp ./configurations/synapse/db.yaml /data/matrix/configurations/synapse/
cp ./configurations/synapse/email.yaml /data/matrix/configurations/synapse/
cp ./configurations/synapse/oidc.yaml /data/matrix/configurations/synapse/
cp ./configurations/synapse-mas/config.yaml /data/matrix/configurations/synapse-mas/
cp ./configurations/nginx/nginx.conf /data/matrix/configurations/nginx/
cp ./configurations/nginx/index.html /data/matrix/configurations/nginx/

#!/bin/sh
set -e

mkdir -p /data

if [ ! -f /data/passkey.pem ]; then
  openssl genpkey -out /data/passkey.pem -outform PEM -algorithm RSA -pkeyopt rsa_keygen_bits:4096 2>/dev/null
fi

cat > /data/config.yml <<ENDCONF
bridge:
  domain: ${SYNAPSE_SERVER_NAME}
  url: http://synapse:8008
  mediaUrl: https://${SYNAPSE_SERVER_NAME}
  port: 9993
  bindAddress: 0.0.0.0
logging:
  level: info
  colorize: true
  json: false
  timestampFormat: HH:mm:ss:SSS
passFile: /data/passkey.pem
listeners:
  - port: 9000
    bindAddress: 0.0.0.0
    resources:
      - webhooks
  - port: 9002
    bindAddress: 0.0.0.0
    resources:
      - widgets
permissions:
  - actor: ${SYNAPSE_SERVER_NAME}
    services:
      - service: "*"
        level: admin
generic:
  enabled: true
  outbound: false
  urlPrefix: https://${SYNAPSE_SERVER_NAME}/hookshot/
  userIdPrefix: _hookshot_
  allowJsTransformationFunctions: false
feeds:
  enabled: true
  pollIntervalSeconds: 600
  pollTimeoutSeconds: 30
bot:
  displayname: Hookshot Bot
ENDCONF

if [ ! -f /data/registration.yml ]; then
  AS_TOKEN=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 64)
  HS_TOKEN=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 64)
  ESCAPED_DOMAIN=$(echo "${SYNAPSE_SERVER_NAME}" | sed 's/\./\\./g')
  cat > /data/registration.yml <<ENDREG
id: matrix-hookshot
as_token: ${AS_TOKEN}
hs_token: ${HS_TOKEN}
namespaces:
  rooms: []
  users:
    - regex: "@_hookshot_.*:${ESCAPED_DOMAIN}"
      exclusive: true
    - regex: "@feeds:${ESCAPED_DOMAIN}"
      exclusive: true
  aliases: []
sender_localpart: hookshot
url: "http://hookshot:9993"
rate_limited: false
de.sorunome.msc2409.push_ephemeral: true
push_ephemeral: true
ENDREG
fi

mkdir -p /registrations
cp /data/registration.yml /registrations/hookshot-registration.yaml
chown -R 1000:1000 /data

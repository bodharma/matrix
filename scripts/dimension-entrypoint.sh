#!/bin/sh
set -e

cat > /home/node/matrix-dimension/config/production.yaml <<ENDCONF
web:
  port: 8184
  address: '0.0.0.0'
homeserver:
  name: "${SYNAPSE_SERVER_NAME}"
  clientServerUrl: "http://synapse:8008"
  accessToken: "${DIMENSION_ACCESS_TOKEN}"
admins:
  - "${BRIDGE_ADMIN_USER}"
database:
  file: "dimension.db"
  botData: "dimension.bot.json"
stickers:
  enabled: true
  stickerBot: "@stickers:t2bot.io"
  managerUrl: "https://stickers.t2bot.io"
dimension:
  publicUrl: "${DIMENSION_PUBLIC_URL}"
ENDCONF

exec node /home/node/matrix-dimension/build/app/index.js -p 8184

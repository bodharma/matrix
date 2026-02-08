#!/bin/sh
set -e

cat > /etc/nginx/conf.d/default.conf <<'ENDNGINX'
resolver 127.0.0.11 valid=10s;

server {
    listen 80;

    set $mas_upstream http://synapse-mass-authentication-service:8080;
    set $synapse_upstream http://synapse:8008;

    location = /.well-known/matrix/client/index.html {
        root /usr/share/nginx/html;
    }

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
}
ENDNGINX

mkdir -p /usr/share/nginx/html/.well-known/matrix/client
cat > /usr/share/nginx/html/.well-known/matrix/client/index.html <<ENDHTML
{"m.homeserver":{"base_url":"${SYNAPSE_FQDN}"},"org.matrix.msc3575.proxy":{"url":"${SYNAPSE_SYNC_FQDN}"},"org.matrix.msc2965.authentication":{"issuer":"${AUTHENTICATION_ISSUER}","account":"${SYNAPSE_MAS_FQDN}/account"}}
ENDHTML

exec nginx -g 'daemon off;'

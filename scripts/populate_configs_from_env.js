const fs = require("fs");
const { getEnv } = require("./utils");

const variables = {
  SYNAPSE_SERVER_NAME: getEnv("SYNAPSE_SERVER_NAME"),
  ADMIN_EMAIL: getEnv("ADMIN_EMAIL"),
  POSTGRES_SYNAPSE_USER: getEnv("POSTGRES_SYNAPSE_USER"),
  POSTGRES_SYNAPSE_PASSWORD: getEnv("POSTGRES_SYNAPSE_PASSWORD"),
  POSTGRES_SYNAPSE_DB: getEnv("POSTGRES_SYNAPSE_DB"),
  POSTGRES_SYNAPSE_HOST: "postgres-synapse",
  SMTP_HOST: getEnv("SMTP_HOST"),
  SMTP_PORT: getEnv("SMTP_PORT"),
  SMTP_USER: getEnv("SMTP_USER"),
  SMTP_PASSWORD: getEnv("SMTP_PASSWORD"),
  SMTP_REQUIRE_TRANSPORT_SECURITY:
    getEnv("SMTP_REQUIRE_TRANSPORT_SECURITY").toLowerCase() === "true"
      ? "true"
      : "false",
  SMTP_NOTIFY_FROM: getEnv("SMTP_NOTIFY_FROM"),
  SYNAPSE_FRIENDLY_SERVER_NAME: getEnv("SYNAPSE_FRIENDLY_SERVER_NAME"),
  KEYCLOAK_FQDN: getEnv("KEYCLOAK_FQDN"),
  KEYCLOAK_CLIENT_ID: getEnv("KEYCLOAK_CLIENT_ID"),
  KEYCLOAK_CLIENT_SECRET: getEnv("KEYCLOAK_CLIENT_SECRET"),
  SYNAPSE_FQDN: getEnv("SYNAPSE_FQDN"),
  SYNAPSE_SYNC_FQDN: getEnv("SYNAPSE_SYNC_FQDN"),
  SYNAPSE_MAS_FQDN: getEnv("SYNAPSE_MAS_FQDN"),
  AUTHENTICATION_ISSUER: getEnv("AUTHENTICATION_ISSUER"),
  SYNAPSE_MAS_SECRET: getEnv("SYNAPSE_MAS_SECRET"),
  SYNAPSE_API_ADMIN_TOKEN: getEnv("SYNAPSE_API_ADMIN_TOKEN"),
  KEYCLOAK_REALM_IDENTIFIER: getEnv("KEYCLOAK_REALM_IDENTIFIER"),
};

const templates = [
  {
    templateFile: "./configurations/synapse/template.homeserver.yaml",
    outFile: "./configurations/synapse/homeserver.yaml",
  },
  {
    templateFile: "./configurations/synapse/template.db.yaml",
    outFile: "./configurations/synapse/db.yaml",
  },
  {
    templateFile: "./configurations/synapse/template.email.yaml",
    outFile: "./configurations/synapse/email.yaml",
  },
  {
    templateFile: "./configurations/synapse/template.oidc.yaml",
    outFile: "./configurations/synapse/oidc.yaml",
  },
  {
    templateFile: "./configurations/nginx/template.well-known.html",
    // to be mounted in container
    // html/.well-known/matrix/client/index.html
    outFile: "./configurations/nginx/index.html",
  },
];

function populateFile(templateFile, outFile) {
  let fileContents = fs.readFileSync(templateFile, "utf8");

  Object.entries(variables).forEach(([key, value]) => {
    fileContents = fileContents.split(`{{${key}}}`).join(value);
  });

  fs.writeFileSync(outFile, fileContents);
}

function populateConfigsFromEnv() {
  for (const template of templates) {
    populateFile(template.templateFile, template.outFile);
  }
}

module.exports = {
  populateConfigsFromEnv,
};
"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");

const appId = process.env.APP_ID;
const installationId = process.env.INSTALLATION_ID;
const keyPath = process.env.APP_KEY_PATH || "/secrets/app-key.pem";
const apiUrl = (process.env.GITHUB_API_URL || "https://api.github.com").replace(/\/+$/, "");

function fail(message) {
  console.error(`generate-token: ${message}`);
  process.exit(1);
}

if (!appId) fail("APP_ID is not set");
if (!installationId) fail("INSTALLATION_ID is not set");

let privateKey;
try {
  privateKey = fs.readFileSync(keyPath);
} catch (error) {
  fail(`cannot read private key at ${keyPath}: ${error.code || error.message}`);
}

const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const unsigned = `${encode({ alg: "RS256", typ: "JWT" })}.${encode({
  iat: now - 60,
  exp: now + 540,
  iss: appId,
})}`;
const signature = crypto.sign("RSA-SHA256", Buffer.from(unsigned), privateKey).toString("base64url");

async function main() {
  const response = await fetch(`${apiUrl}/app/installations/${installationId}/access_tokens`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${unsigned}.${signature}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "renovate-gcp-runner",
    },
    signal: AbortSignal.timeout(15000),
  });

  const body = await response.json().catch(() => ({}));
  if (!response.ok || !body.token) {
    fail(`GitHub API returned ${response.status}: ${body.message || "no token in response"}`);
  }

  process.stdout.write(body.token);
}

main().catch((error) => fail(error.message));

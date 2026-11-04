#!/bin/bash
set -euo pipefail

if [[ -z "${RENOVATE_TOKEN:-}" ]]; then
  RENOVATE_TOKEN="$(node /usr/local/bin/generate-token.js)"
  export RENOVATE_TOKEN
fi

exec /usr/local/sbin/renovate-entrypoint.sh renovate "$@"

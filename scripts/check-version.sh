#!/usr/bin/env bash
# Validates the release version stored in the VERSION file (MAJOR.MINOR.PATCH).
#
#   check-version.sh pr <base-branch>   pull requests: if image files changed,
#                                       VERSION must be bumped and be newer than
#                                       the latest released version
#   check-version.sh publish            main branch: VERSION must be newer than the
#                                       latest release and not already released
set -euo pipefail

cd "$(dirname "$0")/.."

mode="${1:-}"
version="$(tr -d '[:space:]' < VERSION)"

if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "VERSION must contain a version like 1.2.3, got: '${version}'" >&2
  exit 1
fi

latest="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -n1)"
latest="${latest#v}"

require_newer() {
  if [[ -z "$latest" ]]; then
    return 0
  fi
  local highest
  highest="$(printf '%s\n%s\n' "$latest" "$version" | sort -V | tail -n1)"
  if [[ "$version" == "$latest" || "$highest" != "$version" ]]; then
    echo "VERSION ${version} must be newer than the latest release ${latest}." >&2
    exit 1
  fi
}

case "$mode" in
  pr)
    base="${2:?usage: check-version.sh pr <base-branch>}"
    changed="$(git diff --name-only "origin/${base}...HEAD")"
    if grep -Eq '^(Dockerfile|entrypoint\.sh|generate-token\.js)$' <<< "$changed"; then
      if ! grep -qx 'VERSION' <<< "$changed"; then
        echo "Image files changed, so VERSION must be bumped in this pull request." >&2
        exit 1
      fi
      require_newer
    fi
    ;;
  publish)
    if git rev-parse -q --verify "refs/tags/v${version}" > /dev/null; then
      echo "Release v${version} already exists. Bump VERSION before changing the image." >&2
      exit 1
    fi
    require_newer
    ;;
  *)
    echo "usage: check-version.sh pr <base-branch> | publish" >&2
    exit 2
    ;;
esac

echo "VERSION ${version} is valid (latest release: ${latest:-none})."

FROM renovate/renovate:44.213.0@sha256:700a0c525b8b5d0fb961a186e722da96bf160a59bbb219039ada75e39d3befd1

LABEL org.opencontainers.image.title="renovate-gcp-runner" \
      org.opencontainers.image.description="Self-hosted Renovate that authenticates as a GitHub App, built for Cloud Run Jobs" \
      org.opencontainers.image.licenses="MIT"

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0644 generate-token.js /usr/local/bin/generate-token.js

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

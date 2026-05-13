FROM mcr.microsoft.com/devcontainers/javascript-node:4-24-trixie

# Trust the GoC root used by the corporate TLS interception chain so Node,
# curl, git, and other tooling inside the devcontainer can reach external HTTPS
# services such as Supabase while connected to the VPN.
# This must run BEFORE any step that fetches from HTTPS (e.g. fly.io keyring).
RUN wget -q --header="Host: pki-icp.canada.ca" \
    "http://167.43.15.18/aia/GoC-GdC-Root-A.crt" \
    -O /tmp/GoC-GdC-Root-A.crt \
    && cp /tmp/GoC-GdC-Root-A.crt /usr/local/share/ca-certificates/GoC-GdC-Root-A.crt \
    && update-ca-certificates \
    && rm /tmp/GoC-GdC-Root-A.crt

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libreoffice \
    && FLYCTL_INSTALL=/usr/local curl -fsSL https://fly.io/install.sh | sh -s -- --non-interactive \
    && rm -rf /var/lib/apt/lists/*

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt
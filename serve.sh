#!/usr/bin/env bash
# aur-forge serve — run lighttpd against /repo. Long-running.
#
# Replaces darkhttpd (which has no CGI support, verified against the
# upstream source). lighttpd serves:
#   - the pacman repo at /<REPO_NAME>.x86_64/ (static files)
#   - the public signing key at /keys/aur-forge.pub (static, symlinked
#     into /repo/keys at init.sh time)
#   - the web UI at / (GET -> /cgi-bin/index.cgi via mod_rewrite)
#   - the form handlers at /cgi-bin/check.cgi and /cgi-bin/add.cgi
#
# Traefik in front of the container terminates TLS and forwards plain
# HTTP to this port.
set -euo pipefail

REPO_NAME="${REPO_NAME:-custom}"
PORT="${PORT:-8080}"

# Sanity: the repo dir should exist (init must have run first).
[[ -d "/repo/${REPO_NAME}.x86_64" ]] || {
    echo "[serve] /repo/${REPO_NAME}.x86_64 missing — run 'init' first" >&2
    exit 1
}

# Sanity: the CGI script dir should exist (Dockerfile COPY).
[[ -d /usr/lib/aur-forge/cgi-bin ]] || {
    echo "[serve] /usr/lib/aur-forge/cgi-bin missing — image is broken" >&2
    exit 1
}

# Sanity: CSRF secret should exist (Dockerfile RUN at build time).
[[ -s /etc/aur-forge/csrf-secret ]] || {
    echo "[serve] /etc/aur-forge/csrf-secret missing — image is broken" >&2
    exit 1
}

# lighttpd needs a writable upload-dir for its temp files (used by
# mod_dirlisting, mod_cgi, mod_alias). The run-as-user (uid 999) needs
# to be able to create files here.
mkdir -p /var/cache/aur-forge-lighttpd /var/run/aur-forge /var/log/aur-forge-lighttpd
chown -R 999:1000 /var/cache/aur-forge-lighttpd /var/run/aur-forge /var/log/aur-forge-lighttpd 2>/dev/null || true

echo "[serve] lighttpd on 0.0.0.0:${PORT} -> /repo (cgi-bin: /usr/lib/aur-forge/cgi-bin)"
# lighttpd in -D (don't daemonize) mode is the systemd-friendly form.
# The unit's `kill -HUP $(pidof lighttpd)` triggers a graceful reload
# after lighttpd.conf edits; `systemctl restart aur-forge` is the
# blunt option.
exec /usr/bin/lighttpd \
    -D \
    -f /etc/aur-forge/lighttpd.conf

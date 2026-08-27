#!/usr/bin/env bash
# aur-forge serve — run darkhttpd against /repo. Long-running.
set -euo pipefail

REPO_NAME="${REPO_NAME:-custom}"
PORT="${PORT:-8080}"

# Sanity: the repo dir should exist (init must have run first).
[[ -d "/repo/${REPO_NAME}.x86_64" ]] || {
    echo "[serve] /repo/${REPO_NAME}.x86_64 missing — run 'init' first" >&2
    exit 1
}

# darkhttpd: -1 single-threaded is fine for a tiny repo, but we want
# concurrent GETs so pacman can fetch multiple packages in parallel.
# --no-listing hides the directory index for anything we don't explicitly
# link.
echo "[serve] darkhttpd on 0.0.0.0:${PORT} -> /repo"
exec darkhttpd /repo \
    --port "${PORT}" \
    --addr 0.0.0.0 \
    --no-listing \
    --log /dev/stdout

#!/usr/bin/env bash
# aur-forge check.cgi — POST handler for "Check / build" button.
#
# Validates CSRF token, then background-spawns /usr/local/bin/update.sh.
# update.sh queries AUR, compares versions, and rebuilds only the diff
# (no force-rebuild). Returns an HTML page immediately with a status
# message; the actual build runs asynchronously.

set -euo pipefail

LIB=""
for candidate in \
    /usr/local/lib/aur-forge/lib-aur.sh \
    /usr/lib/aur-forge/lib-aur.sh \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)/lib-aur.sh"; do
    [[ -f "$candidate" ]] && LIB="$candidate" && break
done
if [[ -z "$LIB" ]]; then
    printf 'Content-Type: text/html; charset=utf-8\r\n\r\n' 2>/dev/null || true
    printf '<h1>lib-aur.sh not found</h1>\n'
    exit 1
fi
# shellcheck disable=SC1090
. "$LIB"

method="${REQUEST_METHOD:-GET}"
if [[ "$method" != "POST" ]]; then
    cgi_send_header
    cgi_html_doc "405" "<h1>405 Method Not Allowed</h1>
<p>Use POST with a form submission from <a href=\"/\">/</a>.</p>"
    exit 0
fi

body="$(read_post_body)"
parse_form "$body"
csrf="${FORM[csrf]:-}"

if ! csrf_token_validate "$csrf"; then
    cgi_send_header
    cgi_html_doc "403" "<h1>403 Forbidden</h1>
<p>CSRF token missing or invalid. <a href=\"/\">Back to status page</a>.</p>"
    exit 0
fi

# Background-spawn update.sh. setid puts it in its own process group so
# SIGTERM to the CGI doesn't kill the build. Output is captured to the
# container's stdout/stderr (which systemd or docker logs will pick up).
LOG_TAG="[aur-forge-check $(date -u +%FT%TZ)]"
setsid nohup /usr/local/bin/bash -c "echo '${LOG_TAG} starting update.sh'; /usr/local/bin/update.sh" \
    >/var/log/aur-forge-check.log 2>&1 < /dev/null &
spawn_pid=$!

cgi_send_header
cgi_html_doc "check triggered" "<h1>Build check queued</h1>
<div class=\"notice notice-ok\">spawned update.sh as PID ${spawn_pid}; logging to <code>/var/log/aur-forge-check.log</code>. Redirecting back to status in 3 seconds&hellip;</div>
<script>setTimeout(function(){window.location.href='/';}, 3000);</script>
<p><a href=\"/\">&larr; Back to status page</a></p>"

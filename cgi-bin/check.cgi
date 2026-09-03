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

# Background-spawn update.sh. setsid puts it in its own process group so
# SIGTERM to the CGI doesn't kill the build; nohup makes it ignore SIGHUP.
LOG_TAG="[aur-forge-check $(date -u +%FT%TZ)]"
# IMPORTANT: invoke bash by its real path. The Arch base image ships bash
# at /usr/bin/bash; there is NO bash at /usr/local/bin/bash. Calling the
# wrong path produces a silent nohup error and the build never runs.
#
# Log routing: we write the build's output to BOTH destinations:
#   1. $LOG_FILE (for operators with shell access)
#   2. PID 1's stdout (which is what `docker logs` captures)
#
# Writing to PID 1's stdout is done via a process substitution + tee that
# forks /proc/1/fd/1 (the container's stdout). Without this, nohup
# detaches the build from lighttpd's stdout AND inherits nohup's default
# of redirecting stdout to nohup.out — so logs go nowhere visible. The
# previous "echo >&2" attempt only worked when the build happened to run
# in the same session as lighttpd, which is unreliable under setsid.
#
# The log directory is created here so the file redirect never fails on
# the very first invocation after an image rebuild.
mkdir -p /var/log/aur-forge-check
LOG_FILE="/var/log/aur-forge-check/check.log"

# Wrap in bash -c so the LOG_TAG+startup echo go through the same
# pipeline as update.sh output. Process substitution forks tee, which
# writes to both $LOG_FILE and /proc/1/fd/1 in parallel.
setsid nohup /usr/bin/bash -c "
    echo '${LOG_TAG} starting update.sh'
    /usr/local/bin/update.sh
    rc=\$?
    echo \"${LOG_TAG} update.sh finished with rc=\${rc}\"
    exit \${rc}
" > >(/usr/bin/tee -a "$LOG_FILE" > /proc/1/fd/1) 2> >(/usr/bin/tee -a "$LOG_FILE" > /proc/1/fd/1) < /dev/null &
spawn_pid=$!

cgi_send_header
cgi_html_doc "check triggered" "<h1>Build check queued</h1>
<div class=\"notice notice-ok\">spawned update.sh as PID ${spawn_pid}; logging to <code>${LOG_FILE}</code> and the container's stdout (<code>docker logs aur-forge</code>). Redirecting back to status in 3 seconds&hellip;</div>
<script>setTimeout(function(){window.location.href='/';}, 3000);</script>
<p><a href=\"/\">&larr; Back to status page</a></p>"

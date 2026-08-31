#!/usr/bin/env bash
# aur-forge run — 24/7 single-container mode.
#
# Starts three things in parallel under a single bash process group:
#   1. lighttpd foreground, serving /repo on $PORT (default 8080).
#      Traefik front of that publishes https://aur-forge.gateslab.win.
#      lighttpd also handles the bash CGI at /cgi-bin/{index,check,add}.cgi
#      for the web UI. Replaces darkhttpd (which has no CGI support).
#   2. A nightly scheduler background loop that, at NIGHTLY_AT (default
#      "03:00", interpreted in TZ which the container must be set to),
#      runs the full nightly sequence:
#        a. AUR-RPC diff scan  (rebuilds packages whose upstream Version
#           changed; skips OutOfDate).
#        b. archcanary + PKGBUILD-diff re-scan over /pkglist; any
#           PKGBUILD that changed since its last stored approval opens a
#           new quarantine Issue.
#        c. Drain-quarantine — closes/dismisses any open quarantine
#           Issue that has been labeled approved (rebuilds the package
#           and updates the stored hash) or rejected (deletes the
#           cloned tree, never builds).
#   3. This very bash, holding the trap that forwards SIGTERM to both.
#
# On SIGTERM, lighttpd gets SIGTERM (it shuts down cleanly in <1s) and
# the scheduler exits its current sleep. Container exit code 0.
#
# All output is line-buffered and goes to stdout so Komodo / docker logs
# can capture it.
set -uo pipefail

PORT="${PORT:-8080}"
NIGHTLY_AT="${NIGHTLY_AT:-03:00}"
LOG_TAG="[$(date -u +%FT%TZ)]"

# ---------------------------------------------------------------------
# Idempotent bootstrap: generate the GPG signing key (once) + seed the
# repo skeleton, every time the container starts. Safe because init.sh
# short-circuits when the key already exists in /keys/trusted-key.fpr.
# After first deploy the bootstrap adds ~1ms (keygen check + gpg
# --export). On first deploy or after a key rotation it adds ~3-5s.
# ---------------------------------------------------------------------
/usr/local/bin/init.sh

# ---------------------------------------------------------------------
# Subprocess plumbing
# ---------------------------------------------------------------------
DARKHTTD_PID=""  # legacy name; now holds the lighttpd PID. Renaming would
                 # break the cleanup() function below, so kept as-is.
SCHED_PID=""

cleanup() {
    local sig="$1"
    echo "${LOG_TAG} [run] received SIG${sig}, shutting down"
    # Kill the scheduler first so it doesn't try to spawn another job
    # while we're tearing down.
    if [[ -n "${SCHED_PID}" ]] && kill -0 "${SCHED_PID}" 2>/dev/null; then
        kill -TERM "${SCHED_PID}" 2>/dev/null || true
    fi
    if [[ -n "${DARKHTTD_PID}" ]] && kill -0 "${DARKHTTD_PID}" 2>/dev/null; then
        kill -TERM "${DARKHTTD_PID}" 2>/dev/null || true
        # Give it a couple seconds to flush + exit.
        for _ in 1 2 3 4 5; do
            kill -0 "${DARKHTTD_PID}" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "${DARKHTTD_PID}" 2>/dev/null || true
    fi
    # Reap both.
    wait "${SCHED_PID}" 2>/dev/null || true
    wait "${DARKHTTD_PID}" 2>/dev/null || true
    exit 0
}

trap 'cleanup TERM' TERM
trap 'cleanup INT'  INT
trap 'cleanup HUP'  HUP

# ---------------------------------------------------------------------
# Scheduler — the night loop.
# ---------------------------------------------------------------------
nightly_sequence() {
    echo "${LOG_TAG} [scheduler] nightly sequence starting"

    # Step 1: AUR-RPC diff scan (rebuilds packages whose upstream
    # Version differs from /repo).
    if [[ -s "${PKGLIST:-/pkglist}" ]]; then
        echo "${LOG_TAG} [scheduler] AUR diff scan"
        if ! PKGLIST="${PKGLIST:-/pkglist}" /usr/local/bin/update.sh 2>&1; then
            echo "${LOG_TAG} [scheduler] AUR diff scan failed (rc=$?); continuing" >&2
        fi
    fi

    # Step 2: archcanary re-scan over the current /pkglist. The gate
    # inside build.sh compares each PKGBUILD against its stored
    # approval hash; any drift opens a quarantine Issue.
    if [[ -s "${PKGLIST:-/pkglist}" ]]; then
        echo "${LOG_TAG} [scheduler] archcanary re-scan"
        # Run with --dry-run so we don't rebuild every package — only
        # the rebuilds the diff scan already triggered in step 1 should
        # land in /repo. The gate still opens Issues for any PKGBUILD
        # drift detected during the scan. The --dry-run flag in
        # build.sh / archcanary integration is intended for exactly this
        # "scan only" mode.
        if ! PKGLIST="${PKGLIST:-/pkglist}" /usr/local/bin/build.sh --dry-run 2>&1; then
            echo "${LOG_TAG} [scheduler] archcanary re-scan failed (rc=$?); continuing" >&2
        fi
    fi

    # Step 3: drain quarantine Issues.
    echo "${LOG_TAG} [scheduler] draining quarantine Issues"
    if ! /usr/local/bin/drain-quarantine.sh 2>&1; then
        echo "${LOG_TAG} [scheduler] drain-quarantine failed (rc=$?); continuing" >&2
    fi

    echo "${LOG_TAG} [scheduler] nightly sequence complete"
}

scheduler_loop() {
    echo "${LOG_TAG} [scheduler] starting; nightly at ${NIGHTLY_AT} (TZ=${TZ:-UTC})"
    while true; do
        # Compute seconds until next NIGHTLY_AT in container's TZ.
        # `date` +%s gives UTC epoch; we need local epoch. Workaround:
        # compute (next NIGHTLY_AT in local TZ) - now, both as UTC seconds.
        now_epoch="$(date -u +%s)"
        target_epoch="$(TZ="${TZ:-UTC}" date -u -d "today ${NIGHTLY_AT}" +%s)"
        # If target is already past today, push to tomorrow.
        if (( target_epoch <= now_epoch )); then
            target_epoch="$(TZ="${TZ:-UTC}" date -u -d "tomorrow ${NIGHTLY_AT}" +%s)"
        fi
        sleep_for=$(( target_epoch - now_epoch ))
        echo "${LOG_TAG} [scheduler] next run in ${sleep_for}s ($(TZ="${TZ:-UTC}" date -u -d "@${target_epoch}" '+%Y-%m-%d %H:%M:%S %Z'))"

        # Sleep in 60-second chunks so SIGTERM is honored within ~1 min
        # instead of however long until next run.
        remaining="${sleep_for}"
        while (( remaining > 0 )); do
            chunk=60
            if (( remaining < chunk )); then chunk="${remaining}"; fi
            sleep "${chunk}" &
            sleep_pid=$!
            wait "${sleep_pid}" 2>/dev/null || {
                # Woken by signal — exit cleanly.
                exit 0
            }
            remaining=$((remaining - chunk))
        done

        nightly_sequence
    done
}

# ---------------------------------------------------------------------
# Start lighttpd (foreground but we'll background it so we can wait
# on it; it'll block until killed). serve.sh is the wrapper that does
# the chdir to /repo + bind to ${PORT}.
# ---------------------------------------------------------------------
echo "${LOG_TAG} [run] starting lighttpd on :${PORT}"
/usr/local/bin/serve.sh &
DARKHTTD_PID=$!   # variable name kept for back-compat with cleanup() below

# Give lighttpd a moment to bind + log "server started".
sleep 1
if ! kill -0 "${DARKHTTD_PID}" 2>/dev/null; then
    echo "${LOG_TAG} [run] lighttpd exited immediately; aborting" >&2
    exit 1
fi

# Start scheduler.
scheduler_loop &
SCHED_PID=$!

# Wait for either child to exit (lighttpd death = fatal; scheduler
# death = just log and continue).
while true; do
    if ! kill -0 "${DARKHTTD_PID}" 2>/dev/null; then
        echo "${LOG_TAG} [run] lighttpd died; shutting down" >&2
        cleanup TERM
    fi
    if ! kill -0 "${SCHED_PID}" 2>/dev/null; then
        echo "${LOG_TAG} [run] scheduler died; shutting down" >&2
        cleanup TERM
    fi
    sleep 5 &
    wait $! 2>/dev/null || true
done
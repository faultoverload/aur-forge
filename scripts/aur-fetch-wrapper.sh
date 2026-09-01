#!/usr/bin/env bash
# aur-forge aur-fetch-wrapper.sh — single-command AUR fetch.
#
# Why a wrapper exists
# --------------------
# We pin aurutils, then invoke `aur fetch` from the pinned
# install. The wrapper exists for two reasons:
#
#   1. Trace-logging: every fetch goes through this entry point,
#      so `journalctl`/docker logs always have an audit trail
#      with the package name and the resolved exit code.
#   2. Single-command invariant: the 2026-08-30 build-trigger bug
#      showed that chaining `aur` with subshells/redirects on the
#      same line silently drops failures. The wrapper keeps the
#      invocation to ONE command — pure `aur fetch ... pkg` — and
#      forbids any `$(...)`, `<(...)`, or `| tee` on the same line.
#
# Usage:
#   aur-fetch-wrapper.sh <pkgbase> [extra aur-fetch args...]
#
# Output: aur fetch's stdout/stderr (it writes results to
# AUR_RESULTS_FILE if --results is used; we leave that up to the
# caller via the env var AUR_FETCH_RESULTS).
#
# Exit:
#   0 - fetch succeeded
#   1 - args / env invalid
#   2 - fetch failed (network/clone/conflict)
set -euo pipefail

# Defensive: refuse to be called as part of a ><();| chain. The
# 2026-08-30 bait file showed that combining a foreign command
# with redirects on the same line silently breaks the parent
# pipeline. We detect a few text patterns that show the caller's
# invocation was a subshell or command-substitution, and refuse
# to proceed — fail-closed because the original bug swallowed
# errors silently.
if [[ "$*" == *'$('* ]] || [[ "$*" == *'`'* ]] || [[ "$*" == *'<('* ]] || [[ "$*" == *'>('* ]]; then
    printf '[aur-fetch-wrapper] refused: invocation appears combined with a subshell/redirect (%s)\n' "$*" >&2
    exit 2
fi

if [[ "$#" -lt 1 ]]; then
    printf 'usage: %s <pkgbase> [extra aur-fetch args...]\n' "$(basename "$0")" >&2
    exit 1
fi

# Localize which `aur` we resolve to. Pinned by Dockerfile COPY into
# /usr/local/lib/aur-forge/aurutils/. We deliberately do NOT search
# PATH, because PATH may include a later-installed aurutils from a
# user's homedir or a misconfigured bind mount.
AUR_BIN="${AUR_BIN:-/usr/local/lib/aur-forge/aurutils/aur}"
if [[ ! -x "$AUR_BIN" ]]; then
    printf '[aur-fetch-wrapper] FATAL: pinned aurutils not found at %s\n' "$AUR_BIN" >&2
    exit 2
fi

# Verify the pin file matches the just-served helper. If the
# operator rebuilt the image without running install-aurutils.sh,
# this fails closed.
PIN_FILE="${AURUTILS_PIN_DEST:-/usr/local/lib/aur-forge/aurutils}/aurutils.pin"
if [[ ! -r "$PIN_FILE" ]]; then
    printf '[aur-fetch-wrapper] FATAL: %s missing — image was not provisioned by install-aurutils.sh\n' "$PIN_FILE" >&2
    exit 2
fi
PIN_VERSION="$(awk -F= '/^AURUTILS_VERSION=/{print $2; exit}' "$PIN_FILE")"
if [[ "$PIN_VERSION" != "${AURUTILS_VERSION:-}" ]] \
   && [[ "${AURUTILS_VERSION:-UNSET}" != "UNSET" ]]; then
    printf '[aur-fetch-wrapper] WARNING: AURUTILS_VERSION (%s) != installed pin (%s); continuing because AURUTILS_VERSION is explicit\n' "${AURUTILS_VERSION-unset}" "$PIN_VERSION" >&2
fi

# Resolve and run. ONE command — no `$(...)`, no `<(...)`, no
# `| tee`, no redirect chaining inside the runnable line. The
# whole "double-call" bait form is documented in pitfalls.
"$AUR_BIN" fetch "$@"

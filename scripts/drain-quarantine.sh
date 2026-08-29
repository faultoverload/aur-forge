#!/usr/bin/env bash
# aur-forge drain-quarantine.sh — poll GitHub Issues for quarantine
# decisions and act on them.
#
# Designed to run from a Komodo procedure on a 15-minute schedule, or
# on-demand from the CLI. Each run is bounded (issues_fetched < 100 by
# default) so we don't burn the rate limit.
#
# For every open issue labelled `quarantine/blocked`, inspect the labels:
#
#   quarantine/approved   → rebuild the package, refresh /approvals/<pkg>.json,
#                            comment the build log on the issue,
#                            close with label quarantine/done
#   quarantine/rejected   → discard the cloned tree (if present),
#                            comment "rejected",
#                            close with label quarantine/rejected-done
#   quarantine/re-flagged → do nothing — handled by open-quarantine-issue.sh
#                            (which creates a fresh issue and closes the old)
#   no decision label     → leave open, skip silently
#
# Usage:
#   drain-quarantine.sh [--dry-run] [--limit=50]
#
# Env:
#   GITHUB_TOKEN  — required for any actual work
#   GITHUB_REPO   — "owner/name" (default faultoverload/aur-forge)
#   AUR_FORGE_BUILD_SH — path to build.sh (default /usr/local/bin/build.sh)
#
# Exit: 0 on a clean run (whether or not anything happened).
set -euo pipefail

GITHUB_API="https://api.github.com"
DRY_RUN=0
LIMIT=50
REPO="${GITHUB_REPO:-faultoverload/aur-forge}"

for arg in "$@"; do
    case "$arg" in
        --dry-run)        DRY_RUN=1 ;;
        --limit=*)        LIMIT="${arg#*=}" ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/approval-store.sh
source "${SCRIPT_DIR}/approval-store.sh"

# Resolve the build.sh binary. In-container it lives at
# /usr/local/bin/build.sh; in dev / CI, fall back to PATH.
BUILD_SH="${AUR_FORGE_BUILD_SH:-/usr/local/bin/build.sh}"
if [[ ! -x "$BUILD_SH" ]]; then
    BUILD_SH="$(command -v build.sh || true)"
fi
[[ -x "$BUILD_SH" ]] || { echo "[drain-quarantine] build.sh not found on PATH and AUR_FORGE_BUILD_SH not set" >&2; exit 0; }

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "[drain-quarantine] GITHUB_TOKEN unset — nothing to do." >&2
    exit 0
fi

TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

log() { echo "[drain-quarantine] $*"; }
warn() { echo "[drain-quarantine] WARNING: $*" >&2; }

# has_label <json_labels> <name> — echoes the matched label object if the
# label is present, otherwise exits non-zero.
has_label() {
    local labels_json="$1" label_name="$2"
    printf '%s' "$labels_json" | jq -e --arg n "$label_name" '.[] | select(.name == $n)' >/dev/null
}

# close_issue_with_comment <issue_num> <body> <close_label> — post a
# comment on the issue and close it (with the additional label).
close_issue_with_comment() {
    local issue_num="$1"
    local body="$2"
    local close_label="$3"

    local resp="${TMPDIR_RUN}/comment.json"
    local code
    code="$(
        curl -sS -o "$resp" -w '%{http_code}' \
            -X POST \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "${GITHUB_API}/repos/${REPO}/issues/${issue_num}/comments" \
            --data "$(jq -nc --arg b "$body" '{body:$b}')" \
        || echo "000"
    )"
    [[ "$code" =~ ^2 ]] || { warn "comment on issue ${issue_num} returned ${code}"; return; }

    local resp2="${TMPDIR_RUN}/close.json"
    local code2
    code2="$(
        curl -sS -o "$resp2" -w '%{http_code}' \
            -X PATCH \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "${GITHUB_API}/repos/${REPO}/issues/${issue_num}" \
            --data "$(jq -nc --arg l "$close_label" \
                '{state:"closed", labels:([$l])}')" \
        || echo "000"
    )"
    [[ "$code2" =~ ^2 ]] || { warn "close issue ${issue_num} returned ${code2}"; return; }
    log "issue ${issue_num} closed with ${close_label}"
}

# Page through all open quarantine/blocked issues. Stop when an empty
# page comes back. Concatenate into one JSON array.
ISSUES_FILE="${TMPDIR_RUN}/issues.json"
PAGE=1
PAGES_FOUND=0
while :; do
    PAGE_FILE="${TMPDIR_RUN}/issues-page-${PAGE}.json"
    HTTP_CODE="$(
        curl -sS -o "$PAGE_FILE" -w '%{http_code}' \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "${GITHUB_API}/repos/${REPO}/issues?state=open&labels=quarantine/blocked&per_page=${LIMIT}&page=${PAGE}" \
        || echo "000"
    )"
    if [[ "$HTTP_CODE" != "200" ]]; then
        warn "issues page ${PAGE} returned HTTP ${HTTP_CODE}; aborting cycle."
        head -c 500 "$PAGE_FILE" >&2 || true
        echo >&2
        exit 0
    fi
    # Detect "no more pages" by an empty array.
    if [[ "$(jq 'length' "$PAGE_FILE")" -eq 0 ]]; then
        rm -f "$PAGE_FILE"
        break
    fi
    PAGE=$((PAGE+1))
    PAGES_FOUND=$((PAGES_FOUND+1))
    # Safety net so a runaway state doesn't loop forever.
    [[ "$PAGE" -le 10 ]] || { warn "hit 10-page safety limit"; break; }
done

# Concatenate the surviving pages.
: > "$ISSUES_FILE"
for f in "${TMPDIR_RUN}"/issues-page-*.json; do
    [[ -e "$f" ]] || continue
    jq '.' "$f"
done | jq -s '.' > "$ISSUES_FILE"
rm -f "${TMPDIR_RUN}"/issues-page-*.json

TOTAL="$(jq 'length' "$ISSUES_FILE")"
log "found ${TOTAL} open quarantine/blocked issue(s) across ${PAGES_FOUND} page(s)"

[[ "$TOTAL" -eq 0 ]] && exit 0

# Process each issue. Using a tmp file per iteration so the read loop
# works without surprises (the `while | read` trick kills variables set
# inside the loop when used inside a pipeline).
ISSUE_INDEX=0
while [[ "$ISSUE_INDEX" -lt "$TOTAL" ]]; do
    ISSUE_JSON="${TMPDIR_RUN}/issue-${ISSUE_INDEX}.json"
    jq -c ".[${ISSUE_INDEX}]" "$ISSUES_FILE" > "$ISSUE_JSON"
    ISSUE_INDEX=$((ISSUE_INDEX+1))

    NUMBER="$(jq -r '.number' "$ISSUE_JSON")"
    TITLE="$(jq -r '.title' "$ISSUE_JSON")"
    PKG="$(printf '%s' "$TITLE" | awk -F'] ' '{print $NF}')"
    LABELS_JSON="$(jq -c '.labels' "$ISSUE_JSON")"

    if has_label "$LABELS_JSON" "quarantine/re-flagged"; then
        log "issue ${NUMBER} (${PKG}) is quarantine/re-flagged — leaving alone"
        continue
    fi

    if has_label "$LABELS_JSON" "quarantine/approved"; then
        log "issue ${NUMBER} (${PKG}) approved — triggering rebuild"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "  --dry-run: would invoke build.sh --only=${PKG}"
            continue
        fi
        BUILD_LOG="${TMPDIR_RUN}/build-${PKG}.log"
        if "$BUILD_SH" --only="$PKG" >"$BUILD_LOG" 2>&1; then
            close_issue_with_comment "$NUMBER" \
                "$(printf '**drain-quarantine:** rebuild succeeded.\n\n```\n%s\n```' \
                    "$(tail -40 "$BUILD_LOG")")" \
                "quarantine/done"
        else
            warn "rebuild for ${PKG} failed — closing with quarantine/build-failed"
            close_issue_with_comment "$NUMBER" \
                "$(printf '**drain-quarantine:** rebuild FAILED.\n\n```\n%s\n```' \
                    "$(tail -40 "$BUILD_LOG")")" \
                "quarantine/build-failed"
        fi
        continue
    fi

    if has_label "$LABELS_JSON" "quarantine/rejected"; then
        log "issue ${NUMBER} (${PKG}) rejected — discarding clone"
        if [[ "$DRY_RUN" -eq 0 ]]; then
            rm -rf "/cache/work/${PKG}"
            remove_approval "$PKG"
        fi
        close_issue_with_comment "$NUMBER" \
            "**drain-quarantine:** rejected — not building. Clone discarded, approval removed." \
            "quarantine/rejected-done"
        continue
    fi

    log "issue ${NUMBER} (${PKG}) has no decision label — skipping"
done

log "done"

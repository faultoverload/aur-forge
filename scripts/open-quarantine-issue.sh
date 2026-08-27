#!/usr/bin/env bash
# aur-forge open-quarantine-issue.sh — file a GitHub Issue when build.sh
# decides to quarantine a package.
#
# Usage:
#   open-quarantine-issue.sh <pkg> <reason> <details_json_path>
#
# reason is one of the canonical quarantine reasons:
#   BLOCKLIST-MATCH
#   PKGBUILD-DEPS-CHANGED
#   PKGBUILD-CODE-CHANGED
#   PKGBUILD-INSTALL-ADDED
#   PKGBUILD-INSTALL-EDITED
#
# Exit codes:
#   0 — issue opened (or attempted; check the URL on stdout)
#   1 — GITHUB_TOKEN unset, no issue opened, build is already aborted anyway
#   2 — malformed arguments
#
# On 401/403 from the API we log a warning and exit 0 — the build is
# already aborted, we just couldn't file the paperwork.
set -euo pipefail

GITHUB_API="https://api.github.com"

if [[ $# -lt 3 ]]; then
    echo "usage: $0 <pkg> <reason> <details_json_path>" >&2
    exit 2
fi

PKG="$1"
REASON="$2"
DETAILS_FILE="$3"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "[open-quarantine-issue] GITHUB_TOKEN unset — skipping issue creation for $PKG ($REASON)" >&2
    echo "[open-quarantine-issue] build is already aborted; reviewer must triage manually" >&2
    exit 1
fi

if [[ ! -s "$DETAILS_FILE" ]]; then
    echo "[open-quarantine-issue] details file missing or empty: $DETAILS_FILE" >&2
    exit 2
fi

# GITHUB_REPO is "owner/name" — default to faultoverload/aur-forge.
REPO="${GITHUB_REPO:-faultoverload/aur-forge}"

# Sanitize reason into a label-safe slug.
LABEL_SLUG="$(printf '%s' "$REASON" | tr '[:upper:]' '[:lower:]')"

TITLE="[QUARANTINE][${REASON}] ${PKG}"

# Build the body from the details JSON. We use jq to extract the most
# important fields, then wrap them in a markdown template. Everything else
# in the JSON is preserved in a fenced code block at the bottom for the
# reviewer who wants raw data.
BODY="$(jq -r --arg pkg "$PKG" --arg reason "$REASON" '
    {
        pkgbuild_sha256:        (.pkgbuild_sha256        // "n/a"),
        srcinfo_sha256:         (.srcinfo_sha256         // "n/a"),
        archcanary_exit_code:   (.archcanary_exit_code   // "n/a"),
        approved_version:       (.approved_version       // "first build"),
        workdir:                (.workdir                // "n/a"),
        blocklist_match:        (.blocklist_match        // false),
        pkgbuild_obfuscation:   (.pkgbuild_obfuscation   // false)
    } as $m
    | "## Quarantine event\n\n" +
      "Package: **\($pkg)**\n" +
      "Reason: **\($reason)**\n\n" +
      "- PKGBUILD SHA-256:  `\($m.pkgbuild_sha256)`\n" +
      "- .SRCINFO SHA-256:  `\($m.srcinfo_sha256)`\n" +
      "- archcanary exit:   `\($m.archcanary_exit_code)` (2 = flagged)\n" +
      "- Approved version:  `\($m.approved_version)`\n" +
      "- Cloned tree:       `\($m.workdir)`\n" +
      "- Blocklist match:   `\($m.blocklist_match)`\n" +
      "- PKGBUILD obfuscation flag: `\($m.pkgbuild_obfuscation)`\n\n" +
      "## Reviewer actions\n\n" +
      "Add one of these labels to close this issue:\n\n" +
      "- `quarantine/approved` — drain procedure will rebuild and refresh the hash\n" +
      "- `quarantine/rejected` — drain procedure will discard the clone\n\n" +
      "## Raw details\n\n```json\n" + (. | tostring) + "\n```\n"
' "$DETAILS_FILE")"

LABELS_JSON="$(jq -nc \
    --arg reason "$LABEL_SLUG" \
    '["quarantine/" + $reason, "quarantine/blocked"]')"

PAYLOAD="$(jq -nc \
    --arg title "$TITLE" \
    --arg body  "$BODY" \
    --argjson labels "$LABELS_JSON" \
    '{title: $title, body: $body, labels: $labels}')"

RESPONSE_FILE="$(mktemp)"
HTTP_CODE="$(
    curl -sS -o "$RESPONSE_FILE" -w '%{http_code}' \
        -X POST \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${GITHUB_API}/repos/${REPO}/issues" \
        -d "$PAYLOAD" || echo "000"
)"

case "$HTTP_CODE" in
    2*)
        ISSUE_URL="$(jq -r '.html_url // "unknown"' "$RESPONSE_FILE" 2>/dev/null || echo "unknown")"
        ISSUE_NUM="$(jq -r '.number // "unknown"' "$RESPONSE_FILE" 2>/dev/null || echo "unknown")"
        echo "[open-quarantine-issue] filed issue #${ISSUE_NUM} for ${PKG} (${REASON}): ${ISSUE_URL}"
        rm -f "$RESPONSE_FILE"
        exit 0
        ;;
    401|403)
        echo "[open-quarantine-issue] WARNING: GitHub returned ${HTTP_CODE} — token may be stale or repo may have disabled Issues." >&2
        echo "[open-quarantine-issue] review the response below and re-run manually:" >&2
        head -c 1000 "$RESPONSE_FILE" >&2
        echo >&2
        rm -f "$RESPONSE_FILE"
        # Build is already aborted; we just couldn't file the issue.
        exit 0
        ;;
    *)
        echo "[open-quarantine-issue] WARNING: GitHub returned HTTP ${HTTP_CODE} — issue NOT filed." >&2
        head -c 1000 "$RESPONSE_FILE" >&2
        echo >&2
        rm -f "$RESPONSE_FILE"
        exit 0
        ;;
esac

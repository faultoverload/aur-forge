#!/usr/bin/env bash
# aur-forge quarantine-decide — approve or reject a quarantined package.
#
# The single entry point for the web UI (cgi-bin/package.cgi). It
#   1. records the decision with build.sh --approve= / --reject=
#      (approval/rejection store, snapshot, history; pinned to the PKGBUILD
#      hash the reviewer saw via --sha),
#   2. syncs the GitHub Issue (comment + close) when GITHUB_TOKEN is set,
#   3. for "approve": starts the rebuild in the background (unless --no-build).
#
# usage: quarantine-decide.sh approve|reject <pkg> [--sha SHA256] [--by NAME]
#                                           [--issue N] [--no-build]
# exit:  0 ok · 2 usage · 3 PKGBUILD changed since review · 4 nothing quarantined
set -uo pipefail

BUILD_SH="${AUR_FORGE_BUILD_SH:-/usr/local/bin/build.sh}"
GITHUB_API="${GITHUB_API:-https://api.github.com}"
REPO="${GITHUB_REPO:-faultoverload/aur-forge}"
LOG_FILE="${AUR_FORGE_LOG_FILE:-/var/log/aur-forge-check/check.log}"

usage() { echo "usage: $0 approve|reject <pkg> [--sha SHA256] [--by NAME] [--issue N] [--no-build]" >&2; exit 2; }

[[ $# -ge 2 ]] || usage
action="$1"; pkg="$2"; shift 2
[[ "$action" == approve || "$action" == reject ]] || usage
[[ "$pkg" =~ ^[a-z0-9][a-z0-9._+-]{0,63}$ && "$pkg" != *..* ]] || { echo "invalid package name" >&2; exit 2; }

sha=""; by="${DECIDED_BY:-web-ui}"; issue=""; build=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sha)      sha="$2"; shift 2 ;;
        --by)       by="$2"; shift 2 ;;
        --issue)    issue="$2"; shift 2 ;;
        --no-build) build=0; shift ;;
        *) usage ;;
    esac
done
[[ -z "$sha" || "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid --sha" >&2; exit 2; }
by_re='^[A-Za-z0-9._@ -]{1,40}$'
[[ "$by" =~ $by_re ]] || by="web-ui"
[[ -z "$issue" || "$issue" =~ ^[0-9]+$ ]] || usage

# --- 1. record the decision --------------------------------------------------
args=( "--${action}=${pkg}" "--by=${by}" )
[[ -n "$sha"   ]] && args+=( "--expect-sha=${sha}" )
[[ -n "$issue" ]] && args+=( "--issue=${issue}" )
out="$("$BUILD_SH" "${args[@]}" 2>&1)"; rc=$?
printf '%s\n' "$out"
(( rc == 0 )) || exit "$rc"

# --- 2. GitHub Issue sync (best effort) -------------------------------------
gh() { curl -sS -m 20 -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    if [[ -z "$issue" ]]; then
        issue="$(gh "${GITHUB_API}/repos/${REPO}/issues?state=open&labels=quarantine%2Fblocked&per_page=100" 2>/dev/null \
                 | jq -r --arg p "$pkg" '[.[]? | select(.title | endswith("] " + $p)) | .number][0] // empty' 2>/dev/null || true)"
    fi
    if [[ -n "$issue" ]]; then
        if [[ "$action" == approve ]]; then verb="approved"; closelabel="quarantine/done"
        else verb="rejected"; closelabel="quarantine/rejected-done"; fi
        body="**${verb}** via the aur-forge web UI by \`${by}\`${sha:+ (PKGBUILD sha256 \`${sha:0:16}…\`)}."
        [[ "$action" == approve && $build -eq 1 ]] && body+=$'\n\nRebuild started; see the package page for the result.'
        gh -X POST "${GITHUB_API}/repos/${REPO}/issues/${issue}/comments" \
           --data "$(jq -nc --arg b "$body" '{body:$b}')" >/dev/null 2>&1 || echo "[decide] WARNING: could not comment on issue #${issue}" >&2
        gh -X PATCH "${GITHUB_API}/repos/${REPO}/issues/${issue}" \
           --data "$(jq -nc --arg l "$closelabel" '{state:"closed", labels:[$l]}')" >/dev/null 2>&1 \
           && echo "[decide] issue #${issue} closed (${closelabel})" || echo "[decide] WARNING: could not close issue #${issue}" >&2
    else
        echo "[decide] no open quarantine Issue found for ${pkg} (nothing to close)"
    fi
fi

# --- 3. rebuild --------------------------------------------------------------
if [[ "$action" == approve && $build -eq 1 ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    tag="[aur-forge-decide $(date -u +%FT%TZ)]"
    setsid nohup /usr/bin/bash -c "
        echo '${tag} rebuilding ${pkg} after approval'
        '${BUILD_SH}' --only='${pkg}'
        echo \"${tag} build.sh finished for ${pkg} rc=\$?\"
    " >> "$LOG_FILE" 2>&1 < /dev/null &
    echo "[decide] rebuild of ${pkg} started in the background (pid $!, log: ${LOG_FILE})"
fi
exit 0

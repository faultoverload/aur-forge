#!/usr/bin/env bash
# aur-forge index.cgi — package status page.
#
# GET / -> render the HTML table of every package in pkglist.txt with
# its current status, local version, and AUR version.
#
# Status values:
#   built          — *.pkg.tar.zst exists in /repo/<repo>.x86_64/
#   building       — /cache/work/<pkg> exists (a clone is on disk)
#   quarantined    — a quarantined clone on disk and/or an open [QUARANTINE] Issue; the
#                    row links to the package page (cgi-bin/package.cgi) to review it
#   rejected       — this exact PKGBUILD was rejected; not built until it changes
#   missing        — package is in pkglist.txt but not in /repo (no build yet)
#
# The page also renders:
#   - "Check for new builds" button (POSTs to /cgi-bin/check.cgi)
#   - "Add packages" form (POSTs to /cgi-bin/add.cgi)
#   - install instructions (only on the GET / handler)

set -euo pipefail

# Locate lib-aur.sh. In the production image it lives at
# /usr/local/lib/aur-forge/lib-aur.sh (or /usr/lib/aur-forge/, depending
# on image layout); in the smoke test it's adjacent at ../scripts/.
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
export APPROVALS_DIR="${APPROVALS_DIR:-/approvals}"
export QUARANTINE_DIR="${QUARANTINE_DIR:-/cache/work-quarantine}"
# shellcheck disable=SC1090,SC1091
. "$(dirname "$LIB")/approval-store.sh"

# lib-aur.sh defaults REPO_NAME/PKGLIST from env; respect those.

# ---------------------------------------------------------------------
# Gather data: pkglist -> associative arrays keyed by package name.
# ---------------------------------------------------------------------
declare -A PKG_LOCAL_VER  # name -> version in /repo
declare -A PKG_AUR_VER    # name -> version on AUR
declare -A PKG_OOD        # name -> "null" or unix-timestamp string
declare -A PKG_STATUS     # name -> built|building|quarantined|missing

# Local versions
PKGS_STR="$(parse_pkglist | tr '\n' ' ' | sed 's/ $//')"
# shellcheck disable=SC2206  # word-split intentional; pkg names don't contain spaces
PKGS_ARR=( $PKGS_STR )
if [[ -n "$PKGS_STR" ]]; then
    PKGS="$PKGS_STR"  # export for lib-aur.sh
    export PKGS
    while IFS=$'\t' read -r n v; do
        [[ -z "$n" ]] && continue
        PKG_LOCAL_VER["$n"]="$v"
    done < <(parse_local_versions)
    unset PKGS
fi

# AUR versions
if [[ ${#PKGS_ARR[@]} -gt 0 ]]; then
    while IFS=$'\t' read -r n v o; do
        [[ -z "$n" ]] && continue
        PKG_AUR_VER["$n"]="$v"
        PKG_OOD["$n"]="$o"
    done < <(query_aur_versions "${PKGS_ARR[@]}")
fi

# Build status from local filesystem. Building is inferred from a clone
# in /cache/work/<pkg>; quarantined from open GH Issues (if GITHUB_TOKEN
# is set); otherwise built or missing.
declare -A QUARANTINED  # name -> issue number ("" when only a local stash exists)
declare -A REJECTED
if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_REPO:-}" ]]; then
    # Titles look like "[QUARANTINE][<REASON>] <pkgname>" (scripts/open-quarantine-issue.sh).
    while IFS=$'\t' read -r title issue_num; do
        [[ -z "$issue_num" ]] && continue
        pkg="${title##*] }"
        [[ -n "$pkg" ]] && QUARANTINED["$pkg"]="$issue_num"
    done < <(curl -fsS -m 8 \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_REPO}/issues?state=open&labels=quarantine%2Fblocked&per_page=100" \
        2>/dev/null | jq -r '.[]? | select(.title | startswith("[QUARANTINE]")) | [.title, (.number|tostring)] | @tsv' 2>/dev/null || true)
fi
# A quarantined clone on disk is authoritative even without GitHub access.
for pkg in "${PKGS_ARR[@]}"; do
    if [[ -n "$(quarantine_stashes "$pkg" | tail -n1)" ]]; then
        QUARANTINED["$pkg"]="${QUARANTINED[$pkg]:-}"
    fi
    [[ -s "${APPROVALS_DIR}/${pkg}.rejected.json" ]] && REJECTED["$pkg"]=1
done

for pkg in "${PKGS_ARR[@]}"; do
    if [[ -n "${QUARANTINED[$pkg]+x}" ]]; then
        PKG_STATUS["$pkg"]="quarantined"
    elif [[ -n "${REJECTED[$pkg]:-}" ]]; then
        PKG_STATUS["$pkg"]="rejected"
    elif [[ -d "/cache/work/${pkg}" ]]; then
        PKG_STATUS["$pkg"]="building"
    elif [[ -n "${PKG_LOCAL_VER[$pkg]:-}" ]]; then
        PKG_STATUS["$pkg"]="built"
    else
        PKG_STATUS["$pkg"]="missing"
    fi
done

# ---------------------------------------------------------------------
# Render HTML.
# ---------------------------------------------------------------------
csrf_field="$(csrf_form_field)"

# Build the table rows.
table_rows=""
for pkg in "${PKGS_ARR[@]}"; do
    local_ver="${PKG_LOCAL_VER[$pkg]:-—}"
    aur_ver="${PKG_AUR_VER[$pkg]:-?}"
    ood="${PKG_OOD[$pkg]:-null}"
    status="${PKG_STATUS[$pkg]:-missing}"
    issue_cell="—"
    if [[ "$status" == "quarantined" ]]; then
        issue_cell="<a href=\"/cgi-bin/package.cgi?name=$(html_escape "$pkg")\"><strong>review &rarr;</strong></a>"
        issue_num="${QUARANTINED[$pkg]:-}"
        [[ -n "$issue_num" ]] && issue_cell+=" &middot; <a href=\"https://github.com/${GITHUB_REPO}/issues/${issue_num}\">#${issue_num}</a>"
    elif [[ "$status" == "rejected" ]]; then
        issue_cell="<a href=\"/cgi-bin/package.cgi?name=$(html_escape "$pkg")\">rejected &rarr;</a>"
    fi
    ood_disp="—"
    if [[ "$ood" != "null" && -n "$ood" ]]; then
        ood_disp="marked OOD"
    fi
    table_rows+="<tr>"
    table_rows+="<td><a href=\"/cgi-bin/package.cgi?name=$(html_escape "$pkg")\"><code>$(html_escape "$pkg")</code></a></td>"
    table_rows+="<td><span class=\"status-${status}\">${status}</span></td>"
    table_rows+="<td>$(html_escape "$local_ver")</td>"
    table_rows+="<td>$(html_escape "$aur_ver")</td>"
    table_rows+="<td>$(html_escape "$ood_disp")</td>"
    table_rows+="<td>${issue_cell}</td>"
    table_rows+="</tr>"
done

review_banner=""
n_review=0
for pkg in "${PKGS_ARR[@]}"; do [[ "${PKG_STATUS[$pkg]:-}" == "quarantined" ]] && n_review=$((n_review+1)); done
if (( n_review > 0 )); then
    review_banner="<div class=\"banner\"><strong>${n_review} package(s) awaiting quarantine review</strong> &mdash; click <em>review</em> in the Quarantine column to read the PKGBUILD and approve or reject it.</div>"
fi

body=$(cat <<BODY
<h1>aur-forge package status</h1>
${review_banner}

<p>Showing <strong>${#PKGS_ARR[@]}</strong> package(s) from <code>pkglist.txt</code>. Repo: <code>${REPO_NAME}</code>.</p>

<table>
<thead>
<tr>
<th>Package</th>
<th>Status</th>
<th>Local ver</th>
<th>AUR ver</th>
<th>AUR flag</th>
<th>Review</th>
</tr>
</thead>
<tbody>
${table_rows}
</tbody>
</table>

<h2>Trigger a check</h2>
<form method="POST" action="/cgi-bin/check.cgi">
<input type="hidden" name="csrf" value="${csrf_field}">
<p>Runs <code>update.sh</code> in the background. Rebuilds only packages whose upstream AUR version differs from the local version. Safe to press repeatedly — no-op if everything is current.</p>
<input type="submit" value="Check / build out-of-date packages">
</form>

<h2>Add packages</h2>
<form method="POST" action="/cgi-bin/add.cgi">
<input type="hidden" name="csrf" value="${csrf_field}">
<p>One package name per line. Validated against the Arch package-name regex; anything that doesn't match is silently dropped. Duplicates against the current <code>pkglist.txt</code> are ignored.</p>
<textarea name="packages" placeholder="yay&#10;paru&#10;trizen"></textarea><br>
<input type="submit" value="Add to pkglist.txt">
</form>

<h2>Install instructions</h2>
<p>Add this repo to an Arch Linux client:</p>
<pre><code># 1. Import the signing key
sudo pacman-key --recv-keys FPR_PLACEHOLDER
sudo pacman-key --lsign-key FPR_PLACEHOLDER

# OR fetch it directly:
curl -fsSL https://aur-forge.gateslab.win/keys/aur-forge.pub \\
    | sudo pacman-key --add -

# 2. Register the repo
curl -fsSL https://aur-forge.gateslab.win/install-repo.sh | sudo bash

# 3. Install anything from the repo
pacman -Syu &lt;package-name&gt;</code></pre>
<p>Or browse the repo directly: <a href="/${REPO_NAME}.x86_64/">/${REPO_NAME}.x86_64/</a> &middot; <a href="/keys/aur-forge.pub">public signing key</a>.</p>
BODY
)

cgi_send_header
cgi_html_doc "aur-forge — package status" "$body"

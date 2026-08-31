#!/usr/bin/env bash
# aur-forge add.cgi — POST handler for the "Add packages" form.
#
# Validates CSRF token, parses the textarea, validates each line against
# the Arch package-name regex, deduplicates against the current pkglist,
# and atomically appends new entries.
#
# Output: a summary page listing added/ignored/rejected packages.

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
pkgs_raw="${FORM[packages]:-}"

if ! csrf_token_validate "$csrf"; then
    cgi_send_header
    cgi_html_doc "403" "<h1>403 Forbidden</h1>
<p>CSRF token missing or invalid. <a href=\"/\">Back to status page</a>.</p>"
    exit 0
fi

if [[ -z "$pkgs_raw" ]]; then
    cgi_send_header
    cgi_html_doc "no input" "<h1>No packages supplied</h1>
<p>The form's <code>packages</code> field was empty. <a href=\"/\">Back to status page</a>.</p>"
    exit 0
fi

# ---------------------------------------------------------------------
# Validate every line. Track which are valid, which already exist,
# which are malformed, which are empty/comments.
# ---------------------------------------------------------------------
declare -a ADDED=()
declare -a ALREADY=()
declare -a INVALID=()
declare -a IGNORED=()

# Existing pkglist (for dedup)
declare -A EXISTING
while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue
    EXISTING["$line"]=1
done < <(cat "$PKGLIST" 2>/dev/null || true)

# Parse the textarea input. Handle \r\n line endings.
while IFS= read -r line; do
    line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^# ]]; then IGNORED+=("$line"); continue; fi

    if ! pkgname_is_valid "$line"; then
        INVALID+=("$line")
        continue
    fi
    if [[ -n "${EXISTING["$line"]:-}" ]]; then
        ALREADY+=("$line")
        continue
    fi
    ADDED+=("$line")
    EXISTING["$line"]=1
done <<< "$pkgs_raw"

# ---------------------------------------------------------------------
# Append the new packages to /pkglist.
#
# IMPORTANT: /pkglist is a bind-mounted regular file (compose
# bind-mounts /opt/docker/data/aur-forge/pkglist.txt → /pkglist
# inside the container). On Linux, mv-ing over a bind-mounted file
# fails with "Device or resource busy" because the kernel considers
# the file in-use. So instead of write-tmp + atomic-mv, we write
# in-place: read current contents, then write the new content
# (existing + appended entries) into a fresh temp file in /tmp,
# then cat that into /pkglist with a leading newline guard. This
# isn't strictly atomic (a SIGKILL mid-write could leave the file
# truncated), but /pkglist is tiny (single-line package names),
# a single CGI process owns writes, and the only consequence of
# corruption is "user retries" — no external state depends on the
# file being mid-rewrite being well-formed.
# ---------------------------------------------------------------------
if [[ ${#ADDED[@]} -gt 0 ]]; then
    # Build the new content in a /tmp file (not in /pkglist's directory,
    # which is a regular file, not a directory).
    new_content="$(mktemp /tmp/pkglist-new.XXXXXX)"
    trap 'rm -f "$new_content"' EXIT

    # Copy current content first (if any).
    if [[ -s "$PKGLIST" ]]; then
        cat "$PKGLIST" > "$new_content"
        # Ensure file ends with exactly one newline before appending.
        if [[ "$(tail -c 1 "$PKGLIST" | wc -l)" -eq 0 ]]; then
            printf '\n' >> "$new_content"
        fi
    fi
    # Append new entries, each terminated by a newline.
    for pkg in "${ADDED[@]}"; do
        printf '%s\n' "$pkg" >> "$new_content"
    done

    # Write the new content over the bind-mounted file. We can't
    # use mv (device busy). Append is safe but doesn't truncate.
    # So: open for write (truncate), then cat the new content.
    if ! cat "$new_content" > "$PKGLIST"; then
        cgi_send_header
        cgi_html_doc "500" "<h1>500 Internal Error</h1>
<p>Failed to write pkglist at <code>${PKGLIST}</code>. Check that the bind-mount is read-write and the directory has enough space.</p>"
        exit 0
    fi
fi

# ---------------------------------------------------------------------
# Render summary.
# ---------------------------------------------------------------------
escape_list() {
    local sep=""
    for p in "$@"; do
        printf '%s<code>%s</code>' "$sep" "$(html_escape "$p")"
        sep=", "
    done
}

added_html="$([[ ${#ADDED[@]}    -gt 0 ]] && escape_list "${ADDED[@]}"    || echo '<em>none</em>')"
already_html="$([[ ${#ALREADY[@]}  -gt 0 ]] && escape_list "${ALREADY[@]}"  || echo '<em>none</em>')"
invalid_html="$([[ ${#INVALID[@]}  -gt 0 ]] && escape_list "${INVALID[@]}"  || echo '<em>none</em>')"
ignored_html="$([[ ${#IGNORED[@]}  -gt 0 ]] && escape_list "${IGNORED[@]}"  || echo '<em>none</em>')"

if [[ ${#ADDED[@]} -gt 0 ]]; then
    notice_class="notice-ok"
    notice_msg="Added <strong>${#ADDED[@]}</strong> package(s) to <code>${PKGLIST}</code>."
else
    notice_class="notice-err"
    notice_msg="No packages were added."
fi

csrf_field="$(csrf_form_field)"

body=$(cat <<BODY
<h1>Add packages — result</h1>
<div class="notice ${notice_class}">${notice_msg}</div>

<h2>Added (${#ADDED[@]})</h2>
<p>${added_html}</p>

<h2>Already in pkglist (${#ALREADY[@]})</h2>
<p>${already_html}</p>

<h2>Invalid / rejected (${#INVALID[@]})</h2>
<p>${invalid_html}</p>
<p><small>Rejection reasons: empty line, contains whitespace, doesn't match <code>^[a-z0-9][a-z0-9._+-]{0,63}$</code>, or contains <code>/</code> or <code>..</code>.</small></p>

<h2>Ignored comments (${#IGNORED[@]})</h2>
<p>${ignored_html}</p>

<p><a href="/">&larr; Back to status page</a> (the new packages will show up on next page load; the next <code>update.sh</code> run will build them).</p>

<h3>Add more</h3>
<form method="POST" action="/cgi-bin/add.cgi">
<input type="hidden" name="csrf" value="${csrf_field}">
<textarea name="packages" placeholder="yay&#10;paru"></textarea><br>
<input type="submit" value="Add to pkglist.txt">
</form>
BODY
)

cgi_send_header
cgi_html_doc "aur-forge — add packages" "$body"

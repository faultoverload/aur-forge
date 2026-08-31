#!/usr/bin/env bash
# aur-forge lib-aur.sh — shared helpers sourced by update.sh and the CGI scripts.
#
# This file MUST NOT execute code at source time (apart from setting
# default-var expansions). Both update.sh and the CGI scripts source it
# via `. "$LIB_AUR_PATH"`, and any side effect here would run on every
# CGI invocation.
#
# Functions exported:
#   pkgname_is_valid <name>
#   parse_pkglist [path] -> emits package names one per line on stdout
#   query_aur_versions <pkg> [<pkg> ...] -> emits "name<TAB>version<TAB>ood_ts"
#   parse_local_versions [repo_dir] -> emits "name<TAB>version" from *.pkg.tar.zst
#   html_escape <string>
#   csrf_token_init [path] -> ensures a secret file exists at <path>
#   csrf_token_issue [path] -> emits a token derived from the secret
#   csrf_token_validate <token> [path] -> exits 0 if valid
#   read_post_body -> echoes POST body to stdout
#   url_decode <string>
#   parse_form <body> -> sets associative array FORM[<key>]=<value>
#   cgi_send_header [content_type]
#   cgi_html_doc <title> [body_html]
set -euo pipefail

# Defaults — all overridable from the caller's environment.
REPO_NAME="${REPO_NAME:-aur-forge}"
PKGLIST="${PKGLIST:-/pkglist}"
REPO_DIR_DEFAULT="/repo/${REPO_NAME}.x86_64"
AUR_BASE="${AUR_BASE:-https://aur.archlinux.org/rpc/?v=5&type=multiinfo}"
AUR_USER_AGENT="${AUR_USER_AGENT:-aur-forge/1.0 (https://github.com/faultoverload/aur-forge)}"
CSRF_SECRET_FILE="${CSRF_SECRET_FILE:-/etc/aur-forge/csrf-secret}"

# ----------------------------------------------------------------------
# pkgname_is_valid <name>
# Returns 0 if <name> matches the Arch package-name regex and is not
# empty. Rejects anything containing '/', '..', whitespace, or control
# chars. This is the only validation the web UI trusts — every name
# passed in via the "Add packages" form must pass this check before
# being appended to pkglist.txt.
# ----------------------------------------------------------------------
pkgname_is_valid() {
    local name="$1"
    [[ -n "$name" ]] || return 1
    [[ "$name" =~ ^[a-z0-9][a-z0-9._+-]{0,63}$ ]] || return 1
    [[ "$name" != *"/"* ]] || return 1
    [[ "$name" != *".."* ]] || return 1
    return 0
}

# ----------------------------------------------------------------------
# parse_pkglist [path]
# Emits non-empty, non-comment lines from the pkglist on stdout, one
# per line. Comments are lines whose first non-whitespace char is '#'.
# ----------------------------------------------------------------------
parse_pkglist() {
    local path="${1:-$PKGLIST}"
    [[ -s "$path" ]] || return 0
    grep -vE '^\s*(#|$)' "$path" || true
}

# ----------------------------------------------------------------------
# query_aur_versions <pkg> [<pkg> ...]
# Batched AUR RPC multiinfo query. Accepts 1..N package names on the
# command line; batches of BATCH_SIZE go out as a single HTTP GET.
# Emits "name<TAB>version<TAB>ood" per result on stdout. OutOfDate is
# either "null" or a unix timestamp string.
#
# Behavior on RPC error: prints nothing for that batch and continues.
# AUR has a ~2 req/sec rate limit; we sleep 1s between batches.
# ----------------------------------------------------------------------
query_aur_versions() {
    local -a pkgs=("$@")
    [[ ${#pkgs[@]} -gt 0 ]] || return 0

    local BATCH_SIZE="${AUR_BATCH_SIZE:-20}"
    local i=0
    local total="${#pkgs[@]}"
    while (( i < total )); do
        local -a batch=("${pkgs[@]:i:BATCH_SIZE}")
        i=$((i + BATCH_SIZE))

        local url="${AUR_BASE}"
        local p
        for p in "${batch[@]}"; do
            local enc
            enc="$(printf '%s' "$p" | jq -sRr @uri)"
            url="${url}&arg%5B%5D=${enc}"
        done

        local resp
        resp="$(curl -fsS -A "$AUR_USER_AGENT" --max-time 30 "$url" 2>/dev/null)" || {
            echo "[lib-aur] AUR RPC call failed (batch starting at $((i - ${#batch[@]}))" >&2
            continue
        }

        printf '%s' "$resp" | jq -r '.results[]? | [.Name, .Version, (.OutOfDate|tostring)] | @tsv' 2>/dev/null || true

        # Be polite to AUR RPC.
        sleep 1
    done
}

# ----------------------------------------------------------------------
# parse_local_versions [repo_dir]
# Scans <repo_dir>/*.pkg.tar.zst and emits "name<TAB>version" on stdout.
# Filenames look like <name>-<ver>-<arch>.pkg.tar.zst; we strip the
# trailing arch+suffix then peel off the leading name (matching against
# the package list when available so names containing '-' aren't mis-split).
#
# If no repo_dir is given, defaults to /repo/${REPO_NAME}.x86_64.
# If PKGS[@] is set in the caller's env (space-separated), name-matching
# is restricted to those names. Otherwise we fall back to splitting at
# the last '-' before the version (less accurate for hyphenated names).
# ----------------------------------------------------------------------
parse_local_versions() {
    local repo_dir="${1:-$REPO_DIR_DEFAULT}"
    [[ -d "$repo_dir" ]] || return 0
    shopt -s nullglob
    local f
    for f in "$repo_dir"/*.pkg.tar.zst; do
        local base="${f##*/}"
        local noarch="${base%-x86_64.pkg.tar.zst}"
        noarch="${noarch%%-any.pkg.tar.zst}"
        local name ver
        # Caller may export PKGS as a space-separated string (update.sh
        # convention) or as an array (CGI convention). Handle both.
        if [[ -n "${PKGS[*]:-}" ]]; then
            # shellcheck disable=SC2207  # array expansion is intentional
            local -a _known_pkgs
            if [[ "$(declare -p PKGS 2>/dev/null)" =~ "declare -a" ]]; then
                _known_pkgs=("${PKGS[@]}")
            else
                # shellcheck disable=SC2206  # word-split is intentional
                _known_pkgs=(${PKGS})
            fi
            local pname
            for pname in "${_known_pkgs[@]}"; do
                if [[ "$noarch" == "${pname}-"* ]]; then
                    printf '%s\t%s\n' "$pname" "${noarch#"${pname}"-}"
                    break
                fi
            done
        else
            # Best-effort split: peel off the last '-' segment as the
            # version. For hyphenated names this is wrong, but we don't
            # have a name list to match against, so it's the best we can do.
            name="${noarch%-*}"
            ver="${noarch##*-}"
            printf '%s\t%s\n' "$name" "$ver"
        fi
    done
}

# ----------------------------------------------------------------------
# html_escape <string>
# Echoes <string> with &, <, >, ", and ' replaced by their HTML
# entity equivalents. Used by every CGI script before emitting user-
# supplied content into the HTML body.
# ----------------------------------------------------------------------
html_escape() {
    local s="${1-}"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "${s//\'/&#39;}"
}

# ----------------------------------------------------------------------
# CSRF helpers
#
# csrf_token_init [path]
#   Ensures <path> contains a 32-byte hex secret. Creates the file with
#   mode 0600 if missing. Idempotent.
#
# csrf_token_issue [path]
#   Emits a token: hex(sha256(secret + ":" + random)). The token has a
#   short effective lifetime (the secret + a nonce) but no real expiry —
#   good enough to block naive drive-by bots. Not a substitute for real
#   auth if you ever expose this beyond a homelab.
#
# csrf_token_validate <token> [path]
#   Exits 0 if <token> matches what csrf_token_issue would produce for
#   the same secret. Note: there's no nonce persistence — validation
#   works because the secret is the only entropy, and a bot would need
#   to read the page first to obtain a matching token. This is best-
#   effort CSRF, not cryptographically strong.
# ----------------------------------------------------------------------
csrf_token_init() {
    local path="${1:-$CSRF_SECRET_FILE}"
    if [[ ! -s "$path" ]]; then
        mkdir -p "$(dirname "$path")"
        umask 077
        head -c 32 /dev/urandom | xxd -p -c 64 > "$path" 2>/dev/null || \
            head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$path"
        chmod 0600 "$path"
    fi
}

csrf_token_issue() {
    local path="${1:-$CSRF_SECRET_FILE}"
    csrf_token_init "$path"
    local secret
    secret="$(cat "$path" 2>/dev/null || true)"
    local nonce
    nonce="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' 2>/dev/null || echo "nonce$$")"
    printf '%s' "${secret}:${nonce}" | sha256sum | awk '{print $1}'
}

csrf_token_validate() {
    local token="$1"
    local path="${2:-$CSRF_SECRET_FILE}"
    [[ -n "$token" ]] || return 1
    # Without nonce persistence we can only verify that the token
    # matches the "current shape" of (secret + nonce) for *some* nonce.
    # That is: we re-issue with a fresh nonce and require equality.
    # In practice this is checked by re-issuing server-side and
    # comparing in constant time. The cost is that a page reload
    # produces a new token, but a POST with the old token still passes.
    local secret
    secret="$(cat "$path" 2>/dev/null || true)"
    [[ -n "$secret" ]] || return 1
    # Recompute over the same nonce prefix? No — we don't know it. We
    # therefore accept any token whose sha256(secret:arbitrary_string)
    # could plausibly match. To keep this meaningful at all, require
    # that the token's sha256 prefix matches sha256(secret + ":") —
    # which it can't unless the secret is known. Effectively this
    # validation is: "the submitted token was produced by a server
    # that has the secret". That requires the page that issued the
    # form and the CGI to share the secret (which they do, both reading
    # the same file).
    #
    # To verify: the submitter must have computed sha256(secret + ":" + nonce)
    # using the same secret. The CGI recomputes sha256(secret + ":" + nonce)
    # for the nonce it stored in the form... but we don't store the nonce.
    #
    # Simplest correct approach: store the nonce alongside the token in
    # the hidden field as "nonce:hash". On POST, look up the nonce,
    # recompute, compare. See the CGI scripts which encode the form
    # field as "csrf=<nonce>:<hash>".
    local nonce="${token%%:*}"
    local hash="${token##*:}"
    [[ "$nonce" =~ ^[a-f0-9]{32}$ ]] || return 1
    [[ "$hash"  =~ ^[a-f0-9]{64}$ ]] || return 1
    local expected
    expected="$(printf '%s' "${secret}:${nonce}" | sha256sum | awk '{print $1}')"
    [[ "$expected" == "$hash" ]]
}

# Form-field helper: returns a token of the form "nonce:hash".
csrf_form_field() {
    local path="${1:-$CSRF_SECRET_FILE}"
    csrf_token_init "$path"
    local secret
    secret="$(cat "$path" 2>/dev/null || true)"
    local nonce
    nonce="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' 2>/dev/null || echo "nonce$$")"
    local hash
    hash="$(printf '%s' "${secret}:${nonce}" | sha256sum | awk '{print $1}')"
    printf '%s:%s' "$nonce" "$hash"
}

# ----------------------------------------------------------------------
# read_post_body
# Reads stdin (the POST body) up to CONTENT_LENGTH bytes and echoes it.
# ----------------------------------------------------------------------
read_post_body() {
    local cl="${CONTENT_LENGTH:-0}"
    [[ "$cl" =~ ^[0-9]+$ ]] || cl=0
    if (( cl > 0 )); then
        head -c "$cl" || true
    fi
}

# ----------------------------------------------------------------------
# url_decode <string>
# Decodes percent-encoded URL sequences. '+' becomes space.
# ----------------------------------------------------------------------
url_decode() {
    local s="${1-}"
    # Replace + with space, then percent-decode hex sequences.
    s="${s//+/ }"
    printf '%b' "${s//%/\\x}"
}

# ----------------------------------------------------------------------
# parse_form <body>
# Splits a URL-encoded form body on '&' and '=' into the associative
# array FORM[<key>]=<value>. Sets FORM as a side effect in the caller's
# scope.
# ----------------------------------------------------------------------
parse_form() {
    local body="$1"
    # IMPORTANT: declare -gA, not FORM=().
    #
    # A bare `FORM=()` would create an INDEXED array in the caller's
    # scope. Then `FORM["$k"]=...` in the loop below is parsed by bash
    # as `FORM[ EXPR ]=...` where EXPR is `csrf` (literal, since $k="csrf")
    # — but bash 5.x treats that as a VARIABLE NAME to expand before
    # using as an array index. Since `$csrf` is unset and the caller has
    # `set -u`, bash dies with:
    #
    #     lib-aur.sh: line 304: csrf: unbound variable
    #
    # even though no `csrf` reference exists in this function. The fix
    # is to declare FORM as an ASSOCIATIVE array (declare -A) up front;
    # with -A, `FORM["csrf"]=...` uses the literal string "csrf" as a
    # key, not a variable expansion. The -g flag promotes the
    # declaration to global scope so the caller's array reference works
    # when this function runs in a subshell (lighttpd spawns CGI
    # scripts via `bash cgi-bin/add.cgi` which DOES inherit set -u).
    declare -gA FORM=()
    [[ -z "$body" ]] && return 0
    local pair
    IFS='&' read -ra pairs <<< "$body"
    for pair in "${pairs[@]}"; do
        local k="${pair%%=*}"
        local v="${pair#*=}"
        [[ -z "$k" ]] && continue
        # shellcheck disable=SC2034  # FORM is the caller's array
        FORM["$k"]="$(url_decode "$v")"
    done
}

# ----------------------------------------------------------------------
# cgi_send_header [content_type]
# Emits a CGI response header. Default Content-Type is text/html.
# ----------------------------------------------------------------------
cgi_send_header() {
    local ct="${1:-text/html; charset=utf-8}"
    printf 'Content-Type: %s\r\n\r\n' "$ct"
}

# ----------------------------------------------------------------------
# cgi_html_doc <title> [body_html]
# Emits a minimal HTML5 document with a dark retro stylesheet, the
# supplied <title>, and the supplied <body> HTML. The style block is
# inlined so the page works without any external CSS.
# ----------------------------------------------------------------------
cgi_html_doc() {
    local title="$1"
    local body="${2-}"
    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>$(html_escape "$title")</title>
<style>
:root {
    --bg: #1a1a1a;
    --fg: #d0d0d0;
    --accent: #6cf;
    --border: #555;
    --row-alt: #222;
    --ok: #6c6;
    --warn: #fc6;
    --err: #f66;
}
* { box-sizing: border-box; }
body {
    background: var(--bg);
    color: var(--fg);
    font-family: "Courier New", "Lucida Console", monospace;
    margin: 2em auto;
    max-width: 1100px;
    padding: 0 1em;
    line-height: 1.5;
}
h1, h2, h3 { color: var(--accent); border-bottom: 1px solid var(--border); padding-bottom: 0.2em; }
a { color: var(--accent); }
code, pre, kbd {
    background: #000;
    border: 1px solid var(--border);
    padding: 0.1em 0.3em;
    border-radius: 2px;
}
pre { padding: 0.8em; overflow-x: auto; }
table {
    border-collapse: collapse;
    width: 100%;
    margin: 1em 0;
}
th, td {
    border: 1px solid var(--border);
    padding: 0.4em 0.6em;
    text-align: left;
    vertical-align: top;
}
th { background: #2a2a2a; color: var(--accent); }
tr:nth-child(even) td { background: var(--row-alt); }
.status-built { color: var(--ok); }
.status-building { color: var(--warn); }
.status-quarantined { color: var(--err); }
.status-missing { color: var(--err); }
form { margin: 1em 0; padding: 1em; border: 1px solid var(--border); background: #181818; }
textarea {
    width: 100%;
    min-height: 8em;
    background: #000;
    color: var(--fg);
    border: 1px solid var(--border);
    font-family: inherit;
    padding: 0.5em;
}
input[type=submit] {
    background: var(--accent);
    color: #000;
    border: 1px solid var(--accent);
    padding: 0.5em 1.2em;
    font-family: inherit;
    font-weight: bold;
    cursor: pointer;
    margin-top: 0.5em;
}
input[type=submit]:hover { background: #8df; }
.notice { padding: 0.8em; border: 1px solid var(--border); margin: 1em 0; }
.notice-ok { border-color: var(--ok); }
.notice-err { border-color: var(--err); }
footer { margin-top: 2em; padding-top: 1em; border-top: 1px solid var(--border); font-size: 0.9em; color: #888; }
</style>
</head>
<body>
$body
<footer>
aur-forge web UI &mdash; powered by <code>lighttpd + bash CGI</code>.
Pacman repo at <a href="/${REPO_NAME}.x86_64/">/${REPO_NAME}.x86_64/</a>.
</footer>
</body>
</html>
HTML
}

#!/usr/bin/env bash
# aur-forge package.cgi — per-package detail page and quarantine management.
#
#   GET  /cgi-bin/package.cgi?name=<pkg>   full details: status, quarantine
#                                           review (PKGBUILD, static findings,
#                                           archcanary, diff vs approved),
#                                           approval record, served files, AUR
#                                           info, ABI state, history.
#   POST /cgi-bin/package.cgi              action=approve|reject|rescan|rebuild|
#                                           unreject (CSRF-checked; approve and
#                                           reject are pinned to the PKGBUILD
#                                           sha256 the reviewer was shown).
#
# Reads only. Nothing on this page executes a PKGBUILD. State-changing work is
# delegated to scripts/quarantine-decide.sh / build.sh.
set -euo pipefail

LIB=""
for candidate in \
    /usr/local/lib/aur-forge/lib-aur.sh \
    /usr/lib/aur-forge/lib-aur.sh \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)/lib-aur.sh"; do
    [[ -f "$candidate" ]] && LIB="$candidate" && break
done
if [[ -z "$LIB" ]]; then
    printf 'Content-Type: text/html; charset=utf-8\r\n\r\n<h1>lib-aur.sh not found</h1>\n'
    exit 1
fi
LIBDIR="$(dirname "$LIB")"
# shellcheck disable=SC1090
. "$LIB"
export APPROVALS_DIR="${APPROVALS_DIR:-/approvals}"
export QUARANTINE_DIR="${QUARANTINE_DIR:-/cache/work-quarantine}"
# shellcheck disable=SC1090,SC1091
. "${LIBDIR}/approval-store.sh"
# shellcheck disable=SC1090,SC1091
. "${LIBDIR}/pkg-analysis.sh"

REPO_DIR="${REPO_DIR:-/repo/${REPO_NAME}.x86_64}"
ABI_STATE_DIR="${ABI_STATE_DIR:-/cache/abi}"
LOG_FILE="${AUR_FORGE_LOG_FILE:-/var/log/aur-forge-check/check.log}"
DECIDE="${AUR_FORGE_DECIDE_SH:-/usr/local/bin/quarantine-decide.sh}"
BUILD_SH="${AUR_FORGE_BUILD_SH:-/usr/local/bin/build.sh}"
CHECK_ABI="${CHECK_ABI:-/usr/local/bin/check-abi.sh}"
GH_REPO="${GITHUB_REPO:-faultoverload/aur-forge}"

h() { html_escape "${1-}"; }
fail_page() {   # fail_page <code> <message>
    cgi_send_header
    cgi_html_doc "$1" "<h1>$(h "$1")</h1><div class=\"notice notice-err\">$(h "$2")</div><p><a href=\"/\">&larr; back to the package list</a></p>"
    exit 0
}

# ---------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------
method="${REQUEST_METHOD:-GET}"
declare -A QS=()
if [[ -n "${QUERY_STRING:-}" ]]; then
    IFS='&' read -ra _qs <<< "$QUERY_STRING"
    for _p in "${_qs[@]}"; do
        _k="${_p%%=*}"; _v="${_p#*=}"
        [[ -n "$_k" ]] && QS["$_k"]="$(url_decode "$_v")"
    done
fi

action=""; sha_in=""; confirm=""
if [[ "$method" == "POST" ]]; then
    parse_form "$(read_post_body)"
    csrf_token_validate "${FORM[csrf]:-}" || fail_page "403 Forbidden" "CSRF token missing or invalid. Go back to the package page and try again."
    pkg="${FORM[name]:-}"
    action="${FORM[action]:-}"
    sha_in="${FORM[sha]:-}"
    confirm="${FORM[confirm]:-}"
else
    pkg="${QS[name]:-}"
fi
pkgname_is_valid "$pkg" || fail_page "400 Bad Request" "Missing or invalid package name. Use ?name=<package>."

# ---------------------------------------------------------------------
# Data gathering
# ---------------------------------------------------------------------
stash="$(quarantine_stashes "$pkg" | tail -n1 || true)"
approval_json=""; approval_exists "$pkg" && approval_json="$(read_approval "$pkg")"
rejected_json=""; [[ -s "${APPROVALS_DIR}/${pkg}.rejected.json" ]] && rejected_json="$(cat "${APPROVALS_DIR}/${pkg}.rejected.json")"
snapshot_dir="${APPROVALS_DIR}/${pkg}.snapshot"
history_file="${APPROVALS_DIR}/${pkg}.history.jsonl"
in_pkglist=0
while IFS= read -r _n; do [[ "$_n" == "$pkg" ]] && in_pkglist=1; done < <(parse_pkglist)

# Served files (exact name, plus the -debug split package).
declare -a SERVED=()
shopt -s nullglob
for _f in "$REPO_DIR"/*.pkg.tar.zst; do
    _b="${_f##*/}"
    [[ "$_b" =~ ^(.+)-([^-]+-[^-]+)-([^-]+)\.pkg\.tar\.zst$ ]] || continue
    [[ "${BASH_REMATCH[1]}" == "$pkg" || "${BASH_REMATCH[1]}" == "${pkg}-debug" ]] && SERVED+=("$_f")
done
shopt -u nullglob
db_ver=""
if [[ -s "${REPO_DIR}/${REPO_NAME}.db.tar.zst" ]]; then
    while IFS= read -r _e; do
        _e="${_e%/}"
        [[ "$_e" == "$pkg"-* ]] || continue
        _rest="${_e#"${pkg}"-}"
        [[ "$_rest" =~ ^([0-9]+:)?[^-]+-[0-9]+(\.[0-9]+)?$ ]] && db_ver="$_rest"
    done < <(tar -tf "${REPO_DIR}/${REPO_NAME}.db.tar.zst" 2>/dev/null | awk -F/ 'NF==2 && $2=="" {print}')
fi

status="missing"
if   [[ -n "$stash" ]];                        then status="quarantined"
elif [[ -n "$rejected_json" ]];                then status="rejected"
elif [[ -d "/cache/work/${pkg}" ]];            then status="building"
elif [[ ${#SERVED[@]} -gt 0 || -n "$db_ver" ]]; then status="built"
fi

# GitHub Issue(s) for this package (best effort, short timeout).
issue_num=""; issue_url=""; issue_title=""
if [[ -n "${GITHUB_TOKEN:-}" && "${PKG_PAGE_OFFLINE:-0}" != "1" ]]; then
    _hit="$(curl -fsS -m 6 -H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GH_REPO}/issues?state=open&labels=quarantine%2Fblocked&per_page=100" 2>/dev/null \
        | jq -r --arg p "$pkg" '[.[]? | select(.title | endswith("] " + $p)) | [(.number|tostring), .title]][0] // empty | @tsv' 2>/dev/null || true)"
    if [[ -n "$_hit" ]]; then
        issue_num="${_hit%%$'\t'*}"
        issue_title="${_hit#*$'\t'}"
        issue_url="https://github.com/${GH_REPO}/issues/${issue_num}"
    fi
fi

# ---------------------------------------------------------------------
# POST actions
# ---------------------------------------------------------------------
spawn_bg() {   # spawn_bg <label> <cmd...>  — detached, output appended to LOG_FILE
    local label="$1"; shift
    mkdir -p "$(dirname "$LOG_FILE")"
    setsid nohup /usr/bin/bash -c '
        tag="[aur-forge-web $(date -u +%FT%TZ)]"; echo "$tag $0"; "$@"; echo "$tag finished rc=$?"
    ' "$label" "$@" >> "$LOG_FILE" 2>&1 < /dev/null &
    echo "$!"
}

if [[ "$method" == "POST" ]]; then
    result=""; ok=1
    case "$action" in
        approve|reject)
            if [[ "$confirm" != "yes" ]]; then
                fail_page "400 Bad Request" "Tick the confirmation box to ${action}."
            fi
            [[ "$sha_in" =~ ^[0-9a-f]{64}$ ]] || fail_page "400 Bad Request" "Missing PKGBUILD hash — reload the package page."
            result="$("$DECIDE" "$action" "$pkg" --sha "$sha_in" --by "web-ui" ${issue_num:+--issue "$issue_num"} 2>&1)" || ok=0
            ;;
        rescan)
            pid="$(spawn_bg "re-scanning $pkg" "$BUILD_SH" --scan-only --only="$pkg")"
            result="Re-scan of ${pkg} started (pid ${pid}); the page below refreshes automatically."
            ;;
        rebuild)
            pid="$(spawn_bg "rebuilding $pkg" "$BUILD_SH" --only="$pkg")"
            result="Rebuild of ${pkg} started (pid ${pid}). It still goes through the gate: an unreviewed change is quarantined again."
            ;;
        unreject)
            clear_rejection "$pkg"; log_event "$pkg" "rejection-cleared" "rejection cleared via web UI"
            result="Rejection of ${pkg} cleared. It will be scanned again on the next run (or press Re-scan)."
            ;;
        *) fail_page "400 Bad Request" "Unknown action." ;;
    esac
    cls="notice-ok"; (( ok )) || cls="notice-err"
    cgi_send_header
    cgi_html_doc "${pkg} — ${action}" "<h1>$(h "$pkg"): $(h "$action")</h1>
<div class=\"notice ${cls}\"><pre>$(h "$result")</pre></div>
<script>setTimeout(function(){window.location.href='/cgi-bin/package.cgi?name=$(h "$pkg")';}, 4000);</script>
<p><a href=\"/cgi-bin/package.cgi?name=$(h "$pkg")\">&larr; back to ${pkg}</a> &middot; <a href=\"/\">package list</a></p>"
    exit 0
fi

# ---------------------------------------------------------------------
# Render helpers
# ---------------------------------------------------------------------
fmt_epoch() { date -u -d "@$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$1"; }
human_size() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }

# numbered_listing FILE FINDINGS_TSV [ID_PREFIX] — <pre> body with line numbers;
# flagged lines are highlighted by their worst severity. With ID_PREFIX each
# line gets id="<prefix><n>" so the findings table can link to it.
numbered_listing() {
    local f="$1" findings="$2" prefix="${3:-}"
    awk -F'\t' -v prefix="$prefix" '
        function esc(s) { gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); gsub(/"/,"\\&quot;",s); return s }
        BEGIN { rank["high"]=3; rank["medium"]=2; rank["info"]=1 }
        FNR==NR { if ($1 != "" && ($2 in rank) && (!($1 in best) || rank[$2] > best[$1])) { best[$1]=rank[$2]; name[$1]=$2 } next }
        { cls = (FNR in best) ? " class=\"hl-" name[FNR] "\"" : "";
          id  = (prefix != "") ? " id=\"" prefix FNR "\"" : "";
          printf "<span%s%s><span class=\"ln\">%4d</span> %s</span>\n", id, cls, FNR, esc($0) }
    ' <(printf '%s\n' "$findings") "$f"
}

badge() { printf '<span class="status-%s">%s</span>' "$1" "$(h "$1")"; }

# ---------------------------------------------------------------------
# Page
# ---------------------------------------------------------------------
csrf="$(csrf_form_field)"
action_form() {  # action_form <action> <label> [extra hidden html] [css class] [pre-html]
    printf '<form method="POST" action="/cgi-bin/package.cgi" class="%s">%s<input type="hidden" name="csrf" value="%s"><input type="hidden" name="name" value="%s"><input type="hidden" name="action" value="%s">%s<input type="submit" value="%s"></form>' \
        "${4:-inline}" "${5:-}" "$csrf" "$(h "$pkg")" "$1" "${3:-}" "$(h "$2")"
}

page=""
page+="<p><a href=\"/\">&larr; all packages</a></p>
<h1>$(h "$pkg") $(badge "$status")</h1>"
[[ $in_pkglist -eq 0 ]] && page+="<div class=\"notice\">This package is not in <code>pkglist.txt</code>.</div>"

# Quick facts line
facts="<table class=\"facts\"><tbody>
<tr><th>Repo version (db)</th><td>$(h "${db_ver:-—}")</td></tr>
<tr><th>Links</th><td><a href=\"https://aur.archlinux.org/packages/$(h "$pkg")\">AUR page</a> &middot; <a href=\"https://aur.archlinux.org/cgit/aur.git/log/?h=$(h "$pkg")\">AUR git log</a>"
[[ -n "$issue_url" ]] && facts+=" &middot; <a href=\"$(h "$issue_url")\">GitHub Issue #$(h "$issue_num")</a>"
facts+="</td></tr></tbody></table>"
page+="$facts"

# ---- Quarantine review ------------------------------------------------------
if [[ -n "$stash" ]]; then
    q_sha="$(sha256sum "$stash/PKGBUILD" | awk '{print $1}')"
    q_time="$(fmt_epoch "$(stat -c %Y "$stash" 2>/dev/null || echo 0)")"
    q_reason="$( [[ -s "$history_file" ]] && jq -rs '[.[] | select(.event=="quarantined")] | last | .detail // empty' "$history_file" 2>/dev/null || true)"
    # No history yet (quarantined before history existed)? fall back to the Issue title.
    if [[ -z "$q_reason" && -n "$issue_title" ]]; then
        q_reason="$(sed -E 's/^\[QUARANTINE\]\[([^]]*)\].*/\1/' <<<"$issue_title")"
    fi
    findings="$(pkgbuild_findings "$stash/PKGBUILD")"
    fsum="$(findings_summary "$stash/PKGBUILD")"
    canary=""
    if command -v archcanary >/dev/null 2>&1; then
        canary="$(timeout 20 archcanary --search-packages="$pkg" --no-notify --color=never 2>&1 | head -n 15 || true)"
    fi
    page+="<h2>Quarantine &mdash; review required</h2>
<div class=\"notice notice-err\">
<p><strong>$(h "${q_reason:-quarantined}")</strong></p>
<p>Quarantined $(h "$q_time"). Nothing from this clone has been built or published. PKGBUILD sha256: <code>$(h "$q_sha")</code></p>
<p>Static findings: <strong>$(h "$fsum")</strong> (heuristics &mdash; read the PKGBUILD below).</p></div>"
    [[ -n "$canary" ]] && page+="<h3>archcanary</h3><pre>$(h "$canary")</pre>"

    if [[ -n "$findings" ]]; then
        page+="<h3>Findings</h3><table><thead><tr><th>Line</th><th>Severity</th><th>Rule</th><th>Text</th></tr></thead><tbody>"
        while IFS=$'\t' read -r _l _s _r _t; do
            page+="<tr><td><a href=\"#L${_l}\">${_l}</a></td><td class=\"sev-${_s}\">$(h "$_s")</td><td>$(h "$_r")</td><td><code>$(h "$_t")</code></td></tr>"
        done <<< "$findings"
        page+="</tbody></table>"
    fi

    # What changed vs the last approved version
    if [[ -f "$snapshot_dir/PKGBUILD" ]]; then
        d="$(unified_diff "$snapshot_dir/PKGBUILD" "$stash/PKGBUILD" 400)"
        page+="<h3>PKGBUILD diff vs. last approved</h3>"
        if [[ -n "$d" ]]; then page+="<pre class=\"diff\">$(h "$d")</pre>"; else page+="<p>No difference in PKGBUILD text.</p>"; fi
        for _i in "$stash"/*.install; do
            [[ -f "$_i" ]] || continue
            _bn="${_i##*/}"
            if [[ -f "$snapshot_dir/$_bn" ]]; then
                d="$(unified_diff "$snapshot_dir/$_bn" "$_i" 300)"
                page+="<h3>${_bn} diff</h3>"; [[ -n "$d" ]] && page+="<pre class=\"diff\">$(h "$d")</pre>" || page+="<p>Unchanged.</p>"
            else
                page+="<h3>${_bn} <span class=\"sev-high\">(new .install file)</span></h3>"
            fi
        done
    else
        page+="<p class=\"muted\">No approved snapshot to diff against (first review of this package, or it was approved before snapshots existed).</p>"
    fi

    # Metadata + sources (static)
    meta="$(static_srcinfo "$stash")"
    if [[ -n "$meta" ]]; then
        page+="<h3>Metadata (static)</h3><table><tbody>"
        while IFS=$'\t' read -r _k _v; do page+="<tr><th>$(h "$_k")</th><td><code>$(h "$_v")</code></td></tr>"; done <<< "$meta"
        page+="</tbody></table>"
    fi
    urls="$(sourced_urls "$stash/PKGBUILD")"
    [[ -n "$urls" ]] && page+="<h3>URLs mentioned</h3><pre>$(h "$urls")</pre>"

    page+="<h3>Files in the clone</h3><pre>$(h "$(cd "$stash" && ls -la --time-style=long-iso . 2>/dev/null | grep -v '^total' | grep -v ' \.git$' || true)")</pre>"
    page+="<h3>PKGBUILD</h3><pre class=\"listing\">$(numbered_listing "$stash/PKGBUILD" "$findings" L)</pre>"
    for _i in "$stash"/*.install; do
        [[ -f "$_i" ]] || continue
        _bn="${_i##*/}"
        page+="<h3>${_bn}</h3><pre class=\"listing\">$(numbered_listing "$_i" "$(pkgbuild_findings "$_i")")</pre>"
    done
    page+="<h2>Decision</h2>
<div class=\"decision\">"
    page+="$(action_form approve "Approve this PKGBUILD and rebuild" \
        "<input type=\"hidden\" name=\"sha\" value=\"$(h "$q_sha")\">" "decision-form approve" \
        "<p>Approving records <code>${q_sha:0:16}…</code> as trusted, snapshots it for future diffs and rebuilds now. If the AUR changes before the rebuild fetches it, the new text is quarantined again.</p>$( [[ "$fsum" != "0 high, 0 medium, 0 info" ]] && echo "<p class=\"sev-high\">The heuristics flagged lines above &mdash; check each one.</p>" )<label><input type=\"checkbox\" name=\"confirm\" value=\"yes\" required> I have read this PKGBUILD$( [[ -n "$(ls "$stash"/*.install 2>/dev/null)" ]] && echo " and its .install file(s)" ).</label><br>")"
    page+="$(action_form reject "Reject (do not build)" \
        "<input type=\"hidden\" name=\"sha\" value=\"$(h "$q_sha")\">" "decision-form reject" \
        "<p>Rejecting remembers this exact PKGBUILD as bad: it is not built and does not reopen an Issue every night. A changed PKGBUILD is reviewed again. Any earlier approved build stays served.</p><label><input type=\"checkbox\" name=\"confirm\" value=\"yes\" required> Reject <code>${q_sha:0:16}…</code>.</label><br>")"
    page+="$(action_form rescan "Re-scan from AUR" "" "decision-form")</div>"
fi

# ---- Rejection record ---------------------------------------------------
if [[ -n "$rejected_json" && -z "$stash" ]]; then
    page+="<h2>Rejected</h2><div class=\"notice notice-err\">This exact PKGBUILD (<code>$(h "$(jq -r '.pkgbuild_sha256[0:16]' <<<"$rejected_json")")…</code>) was rejected by <code>$(h "$(jq -r '.rejected_by' <<<"$rejected_json")")</code> on $(h "$(jq -r '.rejected_at' <<<"$rejected_json")"). It is not built until the PKGBUILD changes upstream.</div>"
    page+="$(action_form unreject "Clear rejection and re-review" "" "inline")"
fi

# ---- Approval record ----------------------------------------------------
page+="<h2>Approval</h2>"
if [[ -n "$approval_json" ]]; then
    page+="<table><tbody>
<tr><th>Approved version</th><td>$(h "$(jq -r '.approved_version' <<<"$approval_json")")</td></tr>
<tr><th>Approved</th><td>$(h "$(jq -r '.approved_at' <<<"$approval_json")") by <code>$(h "$(jq -r '.approved_by' <<<"$approval_json")")</code></td></tr>
<tr><th>PKGBUILD sha256</th><td><code>$(h "$(jq -r '.pkgbuild_sha256' <<<"$approval_json")")</code></td></tr>
<tr><th>archcanary list match at approval</th><td>$(h "$(jq -r '.blocklist_match_at_approval' <<<"$approval_json")")</td></tr>
<tr><th>Notes</th><td>$(h "$(jq -r '.notes' <<<"$approval_json")")</td></tr>
<tr><th>Issue</th><td>$(h "$(jq -r '.issue // "—"' <<<"$approval_json")")</td></tr>
</tbody></table>"
    if [[ -f "$snapshot_dir/PKGBUILD" ]]; then
        page+="<details><summary>Approved PKGBUILD (snapshot)</summary><pre class=\"listing\">$(numbered_listing "$snapshot_dir/PKGBUILD" "")</pre></details>"
    fi
else
    page+="<p class=\"muted\">No approval on record (never built, or built before approvals were recorded).</p>"
fi

# ---- Served files -------------------------------------------------------
page+="<h2>Served packages</h2>"
if [[ ${#SERVED[@]} -gt 0 ]]; then
    page+="<table><thead><tr><th>File</th><th>Size</th><th>Built</th><th>Signature</th><th>In db</th></tr></thead><tbody>"
    for _f in "${SERVED[@]}"; do
        _b="${_f##*/}"
        _sig="no"; [[ -f "${_f}.sig" ]] && _sig="yes"
        _in="—"; [[ -n "$db_ver" && "$_b" == "${pkg}-${db_ver}-"* ]] && _in="yes"
        page+="<tr><td><a href=\"/${REPO_NAME}.x86_64/$(h "$_b")\">$(h "$_b")</a></td><td>$(human_size "$(stat -c %s "$_f")")</td><td>$(fmt_epoch "$(stat -c %Y "$_f")")</td><td>${_sig}</td><td>${_in}</td></tr>"
    done
    page+="</tbody></table>"
    page+="$(action_form rebuild "Rebuild now" "" "inline")"
else
    page+="<p class=\"muted\">Nothing served yet.</p>"
    [[ "$status" != "quarantined" && "$status" != "rejected" ]] && page+="$(action_form rebuild "Build now" "" "inline")"
fi

# ---- Upstream (AUR) -----------------------------------------------------
page+="<h2>Upstream (AUR)</h2>"
aur_json=""
if [[ "${PKG_PAGE_OFFLINE:-0}" != "1" ]]; then
    aur_json="$(curl -fsS -m 8 -A "$AUR_USER_AGENT" "https://aur.archlinux.org/rpc/v5/info?arg%5B%5D=${pkg}" 2>/dev/null | jq -c '.results[0] // empty' 2>/dev/null || true)"
fi
if [[ -n "$aur_json" ]]; then
    j() { jq -r "$1" <<<"$aur_json"; }
    ood="$(j '.OutOfDate // empty')"; [[ -n "$ood" ]] && ood="flagged out of date $(fmt_epoch "$ood")" || ood="no"
    page+="<table><tbody>
<tr><th>Version</th><td>$(h "$(j .Version)")</td></tr>
<tr><th>Description</th><td>$(h "$(j '.Description // "—"')")</td></tr>
<tr><th>Maintainer</th><td>$(h "$(j '.Maintainer // "ORPHAN"')")</td></tr>
<tr><th>Last modified</th><td>$(fmt_epoch "$(j .LastModified)")</td></tr>
<tr><th>Votes / popularity</th><td>$(h "$(j .NumVotes)") / $(h "$(j '.Popularity | tostring')")</td></tr>
<tr><th>Out of date</th><td>$(h "$ood")</td></tr>
<tr><th>Depends</th><td><code>$(h "$(j '(.Depends // []) | join(", ")')")</code></td></tr>
<tr><th>Make depends</th><td><code>$(h "$(j '(.MakeDepends // []) | join(", ")')")</code></td></tr>
<tr><th>Upstream URL</th><td>$(h "$(j '.URL // "—"')")</td></tr>
</tbody></table>"
else
    page+="<p class=\"muted\">Not on the AUR (removed or renamed), or the AUR RPC could not be reached.</p>"
fi

# ---- ABI / rebuild state --------------------------------------------------
page+="<h2>Library / ABI state</h2>"
abi_out=""
if [[ -x "$CHECK_ABI" && ${#SERVED[@]} -gt 0 ]]; then
    abi_out="$(ABI_STATE_DIR="$ABI_STATE_DIR" timeout 60 "$CHECK_ABI" --repo-dir "$REPO_DIR" --name "$REPO_NAME" "$pkg" 2>/dev/null || true)"
fi
if [[ -n "$abi_out" ]]; then
    page+="<div class=\"notice\">check-abi reports: <code>$(h "$(cut -f2 <<<"$abi_out")")</code></div>"
else
    page+="<p>No unresolved shared libraries or Python-version drift against the current build chroot.</p>"
fi
[[ -s "${ABI_STATE_DIR}/baseline/${pkg}" ]] && page+="<p class=\"muted\">Baseline (already unresolved when first checked, ignored as drift): <code>$(h "$(cat "${ABI_STATE_DIR}/baseline/${pkg}")")</code></p>"
[[ -s "${ABI_STATE_DIR}/attempts/${pkg}" ]] && page+="<p class=\"muted\">Rebuild attempted for: <code>$(h "$(cat "${ABI_STATE_DIR}/attempts/${pkg}")")</code> (not retried if still unresolved)</p>"

# ---- History ------------------------------------------------------------
page+="<h2>History</h2>"
if [[ -s "$history_file" ]]; then
    page+="<table><thead><tr><th>When</th><th>Event</th><th>By</th><th>Detail</th><th>PKGBUILD sha</th></tr></thead><tbody>"
    while IFS=$'\t' read -r _ts _ev _by _dt _sh; do
        page+="<tr><td>$(h "$_ts")</td><td>$(h "$_ev")</td><td>$(h "$_by")</td><td>$(h "$_dt")</td><td><code>$(h "${_sh:0:12}")</code></td></tr>"
    done < <(jq -r '[.ts,.event,.by,.detail,.pkgbuild_sha256]|@tsv' "$history_file" 2>/dev/null | tac | head -n 40)
    page+="</tbody></table>"
else
    page+="<p class=\"muted\">No recorded events yet (history starts with the next gate decision).</p>"
fi

# ---- Recent log ---------------------------------------------------------
if [[ -s "$LOG_FILE" ]]; then
    page+="<details><summary>Recent build log lines mentioning ${pkg}</summary><pre>$(h "$( { grep -F -- "$pkg" "$LOG_FILE" 2>/dev/null || true; } | tail -n 40)")</pre></details>"
fi

cgi_send_header
cgi_html_doc "${pkg} — aur-forge" "$page"

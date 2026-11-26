#!/usr/bin/env bash
# aur-forge approval-store.sh — helpers for the on-disk approval store.
#
# Each package we ever built and decided to trust gets a JSON file at
# /approvals/<pkg>.json. The file is the durable record of "yes, I have
# seen this PKGBUILD, it was clean at approval time, and here is the hash
# to compare future versions against."
#
# This module is sourced by build.sh and drain-quarantine.sh — it does
# NOT shell out to external services. It only touches /approvals.
#
# Schema (see body of write_approval):
#   {
#     "package": "aur-example",
#     "approved_at": "2026-08-27T18:42:11Z",
#     "approved_by": "faultoverload",
#     "issue": 42,
#     "pkgbuild_sha256": "...",
#     "srcinfo_sha256":  "...",
#     "approved_version": "1.2.3-1",
#     "blocklist_match_at_approval": false,
#     "pkgbuild_obfuscation_at_approval": false,
#     "notes": "auto-approved on first clean build"
#   }
set -euo pipefail

APPROVALS_DIR="${APPROVALS_DIR:-/approvals}"
mkdir -p "$APPROVALS_DIR"

# read_approval <pkg> — echoes the JSON for <pkg>, or returns non-zero if
# no record exists. Empty output + non-zero exit is the canonical signal
# for "first build / never seen before".
read_approval() {
    local pkg="$1"
    local path="${APPROVALS_DIR}/${pkg}.json"
    if [[ ! -s "$path" ]]; then
        return 1
    fi
    cat "$path"
}

# approval_exists <pkg> — quiet existence test, exit 0 if present.
approval_exists() {
    local pkg="$1"
    [[ -s "${APPROVALS_DIR}/${pkg}.json" ]]
}

# write_approval <pkg> <pkgbuild_sha256> <srcinfo_sha256> <version>
#                [issue] [blocklist_match] [obfuscation] [notes...]
# Writes the canonical JSON record atomically (write to tmp, rename).
# jq is the only dependency; we don't shell out to anything else.
write_approval() {
    local pkg="$1"
    local pkgbuild_sha="$2"
    local srcinfo_sha="$3"
    local version="$4"
    local issue="${5:-null}"
    local blocklist="${6:-false}"
    local obfuscation="${7:-false}"
    local notes="${8:-auto-approved on first clean build}"

    local approved_at
    approved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local approved_by="${APPROVED_BY:-faultoverload}"

    local target="${APPROVALS_DIR}/${pkg}.json"
    local tmp="${target}.tmp.$$"

    jq -n \
        --arg package    "$pkg" \
        --arg approved_at "$approved_at" \
        --arg approved_by "$approved_by" \
        --argjson issue   "$issue" \
        --arg pkgbuild_sha256 "$pkgbuild_sha" \
        --arg srcinfo_sha256  "$srcinfo_sha" \
        --arg approved_version "$version" \
        --argjson blocklist_match_at_approval "$blocklist" \
        --argjson pkgbuild_obfuscation_at_approval "$obfuscation" \
        --arg notes "$notes" \
        '{
            package: $package,
            approved_at: $approved_at,
            approved_by: $approved_by,
            issue: $issue,
            pkgbuild_sha256: $pkgbuild_sha256,
            srcinfo_sha256:  $srcinfo_sha256,
            approved_version: $approved_version,
            blocklist_match_at_approval: $blocklist_match_at_approval,
            pkgbuild_obfuscation_at_approval: $pkgbuild_obfuscation_at_approval,
            notes: $notes
        }' > "$tmp"

    chmod 0644 "$tmp"
    mv -f "$tmp" "$target"
}

# list_approved — emits one package name per line for every approval on disk.
# Used by drain-quarantine.sh when listing what we already trust.
list_approved() {
    local f
    for f in "$APPROVALS_DIR"/*.json; do
        [[ -e "$f" ]] || continue
        jq -r '.package' "$f"
    done
}

# approval_field <pkg> <field> — echoes a single field from the stored JSON.
# Convenience for build.sh / drain-quarantine.sh.
approval_field() {
    local pkg="$1"
    local field="$2"
    local path="${APPROVALS_DIR}/${pkg}.json"
    [[ -s "$path" ]] || return 1
    jq -r --arg f "$field" '.[$f] // empty' "$path"
}

# remove_approval <pkg> — drop a record. Used by drain-quarantine.sh on
# rejection when we want to force a full re-review next time.
remove_approval() {
    local pkg="$1"
    rm -f "${APPROVALS_DIR}/${pkg}.json"
}

# ---------------------------------------------------------------------
# Audit trail, approved-PKGBUILD snapshots and rejections.
# ---------------------------------------------------------------------
# These back the web UI's package page (cgi-bin/package.cgi) and the
# quarantine decision flow (build.sh --approve= / --reject=).
#
#   /approvals/<pkg>.history.jsonl   one JSON object per gate/decision event
#   /approvals/<pkg>.snapshot/       PKGBUILD + *.install + .SRCINFO as approved,
#                                    so a later quarantine can show a real diff
#   /approvals/<pkg>.rejected.json   {pkgbuild_sha256, rejected_at, rejected_by}:
#                                    that exact PKGBUILD stays rejected (no new
#                                    Issue every night) until it changes

# log_event <pkg> <event> [detail] [sha] — append one line to the history.
log_event() {
    local pkg="$1" event="$2" detail="${3:-}" sha="${4:-}"
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event "$event" \
        --arg detail "$detail" --arg sha "$sha" --arg by "${APPROVED_BY:-system}" \
        '{ts:$ts, event:$event, detail:$detail, pkgbuild_sha256:$sha, by:$by}' \
        >> "${APPROVALS_DIR}/${pkg}.history.jsonl" 2>/dev/null || true
}

# snapshot_approval <pkg> <workdir> — keep the approved PKGBUILD + install files.
snapshot_approval() {
    local pkg="$1" workdir="$2" snap="${APPROVALS_DIR}/${pkg}.snapshot"
    rm -rf "$snap"; mkdir -p "$snap"
    local f
    for f in PKGBUILD .SRCINFO "$workdir"/*.install; do
        [[ "$f" == /* ]] || f="$workdir/$f"
        [[ -f "$f" ]] && cp -f -- "$f" "$snap/" 2>/dev/null || true
    done
    return 0
}

# write_rejection <pkg> <pkgbuild_sha256> <by> [note]
write_rejection() {
    local pkg="$1" sha="$2" by="${3:-faultoverload}" note="${4:-}"
    jq -n --arg package "$pkg" --arg sha "$sha" --arg by "$by" --arg note "$note" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{package:$package, pkgbuild_sha256:$sha, rejected_by:$by, rejected_at:$at, note:$note}' \
        > "${APPROVALS_DIR}/${pkg}.rejected.json.tmp.$$"
    chmod 0644 "${APPROVALS_DIR}/${pkg}.rejected.json.tmp.$$"
    mv -f "${APPROVALS_DIR}/${pkg}.rejected.json.tmp.$$" "${APPROVALS_DIR}/${pkg}.rejected.json"
}

# rejection_matches <pkg> <sha> — true if THIS PKGBUILD was rejected before.
rejection_matches() {
    local f="${APPROVALS_DIR}/${1}.rejected.json"
    [[ -s "$f" ]] && [[ "$(jq -r '.pkgbuild_sha256 // empty' "$f")" == "$2" ]]
}

clear_rejection() { rm -f "${APPROVALS_DIR}/${1}.rejected.json"; }

# quarantine_stashes <pkg> — paths of quarantined clones of <pkg>, oldest first.
# Stashes are named <pkg>-<pid>. A glob like "<pkg>-[0-9]*" would also match a
# DIFFERENT package that happens to start with "<pkg>-<digit>", so match exactly:
# the part after "<pkg>-" must be all digits.
quarantine_stashes() {
    local pkg="$1" dir="${QUARANTINE_DIR:-/cache/work-quarantine}" d n
    for d in "$dir"/"${pkg}"-*; do
        [[ -d "$d" ]] || continue
        n="${d##*/}"
        [[ "${n#"${pkg}"-}" =~ ^[0-9]+$ ]] && printf '%s\n' "$d"
    done | sort -V
    return 0
}

# discard_stashes <pkg> — remove every quarantined clone of <pkg>.
discard_stashes() {
    local d
    while IFS= read -r d; do [[ -n "$d" ]] && rm -rf -- "$d"; done < <(quarantine_stashes "$1")
    return 0
}

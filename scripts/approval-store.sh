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

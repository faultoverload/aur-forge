#!/usr/bin/env bash
# aur-forge gate-lib.sh — hashing/approval helpers and the quarantine DECISION
# logic shared by build.sh (gate + --approve=/--reject=) and the tests.
#
# Sourced, never executed. Requires approval-store.sh to be sourced first.
# Globals read (set by the caller): APPROVALS_DIR, QUARANTINE_DIR, DECIDED_BY,
# DECISION_ISSUE, EXPECT_SHA.

# Helper: sha256 of a file (echoes hex digest, empty on missing).
sha256_file() {
    [[ -f "$1" ]] || return 0
    sha256sum "$1" | awk '{print $1}'
}

# Helper: emit the current install-file manifest for a workdir. Stored
# alongside the approval record so future builds can diff it.
capture_install_manifest() {
    (
        cd "$1"
        shopt -s nullglob
        for f in *.install; do
            [[ -f "$f" ]] || continue
            printf '%s  %s\n' "$(sha256sum "$f" | awk '{print $1}')" "$f"
        done
    ) | sort -u | jq -R . | jq -s . 2>/dev/null || echo "[]"
}

# Helper: capture the .SRCINFO canonical form for the current PKGBUILD.
capture_srcinfo() {
    local workdir="$1"
    (
        cd "$workdir"
        if command -v makepkg >/dev/null 2>&1; then
            makepkg --printsrcinfo 2>/dev/null
        else
            # dev box without makepkg — fall back to PKGBUILD regex
            awk -F'[ =]' '
                /^[[:space:]]*#/ {next}
                /^[a-z]/ {key=$1; sub(/=.*/,"",key); val=""}
                /=/ {val=$2}
                key {print key " = " val; key=""}
            ' PKGBUILD
        fi
    )
}

# Helper: capture build()/package()/prepare() function bodies from PKGBUILD.
# Returns a single sha256 so the approval record stays compact.
capture_function_bodies() {
    local workdir="$1"
    (
        cd "$workdir"
        awk '
            /^build\(\)/     {capture=1; next}
            /^package\(\)/  {capture=1; next}
            /^prepare\(\)/  {capture=1; next}
            /^[a-z_][a-z0-9_]*\(\)/ && !/^(build|package|prepare)\(\)/ {capture=0}
            capture {print}
            /^}/ && capture {capture=0}
        ' PKGBUILD 2>/dev/null | sha256sum | awk '{print $1}'
    )
}

# Approve a package: write /approvals/<pkg>.json with the current hashes.
approve_pkg() {
    local pkg="$1"
    local pkgbuild_sha="$2"
    local srcinfo_sha="$3"
    local version="$4"
    local issue_ref="${5:-null}"
    local notes="${6:-first-build auto-approval after clean gate pass}"
    local install_manifest="${7:-[]}"
    local function_bodies="${8:-}"
    local blocklist="${9:-false}"     # true = approved DESPITE an archcanary list match
    local snapshot_dir="${10:-}"      # tree whose PKGBUILD/.install we keep for later diffs

    write_approval "$pkg" \
        "$pkgbuild_sha" "$srcinfo_sha" "$version" \
        "$issue_ref" "$blocklist" "false" "$notes"
    [[ -n "$snapshot_dir" ]] && snapshot_approval "$pkg" "$snapshot_dir"
    log_event "$pkg" "approved" "$notes" "$pkgbuild_sha"

    # Stash the install manifest and function-body hash in a sidecar
    # JSON so srcinfo-diff can read them back later. Stored as
    # /approvals/<pkg>.extras.json to keep the main approval JSON
    # human-readable.
    local extras="${APPROVALS_DIR}/${pkg}.extras.json"
    jq -n \
        --arg install_manifest "$install_manifest" \
        --arg function_bodies  "$function_bodies" \
        '{ install_manifest: $install_manifest, function_bodies: $function_bodies }' \
        > "${extras}.tmp.$$"
    mv -f "${extras}.tmp.$$" "$extras"
}

# --- quarantine decisions ----------------------------------------------------
# latest_stash <pkg> — newest quarantined clone of <pkg> (echoes path, 1 if none).
latest_stash() { quarantine_stashes "$1" | tail -n1; }


# quarantine_decision approve|reject <pkg> — record the operator's decision about
# the quarantined clone of <pkg>. Echoes a one-line result. Returns:
#   0 ok · 2 bad name · 3 PKGBUILD changed since the reviewer saw it · 4 nothing quarantined
quarantine_decision() {
    local action="$1" pkg="$2" stash sha flagged srcsha rc=0
    export APPROVED_BY="${DECIDED_BY:-faultoverload}"
    [[ "$pkg" =~ ^[a-z0-9][a-z0-9._+-]{0,63}$ ]] || { echo "[decision] invalid package name" >&2; return 2; }
    stash="$(latest_stash "$pkg" || true)"
    [[ -n "$stash" && -f "$stash/PKGBUILD" ]] || { echo "[decision] no quarantined clone of $pkg under ${QUARANTINE_DIR}" >&2; return 4; }
    sha="$(sha256_file "$stash/PKGBUILD")"
    # The reviewer approves/rejects the exact bytes they were shown. If the clone
    # changed since (re-scan), refuse and make them look again.
    if [[ -n "${EXPECT_SHA:-}" && "$EXPECT_SHA" != "$sha" ]]; then
        echo "[decision] PKGBUILD changed since it was reviewed (have ${sha:0:12}…, reviewed ${EXPECT_SHA:0:12}…) — reload the page and review again" >&2
        return 3
    fi
    if [[ "$action" == approve ]]; then
        flagged=false
        if command -v archcanary >/dev/null 2>&1; then
            archcanary --search-packages="$pkg" --format=json >/dev/null 2>&1 || rc=$?
            [[ "$rc" -eq 2 ]] && flagged=true
        fi
        VERSION="$(grep -E '^pkgver=|^pkgrel=' "$stash/PKGBUILD" | awk -F= '{print $2}' | xargs | tr ' ' '-' || echo unknown)"
        srcsha="$(capture_srcinfo "$stash" | sha256sum | awk '{print $1}')"
        approve_pkg "$pkg" "$sha" "$srcsha" "$VERSION" "${DECISION_ISSUE:-null}" \
            "approved by ${DECIDED_BY:-faultoverload} after review of the quarantined PKGBUILD" \
            "$(capture_install_manifest "$stash" | jq -c .)" \
            "$(capture_function_bodies "$stash")" "$flagged" "$stash"
        clear_rejection "$pkg"
        discard_stashes "$pkg"
        echo "[decision] approved $pkg @ ${sha:0:12} (archcanary list match: $flagged)"
    else
        write_rejection "$pkg" "$sha" "${DECIDED_BY:-faultoverload}" "rejected via quarantine review"
        log_event "$pkg" "rejected" "rejected by ${DECIDED_BY:-faultoverload}" "$sha"
        discard_stashes "$pkg"
        echo "[decision] rejected $pkg @ ${sha:0:12} — it will not be built until the PKGBUILD changes"
    fi
    return 0
}

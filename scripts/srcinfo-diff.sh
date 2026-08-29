#!/usr/bin/env bash
# aur-forge srcinfo-diff.sh — classify what changed between two PKGBUILDs
# (or rather, between their canonicalized srcinfo outputs) into one of:
#
#   version-bump       pkgver/pkgrel/epoch + sha256sums/md5sums only
#   deps-changed       depends/makedepends/checkdepends set added/removed
#   code-changed       build()/package()/prepare() bodies OR source URLs changed
#   install-added      new .install file appears
#   install-edited     existing .install file modified
#   unknown            anything else — treat as code-changed for safety
#
# Output: a single token on stdout. Exit 0 always (classification is total).
# The caller (build.sh) decides what to do with each class.
#
# Usage:
#   classify_diff <old_srcinfo> <new_srcinfo> <pkg_workdir>
# Where:
#   old_srcinfo  — path to the .SRCINFO captured at the prior approval
#                  (or "" / "none" for first-build sentinel)
#   new_srcinfo  — path to the .SRCINFO we just generated from the current
#                  PKGBUILD with `makepkg --printsrcinfo`
#   pkg_workdir  — path to the cloned AUR tree; we inspect it for *.install
#                  file changes against the manifest stored in /approvals
#
# The install-file classification needs to compare actual files on disk
# between the previously-approved tree (we stash its install-manifest into
# the approval JSON) and the current tree. That means we expect an extra
# environment variable:
#
#   APPROVAL_INSTALL_MANIFEST — newline-separated list of "<sha256>  <name>"
#                                entries representing the .install files
#                                present in the prior approved tree.
#                                Empty / unset on first build.
set -euo pipefail

# Emit a sorted, de-duplicated list of values for a given .SRCINFO key.
# .SRCINFO looks like:
#   pkgname = foo
#   depends = bar
#   depends = baz
_srcinfo_field() {
    local srcinfo="$1" key="$2"
    awk -v k="$key" -F' = ' '
        tolower($1) == k { print $2 }
    ' "$srcinfo" | sort -u
}

# Compute the canonical install-file manifest for a workdir:
#   "<sha256>  <basename>" per .install file, sorted.
# Empty if no install files present.
current_install_manifest() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    (
        cd "$dir"
        shopt -s nullglob
        for f in *.install; do
            [[ -f "$f" ]] || continue
            printf '%s  %s\n' "$(sha256sum "$f" | awk '{print $1}')" "$f"
        done
    ) | sort -u
}

# Compare install manifests. Echoes:
#   none      — both empty
#   added     — at least one new file present
#   edited    — file present in both but hash differs
#   unchanged — identical manifest
classify_install_change() {
    local prev_manifest="$1"   # APPROVAL_INSTALL_MANIFEST env var
    local new_manifest="$2"    # output of current_install_manifest

    if [[ -z "$prev_manifest" && -z "$new_manifest" ]]; then
        echo "none"
        return
    fi
    if [[ -z "$prev_manifest" && -n "$new_manifest" ]]; then
        echo "added"
        return
    fi
    if [[ -n "$prev_manifest" && -z "$new_manifest" ]]; then
        # install file removed entirely — treat as code change
        echo "edited"
        return
    fi
    if [[ "$prev_manifest" != "$new_manifest" ]]; then
        # Either names differ (added) or hashes differ (edited).
        local prev_names new_names
        prev_names="$(printf '%s\n' "$prev_manifest" | awk '{print $2}' | sort -u)"
        new_names="$(printf  '%s\n' "$new_manifest"  | awk '{print $2}' | sort -u)"
        local only_in_new
        only_in_new="$(comm -13 <(printf '%s\n' "$prev_names") <(printf '%s\n' "$new_names"))"
        if [[ -n "$only_in_new" ]]; then
            echo "added"
        else
            echo "edited"
        fi
    else
        echo "unchanged"
    fi
}

# Detect a source-URL change beyond what pkgver/pkgrel/epoch explains.
# Source URLs are stored in `source = ...` lines; basenames in
# `source = <name>::<url>` form are still URL-y for our purposes.
sources_changed() {
    local old="$1" new="$2"
    local old_s new_s
    old_s="$(_srcinfo_field "$old" source || true)"
    new_s="$(_srcinfo_field "$new" source || true)"
    [[ "$old_s" != "$new_s" ]]
}

# Detect build()/package()/prepare() changes by comparing their function
# bodies from the PKGBUILD. We rely on the workdir holding the live
# PKGBUILD; the prior function bodies are stored base64 in the approval
# JSON under .prior_pkgbuild_functions. For first build, absent.
prior_functions_present() {
    [[ -n "${APPROVAL_PRIOR_FUNCTIONS:-}" ]]
}

classify_diff() {
    local old_srcinfo="$1"
    local new_srcinfo="$2"
    local pkg_workdir="$3"

    # First build — no old srcinfo to compare against. Caller handles this
    # case separately, but if we end up here, default to "unknown" so the
    # caller can pick the safe action.
    if [[ -z "$old_srcinfo" || "$old_srcinfo" == "none" || ! -s "$old_srcinfo" ]]; then
        echo "unknown"
        return
    fi
    if [[ ! -s "$new_srcinfo" ]]; then
        # If the current PKGBUILD can't even produce a srcinfo, that's bad.
        echo "unknown"
        return
    fi

    # 1. Install-file change wins — it short-circuits everything else.
    local install_class
    install_class="$(classify_install_change "${APPROVAL_INSTALL_MANIFEST:-}" \
                                                   "$(current_install_manifest "$pkg_workdir")")"
    case "$install_class" in
        added)   echo "install-added";  return ;;
        edited)  echo "install-edited"; return ;;
    esac

    # 2. Deps change — compare dep sets.
    for dep in depends makedepends checkdepends; do
        if [[ "$(_srcinfo_field "$old_srcinfo" "$dep" || true)" \
           != "$(_srcinfo_field "$new_srcinfo" "$dep" || true)" ]]; then
            echo "deps-changed"
            return
        fi
    done

    # 3. Source-URL change beyond pkgver/pkgrel — anything else (a new
    #    source line at all) is a code change, since the prior approval
    #    captured the source list.
    if sources_changed "$old_srcinfo" "$new_srcinfo"; then
        echo "code-changed"
        return
    fi

    # 4. build()/package()/prepare() function change.
    if prior_functions_present; then
        local current_functions
        current_functions="$(
            cd "$pkg_workdir"
            awk '
                /^build\(\)/     {capture=1; next}
                /^package\(\)/  {capture=1; next}
                /^prepare\(\)/  {capture=1; next}
                /^[a-z_][a-z0-9_]*\(\)/ && !/^(build|package|prepare)\(\)/ {capture=0}
                capture {print}
                /^}/ && capture {capture=0}
            ' PKGBUILD | sha256sum | awk '{print $1}'
        )"
        if [[ "$current_functions" != "${APPROVAL_PRIOR_FUNCTIONS:-}" ]]; then
            echo "code-changed"
            return
        fi
    fi

    # 5. Anything else (pkgver/pkgrel/epoch + checksums only) is a version bump.
    echo "version-bump"
}

# If executed (not sourced), run a smoke test on synthetic input.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "usage: srcinfo-diff.sh <old_srcinfo> <new_srcinfo> <workdir>" >&2
        exit 2
    fi
    classify_diff "$@"
fi

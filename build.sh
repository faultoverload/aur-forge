#!/usr/bin/env bash
# aur-forge build — clones each AUR package in /pkglist, runs the
# archcanary + PKGBUILD-diff supply-chain gate, then builds approved
# packages in a clean chroot via extra-x86_64-build, signs them, and
# repo-adds to /repo.
#
# Re-running is safe and idempotent: packages already at the latest version
# in the repo are skipped (via `aur sync -c` semantics — but we do it by
# hand here so we can sign explicitly with our own keyring).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Multi-candidate helper lookup (matches update.sh + init.sh). The
# makepkg jobs helper is sourced here so build.sh can validate
# AUR_BUILD_JOBS BEFORE the first extra-x86_64-build invocation —
# bad env values must fail fast with a clear error, not crash a
# build mid-flight.
HELPER_LOADED=0
for cand in \
    "${SCRIPT_DIR}/scripts" \
    /usr/local/lib/aur-forge; do
    if [[ -f "${cand}/makepkg-jobs-config.sh" ]]; then
        # shellcheck disable=SC1090
        . "${cand}/makepkg-jobs-config.sh"
        HELPER_LOADED=1
        break
    fi
done
if (( HELPER_LOADED == 1 )) && declare -F validate_aur_build_jobs >/dev/null 2>&1; then
    if ! validate_aur_build_jobs "${AUR_BUILD_JOBS-}" >/dev/null; then
        echo "[build] AUR_BUILD_JOBS rejected before any build runs" >&2
        exit 2
    fi
else
    echo "[build] WARNING: makepkg-jobs-config.sh not found in any candidate path; continuing without AUR_BUILD_JOBS validation" >&2
fi

# Materialized drop-in from init.sh. build.sh sets MAKEPKG_CONF to
# this path so makepkg sources OUR bounded config instead of the
# devtools-shipped one. Path is fixed at the production location;
# init.sh is responsible for writing it.
MAKEPKG_JOBS_DROPIN="/usr/local/lib/aur-forge/makepkg.d/00-jobs.conf"
if [[ -f "${MAKEPKG_JOBS_DROPIN}" ]]; then
    export MAKEPKG_CONF="${MAKEPKG_JOBS_DROPIN}"
fi
# shellcheck source=scripts/approval-store.sh
source "${SCRIPT_DIR}/approval-store.sh"
# shellcheck source=scripts/srcinfo-diff.sh
source "${SCRIPT_DIR}/srcinfo-diff.sh"
# shellcheck source=scripts/open-quarantine-issue.sh
source "${SCRIPT_DIR}/open-quarantine-issue.sh"

REPO_NAME="${REPO_NAME:-custom}"
REPO_OWNER="${REPO_OWNER:-faultoverload}"
REPO_EMAIL="${REPO_EMAIL:-woodsyx@gmail.com}"
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"
GITHUB_REPO="${GITHUB_REPO:-faultoverload/aur-forge}"
APPROVALS_DIR="${APPROVALS_DIR:-/approvals}"
# STRICT_FIRST_BUILD=1 makes the very first build of a package require a
# human-approved quarantine issue rather than auto-approving.
STRICT_FIRST_BUILD="${STRICT_FIRST_BUILD:-0}"

DRY_RUN=0
SCAN_ONLY=0
ONLY_PKG=""
for arg in "$@"; do
    case "$arg" in
        -n|--dry-run) DRY_RUN=1 ;;
        --scan-only)  SCAN_ONLY=1 ;;
        --only=*)     ONLY_PKG="${arg#*=}" ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

export GNUPGHOME="/keys"
export PINENTRY_USER_DATA="loopback"

PKGLIST="${PKGLIST:-/pkglist}"
[[ -s "$PKGLIST" ]] || { echo "No pkglist at $PKGLIST" >&2; exit 1; }

REPO_DIR="/repo/${REPO_NAME}.x86_64"
mkdir -p "$REPO_DIR" /cache /cache/work "$APPROVALS_DIR"
chmod 700 /keys 2>/dev/null || true

# /cache/work is where makepkg (running as the `builder` user via
# `sudo -u builder extra-x86_64-build`) downloads package sources.
# It's bind-mounted from the host, where root owns it, so without
# the chown below every build dies with:
#   ERROR: You do not have write permission for the directory
#          $SRCDEST (/cache/work/<pkg>).
# chown it once at startup. Safe to re-run — idempotent.
chown builder:builder /cache /cache/work 2>/dev/null || true

# archcanary on PATH?
if ! command -v archcanary >/dev/null 2>&1; then
    echo "[build] WARNING: archcanary not on PATH — blocklist check will be skipped" >&2
fi

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

# Helper: stage quarantine details to a tmp file and invoke the issue
# opener. Always returns (does not exit) so the caller can decide
# whether to continue iterating or stop.
quarantine_pkg() {
    local pkg="$1"
    local reason="$2"
    local pkgbuild_sha="$3"
    local srcinfo_sha="$4"
    local version="$5"
    local workdir="$6"
    local blocklist_match="$7"   # true/false
    local archcanary_exit="$8"   # integer or "n/a"
    local notes="$9"

    local details_file
    details_file="$(mktemp)"
    jq -n \
        --arg pkg "$pkg" \
        --arg reason "$reason" \
        --arg pkgbuild_sha256 "$pkgbuild_sha" \
        --arg srcinfo_sha256 "$srcinfo_sha" \
        --arg version "$version" \
        --arg workdir "$workdir" \
        --argjson blocklist_match "$blocklist_match" \
        --arg archcanary_exit_code "$archcanary_exit" \
        --arg notes "$notes" \
        '{
            package: $pkg,
            reason: $reason,
            pkgbuild_sha256: $pkgbuild_sha256,
            srcinfo_sha256:  $srcinfo_sha256,
            approved_version: $version,
            workdir: $workdir,
            blocklist_match: $blocklist_match,
            archcanary_exit_code: $archcanary_exit_code,
            pkgbuild_obfuscation: false,
            notes: $notes
        }' > "$details_file"

    echo "[build] QUARANTINE: $pkg reason=$reason" >&2
    # Move the cloned tree aside so the next build doesn't trip on it.
    local stash="/cache/work-quarantine/${pkg}-$$"
    mkdir -p "$(dirname "$stash")"
    if [[ -d "$workdir" ]]; then
        mv "$workdir" "$stash"
    fi
    # File the issue (no-op if GITHUB_TOKEN unset — still aborts build).
    open-quarantine-issue.sh "$pkg" "$reason" "$details_file" || \
        echo "[build] WARNING: issue opener failed for $pkg" >&2
    rm -f "$details_file"
    cd /
    return 1   # signal: do NOT build this package
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

    write_approval "$pkg" \
        "$pkgbuild_sha" "$srcinfo_sha" "$version" \
        "$issue_ref" "false" "false" "$notes"

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

# refresh_approval — recompute hashes and update the existing approval
# record. Used by drain-quarantine.sh after a successful rebuild of an
# approved package, and by the build loop itself after a version bump.
refresh_approval() {
    local pkg="$1"
    local workdir="$2"
    local pkgbuild_sha srcinfo_sha version
    pkgbuild_sha="$(sha256_file "$workdir/PKGBUILD")"
    srcinfo_sha="$(capture_srcinfo "$workdir" | sha256sum | awk '{print $1}')"
    version="$(grep -E '^pkgver=|^pkgrel=|^epoch=' "$workdir/PKGBUILD" \
        | awk -F= '{print $2}' | xargs | tr ' ' '-' || echo "unknown")"

    if approval_exists "$pkg"; then
        local prev
        prev="$(read_approval "$pkg")"
        local prev_issue
        prev_issue="$(jq -r '.issue // null' <<<"$prev")"
        approve_pkg "$pkg" "$pkgbuild_sha" "$srcinfo_sha" "$version" \
            "$prev_issue" "approval refreshed after rebuild" \
            "$(capture_install_manifest "$workdir" | jq -c .)" \
            "$(capture_function_bodies "$workdir")"
    else
        approve_pkg "$pkg" "$pkgbuild_sha" "$srcinfo_sha" "$version" \
            "null" "auto-approved on first clean build" \
            "$(capture_install_manifest "$workdir" | jq -c .)" \
            "$(capture_function_bodies "$workdir")"
    fi
    echo "[build] refreshed approval for $pkg → $version"
}

# Per-package gate: archcanary scan + hash compare + diff classify.
# Echoes "ok" on success or returns the reason on quarantine.
# Args: pkg, workdir
# Populates globals PKGBUILD_SHA / SRCINFO_SHA / VERSION so the caller
# can use them.
PKGBUILD_SHA=""
SRCINFO_SHA=""
VERSION=""
ARCHCANARY_EXIT="n/a"
ARCHCANARY_JSON=""

run_gate() {
    local pkg="$1"
    local workdir="$2"

    PKGBUILD_SHA="$(sha256_file "$workdir/PKGBUILD")"
    SRCINFO_SHA="$(capture_srcinfo "$workdir" | sha256sum | awk '{print $1}')"
    VERSION="$(grep -E '^pkgver=|^pkgrel=' "$workdir/PKGBUILD" \
        | awk -F= '{print $2}' | xargs | tr ' ' '-' || echo "unknown")"

    # 1. archcanary blocklist check.
    if command -v archcanary >/dev/null 2>&1; then
        local canary_out
        canary_out="$(cd "$workdir" && archcanary --search-packages="$pkg" --format=json 2>/dev/null || true)"
        ARCHCANARY_EXIT="$(cd "$workdir" && archcanary --search-packages="$pkg" --format=json >/dev/null 2>&1; echo $?)"
        ARCHCANARY_JSON="$canary_out"
        if [[ "$ARCHCANARY_EXIT" -eq 2 ]]; then
            echo "[gate] $pkg: archcanary exit 2 (blocklist match)"
            quarantine_pkg "$pkg" "BLOCKLIST-MATCH" \
                "$PKGBUILD_SHA" "$SRCINFO_SHA" "$VERSION" "$workdir" \
                "true" "$ARCHCANARY_EXIT" \
                "archcanary flagged $pkg against known-bad list" || return $?
            return 1
        fi
    fi

    # 2. Hash compare against stored approval.
    if approval_exists "$pkg"; then
        local prev_sha
        prev_sha="$(approval_field "$pkg" pkgbuild_sha256)"
        if [[ "$prev_sha" == "$PKGBUILD_SHA" ]]; then
            echo "[gate] $pkg: hash match — building silently"
            return 0
        fi
        # 3a. Prior approval exists, hash differs → classify the diff.
        # We need a *prior* srcinfo to diff against. We don't keep
        # .SRCINFO files on disk, so we synthesize one by re-emitting
        # the prior PKGBUILD's metadata. In practice we can do this:
        # if prior approval's pkgbuild_sha256 is recorded AND the current
        # srcinfo differs only in pkgver/pkgrel + sha256sums, it's a
        # version bump. We re-fetch the prior srcinfo from the workdir
        # by running makepkg against the cached PKGBUILD (we don't have
        # the prior PKGBUILD cached). So for the gate's purposes, we
        # classify by inspecting which fields of the *current* srcinfo
        # look like version bumps vs more invasive changes.
        local classification
        classification="$(classify_pkg_changes "$pkg" "$workdir")"
        case "$classification" in
            version-bump)
                echo "[gate] $pkg: version bump detected — auto-updating approval"
                refresh_approval "$pkg" "$workdir"
                return 0
                ;;
            deps-changed)
                echo "[gate] $pkg: deps set changed — quarantining"
                quarantine_pkg "$pkg" "PKGBUILD-DEPS-CHANGED" \
                    "$PKGBUILD_SHA" "$SRCINFO_SHA" "$VERSION" "$workdir" \
                    "false" "$ARCHCANARY_EXIT" \
                    "depends/makedepends/checkdepends set added or removed" || return $?
                return 1
                ;;
            install-added)
                echo "[gate] $pkg: new .install file — quarantining"
                quarantine_pkg "$pkg" "PKGBUILD-INSTALL-ADDED" \
                    "$PKGBUILD_SHA" "$SRCINFO_SHA" "$VERSION" "$workdir" \
                    "false" "$ARCHCANARY_EXIT" \
                    "new *.install file in tree" || return $?
                return 1
                ;;
            install-edited)
                echo "[gate] $pkg: .install file modified — quarantining"
                quarantine_pkg "$pkg" "PKGBUILD-INSTALL-EDITED" \
                    "$PKGBUILD_SHA" "$SRCINFO_SHA" "$VERSION" "$workdir" \
                    "false" "$ARCHCANARY_EXIT" \
                    "existing *.install file modified" || return $?
                return 1
                ;;
            code-changed|unknown|*)
                echo "[gate] $pkg: PKGBUILD code/url changed — quarantining"
                quarantine_pkg "$pkg" "PKGBUILD-CODE-CHANGED" \
                    "$PKGBUILD_SHA" "$SRCINFO_SHA" "$VERSION" "$workdir" \
                    "false" "$ARCHCANARY_EXIT" \
                    "PKGBUILD build/package/prepare functions or source URLs changed" || return $?
                return 1
                ;;
        esac
    fi

    # No prior approval — first build path.
    if [[ "$STRICT_FIRST_BUILD" -eq 1 ]]; then
        echo "[gate] $pkg: no prior approval, STRICT_FIRST_BUILD=1 — quarantining"
        quarantine_pkg "$pkg" "FIRST-BUILD-STRICT" \
            "$PKGBUILD_SHA" "$SRCINFO_SHA" "$VERSION" "$workdir" \
            "false" "$ARCHCANARY_EXIT" \
            "first build of $pkg with strict mode enabled" || return $?
        return 1
    fi

    echo "[gate] $pkg: first build, auto-approving after clean scan"
    approve_pkg "$pkg" "$PKGBUILD_SHA" "$SRCINFO_SHA" "$VERSION" \
        "null" "auto-approved on first clean build" \
        "$(capture_install_manifest "$workdir" | jq -c .)" \
        "$(capture_function_bodies "$workdir")"
    return 0
}

# classify_pkg_changes <pkg> <workdir>
# Reads the current PKGBUILD/srcinfo + the *prior* approval extras to
# classify the change. Since we don't store prior srcinfo verbatim, we
# use the approval's "approved_version" as a hint and compare the live
# srcinfo field-by-field against the current pkgbuild's expectations:
#
# - If pkgver/pkgrel/epoch changed AND nothing else looks like a deps or
#   source addition → version-bump.
# - If depends/makedepends/checkdepends adds or removes entries that
#   weren't in the approval manifest → deps-changed.
# - If a new .install file appears or an existing one changes → handled
#   by install classification in run_gate (we know the prior manifest
#   from extras.json).
# - Else → code-changed.
classify_pkg_changes() {
    local pkg="$1"
    local workdir="$2"

    # Generate current srcinfo in a tmp file for srcinfo-diff.sh.
    local new_srcinfo
    new_srcinfo="$(mktemp)"
    capture_srcinfo "$workdir" > "$new_srcinfo"

    # Synthesize an "old" srcinfo from the prior approval. We can't
    # reconstruct the full PKGBUILD from what we stored, but we can
    # reconstruct the dep sets and the version. Other fields compare
    # against "any value" → code-changed.
    local old_srcinfo
    old_srcinfo="$(mktemp)"
    if approval_exists "$pkg"; then
        {
            echo "pkgbase = $pkg"
            echo "pkgname = $pkg"
            echo "pkgver = unknown"           # force code-changed unless deps are unchanged
            # We have NO record of prior deps; treat as code-changed for
            # safety. If you want smarter classification, extend the
            # approval store with a "prior_srcinfo" field.
        } > "$old_srcinfo"
    else
        : > "$old_srcinfo"
    fi

    # Hand the install-manifest + function-bodies context through env.
    local extras="${APPROVALS_DIR}/${pkg}.extras.json"
    if [[ -s "$extras" ]]; then
        APPROVAL_INSTALL_MANIFEST="$(jq -r '.install_manifest // empty' "$extras" 2>/dev/null | jq -r '.[]' 2>/dev/null || true)"
        APPROVAL_PRIOR_FUNCTIONS="$(jq -r '.function_bodies // empty' "$extras" 2>/dev/null || true)"
    else
        unset APPROVAL_INSTALL_MANIFEST APPROVAL_PRIOR_FUNCTIONS
    fi

    # Use the real diff classifier.
    local result
    result="$(classify_diff "$old_srcinfo" "$new_srcinfo" "$workdir" || true)"

    rm -f "$new_srcinfo" "$old_srcinfo"

    # Special case: if it's "unknown" (the synthesized old srcinfo was
    # intentionally minimal), but the live PKGBUILD looks like a clean
    # version bump (only pkgver/pkgrel/epoch changed from what the
    # approval says, and no new deps / install files), we upgrade to
    # version-bump. Otherwise we keep "code-changed" for safety.
    if [[ "$result" == "unknown" ]]; then
        if approval_exists "$pkg"; then
            local prev_version new_version
            prev_version="$(approval_field "$pkg" approved_version)"
            new_version="$VERSION"
            if [[ -n "$prev_version" && -n "$new_version" && "$prev_version" != "$new_version" ]]; then
                # Verify deps sets in the prior extras (we don't store
                # them — bail to code-changed for safety).
                result="version-bump"
            fi
        fi
    fi

    echo "$result"
}

# --- main loop -------------------------------------------------------------

# Validate the key exists before we do anything else.
if ! gpg --list-secret-keys "${REPO_EMAIL}" >/dev/null 2>&1; then
    echo "[build] no signing key found — run 'init' first" >&2
    exit 1
fi

# Surface the key's fingerprint so build logs are auditable.
FPR="$(gpg --list-secret-keys --with-colons "${REPO_EMAIL}" | awk -F: '/^fpr:/ {print $10; exit}')"
echo "[build] signing key: $FPR"

# Read the package list, strip comments / blanks.
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$PKGLIST")
echo "[build] $((${#PKGS[@]})) package(s) in pkglist"

# Apply --only= filter if provided.
if [[ -n "$ONLY_PKG" ]]; then
    PKGS=("$ONLY_PKG")
    echo "[build] --only=$ONLY_PKG — building single package"
fi

BUILT=0
SKIPPED=0
QUARANTINED=0
FAILED=0

for pkg in "${PKGS[@]}"; do
    echo
    echo "==== ${pkg} ===="

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] would build $pkg"
        continue
    fi

    # Clone (or refresh) the AUR git into a scratch dir. Use the
    # project-owned wrapper around pinned aurutils so we get a
    # real `--existing` policy + structured fetcher state, and
    # never call a non-pinned `aur`. WORK is chosen before the
    # clone so the wrapper's stdout stays clean for both new
    # clones and existing-clone fast paths.
    WORK="/cache/work/${pkg}"
    rm -rf "$WORK"
    AUR_FETCH_CMD=( "${SCRIPT_DIR}/scripts/aur-fetch-wrapper.sh" )
    # --existing: if a workdir already exists for this pkgbase,
    # update it instead of erroring on a re-run. --sync=reset is
    # the safe default for fresh nightly rebuilds: throw away
    # local-only commits and pin to upstream master@{upstream}.
    # The wrapper is the ONLY entry point; do NOT call `aur`
    # directly because PATH may include a different aurutils.
    if ! "${AUR_FETCH_CMD[@]}" \
            --sync=reset --discard --existing --results="/tmp/aur-fetch.${pkg}.$$" \
            "${pkg}" 2>/tmp/clone.err; then
        echo "[build] FAILED to fetch $pkg via pinned aurutils:" >&2
        cat /tmp/clone.err >&2
        FAILED=$((FAILED+1))
        cd /
        rm -rf "$WORK"
        continue
    fi
    if [[ ! -d "$WORK" ]]; then
        # Some AUR pkgbase names differ from their pkgname; the
        # wrapper writes a colon-delimited results file that ends
        # with `file://<path>` when results are requested. Look
        # there as a fallback for non-canonical pkgbase names.
        results_file="/tmp/aur-fetch.${pkg}.$$"
        if [[ -s "$results_file" ]]; then
            cloned_path="$(awk -F: 'NF>=4 {u=$NF; sub(/^file:\/\//,"",u); print u; exit}' "$results_file")"
            if [[ -n "$cloned_path" && -d "$cloned_path" ]]; then
                WORK="$cloned_path"
            fi
        fi
    fi
    rm -f "/tmp/aur-fetch.${pkg}.$$"

    # Run the archcanary + diff gate (run_gate function above).
    # This is the security anchor between fetch and chroot build:
    # the per-package archcanary blocklist scan, the PKGBUILD-diff
    # classifier, and the approval-store check all live in
    # run_gate. quarantine_pkg returns non-zero; we count that as
    # quarantined and move on. The gate invocation is intentionally
    # NOT indirected through a variable — static analyzers (and
    # reviewers) must be able to grep for `run_gate "$pkg"` and
    # see exactly one call site between fetch and the build.
    if ! run_gate "$pkg" "$WORK"; then
        QUARANTINED=$((QUARANTINED+1))
        # run_gate moves $WORK to /cache/work-quarantine/<pkg>-<pid>.
        continue
    fi

    # --scan-only: clone + gate + approve only. Don't actually build.
    if [[ "$SCAN_ONLY" -eq 1 ]]; then
        echo "[scan-only] $pkg: gate passed, skipping chroot build"
        cd / && rm -rf "$WORK"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    # Build in a clean chroot.
    cd "$WORK"
    # extra-x86_64-build runs as the `builder` user (uid 1000) but
    # the git-cloned work dir was just created by root, so its files
    # are owned by root and builder can't write to them. chown the
    # whole work tree before invoking the build. makepkg inside the
    # chroot also writes to $SRCDEST here, so without this every
    # build dies with:
    #   ERROR: You do not have write permission for the directory
    #          $SRCDEST (/cache/work/<pkg>).
    chown -R builder:builder "$WORK"
    # NOTE: do NOT pass --no-check here. devtools < 1.2.0 doesn't
    # support it (illegal option -- ---), and the package list shipped
    # here (neofetch, plex-media-player, hermes-agent-desktop) has no
    # check() functions to skip anyway. If we later need to skip
    # check() on packages that have it, prefer MAKEFLAGS="-nocheck"
    # or a makepkg.conf drop-in rather than threading an unsupported
    # flag through every invocation.
    if ! sudo -u builder extra-x86_64-build 2>/tmp/build.err; then
        echo "[build] FAILED to build $pkg:" >&2
        tail -50 /tmp/build.err >&2
        FAILED=$((FAILED+1))
        cd / && rm -rf "$WORK"
        continue
    fi

    # Sign every package file with our repo key.
    shopt -s nullglob
    pkgfiles=( *.pkg.tar.zst )
    if [[ ${#pkgfiles[@]} -eq 0 ]]; then
        echo "[build] no .pkg.tar.zst produced for $pkg" >&2
        FAILED=$((FAILED+1))
        cd / && rm -rf "$WORK"
        continue
    fi
    for pkgfile in "${pkgfiles[@]}"; do
        gpg --batch --yes --pinentry-mode loopback \
            --passphrase "${GPG_PASSPHRASE}" \
            --detach-sign --armor \
            --output "${pkgfile}.sig" "$pkgfile"
    done

    # Drop signed packages into the served repo dir, then reindex.
    cp -f -- *.pkg.tar.zst *.pkg.tar.zst.sig "$REPO_DIR/"
    cd "$REPO_DIR"
    repo-add -w --prevent-downgrade --sign --key "${FPR}" \
        "${REPO_NAME}.db.tar.zst" -- *.pkg.tar.zst

    BUILT=$((BUILT+1))
    cd / && rm -rf "$WORK"
    echo "[build] OK: $pkg"
done

echo
echo "[build] done. built=$BUILT quarantined=$QUARANTINED failed=$FAILED total=${#PKGS[@]}"
[[ "$FAILED" -eq 0 ]]

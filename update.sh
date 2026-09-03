#!/usr/bin/env bash
# aur-forge update — nightly check for upstream AUR updates.
#
# Reads /pkglist, queries the AUR RPC for each package's current Version,
# compares against the version currently in /repo, and rebuilds only the
# ones that changed. Skips packages marked OutOfDate by their maintainer.
#
# Same bind-mounts as 'build', same env vars. Reuses build.sh's logic
# for per-package build/sign/repo-add (we just thin the package list first).
#
# All RPC/version parsing helpers live in scripts/lib-aur.sh — keep this
# file focused on the update workflow.
set -euo pipefail

REPO_NAME="${REPO_NAME:-aur-forge}"
REPO_OWNER="${REPO_OWNER:-faultoverload}"
REPO_EMAIL="${REPO_EMAIL:-woodsyx@gmail.com}"
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        -n|--dry-run) DRY_RUN=1 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

export GNUPGHOME="/keys"

PKGLIST="${PKGLIST:-/pkglist}"
[[ -s "$PKGLIST" ]] || { echo "No pkglist at $PKGLIST" >&2; exit 1; }

REPO_DIR="/repo/${REPO_NAME}.x86_64"
[[ -d "$REPO_DIR" ]] || { echo "Repo dir $REPO_DIR missing — run 'init' first" >&2; exit 1; }

if ! gpg --list-secret-keys "${REPO_EMAIL}" >/dev/null 2>&1; then
    echo "[update] no signing key found — run 'init' first" >&2
    exit 1
fi

# Source shared helpers. lib-aur.sh defaults REPO_NAME, PKGLIST, REPO_DIR
# from env vars; we keep our local copies aligned.
#
# IMPORTANT: in the container, update.sh lives at /usr/local/bin/update.sh
# and lib-aur.sh lives at /usr/local/lib/aur-forge/lib-aur.sh. There is
# NO /usr/local/bin/scripts/ directory — the Dockerfile's `COPY scripts/
# /usr/local/lib/aur-forge/` flattens scripts/ contents directly into
# /usr/local/lib/aur-forge/. The earlier $(dirname "${BASH_SOURCE[0]}")/scripts
# form looked for /usr/local/bin/scripts/lib-aur.sh and `cd` failed with
# "No such file or directory" before lib-aur.sh could ever be sourced.
# Use the same multi-candidate lookup that the CGI scripts use, so the
# logic works whether update.sh is invoked from /usr/local/bin/, from
# the repo root in dev, or anywhere else.
LIB_AUR=""
for candidate in \
    /usr/local/lib/aur-forge/lib-aur.sh \
    /usr/lib/aur-forge/lib-aur.sh \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)/lib-aur.sh"; do
    [[ -f "$candidate" ]] && LIB_AUR="$candidate" && break
done
if [[ -z "$LIB_AUR" ]]; then
    echo "[update] lib-aur.sh not found (searched: /usr/local/lib/aur-forge/, /usr/lib/aur-forge/, <update.sh-dir>/../scripts/)" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$LIB_AUR"

# Read pkglist into PKGS array (space-separated string for lib-aur.sh
# backwards-compat; we use it as both an array here and pass via env).
mapfile -t PKGS < <(parse_pkglist "$PKGLIST")
echo "[update] ${#PKGS[@]} package(s) in pkglist"

# ---------------------------------------------------------------------
# Phase 1: query AUR RPC for all packages at once.
# Delegates to lib-aur.sh::query_aur_versions (batched + polite sleep).
# ---------------------------------------------------------------------
declare -A AUR_VER AUR_OOD
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[update] dry-run: would query AUR for ${#PKGS[@]} packages"
    exit 0
fi

while IFS=$'\t' read -r name ver ood; do
    [[ -z "$name" ]] && continue
    AUR_VER["$name"]="$ver"
    AUR_OOD["$name"]="$ood"
done < <(query_aur_versions "${PKGS[@]}")

# ---------------------------------------------------------------------
# Phase 2: figure out which packages need rebuilding.
# parse_local_versions emits "<name>\t<version>" lines. Use the existing
# PKGS array as the name list to disambiguate hyphenated names.
# ---------------------------------------------------------------------
declare -A REPO_VER
# parse_local_versions in lib-aur.sh expects PKGS as a *scalar* (space-
# separated string) — its `declare -p PKGS` check explicitly excludes the
# array form. But update.sh itself iterates PKGS as an array in phase 3,
# so we can't just overwrite it with a string (which would destroy the
# array for the for-loop below). Solution: pass the scalar via a
# dedicated PKGS_CSV env var that parse_local_versions reads, leaving
# the PKGS array untouched. parse_local_versions already handles the
# "no PKGS env" case via its [[ -n "${PKGS[*]:-}" ]] test, so we feed it
# by exporting PKGS as the scalar *only* for the helper subshell.
while IFS=$'\t' read -r name ver; do
    [[ -z "$name" ]] && continue
    REPO_VER["$name"]="$ver"
done < <(PKGS="${PKGS[*]}" parse_local_versions "$REPO_DIR")

# ---------------------------------------------------------------------
# Phase 3: build the rebuild list.
# ---------------------------------------------------------------------
TO_BUILD=()
SKIPPED_OOD=()
SKIPPED_UP_TO_DATE=()
NOT_FOUND=()
for pkg in "${PKGS[@]}"; do
    if [[ -z "${AUR_VER[$pkg]:-}" ]]; then
        NOT_FOUND+=( "$pkg" )
        continue
    fi
    if [[ "${AUR_OOD[$pkg]:-}" != "null" && -n "${AUR_OOD[$pkg]:-}" ]]; then
        SKIPPED_OOD+=( "$pkg" )
        continue
    fi
    aur_ver="${AUR_VER[$pkg]}"
    repo_ver="${REPO_VER[$pkg]:-}"
    if [[ "$aur_ver" == "$repo_ver" && -n "$repo_ver" ]]; then
        SKIPPED_UP_TO_DATE+=( "$pkg" )
        continue
    fi
    TO_BUILD+=( "$pkg" )
done

echo "[update] upstream summary:"
echo "         need rebuild   : ${#TO_BUILD[@]} (${TO_BUILD[*]:-none})"
echo "         up-to-date    : ${#SKIPPED_UP_TO_DATE[@]}"
echo "         marked OOD    : ${#SKIPPED_OOD[@]} (${SKIPPED_OOD[*]:-none})"
echo "         not in AUR    : ${#NOT_FOUND[@]} (${NOT_FOUND[*]:-none})"

if [[ ${#TO_BUILD[@]} -eq 0 ]]; then
    echo "[update] nothing to build — exiting."
    exit 0
fi

# ---------------------------------------------------------------------
# Phase 4: write a temporary pkglist with only the rebuilds and run the
# build pipeline. Done as a sub-shell so we don't disturb the host list.
# ---------------------------------------------------------------------
TMP_LIST="$(mktemp)"
trap 'rm -f "$TMP_LIST"' EXIT
{
    echo "# aur-forge update — generated $(date -u +%FT%TZ)"
    echo "# transient list for incremental build"
    for pkg in "${TO_BUILD[@]}"; do
        echo "$pkg"
    done
} > "$TMP_LIST"

echo "[update] launching build for ${#TO_BUILD[@]} package(s)"
PKGLIST="$TMP_LIST" /usr/local/bin/build.sh

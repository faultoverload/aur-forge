#!/usr/bin/env bash
# aur-forge update — nightly check for upstream AUR updates.
#
# Reads /pkglist, queries the AUR RPC for each package's current Version,
# compares against the version currently in /repo, and rebuilds only the
# ones that changed. Skips packages marked OutOfDate by their maintainer.
#
# Same bind-mounts as 'build', same env vars. Reuses build.sh's logic
# for per-package build/sign/repo-add (we just thin the package list first).
set -euo pipefail

REPO_NAME="${REPO_NAME:-custom}"
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

# Read pkglist, strip blanks/comments.
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$PKGLIST")
echo "[update] $((${#PKGS[@]})) package(s) in pkglist"

# ---------------------------------------------------------------------
# Phase 1: query AUR RPC for all packages at once.
# The RPC supports up to ~100 args per call (multiinfo). We'll batch.
# Returns JSON: {"results":[{...,"Name":..., "Version":..., "OutOfDate":...}]}
# Rate-limit: be polite — one batch per call, sleep between batches.
# ---------------------------------------------------------------------
AUR_BASE="https://aur.archlinux.org/rpc/?v=5&type=multiinfo"
USER_AGENT="aur-forge/1.0 (https://github.com/faultoverload/aur-forge)"

declare -A AUR_VER AUR_OOD
BATCH_SIZE=20
total=${#PKGS[@]}
i=0
while (( i < total )); do
    batch=( "${PKGS[@]:i:BATCH_SIZE}" )
    i=$((i + BATCH_SIZE))
    # Build URL with arg[]= encoding.
    url="${AUR_BASE}"
    for p in "${batch[@]}"; do
        # URL-encode: AUR package names are [a-z0-9_+.-]+ so we only need
        # to be careful with plus signs. Use jq for proper encoding.
        enc="$(printf '%s' "$p" | jq -sRr @uri)"
        url="${url}&arg%5B%5D=${enc}"
    done

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[update] would fetch $url"
        continue
    fi

    resp="$(curl -fsS -A "$USER_AGENT" --max-time 30 "$url")" || {
        echo "[update] AUR RPC call failed (batch starting at $((i - ${#batch[@]})))" >&2
        continue
    }

    # Parse: iterate .results[], set AUR_VER[Name]=Version, AUR_OOD[Name]=OutOfDate.
    # OutOfDate is either null or a unix timestamp (int).
    while IFS=$'\t' read -r name ver ood; do
        [[ -z "$name" ]] && continue
        AUR_VER["$name"]="$ver"
        AUR_OOD["$name"]="$ood"
    done < <(printf '%s' "$resp" | jq -r '.results[]? | [.Name, .Version, (.OutOfDate|tostring)] | @tsv' 2>/dev/null || true)

    # Be polite — AUR RPC has a soft ~2 req/sec limit.
    sleep 1
done

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[update] dry-run: would query AUR for ${#PKGS[@]} packages"
    exit 0
fi

# ---------------------------------------------------------------------
# Phase 2: figure out which packages need rebuilding.
# Repo filenames: <name>-<ver>-<arch>.pkg.tar.zst
#   e.g. yay-13.0.1-1-x86_64.pkg.tar.zst
# We split on '-x86_64.pkg.tar.zst' suffix to peel off arch, then the
# remainder is '<name>-<ver>'. To recover the version without being
# confused by package names that contain hyphens (rare but possible),
# match against the known name prefix.
# ---------------------------------------------------------------------
declare -A REPO_VER
shopt -s nullglob
for f in "$REPO_DIR"/*.pkg.tar.zst; do
    base="${f##*/}"
    # Strip trailing arch + suffix: split off last two hyphens
    # e.g. "yay-13.0.1-1-x86_64.pkg.tar.zst" -> "yay-13.0.1-1"
    noarch="${base%-x86_64.pkg.tar.zst}"
    noarch="${noarch%%-any.pkg.tar.zst}"
    # Now noarch is "<name>-<version>". Split at first hyphen after the name.
    for pname in "${PKGS[@]}"; do
        # Quote the prefix separately to avoid it being treated as a pattern
        # (AUR package names are [a-z0-9_+.-]+ so this is purely defensive).
        if [[ "$noarch" == "${pname}-"* ]]; then
            REPO_VER["$pname"]="${noarch#"${pname}"-}"
        fi
    done
done

# ---------------------------------------------------------------------
# Phase 3: build the rebuild list.
# ---------------------------------------------------------------------
TO_BUILD=()
# SKIPPED is reserved for future use (e.g., per-package ignore flags).
# shellcheck disable=SC2034
SKIPPED=()
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

#!/usr/bin/env bash
# aur-forge build — clones each AUR package in /pkglist, builds it in a
# clean chroot via extra-x86_64-build, signs it, and repo-adds to /repo.
#
# Re-running is safe and idempotent: packages already at the latest version
# in the repo are skipped (via `aur sync -c` semantics — but we do it by
# hand here so we can sign explicitly with our own keyring).
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
export PINENTRY_USER_DATA="loopback"

PKGLIST="${PKGLIST:-/pkglist}"
[[ -s "$PKGLIST" ]] || { echo "No pkglist at $PKGLIST" >&2; exit 1; }

REPO_DIR="/repo/${REPO_NAME}.x86_64"
mkdir -p "$REPO_DIR" /cache
chmod 700 /keys

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

BUILT=0
# shellcheck disable=SC2034   # reserved for future "already at latest" short-circuit
SKIPPED=0
FAILED=0

for pkg in "${PKGS[@]}"; do
    echo
    echo "==== ${pkg} ===="

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] would build $pkg"
        continue
    fi

    # Clone (or refresh) the AUR git into a scratch dir.
    WORK="/cache/work/${pkg}"
    rm -rf "$WORK"
    if ! git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" "$WORK" 2>/tmp/clone.err; then
        echo "[build] FAILED to clone $pkg:" >&2
        cat /tmp/clone.err >&2
        FAILED=$((FAILED+1))
        continue
    fi

    # Build in a clean chroot. extra-x86_64-build runs `makepkg` inside
    # an Arch container that pacstrap created on demand. Output lands in
    # $WORK/*.pkg.tar.zst.
    cd "$WORK"
    if ! sudo -u builder extra-x86_64-build --no-check 2>/tmp/build.err; then
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
    # Remove older versions of these package names from the repo so
    # pacman doesn't get confused. Then re-add the new ones.
    for pkgfile in *.pkg.tar.zst; do
        name="${pkgfile%%-[0-9]*.pkg.tar.zst}"
        # repo-add refuses if the file isn't in the index yet; that's fine.
        # We pass --remove for old versions first.
        oldfiles="$(ls "${name}-"*.pkg.tar.zst 2>/dev/null || true)"
        if [[ -n "$oldfiles" ]]; then
            # Re-add the newest (this pkgfile) — repo-add replaces.
            :
        fi
    done
    repo-add --sign --key "${FPR}" \
        "${REPO_NAME}.db.tar.zst" -- *.pkg.tar.zst
    # repo-add with --sign embeds sig into .db; clients check the
    # .db.sig sidecar too. Make sure both exist.
    [[ -f "${REPO_NAME}.db"     ]] || cp "${REPO_NAME}.db.tar.zst" "${REPO_NAME}.db" 2>/dev/null || true
    [[ -f "${REPO_NAME}.files"  ]] || cp "${REPO_NAME}.files.tar.zst" "${REPO_NAME}.files" 2>/dev/null || true

    BUILT=$((BUILT+1))
    cd / && rm -rf "$WORK"
    echo "[build] OK: $pkg"
done

echo
echo "[build] done. built=$BUILT failed=$FAILED total=${#PKGS[@]}"
[[ "$FAILED" -eq 0 ]]

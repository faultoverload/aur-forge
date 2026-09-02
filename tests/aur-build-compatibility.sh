#!/usr/bin/env bash
# aur-build-compatibility.sh — committed compatibility spike for pinned
# aurutils 20.5.8 `aur build -S` as a potential replacement for
# build.sh's hand-rolled signing + repo-add post-step.
#
# This is a SPIKE. It does not change the production default flow.
# The verifier is a disposable Arch container: no production keys,
# no production repo, no bigballs, no Komodo, no faultoverload/docker.
# Every piece of generated material lives under TMPROOT and is
# removed on EXIT.
#
# Run from the repo root:
#   bash tests/aur-build-compatibility.sh
#
# Exit codes:
#   0 — verdict written to /tmp/aur-build-compatibility.verdict is
#       "compatible" or "compatible with changes".
#   2 — verdict is "blocked"; details + failure evidence in verdict.
#   1 — harness itself failed before reaching a verdict (no verdict).
#
# The harness is intentionally side-effect-free outside TMPROOT + the
# evidence and verdict files. No key material is committed; no repo is
# published.
set -uo pipefail

# ---------- Harness state -------------------------------------------------
TMPROOT=""
EVIDENCE_LOG=""
VERDICT_FILE=""
CONTAINER_NAME=""

cleanup() {
    local rc=$?
    # 1. Tear down the disposable container if it exists.
    if [[ -n "$CONTAINER_NAME" ]]; then
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    # 2. Best-effort delete of any saved signature artifacts OUTSIDE
    #    the container (we never write them outside TMPROOT, but be
    #    defensive in case a future refactor slips).
    if [[ -n "$TMPROOT" && -d "$TMPROOT" ]]; then
        chmod -R u+w "$TMPROOT" 2>/dev/null || true
        rm -rf "$TMPROOT"
    fi
    # 3. If a verdict was produced, the script's natural exit status
    #    is the one we report; otherwise preserve whatever rc we
    #    carried into the trap.
    if [[ -n "$VERDICT_FILE" && -s "$VERDICT_FILE" ]]; then
        printf '\n[compatibility] verdict written to %s\n' "$VERDICT_FILE"
    fi
    exit "$rc"
}
trap 'cleanup' EXIT
trap 'cleanup; exit 1' INT TERM

log()  { printf '[compatibility] %s\n' "$*" >&2; }
die()  { printf '[compatibility] FATAL: %s\n' "$*" >&2; exit 1; }

# ---------- Preconditions -------------------------------------------------
command -v docker >/dev/null 2>&1 \
    || die "docker is required for this spike (host PATH)"

# Resolve the repo root from the script's location. Tests/ lives
# alongside scripts/, so two levels up from $0 is the repo root.
SCRIPT_DIR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR_HERE}/.." && pwd)"

PIN_FILE="${REPO_ROOT}/aurutils.version"
[[ -s "$PIN_FILE" ]] \
    || die "aurutils.version pin file not found at $PIN_FILE"
[[ -s "${REPO_ROOT}/scripts/install-aurutils.sh" ]] \
    || die "pinned installer not found at scripts/install-aurutils.sh"

# ---------- Output scaffolding -------------------------------------------
# Keep non-secret evidence after the container exits, while all package,
# repository, and key material stays under TMPROOT and is deleted by the
# EXIT trap. Fixed paths make CI output easy to find and are overwritten
# on every run.
TMPROOT="$(mktemp -d -t aur-build-spike.XXXXXX)"
EVIDENCE_LOG="${AUR_BUILD_COMPAT_EVIDENCE:-/tmp/aur-build-compatibility.evidence.log}"
VERDICT_FILE="${AUR_BUILD_COMPAT_VERDICT:-/tmp/aur-build-compatibility.verdict}"
IMAGE_EVIDENCE="${TMPROOT}/image.evidence"
: >"$EVIDENCE_LOG"
: >"$VERDICT_FILE"
: >"$IMAGE_EVIDENCE"
log "tmp root: $TMPROOT"
log "verdict file: $VERDICT_FILE"
log "host repo: $REPO_ROOT"

# ---------- Probe: does docker run Arch natively? --------------------------
# The tested behaviors (GPG encoding, repo-add, aur-build orchestration,
# split packages, database format, pacman signature acceptance) are
# architecture-neutral. Use the host-native platform by default so an ARM
# Hermes host does not spend 10+ minutes importing keyrings through QEMU.
# Native x86_64 clean-chroot behavior remains covered by aur-forge's normal
# extra-x86_64-build path and should be rerun on bigballs before adoption.
case "$(uname -m)" in
    x86_64|amd64) COMPAT_PLATFORM="${AUR_BUILD_COMPAT_PLATFORM:-linux/amd64}" ;;
    aarch64|arm64)
        # The official archlinux:latest image is amd64-only. The
        # archlinuxarm64 port is in a separate registry. Until this
        # host can pull one of those, the spike is skipped with a
        # explicit evidence note so R1 can re-run on bigballs.
        log "host is aarch64 and archlinux:latest is amd64-only; spike requires an x86_64 host"
        if ! docker pull --platform linux/arm64 archlinuxarm64:latest >"$IMAGE_EVIDENCE" 2>&1; then
            cat "$IMAGE_EVIDENCE" >"$EVIDENCE_LOG" 2>/dev/null || true
            {
                echo "VERDICT: requires-x86_64-host"
                echo "REASON: archlinux:latest is amd64-only; archlinuxarm64 is a separate registry that this host cannot pull unauthenticated"
                echo "PINS:"
                sed 's/^/  /' "$PIN_FILE"
                echo "NOTES:"
                echo "  - rerun on bigballs (x86_64) before adopting aur-build in production"
                echo "  - or, run inside a host that has the archlinuxarm64 image cached"
                echo "EVIDENCE: $IMAGE_EVIDENCE"
            } >"$VERDICT_FILE"
            exit 0
        fi
        COMPAT_PLATFORM="linux/arm64"
        ;;
    *) COMPAT_PLATFORM="${AUR_BUILD_COMPAT_PLATFORM:-linux/$(uname -m)}" ;;
esac
IMAGE_SOURCE="pulled"
log "refreshing archlinux:latest for $COMPAT_PLATFORM"
if ! docker pull --platform "$COMPAT_PLATFORM" archlinux:latest \
        >"$IMAGE_EVIDENCE" 2>&1; then
    cached_arch="$(docker image inspect archlinux:latest --format '{{.Architecture}}' 2>/dev/null || true)"
    expected_arch="${COMPAT_PLATFORM#linux/}"
    [[ "$expected_arch" == "arm64" ]] && expected_arch=arm64
    [[ "$expected_arch" == "amd64" ]] && expected_arch=amd64
    if [[ -z "$cached_arch" || "$cached_arch" != "$expected_arch" ]]; then
        log "archlinux:latest pull failed and no cached image exists"
        cp "$IMAGE_EVIDENCE" "$EVIDENCE_LOG"
        {
            echo "VERDICT: blocked"
            echo "REASON: could not obtain archlinux:latest"
            echo "EVIDENCE: $EVIDENCE_LOG"
            echo "PINS:"
            sed 's/^/  /' "$PIN_FILE"
        } >"$VERDICT_FILE"
        exit 2
    fi
    IMAGE_SOURCE="cached-after-pull-failure"
    log "pull failed; using cached archlinux:latest"
fi
IMAGE_ID="$(docker image inspect archlinux:latest --format '{{.Id}}')"
printf 'IMAGE_SOURCE=%s\nIMAGE_ID=%s\nCOMPAT_PLATFORM=%s\n' \
    "$IMAGE_SOURCE" "$IMAGE_ID" "$COMPAT_PLATFORM" >>"$IMAGE_EVIDENCE"
log "image source: $IMAGE_SOURCE"

# ---------- Build a disposable GPG key inside the container ---------------
# Generate a throw-away unprotected ed25519 key INSIDE the container.
# This proves the pin's signing path against a real, fresh gpg keyring
# — never /keys, never the production FPR.
log "launching disposable Arch container for build + sign + repo-add"
CONTAINER_NAME="aur-build-spike-$$"

# We use the host's PIN_FILE as the contract; the container installs
# the matching aurutils version using the project's install helper.
# Everything else (key, repo, makepkg config) is built inline.
docker run --rm --platform "$COMPAT_PLATFORM" -i \
    --name "$CONTAINER_NAME" \
    --env "AUR_BUILD_INSTALL_AURUTILS=1" \
    --env "AURUTILS_PIN_FILE=/workspace/aurutils.version" \
    -v "${REPO_ROOT}:/workspace:ro" \
    --entrypoint /usr/bin/bash \
    archlinux:latest \
    -s >"$EVIDENCE_LOG" 2>&1 <<'INNER'
set -euo pipefail
printf 'INNER_STARTED=1\n'
PIN_FILE=/workspace/aurutils.version
WORKDIR=/tmp/spike
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/repo" "$WORKDIR/keys" \
         "$WORKDIR/cache" "$WORKDIR/work"
chmod 700 "$WORKDIR/keys"

# 1. Disable pacman sandbox (same fix the production Dockerfile
#    applies — the default seccomp profile blocks the alpm user's
#    landlock calls so every pacman transaction fails inside Docker).
sed -i "s/^#DisableSandbox/DisableSandbox/" /etc/pacman.conf

# 2. Bootstrap pacman keyring inside the container (archlinux:latest
#    ships the keyring files but no trust signatures applied). Same
#    step the production Dockerfile runs.
pacman-key --init >/dev/null 2>&1 || true
pacman-key --populate archlinux >/dev/null 2>&1 || true

# 3. Install base-devel + devtools + sudo so makepkg has a toolchain
#    and can drop to a non-root user. Yes, this hits the network.
#    The task forbids production key/repo/bigballs access, not
#    ephemeral container setup.
pacman -Syu --noconfirm >/dev/null
pacman -S --noconfirm --needed \
    base-devel devtools sudo pacutils perl-json-xs jq >/dev/null

# 3. Install pinned aurutils using the project helper. The helper
#    fetches the tarball, asserts SHA-256, and stages under
#    /usr/local/lib/aur-forge/aurutils.
AURUTILS_PIN_FILE="$PIN_FILE" \
AUR_BUILD_INSTALL_AURUTILS=1 \
AURUTILS_PIN_DEST=/usr/local/lib/aur-forge/aurutils \
bash /workspace/scripts/install-aurutils.sh
AUR_BIN=/usr/local/lib/aur-forge/aurutils/aur

# 4. Generate a throw-away ed25519 signing key (loopback pinentry,
#    empty passphrase). Never exported out of the container.
export GNUPGHOME="$WORKDIR/keys"
cat > "$WORKDIR/genkey.batch" <<EOF
%no-protection
Key-Type: EDDSA
Key-Curve: ed25519
Key-Usage: sign
Name-Real: aur-build-spike
Name-Email: spike@example.invalid
Name-Comment: aur-build compatibility spike
Expire-Date: 0
%commit
EOF
gpg --batch --pinentry-mode loopback --passphrase "" \
    --generate-key "$WORKDIR/genkey.batch" >/dev/null 2>&1
rm -f "$WORKDIR/genkey.batch"
gpg --batch --armor --export spike@example.invalid \
    > "$WORKDIR/public-key.asc"
FPR=$(gpg --list-secret-keys --with-colons spike@example.invalid \
        | awk -F: "/^fpr:/ {print \$10; exit}")
[ -n "$FPR" ] || { echo "FATAL: could not extract FPR" >&2; exit 1; }
echo "FPR=$FPR"

# 5. Build a split-package source tree. A single PKGBUILD emits two
#    package files so the spike covers aur-build's multi-file loop,
#    not only the one-file happy path. The pure-shell package has no
#    downloads.
PKG_MAIN=aur-build-spike-pkg
PKG_EXTRA=aur-build-spike-extra
mkdir -p "$WORKDIR/src"
# Quoted delimiter: $pkgdir belongs to makepkg's execution
# environment, not this harness shell (set -u would otherwise
# expand it while writing the file).
cat > "$WORKDIR/src/PKGBUILD" <<'EOF'
pkgbase=aur-build-spike
pkgname=(aur-build-spike-pkg aur-build-spike-extra)
pkgver=0.1.0
pkgrel=1
pkgdesc="aur-build compatibility spike"
arch=("any")
depends=()
source=()
build() { :; }
package_aur-build-spike-pkg() {
    install -Dm0644 /dev/null \
        "$pkgdir/usr/share/aur-build-spike-pkg/MARKER"
    printf 'spike-main\n' \
        > "$pkgdir/usr/share/aur-build-spike-pkg/MARKER"
}
package_aur-build-spike-extra() {
    install -Dm0644 /dev/null \
        "$pkgdir/usr/share/aur-build-spike-extra/MARKER"
    printf 'spike-extra\n' \
        > "$pkgdir/usr/share/aur-build-spike-extra/MARKER"
}
EOF

# makepkg refuses to run as root. Use the builder user we create.
useradd -m -s /bin/bash spikebuild >/dev/null 2>&1 || true
chown -R spikebuild:spikebuild "$WORKDIR/src"
cd "$WORKDIR/src"
sudo -u spikebuild makepkg --skippgpcheck --skipchecksums --nocheck \
    --noconfirm >/dev/null
ls -la "$WORKDIR/src"
mapfile -t PKGFILES < <(find "$WORKDIR/src" -maxdepth 1 \
    -type f -name '*.pkg.tar.zst' -print | sort)
[ "${#PKGFILES[@]}" -eq 2 ] \
    || { echo "FATAL: split PKGBUILD produced ${#PKGFILES[@]} files, expected 2" >&2; exit 1; }
printf 'MANUAL_PACKAGE=%s\n' "${PKGFILES[@]}"

# 6. Initialize two disposable pacman keyrings and trust only the
#    disposable key. Package signature verification must use pacman's
#    keyring, not GNUPGHOME, so each installation root gets its own.
init_pacman_keyring() {
    local dbpath="$1"
    mkdir -p "$dbpath"
    pacman-key --gpgdir "$dbpath/gnupg" --init >/dev/null 2>&1
    pacman-key --gpgdir "$dbpath/gnupg" \
        --add "$WORKDIR/public-key.asc" >/dev/null 2>&1
    pacman-key --gpgdir "$dbpath/gnupg" \
        --lsign-key "$FPR" >/dev/null 2>&1
}

# 7. ASCII-armored detached package signatures. Pacman requires the
#    detached signature to be named <package>.sig, regardless of
#    whether its contents are armored or binary. Build a throw-away
#    repo containing both split-package files, then install both with
#    pacman to prove acceptance of the armored format.
mkdir -p "$WORKDIR/repo-armored"
for pkgfile in "${PKGFILES[@]}"; do
    cp "$pkgfile" "$WORKDIR/repo-armored/"
    base=$(basename "$pkgfile")
    gpg --batch --yes --pinentry-mode loopback --passphrase "" \
        --detach-sign --armor \
        --output "$WORKDIR/repo-armored/${base}.sig" \
        "$WORKDIR/repo-armored/$base"
    gpg --batch --verify "$WORKDIR/repo-armored/${base}.sig" \
        "$WORKDIR/repo-armored/$base" >/dev/null 2>&1
done
(
    cd "$WORKDIR/repo-armored"
    repo-add -w --prevent-downgrade armored.db.tar.zst \
        -- ./*.pkg.tar.zst >/dev/null
)
cat > "$WORKDIR/pacman-armored.conf" <<EOF3
[options]
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
[armored]
Server = file://$WORKDIR/repo-armored
EOF3
mkdir -p "$WORKDIR/root-armored" "$WORKDIR/cache-armored"
init_pacman_keyring "$WORKDIR/db-armored"
pacman --config "$WORKDIR/pacman-armored.conf" \
    --root "$WORKDIR/root-armored" --dbpath "$WORKDIR/db-armored" \
    --gpgdir "$WORKDIR/db-armored/gnupg" \
    --cachedir "$WORKDIR/cache-armored" --noconfirm \
    -Sy armored/aur-build-spike-pkg armored/aur-build-spike-extra \
    >/dev/null
[ -s "$WORKDIR/root-armored/usr/share/aur-build-spike-pkg/MARKER" ]
[ -s "$WORKDIR/root-armored/usr/share/aur-build-spike-extra/MARKER" ]
echo "PACMAN_ARMORED_INSTALL=ok"

# 8. Binary detached package signatures. This is the format
#    aur build -S emits by default (--no-armor). Use a second repo and
#    a clean pacman root so this is an independent acceptance proof.
mkdir -p "$WORKDIR/repo-binary"
for pkgfile in "${PKGFILES[@]}"; do
    cp "$pkgfile" "$WORKDIR/repo-binary/"
    base=$(basename "$pkgfile")
    gpg --batch --yes --pinentry-mode loopback --passphrase "" \
        --detach-sign --no-armor \
        --output "$WORKDIR/repo-binary/${base}.sig" \
        "$WORKDIR/repo-binary/$base"
    gpg --batch --verify "$WORKDIR/repo-binary/${base}.sig" \
        "$WORKDIR/repo-binary/$base" >/dev/null 2>&1
done
(
    cd "$WORKDIR/repo-binary"
    repo-add -w --prevent-downgrade binary.db.tar.zst \
        -- ./*.pkg.tar.zst >/dev/null
)
cat > "$WORKDIR/pacman-binary.conf" <<EOF3
[options]
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
[binary]
Server = file://$WORKDIR/repo-binary
EOF3
mkdir -p "$WORKDIR/root-binary" "$WORKDIR/cache-binary"
init_pacman_keyring "$WORKDIR/db-binary"
pacman --config "$WORKDIR/pacman-binary.conf" \
    --root "$WORKDIR/root-binary" --dbpath "$WORKDIR/db-binary" \
    --gpgdir "$WORKDIR/db-binary/gnupg" \
    --cachedir "$WORKDIR/cache-binary" --noconfirm \
    -Sy binary/aur-build-spike-pkg binary/aur-build-spike-extra \
    >/dev/null
[ -s "$WORKDIR/root-binary/usr/share/aur-build-spike-pkg/MARKER" ]
[ -s "$WORKDIR/root-binary/usr/share/aur-build-spike-extra/MARKER" ]
echo "PACMAN_BINARY_INSTALL=ok"

# 8. aur build -S — the actual seam under test. Build the split
#    package via the project-owned aurutils wrapper, with the
#    configurable seams the task body names: --makepkg-conf,
#    --pacman-conf, --results, --no-sync, --prevent-downgrade,
#    --sign (-S).
#
#    We need writable makepkg.conf + pacman.conf files inside the
#    container. The repo starts empty so every package must be built.
rm -rf "$WORKDIR/repo"
mkdir -p "$WORKDIR/repo"
chown -R spikebuild:spikebuild "$WORKDIR/repo"

# Seed an empty database because pinned aurutils resolves the file://
# repo through its extensionless spike.db link before it starts the
# build. The database is unsigned at this point; aur build -S signs
# both it and its .files sibling when updating them.
(
    cd "$WORKDIR/repo"
    repo-add spike.db.tar.zst >/dev/null
)

cat > "$WORKDIR/makepkg.conf" <<EOF3
PACKAGER="aur-build-spike <spike@example.invalid>"
MAKEFLAGS="-j2"
COMPRESSZST=(zstd -c -z -q -T1 -)
EOF3
cat > "$WORKDIR/pacman.conf" <<EOF3
[options]
HoldPkg = pacman glibc
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
[core]
Include = /etc/pacman.d/mirrorlist
[extra]
Include = /etc/pacman.d/mirrorlist
[spike]
SigLevel = Required DatabaseOptional
Server = file://$WORKDIR/repo
EOF3

# aur build consumes directories from --arg-file. Using it avoids
# overloading -d (which means --database, not directory).
mkdir -p "$WORKDIR/src2"
cp "$WORKDIR/src/PKGBUILD" "$WORKDIR/src2/"
printf '%s\n' "$WORKDIR/src2" > "$WORKDIR/aur-build.queue"
# The direct signature probes ran gpg as root. Stop that throw-away
# agent before handing the same disposable keyring to spikebuild, then
# transfer ownership so aur build can start its own noninteractive
# agent without a cross-UID socket conflict.
gpgconf --kill gpg-agent >/dev/null 2>&1 || true
chown -R spikebuild:spikebuild \
    "$WORKDIR/src2" "$WORKDIR/repo" "$WORKDIR/keys" \
    "$WORKDIR/makepkg.conf" "$WORKDIR/pacman.conf" \
    "$WORKDIR/aur-build.queue"

set +e
AUR_GPG=/usr/bin/gpg \
AUR_MAKEPKG=/usr/bin/makepkg \
AUR_REPO_ADD=/usr/bin/repo-add \
AUR_DBROOT="$WORKDIR/repo" \
AUR_REPO=spike \
GNUPGHOME="$WORKDIR/keys" \
GPGKEY="$FPR" \
    sudo -u spikebuild \
        --preserve-env=AUR_GPG,AUR_MAKEPKG,AUR_REPO_ADD,AUR_DBROOT,AUR_REPO,GNUPGHOME,GPGKEY,PATH \
        "$AUR_BIN" build -S --no-sync --prevent-downgrade \
            --database spike \
            --makepkg-conf "$WORKDIR/makepkg.conf" \
            --pacman-conf "$WORKDIR/pacman.conf" \
            --results "$WORKDIR/aur-build.results" \
            --arg-file "$WORKDIR/aur-build.queue" \
            >/tmp/aur-build.out 2>&1
AUR_RC=$?
set -e
printf 'AUR_BUILD_RC=%s\n' "$AUR_RC"
tail -50 /tmp/aur-build.out >&2 || true
[ "$AUR_RC" -eq 0 ] \
    || { echo "FATAL: aur build -S exited $AUR_RC" >&2; exit 1; }

# 9. The results file must contain one build line for each split
#    package. Both package files and both binary signatures must exist.
[ -s "$WORKDIR/aur-build.results" ] \
    || { echo "FATAL: --results file is empty" >&2; exit 1; }
RESULT_COUNT=$(grep -c '^build:file://' "$WORKDIR/aur-build.results")
[ "$RESULT_COUNT" -eq 2 ] \
    || { echo "FATAL: results contain $RESULT_COUNT build lines, expected 2" >&2; exit 1; }
mapfile -t AUR_PKGS < <(find "$WORKDIR/repo" -maxdepth 1 \
    -type f -name 'aur-build-spike-*.pkg.tar.zst' -print | sort)
[ "${#AUR_PKGS[@]}" -eq 2 ] \
    || { echo "FATAL: aur build moved ${#AUR_PKGS[@]} packages, expected 2" >&2; exit 1; }
for pkgfile in "${AUR_PKGS[@]}"; do
    [ -s "${pkgfile}.sig" ] \
        || { echo "FATAL: signature missing for $pkgfile" >&2; exit 1; }
    gpg --batch --verify "${pkgfile}.sig" "$pkgfile" >/dev/null 2>&1 \
        || { echo "FATAL: aur build signature failed for $pkgfile" >&2; exit 1; }
done

# 10. aur build -S must create/update both repository databases and
#     sign them. repo-add maintains extensionless links.
[ -L "$WORKDIR/repo/spike.db" ]
[ -L "$WORKDIR/repo/spike.files" ]
[ -s "$WORKDIR/repo/spike.db.tar.zst" ]
[ -s "$WORKDIR/repo/spike.files.tar.zst" ]
[ -s "$WORKDIR/repo/spike.db.tar.zst.sig" ]
[ -s "$WORKDIR/repo/spike.files.tar.zst.sig" ]
gpg --batch --verify "$WORKDIR/repo/spike.db.tar.zst.sig" \
    "$WORKDIR/repo/spike.db.tar.zst" >/dev/null 2>&1
gpg --batch --verify "$WORKDIR/repo/spike.files.tar.zst.sig" \
    "$WORKDIR/repo/spike.files.tar.zst" >/dev/null 2>&1
echo "REPO_OK=1"

# 11. Verify downgrade prevention against the aur-build-produced db.
mkdir -p "$WORKDIR/older"
cat > "$WORKDIR/older/PKGBUILD" <<'EOF2'
pkgname=aur-build-spike-pkg
pkgver=0.0.1
pkgrel=1
pkgdesc="older spike"
arch=("any")
depends=()
source=()
package() { install -Dm0644 /dev/null "$pkgdir/OLD"; }
EOF2
chown -R spikebuild:spikebuild "$WORKDIR/older"
(
    cd "$WORKDIR/older"
    sudo -u spikebuild makepkg --skippgpcheck --skipchecksums \
        --nocheck --noconfirm >/dev/null
)
OLDER_PKG=$(find "$WORKDIR/older" -maxdepth 1 \
    -type f -name '*.pkg.tar.zst' -print -quit)
cp "$OLDER_PKG" "$WORKDIR/repo/"
(
    cd "$WORKDIR/repo"
    repo-add -w --prevent-downgrade --sign --key "$FPR" \
        spike.db.tar.zst "$(basename "$OLDER_PKG")" >/dev/null 2>&1
)
if bsdtar -xOf "$WORKDIR/repo/spike.db.tar.zst" \
        '*/desc' 2>/dev/null | grep -q '^0\.0\.1-1$'; then
    echo "FATAL: --prevent-downgrade indexed 0.0.1-1" >&2
    exit 1
fi
echo "DOWNGRADE_OK=1"

# 12. Install both aur-build results from the signed file:// repo.
#     Import and locally trust only the disposable public key.
INSTALL_ROOT="$WORKDIR/install-root"
mkdir -p "$INSTALL_ROOT" "$WORKDIR/pacman-db" "$WORKDIR/pacman-cache"
pacman-key --gpgdir "$WORKDIR/pacman-db/gnupg" --init >/dev/null 2>&1
pacman-key --gpgdir "$WORKDIR/pacman-db/gnupg" \
    --add "$WORKDIR/public-key.asc" >/dev/null 2>&1
pacman-key --gpgdir "$WORKDIR/pacman-db/gnupg" \
    --lsign-key "$FPR" >/dev/null 2>&1
# The downgrade fixture is deliberately untrusted and not indexed;
# remove it before pacman fetches by package name.
rm -f "$OLDER_PKG"
pacman --config "$WORKDIR/pacman.conf" \
      --root "$INSTALL_ROOT" --dbpath "$WORKDIR/pacman-db" \
      --gpgdir "$WORKDIR/pacman-db/gnupg" \
      --cachedir "$WORKDIR/pacman-cache" --noconfirm \
      -Sy spike/aur-build-spike-pkg spike/aur-build-spike-extra \
      >/dev/null
[ -s "$INSTALL_ROOT/usr/share/aur-build-spike-pkg/MARKER" ]
[ -s "$INSTALL_ROOT/usr/share/aur-build-spike-extra/MARKER" ]
echo "PACMAN_INSTALL=ok"
echo "SPLIT_PACKAGE_COUNT=2"
echo "SUMMARY: all checks passed"
INNER
DOCKER_RC=$?
{
    printf '\n--- image provenance ---\n'
    cat "$IMAGE_EVIDENCE"
} >>"$EVIDENCE_LOG"

# Capture output for the verdict. The container --rm flag means the
# filesystem inside is gone — but the log is in TMPROOT on the host.
log "container exited with rc=$DOCKER_RC"

if [[ "$DOCKER_RC" -ne 0 ]]; then
    log "compatibility check failed inside the container — see $EVIDENCE_LOG"
    {
        echo "VERDICT: blocked"
        echo "REASON: container exit rc=$DOCKER_RC"
        echo "EVIDENCE: $EVIDENCE_LOG"
        echo "PINS:"
        sed 's/^/  /' "$PIN_FILE"
        echo "---- last 60 lines of evidence ----"
        tail -60 "$EVIDENCE_LOG" 2>/dev/null || echo "(no evidence)"
    } >"$VERDICT_FILE"
    exit 2
fi

# ---------- Parse the container log + emit verdict ------------------------
# The container prints several KEY=value tokens on stdout/stderr. We
# lift them out of the evidence log to populate the verdict doc.
evidence_value() {
    local key="$1"
    grep -E "^${key}=" "$EVIDENCE_LOG" 2>/dev/null \
        | tail -1 | cut -d= -f2- || true
}

PIN_VERSION="$(grep -E '^AURUTILS_VERSION=' "$PIN_FILE" \
                | head -1 | cut -d= -f2)"
PIN_COMMIT="$(grep -E '^AURUTILS_COMMIT=' "$PIN_FILE" \
                | head -1 | cut -d= -f2)"
PIN_SHA="$(grep -E '^AURUTILS_SHA256=' "$PIN_FILE" \
                | head -1 | cut -d= -f2)"
DETECTED_FPR="$(evidence_value FPR)"
IMAGE_SOURCE_RESULT="$(evidence_value IMAGE_SOURCE)"
IMAGE_ID_RESULT="$(evidence_value IMAGE_ID)"
COMPAT_PLATFORM_RESULT="$(evidence_value COMPAT_PLATFORM)"
PACMAN_ARMORED="$(evidence_value PACMAN_ARMORED_INSTALL)"
PACMAN_BINARY="$(evidence_value PACMAN_BINARY_INSTALL)"
REPO_OK="$(evidence_value REPO_OK)"
DOWNGRADE_OK="$(evidence_value DOWNGRADE_OK)"
AUR_BUILD_RC="$(evidence_value AUR_BUILD_RC)"
PACMAN_INSTALL="$(evidence_value PACMAN_INSTALL)"
SPLIT_COUNT="$(evidence_value SPLIT_PACKAGE_COUNT)"
SUMMARY="$(grep -E '^SUMMARY: ' "$EVIDENCE_LOG" 2>/dev/null \
    | tail -1 | sed 's/^SUMMARY: //' || true)"

# This is compatible with changes rather than a drop-in replacement:
# aur build emits binary package signatures, must run as a writable
# unprivileged user, and needs a configured + seeded file:// repo.
if [[ "$PACMAN_ARMORED" == "ok" && "$PACMAN_BINARY" == "ok" \
   && "$REPO_OK" == "1" && "$DOWNGRADE_OK" == "1" \
   && "$AUR_BUILD_RC" == "0" && "$PACMAN_INSTALL" == "ok" \
   && "$SPLIT_COUNT" == "2" && "$SUMMARY" == "all checks passed" ]]; then
    VERDICT_KIND="compatible with changes"
else
    VERDICT_KIND="blocked"
fi

{
    echo "VERDICT: $VERDICT_KIND"
    echo "PIN_VERSION: $PIN_VERSION"
    echo "PIN_COMMIT:  $PIN_COMMIT"
    echo "PIN_SHA256:  $PIN_SHA"
    echo "IMAGE_SOURCE: $IMAGE_SOURCE_RESULT"
    echo "IMAGE_ID: $IMAGE_ID_RESULT"
    echo "COMPAT_PLATFORM: $COMPAT_PLATFORM_RESULT"
    echo "DETECTED_FPR (disposable): $DETECTED_FPR"
    echo "PACMAN_ARMORED_INSTALL: $PACMAN_ARMORED"
    echo "PACMAN_BINARY_INSTALL: $PACMAN_BINARY"
    echo "REPO_ADD_OK: $REPO_OK"
    echo "DOWNGRADE_REJECTED: $DOWNGRADE_OK"
    echo "AUR_BUILD_RC: $AUR_BUILD_RC"
    echo "PACMAN_INSTALL: $PACMAN_INSTALL"
    echo "SPLIT_PACKAGE_COUNT: $SPLIT_COUNT"
    echo "SUMMARY: $SUMMARY"
} >"$VERDICT_FILE"

log "verdict: $VERDICT_KIND"
log "see $VERDICT_FILE for the full evidence"
case "$VERDICT_KIND" in
    compatible) exit 0 ;;
    "compatible with changes") exit 0 ;;
    blocked) exit 2 ;;
    *) die "internal: unknown verdict kind $VERDICT_KIND" ;;
esac

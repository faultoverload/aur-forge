#!/usr/bin/env bash
# aur-forge init — generates the GPG signing key (once) and seeds an empty
# repo so clients can fetch the pubkey via pacman. Idempotent: re-running
# on an existing keyring is a no-op.
set -euo pipefail

REPO_NAME="${REPO_NAME:-custom}"
REPO_OWNER="${REPO_OWNER:-faultoverload}"
REPO_EMAIL="${REPO_EMAIL:-woodsyx@gmail.com}"
GPG_KEY_NAME="${GPG_KEY_NAME:-aur-forge}"
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"   # empty = unprotected key (homelab OK)

export GNUPGHOME="/keys"
mkdir -p /keys /repo /cache
chmod 700 /keys

KEY_FPR_FILE="/keys/trusted-key.fpr"

# If we already have a signing key, just re-ensure the repo skeleton.
if [[ -s "$KEY_FPR_FILE" ]] && gpg --list-secret-keys "$GPG_KEY_NAME" >/dev/null 2>&1; then
    echo "[init] existing key found:"
    gpg --list-secret-keys "$GPG_KEY_NAME"
else
    echo "[init] generating new GPG signing key (no passphrase — homelab use)"
    # Unattended keygen: batch mode + empty passphrase via loopback pinentry.
    # NOTE: don't use --quick-gen-key with "ed25519" — GnuPG 2.4.x returns
    # "Unknown elliptic curve" because ed25519 isn't registered as a
    # standalone curve name in the parser. The batch-file form
    # (Key-Type: EDDSA + Key-Curve: ed25519) is the documented and
    # working spec.
    export PINENTRY_USER_DATA="loopback"
    cat > /tmp/gen-key.batch <<EOF
%no-protection
Key-Type: EDDSA
Key-Curve: ed25519
Key-Usage: sign
Name-Real: ${GPG_KEY_NAME}
Name-Email: ${REPO_EMAIL}
Name-Comment: ${REPO_OWNER}
Expire-Date: 0
%commit
EOF
    gpg --batch --pinentry-mode loopback --passphrase '' \
        --generate-key /tmp/gen-key.batch
    rm -f /tmp/gen-key.batch
    FPR="$(gpg --list-secret-keys --with-colons "$GPG_KEY_NAME" | awk -F: '/^fpr:/ {print $10; exit}')"
    echo "$FPR" > "$KEY_FPR_FILE"
    echo "[init] generated key, fingerprint: $FPR"
fi

# Always re-export the pubkey — it's what clients import.
gpg --export --armor "${REPO_EMAIL}" > /keys/aur-forge.pub
chmod 0644 /keys/aur-forge.pub

# systemd-nspawn (called by arch-nspawn inside extra-x86_64-build)
# refuses to start without /etc/machine-id. archlinux:latest doesn't
# ship one. Idempotent: systemd-machine-id-setup is a no-op if the
# file already exists.
[[ -f /etc/machine-id ]] || systemd-machine-id-setup

# Expose the pubkey through darkhttpd's served root (/repo). darkhttpd
# is rooted at /repo and cannot serve /keys directly because /keys is a
# separate bind mount; symlinking the pubkey into the repo tree lets
# clients fetch https://aur-forge.gateslab.win/keys/aur-forge.pub for
# `pacman-key --add` and pacman-key --lsign. The /repo mount is RW in
# the compose spec so this symlink survives across runs. We point at
# /keys/aur-forge.pub (the source of truth) rather than copy, so key
# rotations are reflected immediately on the next init.
mkdir -p "/repo/keys"
ln -sf /keys/aur-forge.pub "/repo/keys/aur-forge.pub"

# Seed the repo directory. Do NOT touch .db / .files placeholders —
# repo-add creates them on the first real build, and a 0-byte .db
# served to clients will cause pacman to error parsing it. darkhttpd
# runs with --no-listing so the empty directory is harmless.

# ---------------------------------------------------------------------
# Bootstrap the devtools chroot the first time the container starts.
# ---------------------------------------------------------------------
# extra-x86_64-build (called by build.sh) refuses to run unless
# /var/lib/archbuild/extra-x86_64/root already looks like an Arch
# chroot. On first invocation it tries to populate that directory by
# calling `pacman -Sy` inside a `unshare --fork --pid` namespace. In a
# Docker container that namespace breaks the GPG signature path: every
# package comes back with "missing required signature" because the
# gpg-agent socket / keyring files are unreachable from the namespaced
# process. Verified locally — `pacstrap` (which uses the same unshare)
# fails the same way; direct `pacman -Sy -r` without unshare works.
#
# Workaround: bootstrap the chroot ourselves using plain `pacman -Sy
# -r`, which doesn't enter a namespace and so keeps the keyring
# reachable. After this populates /var/lib/archbuild/extra-x86_64/root,
# extra-x86_64-build sees a valid chroot on subsequent calls and skips
# its own (broken) bootstrap. This is idempotent: if the chroot is
# already populated, we no-op.
# ---------------------------------------------------------------------
CHROOT_ROOT="/var/lib/archbuild/extra-x86_64/root"
if [[ ! -f "${CHROOT_ROOT}/usr/bin/pacman" ]]; then
    echo "[init] bootstrapping devtools chroot at ${CHROOT_ROOT}"
    # Pacstrap's temp pacman.conf tweaks DownloadUser (the alpm
    # download sandbox) — Docker's default seccomp profile blocks the
    # syscalls it needs. Mirror that tweak here so the bootstrapped
    # chroot has the same setting pacstrap would have produced.
    TMP_PC="$(mktemp /tmp/pacman.conf.XXXX)"
    cp /etc/pacman.conf "${TMP_PC}"
    sed -i 's/^DownloadUser/#&/' "${TMP_PC}"
    mkdir -p "${CHROOT_ROOT}/var/lib/pacman" \
             "${CHROOT_ROOT}/var/cache/pacman/pkg"
    pacman -Sy --noconfirm \
        -r "${CHROOT_ROOT}" \
        -b "${CHROOT_ROOT}/var/lib/pacman" \
        --cachedir="${CHROOT_ROOT}/var/cache/pacman/pkg/" \
        --config="${TMP_PC}" \
        --disable-sandbox \
        base base-devel >/tmp/init-chroot.log 2>&1 \
      || { echo "[init] chroot bootstrap failed — see /tmp/init-chroot.log"; tail -20 /tmp/init-chroot.log; rm -f "${TMP_PC}"; exit 1; }
    rm -f "${TMP_PC}"
    # arch-nspawn sanity-checks for this marker file; without it every
    # extra-x86_64-build dies with "'root' does not appear to be an
    # Arch chroot." even though the directory is fully populated.
    # CHROOT_VERSION is hardcoded in devtools' lib/archroot.sh — keep
    # it in sync if devtools ever bumps it.
    echo "v6" > "${CHROOT_ROOT}/.arch-chroot"
    echo "[init] chroot ready."
else
    echo "[init] chroot already populated at ${CHROOT_ROOT}"
    # Ensure the .arch-chroot marker exists even on pre-existing
    # chroots (e.g. one bootstrapped by older init.sh that didn't
    # write the marker, or a chroot copied in from elsewhere).
    if [[ ! -f "${CHROOT_ROOT}/.arch-chroot" ]]; then
        echo "v6" > "${CHROOT_ROOT}/.arch-chroot"
        echo "[init] wrote missing .arch-chroot marker"
    fi
fi

echo "[init] ready."
echo "       pubkey: /keys/aur-forge.pub"
echo "       repo:   /repo/${REPO_NAME}.x86_64/"
echo "       Add to client /etc/pacman.conf:"
echo "         [${REPO_NAME}]"
echo "         SigLevel = Required TrustAll"
echo "         Server = https://aur-forge.gateslab.win/repo"

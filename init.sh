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

echo "[init] ready."
echo "       pubkey: /keys/aur-forge.pub"
echo "       repo:   /repo/${REPO_NAME}.x86_64/"
echo "       Add to client /etc/pacman.conf:"
echo "         [${REPO_NAME}]"
echo "         SigLevel = Required TrustAll"
echo "         Server = https://aur-forge.gateslab.win/repo"

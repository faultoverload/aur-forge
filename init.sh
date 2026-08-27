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
        --quick-gen-key "${GPG_KEY_NAME} ed25519 sign never" \
        "${REPO_EMAIL}"
    # Some gpg versions don't accept the combined UID spec above; fall back.
    if ! gpg --list-secret-keys "$GPG_KEY_NAME" >/dev/null 2>&1; then
        gpg --batch --pinentry-mode loopback --generate-key /tmp/gen-key.batch
    fi
    FPR="$(gpg --list-secret-keys --with-colons "$GPG_KEY_NAME" | awk -F: '/^fpr:/ {print $10; exit}')"
    echo "$FPR" > "$KEY_FPR_FILE"
    echo "[init] generated key, fingerprint: $FPR"
fi

# Always re-export the pubkey — it's what clients import.
gpg --export --armor "${REPO_EMAIL}" > /keys/aur-forge.pub
chmod 0644 /keys/aur-forge.pub

# Seed the repo directory + initial db file if absent. The .db.tar.zst
# file gets re-created by repo-add on first build; this just makes the
# served path exist for clients.
mkdir -p "/repo/${REPO_NAME}.x86_64"
touch "/repo/${REPO_NAME}.x86_64/${REPO_NAME}.db"
touch "/repo/${REPO_NAME}.x86_64/${REPO_NAME}.files"

echo "[init] ready."
echo "       pubkey: /keys/aur-forge.pub"
echo "       repo:   /repo/${REPO_NAME}.x86_64/"
echo "       Add to client /etc/pacman.conf:"
echo "         [${REPO_NAME}]"
echo "         SigLevel = Required TrustAll"
echo "         Server = https://aur-forge.gateslab.win/repo"

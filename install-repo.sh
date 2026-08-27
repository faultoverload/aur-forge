#!/usr/bin/env bash
# install-repo.sh — client-side bootstrap for the aur-forge custom repo.
#
# Run this on any Arch machine that should pull packages from your
# aur-forge instance. Imports the GPG pubkey, writes the pacman.conf
# stanza, and refreshes the package database.
#
# Usage:
#   curl -fsSL https://aur-forge.gateslab.win/keys/aur-forge.pub -o /tmp/aur-forge.pub
#   sudo ./install-repo.sh https://aur-forge.gateslab.win
#
# Or with defaults (aur-forge.gateslab.win):
#   sudo ./install-repo.sh
set -euo pipefail

REPO_URL="${1:-https://aur-forge.gateslab.win}"
REPO_NAME="${REPO_NAME:-custom}"
PACMAN_CONF="${PACMAN_CONF:-/etc/pacman.conf}"

[[ $EUID -eq 0 ]] || { echo "Must run as root (use sudo)." >&2; exit 1; }

# 1. Import the repo pubkey into pacman's keyring.
KEY_URL="${REPO_URL%/}/keys/aur-forge.pub"
echo "==> Fetching repo key from ${KEY_URL}"
TMPKEY="$(mktemp)"
trap 'rm -f "$TMPKEY"' EXIT
curl -fsSL "$KEY_URL" -o "$TMPKEY"

# Locate the key fingerprint by importing into a throwaway keyring first,
# then signing it locally trusted, then merging into pacman-key. This is
# the recommended pattern from the Arch wiki.
TMPHOME="$(mktemp -d)"
trap 'rm -rf "$TMPKEY" "$TMPHOME"' EXIT
chmod 700 "$TMPHOME"
export GNUPGHOME="$TMPHOME"
gpg --import "$TMPKEY" >/dev/null
FPR="$(gpg --list-keys --with-colons --import-options show-only \
        --import "$TMPKEY" 2>/dev/null \
        | awk -F: '/^fpr:/ {print $10; exit}')"
[[ -n "$FPR" ]] || { echo "Could not parse key fingerprint" >&2; exit 1; }
unset GNUPGHOME
echo "==> Key fingerprint: $FPR"

pacman-key --recv-keys "$FPR" 2>/dev/null || \
    pacman-key --add "$TMPKEY"
# Trust ultimately — this is your own repo key.
echo -e "5\ny\n" | pacman-key --lsign-key "$FPR" >/dev/null 2>&1 || true

# 2. Write the pacman.conf stanza (idempotent).
STANZA_START="### >>> aur-forge >>>"
STANZA_END="### <<< aur-forge <<<"
if grep -q "$STANZA_START" "$PACMAN_CONF"; then
    echo "==> Stanza already present in $PACMAN_CONF, refreshing"
    # Remove old stanza then re-add.
    sed -i "/$STANZA_START/,/$STANZA_END/d" "$PACMAN_CONF"
fi

cat >> "$PACMAN_CONF" <<EOF

$STANZA_START
[${REPO_NAME}]
SigLevel = Required TrustAll
Server = ${REPO_URL%/}/repo/${REPO_NAME}.x86_64
$STANZA_END
EOF

echo "==> Added [${REPO_NAME}] to $PACMAN_CONF"

# 3. Refresh the package database.
echo "==> Running pacman -Sy"
pacman -Sy "${REPO_NAME}"

echo
echo "Done. Try:  pacman -Ss ^${REPO_NAME}/"
echo "or:        pacman -S ${REPO_NAME}/<package>"

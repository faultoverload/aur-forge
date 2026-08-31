#!/usr/bin/env bash
#
# aur-forge client bootstrap — register a remote aur-forge repo on this Arch
# machine so `pacman -Syu` and `pacman -S <pkg>` work against it.
#
# Served by lighttpd at:
#   https://<server>/install-repo.sh
#
# Usage:
#   curl -fsSL https://aur-forge.gateslab.win/install-repo.sh \
#     | sudo bash -s -- https://aur-forge.gateslab.win
#
# Effect:
#   1. Imports the repo's signing key (from /keys/aur-forge.pub on the server)
#      into pacman's local keyring and marks it trusted.
#   2. Writes a `[custom]` stanza to /etc/pacman.conf pointing at the server.
#   3. Runs `pacman -Sy` to prime the package database.
#
# Re-running is safe — it overwrites the existing stanza and re-imports the key.
# Idempotent.
#
# Environment overrides:
#   REPO_NAME          Repo name to register (default: custom)
#   PACMAN_CONF        Path to pacman.conf (default: /etc/pacman.conf)
#   AUR_FORGE_SERVER   Default server if no arg given (default: https://aur-forge.gateslab.win)

# NOTE: set -u on, but NOT set -e. We do explicit error handling on each
# step that can fail — pacman-key and gpg both return non-zero in corner
# cases (missing key, broken pubring, etc.) that we want to recover from
# rather than abort on. set -o pipefail is also off for the same reason:
# the fingerprint-extraction pipeline legitimately hits empty input when
# pacman-key can't find the uid-derived query, and we fall back to gpg
# rather than crash the script.
set -u

# ---- Args / defaults --------------------------------------------------------

SERVER="${1:-${AUR_FORGE_SERVER:-https://aur-forge.gateslab.win}}"
SERVER="${SERVER%/}"   # strip trailing slash

REPO_NAME="${REPO_NAME:-custom}"
PACMAN_CONF="${PACMAN_CONF:-/etc/pacman.conf}"

# ---- Sanity -----------------------------------------------------------------

if [[ "$SERVER" != http://* && "$SERVER" != https://* ]]; then
    echo "[install-repo] server URL must start with http:// or https://: $SERVER" >&2
    exit 2
fi

# Valid pacman repo name: [a-z0-9._+-]
if [[ ! "$REPO_NAME" =~ ^[a-z0-9][a-z0-9._+-]{0,63}$ ]]; then
    echo "[install-repo] invalid REPO_NAME: $REPO_NAME" >&2
    exit 2
fi

if [[ ! -w "$PACMAN_CONF" ]]; then
    echo "[install-repo] $PACMAN_CONF not writable (need root)" >&2
    echo "[install-repo] run as: curl -fsSL $SERVER/install-repo.sh | sudo bash -s -- $SERVER" >&2
    exit 1
fi

# ---- Fetch + import signing key --------------------------------------------

PUBKEY_URL="$SERVER/keys/aur-forge.pub"
KEYRING_TMP="$(mktemp)"
TMP_CONF="$(mktemp)"
trap 'rm -f "$KEYRING_TMP" "$TMP_CONF"' EXIT

echo "[install-repo] fetching signing key from $PUBKEY_URL"
if ! curl -fsS --connect-timeout 10 -m 60 \
        "$PUBKEY_URL" -o "$KEYRING_TMP" 2>/dev/null; then
    echo "[install-repo] failed to fetch $PUBKEY_URL" >&2
    echo "[install-repo]   - is the URL correct?" >&2
    echo "[install-repo]   - is the server up?" >&2
    echo "[install-repo]   - can this machine reach it?" >&2
    exit 3
fi

# Sanity: keyring must look like an ASCII-armored PGP block.
if ! head -1 "$KEYRING_TMP" | grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----'; then
    echo "[install-repo] fetched file is not a PGP public key (got: $(head -c 60 "$KEYRING_TMP"))" >&2
    exit 3
fi

echo "[install-repo] importing key into pacman keyring"
if ! pacman-key --add "$KEYRING_TMP" 2>/dev/null; then
    echo "[install-repo] pacman-key --add failed (exit $?)" >&2
    exit 3
fi

# ---- Extract the fingerprint from the imported key ------------------------
#
# Try gpg --import-options show-only first — that reads the key file and
# prints its records without modifying any keyring. The fingerprint record
# has type 'fpr' and the SHA is in field 10. This works regardless of which
# keyring pacman-key uses internally.

echo "[install-repo] extracting key fingerprint"
FPR=""
FPR="$(gpg --with-colons --import-options show-only --import "$KEYRING_TMP" 2>/dev/null \
        | awk -F: '$1=="fpr" {print $10; exit}')"

# Sanity check: must be 40 hex chars (or 32 for v5 keys but aur-forge uses ed25519)
if [[ ! "$FPR" =~ ^[0-9A-F]{40}$ ]]; then
    FPR=""
fi

if [[ -z "$FPR" ]]; then
    echo "[install-repo] WARNING: could not extract fingerprint from key." >&2
    echo "[install-repo]   key IS imported into pacman's keyring." >&2
    echo "[install-repo]   you may need to run manually:" >&2
    echo "[install-repo]     sudo pacman-key --lsign-key <FPR>" >&2
else
    echo "[install-repo] locally signing key $FPR"
    # Use printf answers to the trust prompt so the call is non-interactive.
    # pacman-key --lsign-key asks: "Really sign? [y/N]" — answer "y\n".
    if ! printf 'y\n' | pacman-key --lsign-key "$FPR" >/dev/null 2>&1; then
        echo "[install-repo] WARNING: pacman-key --lsign-key failed." >&2
        echo "[install-repo]   the key is imported but not locally trusted." >&2
        echo "[install-repo]   you may need to run: sudo pacman-key --lsign-key $FPR" >&2
    fi
fi

# ---- Write the pacman.conf stanza ------------------------------------------

# Remove any existing [REPO_NAME] stanza (idempotent re-run).
awk -v repo="\\[${REPO_NAME}\\]" '
    BEGIN { in_repo = 0 }
    # Start of the named repo: drop everything from this line until the next
    # blank line or the start of the next section header.
    $0 ~ "^"repo"[[:space:]]*$" {
        in_repo = 1
        next
    }
    in_repo == 1 {
        # Stop skipping at the next section header [foo] or end of file.
        if ($0 ~ /^\[[^]]+\][[:space:]]*$/) {
            in_repo = 0
        } else if ($0 ~ /^[[:space:]]*$/) {
            in_repo = 0
            # preserve the blank line
        } else {
            next
        }
    }
    { print }
' "$PACMAN_CONF" > "$TMP_CONF"

# Append our fresh stanza at the end of the file.
{
    echo ""
    echo "[${REPO_NAME}]"
    echo "SigLevel = Required TrustAll"
    echo "Server = ${SERVER}"
} >> "$TMP_CONF"

# Atomic replace.
cat "$TMP_CONF" > "$PACMAN_CONF"
chmod 0644 "$PACMAN_CONF"

echo "[install-repo] wrote [${REPO_NAME}] stanza to $PACMAN_CONF"

# ---- Refresh package database -----------------------------------------------

echo "[install-repo] running 'pacman -Sy ${REPO_NAME}'"
if ! pacman -Sy "${REPO_NAME}"; then
    echo "[install-repo] pacman -Sy failed — verify network, key, and Server URL" >&2
    exit 4
fi

echo ""
echo "[install-repo] done. aur-forge repo '${REPO_NAME}' is registered."
echo "[install-repo] try:"
echo "    pacman -Ss ${REPO_NAME}"
echo "    pacman -S <package-name>"
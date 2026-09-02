#!/usr/bin/env bash
# Functional repo-add safety fixture.
#
# Run directly on Arch, or in archlinux:latest as invoked by
# tests/run-tests.sh. REPO_ADD_TEST_TMP may point at a caller-owned
# scratch directory; otherwise the container's temporary filesystem is
# used and discarded with the container.
set -euo pipefail

for cmd in repo-add bsdtar gpg readlink; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "missing required test command: $cmd" >&2
        exit 2
    }
done

FIXTURE_TMP="${REPO_ADD_TEST_TMP:-$(mktemp -d)}"
GNUPGHOME="${FIXTURE_TMP}/gnupg"
REPO_DIR="${FIXTURE_TMP}/repo"
export GNUPGHOME
install -d -m 700 "$GNUPGHOME"
install -d "$REPO_DIR"

# Generate an unprotected signing key in the disposable keyring.
gpg --batch --passphrase '' --quick-gen-key \
    "aur-forge repo-add fixture <fixture@example.invalid>" rsa2048 sign 0 \
    >/dev/null 2>&1
FPR="$(gpg --batch --with-colons --list-secret-keys \
    | awk -F: '$1=="fpr" {print $10; exit}')"
[[ -n "$FPR" ]]

make_fixture_package() {
    local package_file="$1" version="$2"
    local stage
    stage="$(mktemp -d "${FIXTURE_TMP}/stage.XXXXXX")"
    cat > "${stage}/.PKGINFO" <<EOF
pkgname = fixture-pkg
pkgbase = fixture-pkg
pkgver = ${version}
pkgdesc = repo-add safety fixture
url = https://example.invalid
builddate = 1
packager = aur-forge tests
size = 0
arch = any
EOF
    bsdtar --zstd -cf "$package_file" -C "$stage" .PKGINFO
}

newer_pkg="${REPO_DIR}/fixture-pkg-2.0.0-1-any.pkg.tar.zst"
older_pkg="${REPO_DIR}/fixture-pkg-1.0.0-1-any.pkg.tar.zst"
make_fixture_package "$newer_pkg" "2.0.0-1"
make_fixture_package "$older_pkg" "1.0.0-1"

cd "$REPO_DIR"
repo-add -w --prevent-downgrade --sign --key "$FPR" \
    fixture.db.tar.zst -- "$newer_pkg" >/dev/null

# --sign writes a detached signature that verifies against the
# generated fixture key.
[[ -s fixture.db.tar.zst.sig ]]
gpg --batch --verify fixture.db.tar.zst.sig fixture.db.tar.zst \
    >/dev/null 2>&1

# repo-add's rotate_db() maintains both extensionless links. These
# assertions prove build.sh does not need manual fallback copies.
[[ -L fixture.db ]]
[[ "$(readlink fixture.db)" == "fixture.db.tar.zst" ]]
[[ -L fixture.files ]]
[[ "$(readlink fixture.files)" == "fixture.files.tar.zst" ]]

# A lexically later glob entry must not downgrade an indexed package.
# repo-add reports a skipped downgrade as success, so inspect the
# resulting database rather than relying on its exit status.
repo-add -w --prevent-downgrade --sign --key "$FPR" \
    fixture.db.tar.zst -- "$older_pkg" >/dev/null

desc_member="$(bsdtar -tf fixture.db.tar.zst \
    | awk '/\/desc$/ {print; exit}')"
[[ -n "$desc_member" ]]
indexed_version="$(bsdtar -xOf fixture.db.tar.zst "$desc_member" \
    | awk '/^%VERSION%$/ {getline; print; exit}')"
[[ "$indexed_version" == "2.0.0-1" ]]

# Re-adding the current version remains safe and successful.
repo-add -w --prevent-downgrade --sign --key "$FPR" \
    fixture.db.tar.zst -- "$newer_pkg" >/dev/null

echo "repo-add safety fixture passed"

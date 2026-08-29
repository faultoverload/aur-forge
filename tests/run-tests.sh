#!/usr/bin/env bash
# aur-forge test suite — exercises the diff classifier and approval store.
# Run with `bash tests/run-tests.sh` from the repo root. Returns non-zero
# if any test fails. Tests are self-contained: they use /tmp/aur-forge-tests
# as scratch and don't touch the real /approvals directory.
set -euo pipefail

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

# Tell approval-store.sh to use the test dir.
export APPROVALS_DIR="${TEST_TMP}/approvals"
mkdir -p "$APPROVALS_DIR"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${REPO_ROOT}/scripts"

PASS=0
FAIL=0
FAILED_TESTS=()

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); echo "  FAIL: $1" >&2; }
assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$name (got '$actual')"
    else
        fail "$name (expected '$expected', got '$actual')"
    fi
}

echo "=== approval-store.sh ==="
# shellcheck disable=SC1090
source "${SCRIPTS}/approval-store.sh"

# 1. Empty store → read_approval returns 1.
if read_approval "ghost" >/dev/null 2>&1; then
    fail "read_approval on missing pkg should fail"
else
    pass "read_approval on missing pkg returns non-zero"
fi

# 2. approval_exists on missing pkg returns 1.
if approval_exists "ghost"; then
    fail "approval_exists on missing pkg should be false"
else
    pass "approval_exists on missing pkg returns false"
fi

# 3. write_approval creates file with correct schema.
write_approval "hello-pkg" \
    "abc123" "def456" "1.0.0-1" \
    "null" "false" "false" "test notes"
if [[ ! -s "${APPROVALS_DIR}/hello-pkg.json" ]]; then
    fail "write_approval didn't create file"
else
    pass "write_approval created approval file"
    schema_pkg="$(jq -r '.package' "${APPROVALS_DIR}/hello-pkg.json")"
    assert_eq "$schema_pkg" "hello-pkg"  "stored .package field"
    schema_sha="$(jq -r '.pkgbuild_sha256' "${APPROVALS_DIR}/hello-pkg.json")"
    assert_eq "$schema_sha" "abc123"     "stored .pkgbuild_sha256 field"
    schema_issue="$(jq -r '.issue' "${APPROVALS_DIR}/hello-pkg.json")"
    assert_eq "$schema_issue" "null"     "stored .issue field (null)"
    schema_blocklist="$(jq -r '.blocklist_match_at_approval' "${APPROVALS_DIR}/hello-pkg.json")"
    assert_eq "$schema_blocklist" "false" "stored .blocklist_match_at_approval field"
fi

# 4. approval_field returns correct value.
field_val="$(approval_field "hello-pkg" srcinfo_sha256)"
assert_eq "$field_val" "def456" "approval_field returns srcinfo_sha256"

# 5. list_approved emits package names.
approved_list="$(list_approved | sort)"
assert_eq "$(printf '%s\n' "$approved_list")" "hello-pkg" "list_approved emits correct names"

# 6. write_approval is atomic — concurrent writes don't corrupt.
(
    for i in 1 2 3 4 5; do
        write_approval "race-pkg-${i}" "sha$i" "src$i" "1.$i-1" "null" "false" "false" "race-$i" &
    done
    wait
)
all_valid=1
for i in 1 2 3 4 5; do
    if ! jq -e . "${APPROVALS_DIR}/race-pkg-${i}.json" >/dev/null 2>&1; then
        all_valid=0
    fi
done
if [[ "$all_valid" -eq 1 ]]; then
    pass "concurrent write_approval leaves valid JSON files"
else
    fail "concurrent write_approval corrupted at least one JSON"
fi

# 7. remove_approval deletes the record.
remove_approval "hello-pkg"
if approval_exists "hello-pkg"; then
    fail "remove_approval didn't delete record"
else
    pass "remove_approval deletes record"
fi

echo
echo "=== srcinfo-diff.sh ==="

# Helper: make a synthetic .SRCINFO file.
make_srcinfo() {
    local file="$1"
    shift
    printf '%s\n' "$@" > "$file"
}

# Make a synthetic PKGBUILD workdir with a PKGBUILD and optional .install file.
make_workdir() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "${dir}/PKGBUILD" <<'PKG'
pkgname=testpkg
pkgver=1.0.0
pkgrel=1
pkgdesc="synthetic test package"
arch=('any')
depends=('glibc')
makedepends=('git')
checkdepends=()
PKG
}

# 8. classify_diff on missing old_srcinfo → unknown (first-build sentinel).
unset APPROVAL_INSTALL_MANIFEST APPROVAL_PRIOR_FUNCTIONS
new_si="$(mktemp)"
make_srcinfo "$new_si" "pkgname = testpkg" "depends = glibc"
workdir="${TEST_TMP}/wd1"
make_workdir "$workdir"
result="$(bash "${SCRIPTS}/srcinfo-diff.sh" "" "$new_si" "$workdir")"
assert_eq "$result" "unknown" "empty old_srcinfo → unknown"
rm -f "$new_si"

# 9. version-bump: prior and current differ only in pkgver/pkgrel.
old_si="$(mktemp)"; new_si="$(mktemp)"
make_srcinfo "$old_si" \
    "pkgname = testpkg" \
    "pkgver = 0.9.0" \
    "pkgrel = 1" \
    "depends = glibc" \
    "source = https://example.com/testpkg-0.9.0.tar.gz"
make_srcinfo "$new_si" \
    "pkgname = testpkg" \
    "pkgver = 1.0.0" \
    "pkgrel = 1" \
    "depends = glibc" \
    "source = https://example.com/testpkg-1.0.0.tar.gz"
# Note: source URL changed because the upstream tarball name changed.
# That means classify_diff will report code-changed. This is a known
# limitation: we can't perfectly distinguish "version bump that
# includes new tarball name" from "code change" without the full prior
# srcinfo. The version-bump path is taken when ONLY pkgver/pkgrel/epoch
# + checksums change. Here the source URL contains the version, so it's
# actually a benign version bump — our gate errs on the side of caution.
result="$(bash "${SCRIPTS}/srcinfo-diff.sh" "$old_si" "$new_si" "$workdir")"
assert_eq "$result" "code-changed" "source URL containing version → code-changed (safe default)"
rm -f "$old_si" "$new_si"

# 10. deps-changed: prior deps differ.
old_si="$(mktemp)"; new_si="$(mktemp)"
make_srcinfo "$old_si" \
    "pkgname = testpkg" \
    "pkgver = 1.0.0" \
    "pkgrel = 1" \
    "depends = glibc" \
    "source = https://example.com/testpkg-1.0.0.tar.gz"
make_srcinfo "$new_si" \
    "pkgname = testpkg" \
    "pkgver = 1.0.0" \
    "pkgrel = 1" \
    "depends = glibc" \
    "depends = newlib" \
    "source = https://example.com/testpkg-1.0.0.tar.gz"
# Source unchanged, but deps differ.
# However source-changed still trips first. Let me make source match.
make_srcinfo "$old_si" \
    "pkgname = testpkg" "pkgver = 1.0.0" "pkgrel = 1" \
    "depends = glibc" \
    "source = https://example.com/testpkg.tar.gz"
make_srcinfo "$new_si" \
    "pkgname = testpkg" "pkgver = 1.0.0" "pkgrel = 1" \
    "depends = glibc" "depends = newlib" \
    "source = https://example.com/testpkg.tar.gz"
result="$(bash "${SCRIPTS}/srcinfo-diff.sh" "$old_si" "$new_si" "$workdir")"
assert_eq "$result" "deps-changed" "added dep → deps-changed"
rm -f "$old_si" "$new_si"

# 11. install-added: prior manifest empty, current has a file.
echo "" > /tmp/empty_manifest
# But the prior manifest via env is a newline-separated list, not a file.
old_si="$(mktemp)"; new_si="$(mktemp)"
make_srcinfo "$old_si" "pkgname = testpkg" "depends = glibc"
make_srcinfo "$new_si" "pkgname = testpkg" "depends = glibc"
# Install files in workdir.
echo "post_install() { :; }" > "${workdir}/testpkg.install"
APPROVAL_INSTALL_MANIFEST="" \
result="$(APPROVAL_INSTALL_MANIFEST="" bash "${SCRIPTS}/srcinfo-diff.sh" "$old_si" "$new_si" "$workdir")"
assert_eq "$result" "install-added" "new .install file → install-added"
rm -f "$old_si" "$new_si"
rm -f "${workdir}/testpkg.install"

# 12. install-edited: same name, different sha.
echo "post_install() { echo old; }" > "${workdir}/testpkg.install"
old_sha="$(sha256sum "${workdir}/testpkg.install" | awk '{print $1}')"
echo "post_install() { echo new; }" > "${workdir}/testpkg.install"
old_si="$(mktemp)"; new_si="$(mktemp)"
make_srcinfo "$old_si" "pkgname = testpkg" "depends = glibc"
make_srcinfo "$new_si" "pkgname = testpkg" "depends = glibc"
new_sha="$(sha256sum "${workdir}/testpkg.install" | awk '{print $1}')"
APPROVAL_INSTALL_MANIFEST="${old_sha}  testpkg.install" \
result="$(APPROVAL_INSTALL_MANIFEST="${old_sha}  testpkg.install" \
         bash "${SCRIPTS}/srcinfo-diff.sh" "$old_si" "$new_si" "$workdir")"
assert_eq "$result" "install-edited" "modified .install file → install-edited"
rm -f "$old_si" "$new_si"
rm -f "${workdir}/testpkg.install"

# 13. Identical content → version-bump.
old_si="$(mktemp)"; new_si="$(mktemp)"
make_srcinfo "$old_si" \
    "pkgname = testpkg" "pkgver = 1.0.0" "pkgrel = 1" \
    "depends = glibc" \
    "source = https://example.com/testpkg-1.0.0.tar.gz"
make_srcinfo "$new_si" \
    "pkgname = testpkg" "pkgver = 1.0.0" "pkgrel = 1" \
    "depends = glibc" \
    "source = https://example.com/testpkg-1.0.0.tar.gz"
# Identical fields including source. Function-bodies env unset → ignored.
result="$(bash "${SCRIPTS}/srcinfo-diff.sh" "$old_si" "$new_si" "$workdir")"
assert_eq "$result" "version-bump" "identical srcinfo → version-bump (treated as auto-update)"
rm -f "$old_si" "$new_si"

echo
echo "=== open-quarantine-issue.sh (smoke) ==="

# 14. Missing args → exit 2.
if bash "${SCRIPTS}/open-quarantine-issue.sh" 2>/dev/null; then
    fail "open-quarantine-issue.sh without args should exit non-zero"
else
    pass "open-quarantine-issue.sh without args exits non-zero"
fi

# 15. Missing GITHUB_TOKEN → exit 1 + warning.
DETAILS="$(mktemp)"
jq -n '{package:"x", reason:"TEST", pkgbuild_sha256:"a", srcinfo_sha256:"b", approved_version:"1.0-1", workdir:"/cache/work/x", blocklist_match:false, archcanary_exit_code:"n/a"}' > "$DETAILS"
unset GITHUB_TOKEN
if bash "${SCRIPTS}/open-quarantine-issue.sh" "x" "TEST" "$DETAILS" 2>/tmp/open.err; then
    fail "open-quarantine-issue.sh without token should exit non-zero"
else
    pass "open-quarantine-issue.sh without token exits non-zero"
    if grep -q "GITHUB_TOKEN unset" /tmp/open.err; then
        pass "open-quarantine-issue.sh logs clear warning"
    else
        fail "open-quarantine-issue.sh should log clear warning"
    fi
fi
rm -f "$DETAILS"

echo
echo "=== drain-quarantine.sh (smoke) ==="

# 16. Missing GITHUB_TOKEN → exits 0 silently.
unset GITHUB_TOKEN
if bash "${SCRIPTS}/drain-quarantine.sh" 2>/tmp/drain.err; then
    pass "drain-quarantine.sh without token exits 0"
else
    fail "drain-quarantine.sh without token should exit 0"
fi

# 17. Bad arg → exit 2.
if bash "${SCRIPTS}/drain-quarantine.sh" --bad-arg 2>/dev/null; then
    fail "drain-quarantine.sh with bad arg should exit non-zero"
else
    pass "drain-quarantine.sh with bad arg exits non-zero"
fi

echo
echo "=== build.sh syntax (no execution — needs arch environment) ==="

# 18. All scripts pass `bash -n`.
for f in "${SCRIPTS}/approval-store.sh" \
         "${SCRIPTS}/srcinfo-diff.sh" \
         "${SCRIPTS}/open-quarantine-issue.sh" \
         "${SCRIPTS}/drain-quarantine.sh"; do
    if bash -n "$f" 2>/dev/null; then
        pass "bash -n $f"
    else
        fail "bash -n $f — syntax error"
    fi
done

if bash -n "${REPO_ROOT}/build.sh" 2>/dev/null; then
    pass "bash -n build.sh"
else
    fail "bash -n build.sh — syntax error"
fi

echo
echo "=== summary ==="
echo "passed: $PASS"
echo "failed: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILED TESTS:"
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
exit 0

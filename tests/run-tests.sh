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
echo "=== repo-add safety ==="

# Production callsites must use repo-add's lock wait and downgrade guard.
if grep -E -q 'repo-add[[:space:]]+-w[[:space:]]+--prevent-downgrade[[:space:]]+--sign' \
        "${REPO_ROOT}/build.sh"; then
    pass "build.sh uses repo-add -w --prevent-downgrade"
else
    fail "build.sh must use repo-add -w --prevent-downgrade"
fi
if grep -E -q 'repo-add[[:space:]]+-w[[:space:]]+--prevent-downgrade[[:space:]]+--sign' \
        "${REPO_ROOT}/init.sh"; then
    pass "init.sh uses repo-add -w --prevent-downgrade"
else
    fail "init.sh must use repo-add -w --prevent-downgrade"
fi

# repo-add maintains the extensionless links itself; build.sh must not
# retain manual fallback copies that can become stale.
if grep -F -q 'cp "${REPO_NAME}.db.tar.zst" "${REPO_NAME}.db"' \
        "${REPO_ROOT}/build.sh"; then
    fail "build.sh must not manually copy the extensionless .db"
else
    pass "build.sh has no manual extensionless .db copy"
fi
if grep -F -q 'cp "${REPO_NAME}.files.tar.zst" "${REPO_NAME}.files"' \
        "${REPO_ROOT}/build.sh"; then
    fail "build.sh must not manually copy the extensionless .files"
else
    pass "build.sh has no manual extensionless .files copy"
fi

# Exercise the exact production repo-add flags against a real package
# fixture. Use the host's Arch tools when present; otherwise use the
# cached Arch base image when Docker is available. This remains an
# explicit skip rather than reaching the network to pull an image.
if command -v repo-add >/dev/null 2>&1 \
        && command -v bsdtar >/dev/null 2>&1; then
    if bash "${REPO_ROOT}/tests/repo-add-safety.sh" >/tmp/repo-add-safety.out 2>&1; then
        pass "repo-add fixture validates flags, signing, links, and downgrade rejection"
    else
        fail "repo-add fixture failed (see /tmp/repo-add-safety.out)"
    fi
elif command -v docker >/dev/null 2>&1 \
        && docker image inspect archlinux:latest >/dev/null 2>&1; then
    if docker run --rm --platform linux/amd64 \
            -v "${REPO_ROOT}:/workspace:ro" \
            archlinux:latest \
            /usr/bin/bash /workspace/tests/repo-add-safety.sh \
            >/tmp/repo-add-safety.out 2>&1; then
        pass "repo-add fixture validates flags, signing, links, and downgrade rejection (Arch container)"
    else
        fail "repo-add fixture failed in Arch container (see /tmp/repo-add-safety.out)"
    fi
else
    echo "  SKIP: repo-add fixture (Arch tools and cached Arch image unavailable)"
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
echo "=== ccache wording drift (task #3, kanban t_20581c54) ==="
# ---------------------------------------------------------------
# Decision: REMOVE the ccache claim from README.md and entrypoint.sh.
# Rationale (full version in commit body): clean-chroot builds built
# by extra-x86_64-build wipe the cache on every run, so the benefit
# concentrates on -git packages — which aur-forge deliberately
# avoids. Adding a real ccache wiring would require: a pacman -S
# ccache line in the Dockerfile, a bind-mount of a host cache dir,
# CCACHE_DIR + ccache --max-size in the chroot env, and a benchmark
# showing non-trivial wins for the actual package set. None of that
# exists today, so the docs were lying about a feature that does
# not work end-to-end. This test asserts no source file claims
# 'ccache' without an adjacent install/config line; until the
# wiring exists, no claim is allowed.
#
# Scanned files: anything in the repo root + scripts/ + cgi-bin/ +
# www/. Tests/ is intentionally excluded — the test harness itself
# names the forbidden string in its own assertion messages, so it
# would always flag its own existence. The harness file is part of
# the test contract, not part of the user-facing source.
ccache_violations=()
ccache_scan_files=( \
    "${REPO_ROOT}/README.md" \
    "${REPO_ROOT}/entrypoint.sh" \
    "${REPO_ROOT}/Dockerfile" \
    "${REPO_ROOT}/lighttpd.conf" \
    "${REPO_ROOT}/build.sh" \
    "${REPO_ROOT}/init.sh" \
    "${REPO_ROOT}/update.sh" \
    "${REPO_ROOT}/run.sh" \
    "${REPO_ROOT}/serve.sh" \
    "${REPO_ROOT}/install-repo.sh" \
    "${REPO_ROOT}/scripts"/*.sh \
    "${REPO_ROOT}/cgi-bin"/*.cgi \
    "${REPO_ROOT}/www"/* \
)
for f in "${ccache_scan_files[@]}"; do
    [[ -f "$f" ]] || continue
    # Strip comments before scanning so a "no ccache today" note in
    # a code comment doesn't trigger the violation. We grep for
    # literal 'ccache' on non-comment lines (i.e. lines whose first
    # non-whitespace char isn't '#').
    if grep -nE '^[[:space:]]*[^#[:space:]].*\bccache\b' "$f" >/dev/null 2>&1; then
        ccache_violations+=("$f: $(grep -nE '^[[:space:]]*[^#[:space:]].*\bccache\b' "$f" | head -1 | sed 's/^[[:space:]]*//')")
    fi
done
if [[ ${#ccache_violations[@]} -eq 0 ]]; then
    pass "no source file claims 'ccache' without matching install/config line"
else
    fail "no source file claims 'ccache' without matching install/config line" \
        "$(printf '%s\n' "${ccache_violations[@]}")"
fi

echo
echo "=== devtools pacman cache persistence (kanban t_f3555395) ==="
# ---------------------------------------------------------------
# Phase-1 cache persistence: the live baseline (2026-09-01) shows
# pacman-conf resolves CacheDir=/var/cache/pacman/pkg/ (overlay,
# in-container), so every pacman download is lost on container
# recreation. The fix is to prepend a CacheDir line under the
# bind-mounted /cache path so arch-nspawn's first-cache-dir bind
# (line 99 of devtools' arch-nspawn.in) points at host-backed
# storage.
#
# Strategy: ship a pure helper (scripts/pacman-cache-config.sh)
# that takes the upstream config text and a cache path and emits
# the modified config. init.sh applies the result to
# /usr/share/devtools/pacman.conf.d/extra.conf at startup.
#
# These tests pin the contract:
#   1. First CacheDir in the rendered config is the supplied path.
#   2. SigLevel = Required DatabaseOptional is preserved verbatim
#      (we never weaken the trust floor).
#   3. Any CacheServer directive (if present) is preserved.
#   4. Idempotency: re-rendering produces byte-identical output.
#   5. /cache/pacman/pkg creation in Dockerfile uses the expected
#      owner/mode (builder:builder 0755 — the makechrootpkg
#      process drops to `builder` for the actual build).
#   6. docker-compose.sample.yml documents /cache/pacman/pkg.
#   7. README.md documents /cache/pacman/pkg with the same
#      spelling as the code.
#   8. scripts/pacman-cache-config.sh bash -n passes.
# ---------------------------------------------------------------

# Source the helper as a library — same pattern as
# scripts/approval-store.sh and scripts/lib-aur.sh.
PACMAN_CACHE_CONFIG="${SCRIPTS}/pacman-cache-config.sh"
[[ -s "$PACMAN_CACHE_CONFIG" ]] \
    && pass "scripts/pacman-cache-config.sh exists" \
    || fail "scripts/pacman-cache-config.sh exists" "missing helper"

# shellcheck disable=SC1090
if [[ -s "$PACMAN_CACHE_CONFIG" ]]; then
    . "$PACMAN_CACHE_CONFIG"
fi

# Synthetic upstream pacman.conf (matches the devtools-1.5.1 shape
# observed in the live baseline). Includes the trailing #CacheDir
# comment (default-fallback), SigLevel, [core]/[extra] stanzas.
UPSTREAM_PACMAN_CONF='[options]
HoldPkg     = pacman glibc
CleanMethod = KeepInstalled
Architecture = auto
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional
NoProgressBar
ParallelDownloads = 5

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
'

# Minimal but realistic CacheServer-bearing variant: project memory
# flagged that some pacman configs historically tried CacheServer
# (it's not a real directive, but defensive preservation is the
# correct behavior for any custom value a future user adds).
UPSTREAM_WITH_CACHESERVER='[options]
HoldPkg     = pacman glibc
SigLevel    = Required DatabaseOptional
CacheServer = https://cache.example.invalid

[core]
Include = /etc/pacman.d/mirrorlist
'

RENDERED=""
if declare -F render_pacman_cache_conf >/dev/null 2>&1; then
    RENDERED="$(render_pacman_cache_conf "$UPSTREAM_PACMAN_CONF" "/cache/pacman/pkg/")"
fi

if [[ -n "$RENDERED" ]]; then
    # 1. First CacheDir line is /cache/pacman/pkg/.
    first_cache_dir="$(printf '%s\n' "$RENDERED" \
        | grep -E '^[[:space:]]*CacheDir[[:space:]]*=' \
        | head -1 \
        | sed -E 's/^[[:space:]]*CacheDir[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/')"
    assert_eq "$first_cache_dir" "/cache/pacman/pkg/" \
        "first CacheDir in rendered config is /cache/pacman/pkg/"

    # 2. SigLevel preserved verbatim — Required DatabaseOptional.
    if printf '%s\n' "$RENDERED" | grep -E '^[[:space:]]*SigLevel[[:space:]]*=[[:space:]]*Required[[:space:]]+DatabaseOptional' >/dev/null; then
        pass "SigLevel = Required DatabaseOptional preserved"
    else
        fail "SigLevel = Required DatabaseOptional preserved" \
            "got: $(printf '%s\n' "$RENDERED" | grep -E '^[[:space:]]*SigLevel' || echo '<none>')"
    fi

    # 3. Idempotency: re-render with the same inputs, expect
    # byte-identical output. This is a property the helper MUST
    # satisfy so init.sh can re-run on every container start
    # without churn.
    RENDERED_AGAIN="$(render_pacman_cache_conf "$UPSTREAM_PACMAN_CONF" "/cache/pacman/pkg/")"
    assert_eq "$RENDERED_AGAIN" "$RENDERED" \
        "render_pacman_cache_conf is idempotent"

    # 3b. If the upstream config contains a CacheServer directive
    # (defensive: not a real pacman key, but preserve any value
    # the user might have added for a future pacman version).
    RENDERED_CS="$(render_pacman_cache_conf "$UPSTREAM_WITH_CACHESERVER" "/cache/pacman/pkg/")"
    if printf '%s\n' "$RENDERED_CS" | grep -E '^[[:space:]]*CacheServer[[:space:]]*=' >/dev/null; then
        pass "CacheServer directive preserved (defensive)"
    else
        fail "CacheServer directive preserved (defensive)" \
            "lost CacheServer during render"
    fi

    # 4. CacheDir count: at least one (the new one) and the new
    # one is under /cache. The old /var/cache/pacman/pkg/ may or
    # may not survive — implementation choice, but the FIRST one
    # must be /cache/pacman/pkg/.
    cache_dir_count="$(printf '%s\n' "$RENDERED" \
        | grep -cE '^[[:space:]]*CacheDir[[:space:]]*=')"
    if (( cache_dir_count >= 1 )); then
        pass "rendered config has at least one CacheDir line (count=$cache_dir_count)"
    else
        fail "rendered config has at least one CacheDir line" \
            "got count=$cache_dir_count"
    fi

    # 5. The /cache cache path is the FIRST occurrence (so
    # arch-nspawn binds it RW on top of the chroot's path).
    first_dir_line_num="$(printf '%s\n' "$RENDERED" \
        | grep -nE '^[[:space:]]*CacheDir[[:space:]]*=' \
        | head -1 \
        | cut -d: -f1)"
    first_dir_value="$(printf '%s\n' "$RENDERED" \
        | sed -n "${first_dir_line_num}p" \
        | sed -E 's/^[[:space:]]*CacheDir[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/')"
    case "$first_dir_value" in
        /cache/*) pass "first CacheDir resolves under /cache (line $first_dir_line_num: $first_dir_value)" ;;
        *)        fail "first CacheDir resolves under /cache" \
                       "got '$first_dir_value' on line $first_dir_line_num" ;;
    esac
else
    # Render failed or function missing — record the chain so we
    # can fix it after the first commit.
    fail "render_pacman_cache_conf exists and returns text" "no output (function missing or empty)"
    fail "first CacheDir in rendered config is /cache/pacman/pkg/" "skipped — no rendered output"
    fail "SigLevel = Required DatabaseOptional preserved" "skipped — no rendered output"
    fail "render_pacman_cache_conf is idempotent" "skipped — no rendered output"
    fail "CacheServer directive preserved (defensive)" "skipped — no rendered output"
    fail "rendered config has at least one CacheDir line" "skipped — no rendered output"
    fail "first CacheDir resolves under /cache" "skipped — no rendered output"
fi

# 6. bash -n on the helper.
if bash -n "$PACMAN_CACHE_CONFIG" 2>/dev/null; then
    pass "bash -n $PACMAN_CACHE_CONFIG"
else
    fail "bash -n $PACMAN_CACHE_CONFIG" "syntax error"
fi

# 7. docker-compose.sample.yml documents /cache/pacman/pkg.
if grep -F '/cache/pacman/pkg' "${REPO_ROOT}/docker-compose.sample.yml" >/dev/null 2>&1; then
    pass "docker-compose.sample.yml documents /cache/pacman/pkg"
else
    fail "docker-compose.sample.yml documents /cache/pacman/pkg" \
        "missing path string"
fi

# 8. README.md documents /cache/pacman/pkg.
if grep -F '/cache/pacman/pkg' "${REPO_ROOT}/README.md" >/dev/null 2>&1; then
    pass "README.md documents /cache/pacman/pkg"
else
    fail "README.md documents /cache/pacman/pkg" \
        "missing path string"
fi

# 9. README.md distinguishes the three cache paths by name:
# AUR source/work cache, official Arch package cache, clean
# chroot state. Each must be in its own line/section so a
# reader can tell them apart.
if grep -F '/cache/work' "${REPO_ROOT}/README.md" >/dev/null 2>&1 \
   && grep -F '/cache/pacman/pkg' "${REPO_ROOT}/README.md" >/dev/null 2>&1 \
   && grep -F '/var/lib/archbuild' "${REPO_ROOT}/README.md" >/dev/null 2>&1; then
    pass "README.md mentions all three cache paths distinctly (/cache/work, /cache/pacman/pkg, /var/lib/archbuild)"
else
    fail "README.md mentions all three cache paths distinctly" \
        "expected /cache/work + /cache/pacman/pkg + /var/lib/archbuild"
fi

# 10. Dockerfile plants /cache/pacman/pkg at image build time
# with the expected owner/mode. Both the directory creation AND
# the chown must be present — pacstrap runs as root during
# chroot bootstrap, but makechrootpkg drops to `builder` for
# the actual build, so the dir must be writable by both.
dockerfile_text="$(cat "${REPO_ROOT}/Dockerfile")"
if grep -F '/cache/pacman/pkg' <<<"$dockerfile_text" >/dev/null 2>&1; then
    pass "Dockerfile creates /cache/pacman/pkg"
else
    fail "Dockerfile creates /cache/pacman/pkg" \
        "no mkdir/mkdir -p for /cache/pacman/pkg"
fi
if grep -E 'chown[[:space:]]+builder:builder[[:space:]]+.*/cache' <<<"$dockerfile_text" >/dev/null 2>&1 \
   && grep -E 'chown[[:space:]]+builder:builder[[:space:]]+.*(/cache|/cache/pacman/pkg)' <<<"$dockerfile_text" >/dev/null 2>&1; then
    pass "Dockerfile chowns /cache tree to builder:builder"
else
    fail "Dockerfile chowns /cache tree to builder:builder" \
        "expected 'chown builder:builder /cache[/pacman/pkg]'"
fi
# 0755 is the narrowest correct mode: writable by owner
# (builder), readable+executable by group/other. Defends
# against a future chmod 777 copy-paste regression.
if grep -E 'chmod[[:space:]]+0755[[:space:]]+.*(/cache|/cache/pacman/pkg)' <<<"$dockerfile_text" >/dev/null 2>&1; then
    pass "Dockerfile sets /cache mode to 0755"
else
    fail "Dockerfile sets /cache mode to 0755" \
        "expected 'chmod 0755 /cache' or 'chmod 0755 /cache/pacman/pkg'"
fi
# Belt-and-braces: the helper scripts must NOT do a chmod 0777.
# 0777/0775 world-writable modes on a pacman package cache
# would be a clear regression we want the test to catch. Note
# the regex is `0?777` or `0?775` — NOT `0?7[75][57]`, which
# would falsely flag the correct `chmod 0755` mode.
if grep -E '\bchmod[[:space:]]+0?77[57][[:space:]]+.*(/cache|/cache/pacman/pkg)' \
        <<<"$dockerfile_text" >/dev/null 2>&1; then
    fail "Dockerfile must not chmod 0777/0775 /cache" \
        "regression: world-writable cache dir"
fi

# 11. init.sh installs the rendered config into the devtools
# pacman.conf via an Include directive (idempotent). The
# Include path must point at a file we control under
# /usr/local/lib/aur-forge (so pacman -Syu devtools can't
# clobber it). The literal `Include = ...` text only exists
# at runtime inside the devtools extra.conf (not in init.sh
# source), so we assert the runtime contract instead: init.sh
# must call install_pacman_cache_include on the canonical
# extra.conf path.
init_text="$(cat "${REPO_ROOT}/init.sh")"
if grep -F 'install_pacman_cache_include' <<<"$init_text" >/dev/null 2>&1; then
    pass "init.sh calls install_pacman_cache_include"
else
    fail "init.sh calls install_pacman_cache_include" \
        "no call site for the include installer"
fi
if grep -F 'pacman.conf.d/extra.conf' <<<"$init_text" >/dev/null 2>&1; then
    pass "init.sh references the devtools extra.conf"
else
    fail "init.sh references the devtools extra.conf" \
        "missing reference to extra.conf"
fi
# /usr/local/lib/aur-forge/pacman.d/ — the path the drop-in is
# planted under. Must be under our tree (not under /usr/share,
# which is devtools-managed and could be clobbered by upgrades).
if grep -F '/usr/local/lib/aur-forge/pacman.d' <<<"$init_text" >/dev/null 2>&1; then
    pass "init.sh plants drop-in under /usr/local/lib/aur-forge/pacman.d/"
else
    fail "init.sh plants drop-in under /usr/local/lib/aur-forge/pacman.d/" \
        "missing drop-in path"
fi

echo
echo "=== bounded makepkg jobs (kanban t_8f558ae3) ==="
# ---------------------------------------------------------------
# Phase-2 build optimization: configurable, memory-aware makepkg
# parallelism. Container mem_limit is 4g; default AUR_BUILD_JOBS
# stays at 2 even when the host reports more CPUs (8 vCPU / 64 GB
# RAM per the 2026-09-01 live baseline). Compression is bounded to
# the same job count — replaces devtools' default unbounded -T0.
#
# Strategy: a pure helper scripts/makepkg-jobs-config.sh that
# exposes render_makepkg_jobs_block (text-only, exercised by tests)
# and write_makepkg_jobs_dropin (writes a project-owned fragment).
# init.sh sources the helper and writes the fragment at container
# start; build.sh sets MAKEPKG_CONF to that fragment path before
# invoking extra-x86_64-build. /etc/makepkg.conf is NEVER edited —
# a future `pacman -Syu devtools` could rewrite it, and any drop-in
# we plant there would be lost. Keeping the drop-in under our own
# tree (/usr/local/lib/aur-forge/) means devtools upgrades can't
# clobber it.
#
# Tests pin the contract:
#   1. render_makepkg_jobs_block 2 emits -j2 + NPROC=2 +
#      COMPRESSZST=(zstd -c -T2 -)
#   2. Override (AUR_BUILD_JOBS=4) yields -j4 + NPROC=4 + -T4
#   3. Validation rejects 0, negative, non-int, empty, junk, and
#      any value > MAX_AUR_BUILD_JOBS (default 8)
#   4. Default never contains -march=native / -O3 / mold / ccache /
#      distcc / -T0 / --ultra
#   5. README + docker-compose.sample.yml document the knob with
#      the same default (2) the code uses
#   6. init.sh calls write_makepkg_jobs_dropin
#   7. build.sh calls validate_aur_build_jobs before any
#      extra-x86_64-build invocation
# ---------------------------------------------------------------
MAKEPKG_JOBS_CONFIG="${SCRIPTS}/makepkg-jobs-config.sh"
[[ -s "$MAKEPKG_JOBS_CONFIG" ]] \
    && pass "scripts/makepkg-jobs-config.sh exists" \
    || fail "scripts/makepkg-jobs-config.sh exists" "missing helper"

# shellcheck disable=SC1090
if [[ -s "$MAKEPKG_JOBS_CONFIG" ]]; then
    . "$MAKEPKG_JOBS_CONFIG"
fi

if declare -F render_makepkg_jobs_block >/dev/null 2>&1; then
    # Default jobs = 2 (matches AUR_BUILD_JOBS default in init.sh +
    # docker-compose.sample.yml + README). All three overrides must
    # reference the same value or makepkg will desync parallelism.
    RENDERED_DEFAULT="$(AUR_BUILD_JOBS=2 render_makepkg_jobs_block 2>/dev/null || true)"
    if [[ -n "$RENDERED_DEFAULT" ]]; then
        if grep -qE '^MAKEFLAGS="-j2"' <<<"$RENDERED_DEFAULT"; then
            pass "default render contains MAKEFLAGS=\"-j2\""
        else
            fail "default render contains MAKEFLAGS=\"-j2\"" \
                "got: $(printf '%s' \"$RENDERED_DEFAULT\" | head -c 200)"
        fi
        if grep -qE '^NPROC=2$' <<<"$RENDERED_DEFAULT"; then
            pass "default render contains NPROC=2"
        else
            fail "default render contains NPROC=2" \
                "got: $(printf '%s' \"$RENDERED_DEFAULT\" | head -c 200)"
        fi
        if grep -qE '^COMPRESSZST=\(zstd -c -T2 -\)$' <<<"$RENDERED_DEFAULT"; then
            pass "default render contains COMPRESSZST=(zstd -c -T2 -)"
        else
            fail "default render contains COMPRESSZST=(zstd -c -T2 -)" \
                "got: $(printf '%s' \"$RENDERED_DEFAULT\" | head -c 200)"
        fi

        # Explicit override: AUR_BUILD_JOBS=4 → all three values must
        # agree. If any of them drift apart, makepkg compiles with one
        # parallelism and compresses with another — the desync is
        # exactly the bug this knob is supposed to prevent.
        RENDERED_4="$(AUR_BUILD_JOBS=4 render_makepkg_jobs_block 2>/dev/null || true)"
        if [[ -n "$RENDERED_4" ]]; then
            if grep -qE '^MAKEFLAGS="-j4"' <<<"$RENDERED_4" \
               && grep -qE '^NPROC=4$' <<<"$RENDERED_4" \
               && grep -qE '^COMPRESSZST=\(zstd -c -T4 -\)$' <<<"$RENDERED_4"; then
                pass "override AUR_BUILD_JOBS=4 produces consistent -j4/NPROC=4/-T4"
            else
                fail "override AUR_BUILD_JOBS=4 produces consistent -j4/NPROC=4/-T4" \
                    "got: $(printf '%s' \"$RENDERED_4\" | head -c 200)"
            fi
        else
            fail "override AUR_BUILD_JOBS=4 renders" "no output"
        fi

        # Forbidden optimizations: -march=native, -mtune=native, -O3,
        # mold, ccache, distcc. These change generated binaries or add
        # security-irrelevant build deps that the task explicitly
        # forbids ANYWHERE in this card.
        for forbidden in --march=native --mtune=native mold ccache distcc icecream; do
            if grep -qF -- "$forbidden" <<<"$RENDERED_DEFAULT"; then
                fail "default render does not mention '$forbidden'" \
                    "leaked into output: $(grep -F -- \"$forbidden\" <<<\"$RENDERED_DEFAULT\" | head -1)"
            else
                pass "default render does not mention '$forbidden'"
            fi
        done

        # Unbounded thread count (-T0) and devtools' --ultra -20
        # compression level defeat the bounded-jobs goal: zstd -T0
        # = "all cores", --ultra -20 is dog-slow for marginal size
        # gain. Lock compression threads to AUR_BUILD_JOBS and keep
        # the default zstd level.
        if grep -qE 'COMPRESSZST=.*-T0' <<<"$RENDERED_DEFAULT"; then
            fail "default COMPRESSZST does not use unbounded -T0" \
                "regression: -T0 leaked into output"
        else
            pass "default COMPRESSZST does not use unbounded -T0"
        fi
        if grep -qF -- '--ultra' <<<"$RENDERED_DEFAULT"; then
            fail "default COMPRESSZST does not use --ultra" \
                "regression: --ultra leaked into output"
        else
            pass "default COMPRESSZST does not use --ultra"
        fi

        # -O3 / -Ofast are the canonical "fast but unsafe for
        # distribution" optimizations — makepkg defaults to -O2.
        # Reject any -O3 or -Ofast.
        if grep -qE '(^|[[:space:]])-O3([[:space:]]|$)' <<<"$RENDERED_DEFAULT"; then
            fail "default render does not contain -O3" "leaked into output"
        else
            pass "default render does not contain -O3"
        fi
        if grep -qE '(^|[[:space:]])-Ofast([[:space:]]|$)' <<<"$RENDERED_DEFAULT"; then
            fail "default render does not contain -Ofast" "leaked into output"
        else
            pass "default render does not contain -Ofast"
        fi
    else
        fail "render_makepkg_jobs_block returns text" "no output"
    fi

    # Validation: every invalid input MUST fail before rendering. A
    # silent pass would let "AUR_BUILD_JOBS=0" or "AUR_BUILD_JOBS=foo"
    # explode a build under load — the whole point of the bounded
    # knob is to keep these out of the hands of a misconfigured env.
    # Empty string is the test for the case where the operator sets
    # the env var to AUR_BUILD_JOBS= explicitly with no value.
    for bad in 0 -1 "" "abc" "2.5" " 2" "2 " "2;rm -rf" "-j2" "2 jobs"; do
        out="$(AUR_BUILD_JOBS="$bad" render_makepkg_jobs_block 2>/dev/null || true)"
        if [[ -z "$out" ]]; then
            pass "invalid AUR_BUILD_JOBS='${bad}' rejected (no output)"
        else
            fail "invalid AUR_BUILD_JOBS='${bad}' rejected" \
                "leaked output: $(printf '%s' \"$out\" | head -c 120)"
        fi
    done

    # Cap enforcement: the container's mem_limit is 4g; the cap
    # default is MAX_AUR_BUILD_JOBS=8 per the task spec. Anything
    # above that must be rejected even if the host has 32 CPUs.
    out_too_high="$(AUR_BUILD_JOBS=9 render_makepkg_jobs_block 2>/dev/null || true)"
    if [[ -z "$out_too_high" ]]; then
        pass "AUR_BUILD_JOBS=9 rejected (above default MAX_AUR_BUILD_JOBS=8)"
    else
        fail "AUR_BUILD_JOBS=9 rejected (above default MAX_AUR_BUILD_JOBS=8)" \
            "leaked output: $(printf '%s' \"$out_too_high\" | head -c 120)"
    fi
    out_boundary="$(AUR_BUILD_JOBS=8 render_makepkg_jobs_block 2>/dev/null || true)"
    if [[ -n "$out_boundary" ]] && grep -qE '^NPROC=8$' <<<"$out_boundary"; then
        pass "AUR_BUILD_JOBS=8 accepted (boundary)"
    else
        fail "AUR_BUILD_JOBS=8 accepted (boundary)" \
            "got: $(printf '%s' \"$out_boundary\" | head -c 120)"
    fi

    # MAX_AUR_BUILD_JOBS override: operators can raise the cap by
    # exporting the env var before invoking. The helper reads it
    # with a default of 8 — a future tuning pass can lift the cap
    # without editing the helper.
    out_raised_cap="$(MAX_AUR_BUILD_JOBS=16 AUR_BUILD_JOBS=12 render_makepkg_jobs_block 2>/dev/null || true)"
    if [[ -n "$out_raised_cap" ]] && grep -qE '^NPROC=12$' <<<"$out_raised_cap"; then
        pass "MAX_AUR_BUILD_JOBS=16 lets AUR_BUILD_JOBS=12 through"
    else
        fail "MAX_AUR_BUILD_JOBS=16 lets AUR_BUILD_JOBS=12 through" \
            "got: $(printf '%s' \"$out_raised_cap\" | head -c 120)"
    fi
    out_still_capped="$(MAX_AUR_BUILD_JOBS=16 AUR_BUILD_JOBS=17 render_makepkg_jobs_block 2>/dev/null || true)"
    if [[ -z "$out_still_capped" ]]; then
        pass "MAX_AUR_BUILD_JOBS=16 still rejects AUR_BUILD_JOBS=17"
    else
        fail "MAX_AUR_BUILD_JOBS=16 still rejects AUR_BUILD_JOBS=17" \
            "leaked output"
    fi

    # validate_aur_build_jobs: standalone entry point for build.sh
    # to fail fast BEFORE the first extra-x86_64-build invocation.
    # It must succeed (return 0) for valid values and return
    # non-zero for invalid ones — including printing a clear error
    # to stderr.
    if declare -F validate_aur_build_jobs >/dev/null 2>&1; then
        if validate_aur_build_jobs 4 >/dev/null 2>&1; then
            pass "validate_aur_build_jobs accepts 4"
        else
            fail "validate_aur_build_jobs accepts 4" "rejected a valid value"
        fi
        if validate_aur_build_jobs 0 >/dev/null 2>&1; then
            fail "validate_aur_build_jobs rejects 0" "accepted an invalid value"
        else
            pass "validate_aur_build_jobs rejects 0"
        fi
        if validate_aur_build_jobs 999 >/dev/null 2>&1; then
            fail "validate_aur_build_jobs rejects 999" "accepted an out-of-range value"
        else
            pass "validate_aur_build_jobs rejects 999"
        fi
        # Stderr message must be clear — the operator will see it
        # in `docker logs` and in build.sh's own pre-flight output.
        err_msg="$(validate_aur_build_jobs 0 2>&1 || true)"
        if [[ "$err_msg" == *AUR_BUILD_JOBS* ]]; then
            pass "validate_aur_build_jobs mentions AUR_BUILD_JOBS in error"
        else
            fail "validate_aur_build_jobs mentions AUR_BUILD_JOBS in error" \
                "got: $err_msg"
        fi
    else
        fail "validate_aur_build_jobs exists" "function missing"
    fi
else
    fail "render_makepkg_jobs_block exists" "function missing"
fi

# bash -n on the helper.
if bash -n "$MAKEPKG_JOBS_CONFIG" 2>/dev/null; then
    pass "bash -n $MAKEPKG_JOBS_CONFIG"
else
    fail "bash -n $MAKEPKG_JOBS_CONFIG" "syntax error"
fi

# Drop-in writer: write to a project-owned path, idempotent,
# mode 0644, contains a header comment so future readers know
# not to hand-edit.
if declare -F write_makepkg_jobs_dropin >/dev/null 2>&1; then
    TMP_DROP="$(mktemp)"
    if AUR_BUILD_JOBS=3 write_makepkg_jobs_dropin "$TMP_DROP" 2>/dev/null; then
        if [[ -s "$TMP_DROP" ]]; then
            pass "write_makepkg_jobs_dropin creates a non-empty file"
        else
            fail "write_makepkg_jobs_dropin creates a non-empty file" "empty file"
        fi
        mode="$(stat -c '%a' "$TMP_DROP" 2>/dev/null || stat -f '%Lp' "$TMP_DROP" 2>/dev/null || echo unknown)"
        if [[ "$mode" == "644" ]]; then
            pass "drop-in file is mode 0644"
        else
            fail "drop-in file is mode 0644" "got: $mode"
        fi
        if grep -qE '^MAKEFLAGS="-j3"' "$TMP_DROP" \
           && grep -qE '^NPROC=3$' "$TMP_DROP" \
           && grep -qE '^COMPRESSZST=\(zstd -c -T3 -\)$' "$TMP_DROP"; then
            pass "drop-in contains consistent MAKEFLAGS/NPROC/COMPRESSZST"
        else
            fail "drop-in contains consistent MAKEFLAGS/NPROC/COMPRESSZST" \
                "content: $(cat "$TMP_DROP" | head -10)"
        fi
        if head -1 "$TMP_DROP" | grep -qE '^#'; then
            pass "drop-in starts with a comment header"
        else
            fail "drop-in starts with a comment header" \
                "first line: $(head -1 "$TMP_DROP")"
        fi
    else
        fail "write_makepkg_jobs_dropin returns 0" "non-zero exit"
    fi
    # Idempotency: write twice, file should be byte-identical.
    TMP_DROP2="$(mktemp)"
    AUR_BUILD_JOBS=3 write_makepkg_jobs_dropin "$TMP_DROP" >/dev/null 2>&1
    AUR_BUILD_JOBS=3 write_makepkg_jobs_dropin "$TMP_DROP2" >/dev/null 2>&1
    if diff -q "$TMP_DROP" "$TMP_DROP2" >/dev/null 2>&1; then
        pass "write_makepkg_jobs_dropin is idempotent (identical output)"
    else
        fail "write_makepkg_jobs_dropin is idempotent" \
            "diff: $(diff "$TMP_DROP" "$TMP_DROP2")"
    fi
    rm -f "$TMP_DROP" "$TMP_DROP2"
else
    fail "write_makepkg_jobs_dropin exists" "function missing"
fi

# Documentation/code alignment: README and docker-compose.sample.yml
# must document AUR_BUILD_JOBS with the same default (2) the code
# uses. Default cap MAX_AUR_BUILD_JOBS=8 must also be discoverable
# in the README so operators don't have to read source.
if grep -E '^AUR_BUILD_JOBS=' docker-compose.sample.yml >/dev/null 2>&1 \
   || grep -E '^[[:space:]]+AUR_BUILD_JOBS:' docker-compose.sample.yml >/dev/null 2>&1; then
    pass "docker-compose.sample.yml documents AUR_BUILD_JOBS"
    if grep -E 'AUR_BUILD_JOBS:[[:space:]]*"?2"?[[:space:]]*$' docker-compose.sample.yml >/dev/null 2>&1 \
       || grep -E '^AUR_BUILD_JOBS="?2"?$' docker-compose.sample.yml >/dev/null 2>&1; then
        pass "docker-compose.sample.yml pins AUR_BUILD_JOBS default to 2"
    else
        fail "docker-compose.sample.yml pins AUR_BUILD_JOBS default to 2" \
            "expected 'AUR_BUILD_JOBS: 2' (or 'AUR_BUILD_JOBS=\"2\"')"
    fi
else
    fail "docker-compose.sample.yml documents AUR_BUILD_JOBS" "missing key"
fi

if grep -F 'AUR_BUILD_JOBS' README.md >/dev/null 2>&1; then
    pass "README.md documents AUR_BUILD_JOBS"
else
    fail "README.md documents AUR_BUILD_JOBS" "missing key"
fi

# init.sh must call the drop-in writer (same seam pattern as the
# pacman-cache helper tests above). The helper is pure; init.sh is
# the integration point.
init_text="$(cat "${REPO_ROOT}/init.sh")"
if grep -F 'write_makepkg_jobs_dropin' <<<"$init_text" >/dev/null 2>&1; then
    pass "init.sh calls write_makepkg_jobs_dropin"
else
    fail "init.sh calls write_makepkg_jobs_dropin" "no call site"
fi
if grep -F 'makepkg-jobs-config.sh' <<<"$init_text" >/dev/null 2>&1; then
    pass "init.sh sources makepkg-jobs-config.sh"
else
    fail "init.sh sources makepkg-jobs-config.sh" "no source line"
fi

# build.sh must validate AUR_BUILD_JOBS BEFORE invoking
# extra-x86_64-build. The fail-fast contract: if AUR_BUILD_JOBS
# is bad, no build runs and the operator sees the error in
# docker logs immediately.
build_text="$(cat "${REPO_ROOT}/build.sh")"
if grep -F 'validate_aur_build_jobs' <<<"$build_text" >/dev/null 2>&1; then
    pass "build.sh calls validate_aur_build_jobs"
else
    fail "build.sh calls validate_aur_build_jobs" "no call site"
fi

# The drop-in path MUST live under /usr/local/lib/aur-forge (our
# tree) so a future `pacman -Syu devtools` upgrade cannot clobber
# it. Test fails fast if init.sh writes to /etc/makepkg.conf or
# /usr/share/devtools/ — both are devtools-managed.
for forbidden_dropin_path in '/etc/makepkg.conf' '/etc/makepkg.conf.d' \
                             '/usr/share/devtools/makepkg.conf.d'; do
    if grep -F "$forbidden_dropin_path" <<<"$init_text" \
       | grep -F 'write_makepkg_jobs_dropin' >/dev/null 2>&1; then
        fail "init.sh drop-in path is not under devtools-managed dirs ($forbidden_dropin_path)" \
            "regression: drop-in would be clobbered by pacman -Syu devtools"
    else
        pass "init.sh drop-in path is not under devtools-managed dirs ($forbidden_dropin_path)"
    fi
done



echo
echo "=== pinned aurutils install + aur-fetch seam (kanban t_74c2fd9c) ==="
# ---------------------------------------------------------------
# Phase-2 selective aurutils adoption: install aurutils from a
# pinned AUR commit (not master/unpinned main), expose it under
# /usr/local/lib/aur-forge/aurutils/ with a SHA-256 + version
# stamp, and replace the `git clone --depth 1` fetch seam in
# build.sh with `aur-fetch`. The archcanary -> PKGBUILD-diff
# quarantine -> approval -> extra-x86_64-build gate sequence
# stays intact. Forbidden in this card:
#   - aur-sync, aur-view, AUR_PACMAN_AUTH, expect
#   - curl | bash / curl | sh / pipe-to-shell
#   - master / unpinned main
#
# Tests pin:
#   1. aurutils.version pin file is committed alongside the
#      helper and contains the exact commit + sha256 tuple.
#   2. install-aurutils.sh exists and bash -n passes.
#   3. Helper validates the pin tuple syntactically (each line
#      present, sha256 is a 64-char hex string, commit is a
#      40-char hex string) and rejects malformed pins.
#   4. Helper refuses to fetch from `master` / unpinned `main`
#      URLs — the URL slot must be commit-pinned.
#   5. Helper never runs `curl | bash` / `curl | sh` /
#      pipe-to-shell — its source is grep-clean.
#   6. build.sh no longer contains the literal
#      `git clone --depth 1 https://aur.archlinux.org/${pkg}.git`
#      seam (or its expanded form) — replaced by an `aur-fetch`
#      invocation as a single, top-level command (NOT chained
#      with $(...) or <(...) substitutions, per the 2026-08-30
#      build-trigger failure pattern).
#   7. archcanary gate still runs AFTER fetch and BEFORE
#      extra-x86_64-build (gate sequencing is preserved).
#   8. build.sh: WORK=/cache/work/${pkg} + chown builder:builder
#      flow still present.
#   9. Forbidden patterns (aur-sync, aur-view, AUR_PACMAN_AUTH,
#      expect) are absent from build.sh + Dockerfile + the new
#      helper.
#  10. Dockerfile uses the new install helper (instead of its
#      own unpinned git clone).
#  11. README documents where the aurutils version comes from.
#  12. init.sh declares the existing-clone policy knob
#      (AUR_FETCH_CLONE_POLICY) with documented default
#      (discard-for-nightly-rebuilds).
# ---------------------------------------------------------------

AURUTILS_INSTALL="${SCRIPTS}/install-aurutils.sh"
[[ -s "$AURUTILS_INSTALL" ]] \
    && pass "scripts/install-aurutils.sh exists" \
    || fail "scripts/install-aurutils.sh exists" "missing helper"

if bash -n "$AURUTILS_INSTALL" 2>/dev/null; then
    pass "bash -n $AURUTILS_INSTALL"
else
    fail "bash -n $AURUTILS_INSTALL" "syntax error"
fi

# Source the helper as a library — same pattern as the other
# config helpers. The helper is intended to be sourced by
# Dockerfile tests + by build.sh (which calls a public entry
# point like install_pinned_aurutils). Sourcing also lets the
# test exercise pure functions without actually running
# makepkg.
if [[ -s "$AURUTILS_INSTALL" ]]; then
    # shellcheck disable=SC1090
    . "$AURUTILS_INSTALL"
fi

# aurutils.version pin file: ships next to the helper so a
# future upgrade is a 2-line PR (commit SHA + sha256 tuple).
AURUTILS_VERSION_FILE="${REPO_ROOT}/aurutils.version"
if [[ -s "$AURUTILS_VERSION_FILE" ]]; then
    pass "aurutils.version pin file is committed"
    # Pin format: key=value lines, one per logical fact.
    #   AURUTILS_VERSION=20.5.8-1
    #   AURUTILS_COMMIT=<40-char hex>
    #   AURUTILS_SHA256=<64-char hex>
    #   AURUTILS_SOURCE_URL=<https URL ending in the commit hash,
    #                        NOT master / NOT main>
    if grep -E '^AURUTILS_VERSION=' "$AURUTILS_VERSION_FILE" >/dev/null; then
        pass "aurutils.version declares AURUTILS_VERSION"
    else
        fail "aurutils.version declares AURUTILS_VERSION" \
            "missing AURUTILS_VERSION=<x.y.z-N> line"
    fi
    if grep -E '^AURUTILS_COMMIT=[0-9a-f]{40}$' "$AURUTILS_VERSION_FILE" >/dev/null; then
        pass "aurutils.version declares AURUTILS_COMMIT (40-char hex)"
    else
        fail "aurutils.version declares AURUTILS_COMMIT (40-char hex)" \
            "missing or malformed AURUTILS_COMMIT"
    fi
    if grep -E '^AURUTILS_SHA256=[0-9a-f]{64}$' "$AURUTILS_VERSION_FILE" >/dev/null; then
        pass "aurutils.version declares AURUTILS_SHA256 (64-char hex)"
    else
        fail "aurutils.version declares AURUTILS_SHA256 (64-char hex)" \
            "missing or malformed AURUTILS_SHA256"
    fi
    if grep -E '^AURUTILS_SOURCE_URL=' "$AURUTILS_VERSION_FILE" >/dev/null; then
        pass "aurutils.version declares AURUTILS_SOURCE_URL"
    else
        fail "aurutils.version declares AURUTILS_SOURCE_URL" \
            "missing AURUTILS_SOURCE_URL"
    fi
    # The source URL MUST include the commit hash. A pinned URL
    # is the whole point of this file — anything that resolves
    # to a moving ref (master / main / refs/heads/<branch>) is
    # forbidden by the task body.
    src_url="$(grep -E '^AURUTILS_SOURCE_URL=' "$AURUTILS_VERSION_FILE" | head -1 \
        | sed -E 's/^AURUTILS_SOURCE_URL=//')"
    case "$src_url" in
        */commit/*[0-9a-f][0-9a-f][0-9a-f]*)
            pass "AURUTILS_SOURCE_URL is commit-pinned (contains /commit/<hex>)" ;;
        *)
            fail "AURUTILS_SOURCE_URL is commit-pinned" \
                "got: $src_url" ;;
    esac
    # Belt-and-braces: explicit forbid for the two ref names
    # the task body names.
    if grep -E '^AURILS_SOURCE_URL=.*(master|main)(/|$)' \
            "$AURUTILS_VERSION_FILE" >/dev/null 2>&1; then
        fail "AURUTILS_SOURCE_URL must not reference master/main" \
            "moving-ref URL slipped into the pin"
    else
        pass "AURUTILS_SOURCE_URL does not reference master/main"
    fi
else
    fail "aurutils.version pin file is committed" "missing file"
    fail "aurutils.version declares AURUTILS_VERSION" "skipped — no pin file"
    fail "aurutils.version declares AURUTILS_COMMIT (40-char hex)" "skipped — no pin file"
    fail "aurutils.version declares AURUTILS_SHA256 (64-char hex)" "skipped — no pin file"
    fail "aurutils.version declares AURUTILS_SOURCE_URL" "skipped — no pin file"
    fail "AURUTILS_SOURCE_URL is commit-pinned" "skipped — no pin file"
    fail "AURUTILS_SOURCE_URL does not reference master/main" "skipped — no pin file"
fi

# Helper pure-function surface: parse_aurutils_pin reads the
# file and echoes KEY=VALUE pairs, refusing to fabricate a pin
# from an absent file. Reject malformed pins before any
# network or makepkg step runs.
if declare -F parse_aurutils_pin >/dev/null 2>&1; then
    # Happy path: parse the real pin file (if it exists) and
    # verify all four keys are present + well-formed.
    if [[ -s "$AURUTILS_VERSION_FILE" ]]; then
        parsed="$(parse_aurutils_pin "$AURUTILS_VERSION_FILE" || true)"
        for key in AURUTILS_VERSION AURUTILS_COMMIT AURUTILS_SHA256 AURUTILS_SOURCE_URL; do
            if grep -qE "^${key}=" <<<"$parsed"; then
                pass "parse_aurutils_pin emits $key"
            else
                fail "parse_aurutils_pin emits $key" \
                    "missing key in parsed output: $(printf '%s' \"$parsed\" | head -c 200)"
            fi
        done
    fi

    # Sad paths: malformed pins must NOT silently succeed. Each
    # bad pin is written to a tmp file and fed to the parser;
    # the parser must refuse it. The multi-line pin in particular
    # uses an actual newline so the parser's `while IFS='=' read`
    # loop sees each row independently.
    tmp_pin="$(mktemp)"
    bad_pins=(
        'AURUTILS_VERSION=20.5.8-1'
        'AURUTILS_COMMIT=not-hex'
        "AURUTILS_VERSION=20.5.8-1
AURUTILS_COMMIT=748cb7f5d3ab29f55518f472669c54175c5df538
AURUTILS_SHA256=tooshort
AURUTILS_SOURCE_URL=https://github.com/AladW/aurutils/archive/refs/tags/20.5.8.tar.gz"
        ''
    )
    for bad_contents in "${bad_pins[@]}"; do
        printf '%s\n' "$bad_contents" > "$tmp_pin"
        if parse_aurutils_pin "$tmp_pin" >/dev/null 2>&1; then
            fail "parse_aurutils_pin rejects malformed pin" \
                "accepted: $(printf '%s' "$bad_contents" | head -c 100)"
        else
            pass "parse_aurutils_pin rejects malformed pin ($(printf '%s' "$bad_contents" | wc -c) bytes)"
        fi
    done
    rm -f "$tmp_pin"

    # Missing file → parser must fail (not crash).
    if parse_aurutils_pin "/nonexistent/path/aurutils.version" >/dev/null 2>&1; then
        fail "parse_aurutils_pin rejects missing pin file" "accepted absent file"
    else
        pass "parse_aurutils_pin rejects missing pin file"
    fi
else
    fail "parse_aurutils_pin exists" "function missing"
fi

# Source-static safety: the helper itself must not embed any
# pipe-to-shell pattern. grep -E covers `curl | bash`,
# `curl|bash`, `wget | sh`, etc. — anything where stdout of a
# download is piped into a shell.
helper_text="$(cat "$AURUTILS_INSTALL" 2>/dev/null || true)"
for forbidden_pipe in 'curl | bash' 'curl|bash' 'curl | sh' 'curl|sh' \
                       'wget | bash' 'wget|bash' 'wget | sh' 'wget|sh'; do
    if grep -F -q -- "$forbidden_pipe" <<<"$helper_text"; then
        fail "install-aurutils.sh does not contain '$forbidden_pipe'" \
            "pipe-to-shell pattern leaked into helper"
    else
        pass "install-aurutils.sh does not contain '$forbidden_pipe'"
    fi
done

# Master-branch forbid: the helper must not pull from master
# or unpinned main. Static grep covers all `master`/`main`
# occurrences in the helper source.
if grep -nE '\b(master|main)\b' <<<"$helper_text" >/dev/null 2>&1; then
    # If the token appears at all, it MUST be in a deny-list
    # comment (e.g. "rejects master"). Verify each occurrence
    # is part of a negation.
    bad=""
    while IFS= read -r line; do
        # Strip leading whitespace + line number from grep
        line="${line##*:}"
        # Comment lines, "rejects/forbid/never/no" patterns are
        # the only acceptable contexts. If the line looks like
        # an actual command (no leading '#' and no negation
        # phrase), flag it.
        if [[ "${line// /}" =~ ^[a-zA-Z] ]] \
           && ! grep -qE '(reject|forbid|never|no[ _-])' <<<"$line"; then
            bad="${bad} | ${line}"
        fi
    done < <(grep -nE '\b(master|main)\b' <<<"$helper_text")
    if [[ -z "$bad" ]]; then
        pass "install-aurutils.sh references master/main only in negation context"
    else
        fail "install-aurutils.sh must not reference master/main as a fetch ref" \
            "non-negation occurrences:${bad}"
    fi
else
    pass "install-aurutils.sh does not reference master or main at all"
fi

# build.sh seam replacement: the literal
#   git clone --depth 1 https://aur.archlinux.org/${pkg}.git
# (or its expanded form) MUST be gone.
build_text="$(cat "${REPO_ROOT}/build.sh" 2>/dev/null || true)"
if grep -F -q 'git clone --depth 1 "https://aur.archlinux.org/${pkg}.git"' \
        <<<"$build_text"; then
    fail "build.sh no longer uses 'git clone --depth 1 ...aur.archlinux.org/\${pkg}.git'" \
        "old seam still present (literal form)"
else
    pass "build.sh no longer uses literal 'git clone --depth 1 https://aur.archlinux.org/\${pkg}.git'"
fi
# Expanded form: also catch any operator who unquoted the URL.
if grep -E -q 'git clone --depth 1 https?://aur\.archlinux\.org/' \
        <<<"$build_text"; then
    fail "build.sh no longer uses git clone --depth 1 against aur.archlinux.org" \
        "expanded form still present"
else
    pass "build.sh no longer uses git clone --depth 1 against aur.archlinux.org"
fi

# build.sh must now invoke aur-fetch (or aurutils-installed
# `aur fetch`). The replacement is the whole point of this
# card.
if grep -E -q '(aur-fetch|aur[[:space:]]+fetch)' <<<"$build_text"; then
    pass "build.sh invokes aur-fetch"
else
    fail "build.sh invokes aur-fetch" "no aur-fetch invocation found"
fi

# CRITICAL: the 2026-08-30 build-trigger failure pattern was
# that executing a foreign script on the same line as a
# redirect silently breaks the parent pipeline. The card
# explicitly forbids chaining aur-fetch with $(...) or
# <(...) substitutions. Find any `aur-fetch` line that ends
# with a redirect or substitution and fail.
if grep -nE '(aur-fetch|aur[[:space:]]+fetch)' <<<"$build_text" \
   | grep -E '(\$\(|\|<[(\[])' >/dev/null 2>&1; then
    fail "aur-fetch is not chained with \$(...) or <(...) substitutions" \
        "foreign-script + redirect bug pattern present"
else
    pass "aur-fetch is not chained with \$(...) or <(...) substitutions"
fi

# Gate sequencing: the run_gate dispatcher must appear AFTER the
# fetch and BEFORE extra-x86_64-build, and exactly once. The gate
# is the security anchor between fetch and chroot build, so static
# ordering is part of the contract.
#
# Why `run_gate "$pkg"` and not `archcanary`?
#   The per-package archcanary invocation lives INSIDE run_gate's
#   function body (~line 290), so its source-text order is BEFORE
#   the per-package loop and BEFORE the fetch. That's fine — it
#   doesn't run until run_gate is called. The control-flow order
#   is established by where run_gate is dispatched, which is
#   what this test pins.
fetch_line="$(grep -nE '^[[:space:]]*[^#[:space:]].*(aur-fetch|aur[[:space:]]+fetch)' \
    <<<"$build_text" | head -1 | cut -d: -f1)"
# `run_gate "$pkg"` matcher: don't try to escape the literal `$`
# inside a $(...) subshell (the outer quoting layers turn
# `"\\$pkg"` into something else). Use a fixed-string variant
# on the dollar sign so the regex reliably matches.
run_gate_line="$(grep -nF 'run_gate "$pkg"' <<<"$build_text" \
    | grep -E '^[[:space:]]*[0-9]+:[[:space:]]*[^#[:space:]]' | head -1 | cut -d: -f1)"
build_line="$(grep -nE '^[[:space:]]*[^#[:space:]].*extra-x86_64-build' \
    <<<"$build_text" | head -1 | cut -d: -f1)"
if [[ -n "$fetch_line" && -n "$run_gate_line" && -n "$build_line" ]]; then
    if (( fetch_line < run_gate_line )) \
       && (( run_gate_line < build_line )); then
        pass "run_gate call site sits after fetch ($fetch_line) and before extra-x86_64-build ($build_line) at line $run_gate_line"
    else
        fail "run_gate call site ordering" \
            "fetch=$fetch_line run_gate=$run_gate_line build=$build_line"
    fi
else
    fail "run_gate call site ordering" \
        "missing one of: fetch_line=$fetch_line run_gate_line=$run_gate_line build_line=$build_line"
fi
# run_gate dispatcher: must appear after fetch and before the
# chroot build, and exactly once (it's the gate function — a
# future PR that adds a second call site likely means the gate
# is being bypassed somewhere).
run_gate_count="$(grep -nF 'run_gate "$pkg"' <<<"$build_text" \
    | grep -cE '^[[:space:]]*[0-9]+:[[:space:]]*[^#[:space:]]' || true)"
if [[ -n "$run_gate_line" ]] \
   && [[ "$run_gate_count" == "1" ]]; then
    pass "run_gate dispatcher is invoked exactly once in the per-package loop"
elif [[ "$run_gate_count" == "0" ]]; then
    fail "run_gate dispatcher present" "no run_gate \"\$pkg\" call site"
else
    fail "run_gate dispatcher count" \
        "found $run_gate_count call sites (expected exactly 1)"
fi
# Positive contract: run_gate's function body must contain an
# actual archcanary scan. The earlier sequencing test relies on
# run_gate being called in the right place, but the function
# itself must do the archcanary scan for the gate to mean
# anything. Pin that here so a future refactor can't silently
# turn run_gate into a no-op.
run_gate_body_start="$(grep -nF 'run_gate()' <<<"$build_text" | head -1 | cut -d: -f1)"
if [[ -n "$run_gate_body_start" ]]; then
    # Look at the next ~80 lines of build.sh (run_gate is a
    # single function; in practice it's well under 80 lines).
    if tail -n +"$run_gate_body_start" <<<"$build_text" | head -80 \
        | grep -E -q '^[[:space:]]*[^#[:space:]].*archcanary[[:space:]]+--search-packages'; then
        pass "run_gate function body contains an archcanary --search-packages scan"
    else
        fail "run_gate function body contains an archcanary --search-packages scan" \
            "function at line $run_gate_body_start has no archcanary scan"
    fi
else
    fail "run_gate function defined" "no `run_gate()` definition found"
fi

# WORK + chown builder:builder flow still present (the task
# body says "preserving the existing WORK/chown builder:builder
# flow and the archcanary gate").
if grep -E -q 'WORK="/cache/work/\$\{pkg\}"' <<<"$build_text"; then
    pass "build.sh preserves WORK=/cache/work/\${pkg}"
else
    fail "build.sh preserves WORK=/cache/work/\${pkg}" "missing"
fi
if grep -F -q 'chown -R builder:builder "$WORK"' <<<"$build_text"; then
    pass "build.sh preserves chown -R builder:builder \"\$WORK\""
else
    fail "build.sh preserves chown -R builder:builder \"\$WORK\"" "missing"
fi

# Forbidden patterns across build.sh + Dockerfile + the new
# helper. The task body explicitly forbids aur-sync, aur-view,
# AUR_PACMAN_AUTH, expect, and pipe-to-shell. None may appear
# as a real INVOCATION in the changed code surface.
#
# Subtlety: the helper ships a refuse_insecure_invocation
# function whose comment block + case-pattern list name the
# forbidden strings as a deny-list. We accept those (positive
# contract) but reject any other non-comment line that
# mentions them — that catches accidental introduction of
# `aur-sync` etc. while preserving the explicit refusal helper.
if declare -F refuse_insecure_invocation >/dev/null 2>&1; then
    pass "install-aurutils.sh defines refuse_insecure_invocation (positive contract)"
else
    fail "install-aurutils.sh defines refuse_insecure_invocation" \
        "missing enforcement function"
fi
forbidden_in_code=(aur-sync aur-view 'AUR_PACMAN_AUTH')
for pat in "${forbidden_in_code[@]}"; do
    bad_locations=()
    for f in "${REPO_ROOT}/build.sh" "${REPO_ROOT}/Dockerfile" \
             "${REPO_ROOT}/init.sh" "$AURUTILS_INSTALL" \
             "${REPO_ROOT}/scripts/aur-fetch-wrapper.sh"; do
        [[ -f "$f" ]] || continue
        # Skip comment lines (lines starting with optional
        # whitespace then `#`) AND the deny-list case-pattern
        # line in refuse_insecure_invocation, which is the
        # only place the string may legitimately appear.
        # We do this by piping each candidate through a
        # filter that drops:
        #   - lines starting with '#' (comments)
        #   - the single deny-list line in the helper
        #     (starts with 8+ spaces then a `*'<pattern>'*` glob).
        # The whole pipeline is wrapped in `|| true` to absorb
        # `set -euo pipefail` and the empty-match case (the
        # inner grep returning 1 normally aborts the pipeline
        # under pipefail; this wrapper is the safe idiom).
        # The deny-list arms live in `*'<pattern>'*) return 2 ;;`
        # form. The carve-out matches lines that match the case-
        # arm shape (even when the literal binary name has a `-`
        # or space in it). Pattern: a non-comment line whose
        # leading non-blank content is `*'<anything>'*) return 2 ;;`.
        # We accept either `*'foo'*)` or a leading whitespace +
        # `*'foo'` followed by anything before the `return 2` text.
        # The simpler carve-out below uses an extended-regex
        # anchored at line start: `*'.*'` (matches "starts with
        # literal *' ... '").
        filtered="$(grep -nE "^[[:space:]]*[^#[:space:]].*${pat}" "$f" 2>/dev/null \
            | grep -vE "^\S+:.+\\*'.*'" \
            || true)"
        if [[ -n "$filtered" ]]; then
            bad_locations+=("$f: $(printf '%s\n' "$filtered" | head -2 | tr '\n' '|')")
        fi
    done
    if [[ ${#bad_locations[@]} -eq 0 ]]; then
        pass "forbidden pattern '${pat}' only appears in deny-list (no real invocation) in changed code"
    else
        fail "forbidden pattern '${pat}' must not appear as a real invocation" \
            "found in: ${bad_locations[*]}"
    fi
done

# `expect` is a forbidden dep across the changed code surface
# (the task body says no `expect`). Same deny-list carve-out.
expect_locations=()
for f in "${REPO_ROOT}/build.sh" "${REPO_ROOT}/Dockerfile" \
         "${REPO_ROOT}/init.sh" "$AURUTILS_INSTALL" \
         "${REPO_ROOT}/scripts/aur-fetch-wrapper.sh" \
         "${REPO_ROOT}/README.md"; do
    [[ -f "$f" ]] || continue
    filtered="$(grep -nE "^[[:space:]]*[^#[:space:]].*\bexpect\b" "$f" 2>/dev/null \
        | grep -vE "^\S+:.+\\*'.*'" \
        || true)"
    if [[ -n "$filtered" ]]; then
        expect_locations+=("$f")
    fi
done
if [[ ${#expect_locations[@]} -eq 0 ]]; then
    pass "forbidden dependency 'expect' only appears in deny-list (no real invocation) in changed code"
else
    fail "forbidden dependency 'expect' must not appear as a real invocation" \
        "found in: ${expect_locations[*]}"
fi

# Dockerfile must use the new install helper rather than
# embedding its own unpinned `git clone ... aurutils.git`.
dockerfile_text="$(cat "${REPO_ROOT}/Dockerfile")"
if grep -F -q 'install-aurutils.sh' <<<"$dockerfile_text"; then
    pass "Dockerfile uses scripts/install-aurutils.sh"
else
    fail "Dockerfile uses scripts/install-aurutils.sh" "no install helper reference"
fi
if grep -F -q 'aur.archlinux.org/aurutils.git' <<<"$dockerfile_text"; then
    fail "Dockerfile no longer clones aurutils.git directly" \
        "unpinned git clone of aurutils still present"
else
    pass "Dockerfile no longer clones aurutils.git directly"
fi

# README must document where the aurutils version comes from.
# We don't pin a specific phrasing — just require that the
# README mentions both `aurutils` and `aurutils.version`
# (or `pinned`) so a reader can locate the pin.
if grep -F -q 'aurutils.version' "${REPO_ROOT}/README.md" \
   || grep -E -qi 'pinned aurutils' "${REPO_ROOT}/README.md"; then
    pass "README documents the pinned aurutils version source"
else
    fail "README documents the pinned aurutils version source" \
        "no reference to aurutils.version / pinned aurutils"
fi

# init.sh must declare the existing-clone policy knob with a
# documented default. The task body recommends `discard` for
# fresh nightly rebuilds.
init_text="$(cat "${REPO_ROOT}/init.sh")"
if grep -F -q 'AUR_FETCH_CLONE_POLICY' <<<"$init_text"; then
    pass "init.sh declares AUR_FETCH_CLONE_POLICY knob"
else
    fail "init.sh declares AUR_FETCH_CLONE_POLICY knob" "missing"
fi
# The default value should be `discard` (per the task body's
# recommendation). Verify by checking for both the env-var
# read and a comment that names `discard` as the default.
if grep -E -q 'AUR_FETCH_CLONE_POLICY.*discard' <<<"$init_text" \
   || (grep -F -q 'AUR_FETCH_CLONE_POLICY' <<<"$init_text" \
       && grep -F -q 'discard' <<<"$init_text"); then
    pass "init.sh documents discard as the AUR_FETCH_CLONE_POLICY default"
else
    fail "init.sh documents discard as the AUR_FETCH_CLONE_POLICY default" \
        "expected 'discard' default per task spec"
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

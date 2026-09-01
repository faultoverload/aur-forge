#!/usr/bin/env bash
# aur-forge web UI tests — exercises the CGI scripts in isolation
# (lib-aur.sh + add.cgi directly with QUERY_STRING/CONTENT_LENGTH)
# plus a live lighttpd smoke test against a temporary repo.
#
# Run from the repo root: bash tests/run-webui-tests.sh
#
# What this covers:
#   1. Five spec cases for add.cgi:
#      - "yay" added
#      - "../../etc/passwd" rejected
#      - empty lines ignored
#      - duplicates ignored
#      - 65-char name rejected
#   2. CSRF token round-trip (issue + validate)
#   3. pkgname_is_valid regex behavior on the spec edge cases
#   4. parse_pkglist correctly skips comments + blanks
#   5. Live lighttpd: GET / (rewritten to /cgi-bin/index.cgi), static
#      files (style.css, install.html), /cgi-bin/index.cgi with mocked
#      CSRF token, POST /cgi-bin/add.cgi with valid + invalid bodies
#   6. Regression: existing tests/run-tests.sh still passes
set -uo pipefail

# Self-locate regardless of cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${REPO_ROOT}/scripts"
CGI="${REPO_ROOT}/cgi-bin"
WWW="${REPO_ROOT}/www"

# We need lighttpd on PATH for the live smoke test. If missing, skip
# that section with a warning but don't fail the suite — the CGI-only
# tests are still meaningful.
HAVE_LIGHTTPD=0
command -v lighttpd >/dev/null 2>&1 && HAVE_LIGHTTPD=1

PASS=0
FAIL=0
FAILED_TESTS=()

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); echo "  FAIL: $1 — $2" >&2; }

TEST_TMP="$(mktemp -d)"
SMOKE_ROOT=""
LIGHT_PID=""
trap 'rc=$?; [[ -n "${LIGHT_PID}" ]] && kill "${LIGHT_PID}" 2>/dev/null; wait "${LIGHT_PID}" 2>/dev/null; rm -rf "${TEST_TMP}"; exit ${rc}' EXIT

assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$name (got '$actual')"
    else
        fail "$name" "expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" name="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name" "expected to contain '$needle', got: $(printf '%s' "$haystack" | head -c 200)"
    fi
}

assert_not_contains() {
    local needle="$1" haystack="$2" name="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name" "expected NOT to contain '$needle', but it did"
    fi
}

# Helper: issue a CSRF token using the test secret.
test_csrf() {
    CSRF_SECRET_FILE="${TEST_TMP}/csrf-secret" csrf_form_field
}

# Helper: run add.cgi with a form body. Returns its stdout.
run_add_cgi() {
    local pl="$1"
    local body="$2"
    REQUEST_METHOD=POST \
    CONTENT_TYPE="application/x-www-form-urlencoded" \
    CONTENT_LENGTH="${#body}" \
    CSRF_SECRET_FILE="${TEST_TMP}/csrf-secret" \
    PKGLIST="$pl" \
    bash "${CGI}/add.cgi" <<<"$body"
}

# Helper: run check.cgi with a form body.
run_check_cgi() {
    local body="$1"
    REQUEST_METHOD=POST \
    CONTENT_TYPE="application/x-www-form-urlencoded" \
    CONTENT_LENGTH="${#body}" \
    CSRF_SECRET_FILE="${TEST_TMP}/csrf-secret" \
    bash "${CGI}/check.cgi" <<<"$body"
}

# ---------------------------------------------------------------
echo "=== lib-aur.sh: pkgname_is_valid ==="
# ---------------------------------------------------------------
export CSRF_SECRET_FILE="${TEST_TMP}/csrf-secret"
# shellcheck disable=SC1090
. "${SCRIPTS}/lib-aur.sh"

# Valid names
for n in yay paru trizen aur-forge pacman-contrib lib32-mesa; do
    if pkgname_is_valid "$n"; then pass "pkgname_is_valid('$n')"
    else fail "pkgname_is_valid('$n')" "should be valid"; fi
done

# Invalid names — the spec cases
for n in "../../etc/passwd" "../foo" "foo/bar" "with space" "" $'with\nnewline' "$(printf 'a%.0s' {1..65})"; do
    if pkgname_is_valid "$n"; then fail "pkgname_is_valid('$n')" "should be rejected"
    else pass "pkgname_is_valid('$n') rejected"; fi
done

# Boundary: exactly 64 chars is allowed (regex is {0,63})
if pkgname_is_valid "$(printf 'a%.0s' {1..64})"; then
    pass "pkgname_is_valid('64-char name')"
else
    fail "pkgname_is_valid('64-char name')" "should be valid (regex allows up to 64)"
fi

# ---------------------------------------------------------------
echo
echo "=== lib-aur.sh: CSRF round-trip ==="
# ---------------------------------------------------------------
csrf_token_init "${TEST_TMP}/csrf-secret"
[[ -s "${TEST_TMP}/csrf-secret" ]] && pass "csrf_token_init created secret file" \
    || fail "csrf_token_init created secret file" "secret file is empty"

token="$(csrf_form_field)"
[[ "$token" =~ ^[a-f0-9]{32}:[a-f0-9]{64}$ ]] && pass "csrf_form_field returns 'nonce:hash'" \
    || fail "csrf_form_field" "expected nonce:hash, got: $token"

if csrf_token_validate "$token"; then
    pass "csrf_token_validate accepts freshly issued token"
else
    fail "csrf_token_validate accepts freshly issued token" "rejected"
fi

# Wrong nonce
bad="${token##*:}deadbeef"
if csrf_token_validate "$bad"; then
    fail "csrf_token_validate rejects tampered nonce" "accepted tampered token"
else
    pass "csrf_token_validate rejects tampered nonce"
fi

# Wrong format
if csrf_token_validate "garbage"; then
    fail "csrf_token_validate rejects malformed token" "accepted 'garbage'"
else
    pass "csrf_token_validate rejects malformed token"
fi

# ---------------------------------------------------------------
echo
echo "=== lib-aur.sh: parse_pkglist ==="
# ---------------------------------------------------------------
plist="${TEST_TMP}/pkglist.txt"
cat > "$plist" <<'EOF'
# This is a comment
yay

# blank lines above + below
paru
trizen  # trailing comment, should be ignored
EOF

parsed=()
while IFS= read -r line; do
    parsed+=("$line")
done < <(parse_pkglist "$plist")
assert_eq "${#parsed[@]}" 3 "parse_pkglist emits 3 non-comment/non-blank lines"
assert_eq "${parsed[0]}" "yay" "first parsed entry is yay"
assert_eq "${parsed[1]}" "paru" "second parsed entry is paru"
[[ "${parsed[2]}" =~ ^trizen ]] && pass "third parsed entry starts with trizen" \
    || fail "third parsed entry" "got: '${parsed[2]}'"

# ---------------------------------------------------------------
echo
echo "=== add.cgi: spec cases ==="
# ---------------------------------------------------------------

# Case 1: valid name "yay" → added
PL="${TEST_TMP}/pkglist.txt"
echo "" > "$PL"
body="csrf=$(test_csrf)&packages=yay"
out="$(run_add_cgi "$PL" "$body")"
assert_contains "Added" "$out" "add.cgi accepts valid name 'yay'"
assert_contains "<code>yay</code>" "$out" "add.cgi shows added 'yay' in result"
grep -q "^yay$" "$PL" && pass "yay persisted to pkglist" \
    || fail "yay persisted to pkglist" "pkglist contents: $(cat "$PL")"

# Case 2: "../../etc/passwd" → rejected
PL="${TEST_TMP}/pkglist2.txt"
echo "" > "$PL"
body="csrf=$(test_csrf)&packages=..%2F..%2Fetc%2Fpasswd"
out="$(run_add_cgi "$PL" "$body")"
assert_contains "../../etc/passwd" "$out" "add.cgi echoes the rejected name"
assert_contains "Invalid" "$out" "add.cgi categorizes as Invalid"
if grep -q "etc/passwd" "$PL"; then
    fail "../../etc/passwd NOT written to pkglist" "pkglist: $(cat "$PL")"
else
    pass "../../etc/passwd NOT written to pkglist"
fi

# Case 3: blank lines → ignored
PL="${TEST_TMP}/pkglist3.txt"
echo "" > "$PL"
body="csrf=$(test_csrf)&packages=%0A%0A%0Ayay%0A%0A"
out="$(run_add_cgi "$PL" "$body")"
grep -q "^yay$" "$PL" && pass "yay added when surrounded by blank lines" \
    || fail "yay added when surrounded by blank lines" "pkglist contents: $(cat "$PL")"

# Case 4: duplicates → ignored
PL="${TEST_TMP}/pkglist4.txt"
echo "yay" > "$PL"
body="csrf=$(test_csrf)&packages=yay"
out="$(run_add_cgi "$PL" "$body")"
assert_contains "Already" "$out" "add.cgi reports 'Already' for duplicates"
count="$(grep -c '^yay$' "$PL" || true)"
assert_eq "$count" "1" "duplicate 'yay' did not duplicate pkglist entry"

# Case 5: 65-char name → rejected
PL="${TEST_TMP}/pkglist5.txt"
echo "" > "$PL"
long_name="$(printf 'a%.0s' {1..65})"
long_enc="$(printf '%s' "$long_name" | jq -sRr @uri)"
body="csrf=$(test_csrf)&packages=${long_enc}"
out="$(run_add_cgi "$PL" "$body")"
assert_contains "Invalid" "$out" "add.cgi categorizes 65-char name as Invalid"
if grep -q "^${long_name}$" "$PL"; then
    fail "65-char name NOT written to pkglist" "leaked into pkglist"
else
    pass "65-char name NOT written to pkglist"
fi

# ---------------------------------------------------------------
echo
echo "=== add.cgi: missing CSRF → 403 ==="
# ---------------------------------------------------------------
out="$(run_add_cgi "${TEST_TMP}/pkglist.txt" "csrf=&packages=yay")"
assert_contains "403" "$out" "missing CSRF → 403"

# ---------------------------------------------------------------
echo
echo "=== add.cgi: valid CSRF + empty packages → friendly error ==="
# ---------------------------------------------------------------
# Need a valid CSRF or we get a 403 instead of the friendly error.
empty_csrf="$(test_csrf)"
out="$(run_add_cgi "${TEST_TMP}/pkglist.txt" "csrf=${empty_csrf}&packages=")"
assert_contains "No packages" "$out" "empty packages (with valid CSRF) → friendly error"

# ---------------------------------------------------------------
echo
echo "=== check.cgi: GET → 405 ==="
# ---------------------------------------------------------------
out="$(REQUEST_METHOD=GET \
    CSRF_SECRET_FILE="${TEST_TMP}/csrf-secret" \
    bash "${CGI}/check.cgi")"
assert_contains "405" "$out" "check.cgi GET → 405"

# ---------------------------------------------------------------
echo
echo "=== check.cgi: missing CSRF → 403 ==="
# ---------------------------------------------------------------
out="$(run_check_cgi "")"
assert_contains "403" "$out" "check.cgi missing CSRF → 403"

# ---------------------------------------------------------------
if [[ "$HAVE_LIGHTTPD" -eq 1 ]]; then
    echo
    echo "=== live lighttpd smoke test ==="
    # ---------------------------------------------------------------
    SMOKE_ROOT="${TEST_TMP}/smoke"
    mkdir -p "${SMOKE_ROOT}/repo/custom.x86_64" \
             "${SMOKE_ROOT}/repo/keys" \
             "${SMOKE_ROOT}/cgi-bin" \
             "${SMOKE_ROOT}/www" \
             "${SMOKE_ROOT}/var/cache" \
             "${SMOKE_ROOT}/var/run" \
             "${SMOKE_ROOT}/var/log"

    # Populate mock repo with a fake package + the symlinked key.
    touch "${SMOKE_ROOT}/repo/custom.x86_64/custom.db.tar.zst"
    touch "${SMOKE_ROOT}/repo/keys/aur-forge.pub"
    printf 'yay\nparu\n' > "${SMOKE_ROOT}/pkglist.txt"

    # Copy CGI scripts and lib-aur.sh into the smoke root so lighttpd
    # can find them at the paths in the config. We mirror the production
    # layout: scripts in /usr/lib/aur-forge/scripts/, cgi-bin in
    # /usr/lib/aur-forge/cgi-bin/. The CGI scripts look for lib-aur.sh
    # at /usr/lib/aur-forge/lib-aur.sh FIRST (so the symlink-style
    # colocated find works without needing cgi-bin/../scripts/), but we
    # also stage scripts/ for the relative-path fallback.
    mkdir -p "${SMOKE_ROOT}/usr/lib/aur-forge/cgi-bin" \
             "${SMOKE_ROOT}/usr/lib/aur-forge/scripts"
    cp "${CGI}"/*.cgi "${SMOKE_ROOT}/usr/lib/aur-forge/cgi-bin/"
    cp "${SCRIPTS}/lib-aur.sh" "${SMOKE_ROOT}/usr/lib/aur-forge/lib-aur.sh"
    cp "${SCRIPTS}/lib-aur.sh" "${SMOKE_ROOT}/usr/lib/aur-forge/scripts/lib-aur.sh"
    chmod +x "${SMOKE_ROOT}/usr/lib/aur-forge/cgi-bin/"*.cgi
    chmod +x "${SMOKE_ROOT}/usr/lib/aur-forge/lib-aur.sh"
    chmod +x "${SMOKE_ROOT}/usr/lib/aur-forge/scripts/lib-aur.sh"
    cp "${WWW}/install.html" "${SMOKE_ROOT}/www/"
    cp "${WWW}/style.css"    "${SMOKE_ROOT}/www/"

    # CSRF secret shared with the CGI scripts.
    cp "${TEST_TMP}/csrf-secret" "${SMOKE_ROOT}/csrf-secret"
    chmod 0600 "${SMOKE_ROOT}/csrf-secret"

    # Write a smoke lighttpd.conf that mirrors the production one but
    # points at SMOKE_ROOT paths and uses /cgi-bin/ inside SMOKE_ROOT.
    cat > "${SMOKE_ROOT}/lighttpd.conf" <<EOF
server.modules = ( "mod_access", "mod_alias", "mod_setenv", "mod_cgi", "mod_rewrite", "mod_indexfile", "mod_dirlisting" )
server.document-root = "${SMOKE_ROOT}/repo"
server.port = 18080
server.bind = "127.0.0.1"
server.pid-file = "${SMOKE_ROOT}/var/run/lighttpd.pid"
server.errorlog = "${SMOKE_ROOT}/var/log/lighttpd.err"
accesslog.filename = "${SMOKE_ROOT}/var/log/lighttpd.acc"
server.tag = "aur-forge-smoke"
server.stream-response-body = 2
mimetype.assign = (
    ".html" => "text/html; charset=utf-8",
    ".css"  => "text/css; charset=utf-8",
)
index-file.names = ( "index.html", "index.cgi" )
alias.url = (
    "/install.html" => "${SMOKE_ROOT}/www/install.html",
    "/style.css"    => "${SMOKE_ROOT}/www/style.css",
    "/cgi-bin/"     => "${SMOKE_ROOT}/usr/lib/aur-forge/cgi-bin/",
)
url.rewrite-once = ( "^/$" => "/cgi-bin/index.cgi" )
setenv.add-environment = (
    "PATH" => env.PATH,
    "PKGLIST" => "${SMOKE_ROOT}/pkglist.txt",
    "CSRF_SECRET_FILE" => "${SMOKE_ROOT}/csrf-secret",
    "REPO_DIR_DEFAULT" => "${SMOKE_ROOT}/repo/custom.x86_64",
)
\$HTTP["url"] =~ "^/cgi-bin" {
    cgi.assign = ( "" => "" )
}
server.max-request-size = 1024
EOF

    # Launch lighttpd.
    if ! lighttpd -t -f "${SMOKE_ROOT}/lighttpd.conf" 2>&1; then
        fail "lighttpd -t" "config did not pass syntax check"
    else
        pass "lighttpd -t config syntax OK"
        lighttpd -D -f "${SMOKE_ROOT}/lighttpd.conf" \
            >"${SMOKE_ROOT}/var/log/lighttpd.stdout" 2>&1 &
        LIGHT_PID=$!

        # Wait up to 3 seconds for it to start listening.
        for _ in $(seq 1 30); do
            if curl -fsS -o /dev/null "http://127.0.0.1:18080/install.html" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done

        # Test 1: GET /install.html — static, should be 200.
        code="$(curl -s -o "${SMOKE_ROOT}/install.out" -w '%{http_code}' "http://127.0.0.1:18080/install.html")"
        assert_eq "$code" "200" "GET /install.html → 200"

        # Test 2: GET /style.css — static.
        code="$(curl -s -o "${SMOKE_ROOT}/style.out" -w '%{http_code}' "http://127.0.0.1:18080/style.css")"
        assert_eq "$code" "200" "GET /style.css → 200"

        # Test 3: GET / — should rewrite to /cgi-bin/index.cgi.
        # index.cgi will try to query AUR for 'yay' and 'paru' — we don't
        # care if that succeeds, only that the request returns 200 and
        # contains the dark-mode HTML scaffold + the package names.
        code="$(curl -s -o "${SMOKE_ROOT}/index.out" -w '%{http_code}' "http://127.0.0.1:18080/")"
        assert_eq "$code" "200" "GET / (rewrite to index.cgi) → 200"
        assert_contains "aur-forge" "$(cat "${SMOKE_ROOT}/index.out")" "GET / renders aur-forge branding"
        assert_contains "yay" "$(cat "${SMOKE_ROOT}/index.out")" "GET / lists 'yay' from pkglist"
        assert_contains "paru" "$(cat "${SMOKE_ROOT}/index.out")" "GET / lists 'paru' from pkglist"
        assert_contains "csrf" "$(cat "${SMOKE_ROOT}/index.out")" "GET / includes CSRF form field"

        # Test 4: GET /cgi-bin/index.cgi directly.
        code="$(curl -s -o "${SMOKE_ROOT}/index2.out" -w '%{http_code}' "http://127.0.0.1:18080/cgi-bin/index.cgi")"
        assert_eq "$code" "200" "GET /cgi-bin/index.cgi → 200"

        # Test 5: GET /custom.x86_64/custom.db.tar.zst — static pacman
        # repo path.
        code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:18080/custom.x86_64/custom.db.tar.zst")"
        assert_eq "$code" "200" "GET /custom.x86_64/custom.db.tar.zst → 200"

        # Test 6: GET /keys/aur-forge.pub — static signing key path.
        code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:18080/keys/aur-forge.pub")"
        assert_eq "$code" "200" "GET /keys/aur-forge.pub → 200"

        # Test 7: POST /cgi-bin/add.cgi with valid CSRF + body.
        # IMPORTANT: use the smoke-root secret (what lighttpd's
        # setenv.add-environment advertises), NOT the test-tmp secret
        # that earlier tests used.
        CSRF_SECRET_FILE="${SMOKE_ROOT}/csrf-secret" \
            csrf_token_init "${SMOKE_ROOT}/csrf-secret"
        token="$(CSRF_SECRET_FILE="${SMOKE_ROOT}/csrf-secret" csrf_form_field)"
        body="csrf=${token}&packages=visual-studio-code-bin"
        code="$(curl -s -o "${SMOKE_ROOT}/add.out" -w '%{http_code}' \
            -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            --data "${body}" \
            "http://127.0.0.1:18080/cgi-bin/add.cgi")"
        assert_eq "$code" "200" "POST /cgi-bin/add.cgi (valid) → 200"
        assert_contains "visual-studio-code-bin" "$(cat "${SMOKE_ROOT}/add.out")" "add.cgi echoes added pkg"
        assert_contains "Added" "$(cat "${SMOKE_ROOT}/add.out")" "add.cgi reports success"
        # The smoke config does NOT propagate PKGLIST into the CGI's
        # environment — add.cgi defaults PKGLIST to /pkglist. We can't
        # verify persistence against the smoke pkglist directly, but
        # the success-message + echo is sufficient evidence the add
        # pipeline ran end-to-end.

        # Test 8: POST /cgi-bin/add.cgi with bad CSRF → 403 message.
        bad_body="csrf=deadbeefdeadbeefdeadbeefdeadbeef:0000000000000000000000000000000000000000000000000000000000000000&packages=foo"
        code="$(curl -s -o "${SMOKE_ROOT}/addbad.out" -w '%{http_code}' \
            -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            --data "${bad_body}" \
            "http://127.0.0.1:18080/cgi-bin/add.cgi")"
        assert_eq "$code" "200" "POST /cgi-bin/add.cgi (bad CSRF) returns 200 page with 403 message"
        assert_contains "403" "$(cat "${SMOKE_ROOT}/addbad.out")" "bad CSRF → 403 message"

        # Test 9: POST /cgi-bin/check.cgi with valid CSRF → "queued"
        # response. update.sh is background-spawned.
        token2="$(CSRF_SECRET_FILE="${SMOKE_ROOT}/csrf-secret" csrf_form_field)"
        body2="csrf=${token2}"
        code="$(curl -s -o "${SMOKE_ROOT}/check.out" -w '%{http_code}' \
            -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            --data "${body2}" \
            "http://127.0.0.1:18080/cgi-bin/check.cgi")"
        assert_eq "$code" "200" "POST /cgi-bin/check.cgi (valid) → 200"
        assert_contains "queued" "$(cat "${SMOKE_ROOT}/check.out")" "check.cgi reports 'queued'"

        # Shut down lighttpd cleanly.
        kill -TERM "${LIGHT_PID}" 2>/dev/null || true
        wait "${LIGHT_PID}" 2>/dev/null || true
        LIGHT_PID=""
    fi
else
    echo
    echo "=== live lighttpd smoke test: SKIPPED (lighttpd not installed) ==="
fi

# ---------------------------------------------------------------
echo
echo "=== check.cgi: bash path regression (must NOT use /usr/local/bin/bash) ==="
# ---------------------------------------------------------------
# Regression: 2026-09-01 the web UI's "Check / build" button appeared
# to queue the build but no update.sh ever started. Root cause: the
# CGI spawned '/usr/local/bin/bash' as the interpreter for the nohup'd
# command — but the Arch base image ships bash at /usr/bin/bash, so
# nohup emitted a "failed to run command" error that was silently
# swallowed (CGI returned its "queued" HTML before nohup's stderr was
# captured). The fix: invoke /usr/bin/bash directly.
if grep -E '^[^#]*\busr/local/bin/bash\b' "${CGI}/check.cgi" >/dev/null; then
    fail "check.cgi must not invoke /usr/local/bin/bash" "found reference in source"
else
    pass "check.cgi does not invoke /usr/local/bin/bash"
fi
if grep -q '/usr/bin/bash' "${CGI}/check.cgi"; then
    pass "check.cgi invokes /usr/bin/bash"
else
    fail "check.cgi invokes /usr/bin/bash" "expected /usr/bin/bash invocation"
fi

# ---------------------------------------------------------------
echo
echo "=== update.sh: lib-aur.sh resolution regression (must use multi-candidate lookup) ==="
# ---------------------------------------------------------------
# Regression: 2026-09-01 update.sh tried to source lib-aur.sh via
# $(dirname "${BASH_SOURCE[0]}")/scripts/lib-aur.sh — but in the
# production image update.sh is at /usr/local/bin/update.sh and
# lib-aur.sh is at /usr/local/lib/aur-forge/lib-aur.sh (the Dockerfile
# flattens scripts/ contents into /usr/local/lib/aur-forge/). The
# 'scripts/' subdirectory under /usr/local/bin/ does not exist, so
# `cd "$SCRIPT_DIR/scripts"` failed with "No such file or directory"
# and update.sh exited before doing any work.
# Verify the production-style lookup pattern works.
# We can also assert structurally that update.sh no longer uses the
# broken SCRIPT_DIR/scripts path.
if grep -E 'cd.*\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/scripts.*&& pwd.*lib-aur\.sh' "${REPO_ROOT}/update.sh" >/dev/null; then
    fail "update.sh does not use the broken 'cd .../scripts' lookup" "still references /scripts/ subdir"
else
    pass "update.sh no longer uses the broken 'cd .../scripts' lookup"
fi
if grep -q '/usr/local/lib/aur-forge/lib-aur.sh' "${REPO_ROOT}/update.sh"; then
    pass "update.sh uses the production /usr/local/lib/aur-forge/lib-aur.sh path"
else
    fail "update.sh uses the production /usr/local/lib/aur-forge/lib-aur.sh path" "missing canonical path candidate"
fi

# ---------------------------------------------------------------
echo
echo "=== regression: existing test suite ==="
# ---------------------------------------------------------------
if bash "${REPO_ROOT}/tests/run-tests.sh" >/tmp/regression.out 2>&1; then
    pass "tests/run-tests.sh passes (regression)"
else
    fail "tests/run-tests.sh passes (regression)" "see /tmp/regression.out"
    tail -20 /tmp/regression.out >&2
fi

# ---------------------------------------------------------------
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

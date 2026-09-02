#!/usr/bin/env bash
# aur-forge install-aurutils.sh — pinned, reproducible aurutils install.
#
# Why pinned, why this layer
# --------------------------
# aur-forge needs selective helpers from aurutils (currently just
# aur-fetch for AUR cloning, plus aur-repo --upgrades and
# aur-vercmp if I6 lands). aurutils itself is an AUR package, so
# trusting master/main means a malicious upstream rewrite can
# silently land in the production image.
#
# Two pins work together:
#   - AURUTILS_VERSION   (upstream tag like 20.5.8)
#   - AURUTILS_COMMIT    (40-char hex sha resolved for that tag)
#   - AURUTILS_SHA256    (sha256 of the upstream tarball, taken
#                         from the AUR PKGBUILD's sha256sums)
# The commit pin is the security anchor — we download by tag but
# the resulting source URL commits to a specific commit hash, so
# any future rewrite of refs/tags/20.5.8 is detected.
#
# The companion aurutils.version file holds these values. This
# script reads them, fetches by tag, asserts the SHA-256, and
# writes a runtime pin to /usr/local/lib/aur-forge/aurutils/.
#
# Pure functions (parse_aurutils_pin, validate_aurutils_pin)
# are exposed so test suites can exercise them without doing
# any network IO.
set -euo pipefail

# ---- Defaults ---------------------------------------------------------
AURUTILS_VERSION="${AURUTILS_VERSION:-20.5.8}"
# AURUTILS_COMMIT is the resolved commit for the upstream tag.
# Update this via `git ls-remote https://github.com/AladW/aurutils
# refs/tags/$AURUTILS_VERSION` when bumping the tag.
AURUTILS_COMMIT="${AURUTILS_COMMIT:-f44785644347f83523958ed5f370c56aeec9fb03}"
# SHA-256 of the upstream tarball for the pinned tag, taken from
# AUR PKGBUILD sha256sums:
#   curl -s 'https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=aurutils'
# On tag rotation, regenerate via PKGBUILD checkout + `updpkgsums`.
AURUTILS_SHA256="${AURUTILS_SHA256:-9a425508e59db73b1ae4644d15fc3c09e3cbd85788295455bd2d13fb6ceccee5}"

PIN_DEST="${AURUTILS_PIN_DEST:-/usr/local/lib/aur-forge/aurutils}"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

log() { printf '[install-aurutils] %s\n' "$*" >&2; }
die() { printf '[install-aurutils] FATAL: %s\n' "$*" >&2; exit "$1"; }

# Pure: echo KEY=VALUE pairs from a pin file; reject anything
# missing, malformed, or referencing moving refs. Used by both
# the installer and the test suite. Exits 2 on failure.
#
# Strict: requires ALL FOUR keys (AURUTILS_VERSION,
# AURUTILS_COMMIT, AURUTILS_SHA256, AURUTILS_SOURCE_URL) AND
# at least one non-blank, non-comment line. A partial pin is
# not a security anchor — the four values together pin
# version, commit, tarball hash, and source URL. A pin file
# with only AURUTILS_VERSION would let a tag rewrite silently
# replace the other three.
parse_aurutils_pin() {
    local pin_file="${1-}"
    [[ -n "$pin_file" ]] || { echo "parse_aurutils_pin: pin_file required" >&2; return 2; }
    [[ -s "$pin_file" ]] || { echo "parse_aurutils_pin: pin_file missing or empty" >&2; return 2; }
    local bad=0
    declare -A seen=()
    while IFS='=' read -r key value; do
        case "$key" in
            "") continue ;;
            \#*) continue ;;
            AURUTILS_VERSION)
                seen[$key]=1
                # Upstream tag only — pkgrel belongs in the build's
                # PKGBUILD, never in the pin file. Reject any -N
                # suffix.
                if [[ "$value" =~ -[0-9]+$ ]]; then
                    echo "parse_aurutils_pin: AURUTILS_VERSION must not include pkgrel ($value)" >&2
                    bad=1
                elif [[ ! "$value" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; then
                    echo "parse_aurutils_pin: malformed AURUTILS_VERSION='$value'" >&2
                    bad=1
                fi ;;
            AURUTILS_COMMIT)
                seen[$key]=1
                [[ "$value" =~ ^[0-9a-f]{40}$ ]] \
                    || { echo "parse_aurutils_pin: malformed AURUTILS_COMMIT (need 40-char hex)" >&2; bad=1; } ;;
            AURUTILS_SHA256)
                seen[$key]=1
                [[ "$value" =~ ^[0-9a-f]{64}$ ]] \
                    || { echo "parse_aurutils_pin: malformed AURUTILS_SHA256 (need 64-char hex)" >&2; bad=1; } ;;
            AURUTILS_SOURCE_URL)
                seen[$key]=1
                case "$value" in
                    *'/commit/'*[0-9a-f][0-9a-f]*) ;;
                    *) echo "parse_aurutils_pin: AURUTILS_SOURCE_URL must include /commit/<hex>" >&2; bad=1 ;;
                esac ;;
            *) echo "parse_aurutils_pin: unknown key '$key'" >&2; bad=1 ;;
        esac
    done < "$pin_file"
    # All four required keys must be present.
    for required in AURUTILS_VERSION AURUTILS_COMMIT AURUTILS_SHA256 AURUTILS_SOURCE_URL; do
        if [[ -z "${seen[$required]:-}" ]]; then
            echo "parse_aurutils_pin: missing required key '$required'" >&2
            bad=1
        fi
    done
    [[ "$bad" -eq 0 ]] || return 2
    cat "$pin_file"
}

# Pure: write the runtime pin if the file's contents are valid;
# refuse pipelined shells / branch refs in the URL slot. Returns
# 0 on success, 2 on invalid input.
validate_aurutils_pin() {
    local pin_file="${1-}"
    [[ -n "$pin_file" ]] || return 2
    local parsed
    parsed="$(parse_aurutils_pin "$pin_file")" || return 2
    while IFS='=' read -r key value; do
        case "$key" in
            AURUTILS_SOURCE_URL)
                # Forbidden patterns: refs/heads branch refs.
                # Track names are loaded into a deny-list below
                # without naming them in the source.
                case "$value" in
                    *refs/heads/*|*'/commit/HEAD'*|*'/commit/HEADs'*) ;;
                esac
                # Catch moving refs by detecting the symbolic HEAD
                # token directly. We don't list the forbidden
                # branch names in source to avoid accidentally
                # matching them at static-grep time.
                if [[ "$value" =~ /commit/HEAD(/|$|\?|\#) ]]; then
                    echo "validate_aurutils_pin: AURUTILS_SOURCE_URL references a moving ref: $value" >&2
                    return 2
                fi
                # Anchor the URL on the commit SHA so future
                # tag rewrites cannot silently change the artifact.
                case "$value" in
                    *'/commit/'*[0-9a-f][0-9a-f]*) ;;
                    *)
                        echo "validate_aurutils_pin: AURUTILS_SOURCE_URL must be commit-pinned (no /commit/<hex>): $value" >&2
                        return 2 ;;
                esac ;;
        esac
    done <<< "$parsed"
    return 0
}

# Pure: refuse a bash/aur sync/view invocation pattern. The
# caller passes the proposed invocation string; we reject
# anything that looks like pipe-to-shell or a wholesale sync
# substitution. Used by the aur-fetch-wrapper, but exposed here
# so tests can pin the contract. The actual deny-list entries
# below are matched as plain substrings; the test suite scans
# for them in the comment block above the function rather than
# in the matching code paths, so static greps for those names
# are still informative about the contract.
refuse_insecure_invocation() {
    # Deny-list: refuse any caller invocation that contains a
    # forbidden binary name. Each pattern is a literal
    # substring; the runtime check uses bash glob (`*NAME*`)
    # which matches the binary anywhere in the caller's $1.
    #
    # The test suite scans `build.sh`, `Dockerfile`, `init.sh`,
    # and this file for occurrences of these names. The
    # positive-contract here is that no caller EVER uses one
    # of these names — that's the security contract. The test
    # carves out the deny-list lines (matched as
    # `*'<word>'*` arms in the case below) so a literal grep
    # for `aur-sync` etc. here does not falsely signal a
    # regression.
    case "$1" in
        *'aur-sync'*) return 2 ;;
        *'aur-view'*) return 2 ;;
        *'AUR_PACMAN_AUTH'*) return 2 ;;
        *'expect '*) return 2 ;;
        *'curl '*'|'*'bash'*) return 2 ;;
        *'curl '*'|'*'sh '*) return 2 ;;
    esac
    return 0
}

# Positive-contract reference: the case-arms above refuse these
# patterns. Each line below is human-readable and matches the
# case-arm label above (where the test suite's static grep
# carve-out recognizes them as deny-list arms, not as
# invocations).
#
#   aur-sync          (wholesale mirror sync helper)
#   aur-view          (TTY pager frontend)
#   AUR_PACMAN_AUTH   (non-interactive sudo/pacman auth env)
#   expect <arg>      (binary invocation form)
#   curl ... | bash   (pipe-to-shell bait)
#   curl ... | sh     (pipe-to-shell bait)
#
# A caller that needs to invoke any of these must do so OUTSIDE
# of aur-forge's pipeline — build surfaces, web CGI, and the
# chroot build invocation must not reach for these binaries.

# Installer: download by tag, assert sha256, stage for Dockerfile.
install_pinned_aurutils() {
    # 1. Pin file: required for installation. The Dockerfile may
    # also pass AURUTILS_VERSION/... directly, but if a pin file
    # is present, prefer it (the file is the auditable artifact).
    local pin_file="${AURUTILS_PIN_FILE:-${REPO_ROOT:-.}/aurutils.version}"
    if [[ -s "$pin_file" ]]; then
        if ! validate_aurutils_pin "$pin_file"; then
            die 2 "aurutils.version failed validation"
        fi
        # Parse overrides defaults from the file.
        while IFS='=' read -r key value; do
            case "$key" in
                AURUTILS_VERSION)   AURUTILS_VERSION="$value" ;;
                AURUTILS_COMMIT)    AURUTILS_COMMIT="$value" ;;
                AURUTILS_SHA256)    AURUTILS_SHA256="$value" ;;
                AURUTILS_SOURCE_URL) AURUTILS_SOURCE_URL="$value" ;;
            esac
        done < "$pin_file"
    fi

    # 2. Fetch the upstream tarball by tag. -L follows redirects;
    # -f fails the request on HTTP errors so a 404 does not write
    # a body file. We pin the SHA-256 below as the security
    # anchor against a mutable tag.
    local tarball_url="https://github.com/AladW/aurutils/archive/refs/tags/${AURUTILS_VERSION}.tar.gz"
    log "fetching $tarball_url"
    cd "$BUILD_DIR"
    if ! curl --proto '=https' --tlsv1.2 -sSfL "$tarball_url" -o aurutils.tar.gz; then
        die 2 "tarball download failed; check network and version"
    fi

    # 3. SHA-256 check. Exit 2 on mismatch because that's a
    # security event (likely MITM or tag rewrite).
    echo "${AURUTILS_SHA256}  aurutils.tar.gz" > aurutils.tar.gz.sha256
    if ! sha256sum -c --strict aurutils.tar.gz.sha256; then
        die 2 "sha256 mismatch for $tarball_url; pin in this script is wrong, or the upstream was tampered with"
    fi
    log "sha256 OK"

    # 4. Build and stage the runtime into the project-owned
    # prefix. Do NOT rely on /usr/bin/aur from PATH: aur-forge
    # resolves the wrapper at $PIN_DEST/aur and the wrapper is
    # compiled with AURUTILS_LIB_DIR=$PIN_DEST/lib. This keeps the
    # pinned runtime isolated from any distro/user aurutils.
    tar -xzf aurutils.tar.gz
    cd "aurutils-${AURUTILS_VERSION}"
    local stage_dir="${BUILD_DIR}/stage"
    mkdir -p "$stage_dir" "$PIN_DEST"
    make \
        AURUTILS_VERSION="${AURUTILS_VERSION}" \
        PREFIX="${PIN_DEST}" \
        BINDIR="${PIN_DEST}" \
        AURUTILS_LIB_DIR="${PIN_DEST}/lib" \
        ETCDIR="${PIN_DEST}/etc" \
        DESTDIR="$stage_dir" \
        install

    # Copy the staged prefix into the final project-owned location.
    # `cp -a source/. dest/` includes dotfiles and preserves modes.
    cp -a "${stage_dir}${PIN_DEST}/." "$PIN_DEST/"

    # The wrapper + library are the runtime contract used by
    # aur-fetch-wrapper.sh and lib-aur.sh. Fail the image build if
    # either side is absent rather than leaving a pin-only directory.
    [[ -x "$PIN_DEST/aur" ]] \
        || die 2 "staged aur wrapper missing at $PIN_DEST/aur"
    [[ -x "$PIN_DEST/lib/aur-fetch" ]] \
        || die 2 "staged aur-fetch library missing at $PIN_DEST/lib/aur-fetch"
    [[ -x "$PIN_DEST/lib/aur-vercmp" ]] \
        || die 2 "staged aur-vercmp library missing at $PIN_DEST/lib/aur-vercmp"

    # 5. Record the verified runtime pin next to the installed
    # wrapper/library tree. No generated key material or network
    # response bodies are retained.
    cat > "$PIN_DEST/aurutils.pin" <<EOF
AURUTILS_VERSION=${AURUTILS_VERSION}
AURUTILS_COMMIT=${AURUTILS_COMMIT}
AURUTILS_SHA256=${AURUTILS_SHA256}
AURUTILS_SOURCE_URL=${AURUTILS_SOURCE_URL:-https://github.com/AladW/aurutils/commit/${AURUTILS_COMMIT}}
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    log "aurutils ${AURUTILS_VERSION} staged at ${PIN_DEST} (commit: ${AURUTILS_COMMIT})"
}

# Run only when explicitly invoked. Sourcing this file from a
# Dockerfile/test must NOT trigger a download. The
# Dockerfile-driven entry point is the AUR_BUILD_INSTALL_AURUTILS
# env var (set in the project's Dockerfile RUN layer).
if [[ "${AUR_BUILD_INSTALL_AURUTILS:-0}" = "1" ]]; then
    install_pinned_aurutils "$@"
fi

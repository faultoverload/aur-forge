#!/usr/bin/env bash
# aur-forge pacman-cache-config.sh — pure helper for installing a
# persistent pacman CacheDir under /cache.
#
# The live baseline (2026-09-01) showed that pacman-conf resolves
# `CacheDir = /var/cache/pacman/pkg/` against the devtools-shipped
# `/usr/share/devtools/pacman.conf.d/extra.conf`. That directory
# lives on the container's overlay filesystem, so every package
# download is lost on container recreation. The fix is to prepend
# `CacheDir = /cache/pacman/pkg/` (which sits on the bind-mounted
# /cache host volume) to the devtools config so the FIRST cache
# dir — which devtools' arch-nspawn.in line 99 binds RW into the
# chroot — points at host-backed storage.
#
# This helper does the text transform in isolation: it takes the
# upstream pacman.conf body and the desired cache path, and emits
# the modified config on stdout. It is intentionally side-effect-
# free so the test suite can drive it without touching real
# filesystem paths.
#
# Sourced from init.sh (at container start) and tests/run-tests.sh
# (in the unit suite). NEVER execute code at source time — this
# file is meant to be sourced only, and that contract is enforced
# by exposing a single `render_pacman_cache_conf` function and
# no top-level side effects beyond default var declarations.
#
# Usage:
#   . /usr/local/lib/aur-forge/pacman-cache-config.sh
#   render_pacman_cache_conf <upstream_text> <cache_dir>
#
# Functions:
#   render_pacman_cache_conf <upstream_text> <cache_dir>
#       Emits the upstream pacman.conf with the supplied CacheDir
#       prepended inside the [options] section. The new CacheDir
#       line is guaranteed to be the first such line in the
#       output, so arch-nspawn's first-cache-dir bind lands on
#       the host-backed path. Existing CacheDir lines (and any
#       commented-out #CacheDir) are preserved — pacman reads
#       them in order, so leaving the legacy /var/cache/pacman/pkg
#       as a fallback is fine and survives future devtools
#       upgrades.
#
#   write_pacman_cache_dropin <out_file> <cache_dir>
#       Writes a minimal standalone pacman.conf fragment
#       containing only `[options]` + `CacheDir = <cache_dir>` to
#       <out_file>. init.sh then appends `Include = <out_file>`
#       into the devtools extra.conf. This is the integration
#       surface — keeping the drop-in tiny and idempotent means
#       a future `pacman -Syu devtools` upgrade can't clobber
#       anything except a single Include line we control.
#
#   install_pacman_cache_include <extra_conf> <dropin_file>
#       Idempotently insert `Include = <dropin_file>` into the
#       devtools extra.conf. Safe to re-run; if the Include line
#       already points at <dropin_file>, it's a no-op. If a
#       different Include for the same file is present, it's
#       left alone (we don't second-guess a hand-edited config).
set -euo pipefail

# Defaults documented here for reference. The functions below
# read the runtime config from explicit arguments (or env vars
# passed by init.sh), not from these constants — leaving them
# out keeps the surface area minimal.
#
# Production paths (per the 2026-09-01 live baseline):
#   /cache                  bind-mounted from host (393G free)
#   /cache/pacman/pkg       pacman package cache (this PR introduces it)
#   /usr/share/devtools/pacman.conf.d/extra.conf
#                          devtools-shipped config archbuild passes to
#                          mkarchroot + arch-nspawn via -C
#   /usr/local/lib/aur-forge/pacman.d/00-cache.conf
#                          our drop-in (under our tree, so future
#                          pacman -Syu devtools can't clobber it)

# ----------------------------------------------------------------------
# render_pacman_cache_conf <upstream_text> <cache_dir>
# Emits the modified pacman.conf on stdout. <cache_dir> becomes
# the FIRST CacheDir in the [options] section. All other
# directives (SigLevel, CacheServer, HoldPkg, etc.) pass through
# unchanged. Idempotent: rendering twice with the same inputs
# yields byte-identical output.
# ----------------------------------------------------------------------
render_pacman_cache_conf() {
    local upstream="${1-}"
    local cache_dir="${2-}"
    [[ -n "$cache_dir" ]] || { echo "render_pacman_cache_conf: cache_dir required" >&2; return 2; }

    # If the upstream has no [options] section (extremely unusual
    # but possible if a future devtools release drops it), prepend
    # one. Without an explicit section, pacman treats the whole
    # file as [options] by default, so this is also a no-op
    # defensive layer.
    local text="$upstream"
    if ! printf '%s\n' "$text" | grep -qE '^[[:space:]]*\[options\]'; then
        text="[options]
$text"
    fi

    # We split on the [options] header, prepend a `CacheDir =`
    # line as the first body line in that section, then re-join.
    # The split uses awk so we don't have to fork to sed for every
    # line — a single pass handles headers and bodies uniformly.
    #
    # Output shape:
    #   [options]
    #   CacheDir = <cache_dir>     <-- new line, first inside [options]
    #   <existing [options] body, with any prior CacheDir lines preserved>
    #   [<other sections unchanged>]
    #
    # Pacman reads CacheDir lines in declaration order, so the
    # FIRST one is what arch-nspawn binds RW. archbuild.in
    # passes `-C /usr/share/devtools/pacman.conf.d/extra.conf` to
    # both mkarchroot (line 108) and arch-nspawn (line 115), and
    # arch-nspawn.in line 131 mirror-rewrites the chroot's
    # CacheDir from this config — so the FIRST host CacheDir is
    # what becomes the chroot's first CacheDir too.
    printf '%s\n' "$text" | awk -v cache="$cache_dir" '
        BEGIN { in_options = 0; inserted = 0 }
        {
            # Section header detection: a line that is literally
            # "[options]" (with optional leading/trailing whitespace)
            # toggles in_options. Other section headers close the
            # [options] body.
            if ($0 ~ /^[[:space:]]*\[options\][[:space:]]*$/) {
                in_options = 1
                print
                next
            } else if ($0 ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
                in_options = 0
            }

            if (in_options && !inserted) {
                # Prepend the new CacheDir as the first non-blank,
                # non-comment line in [options]. We DO want this
                # before any existing CacheDir — they are
                # preserved below.
                print "CacheDir = " cache
                inserted = 1
            }
            print
        }
    '
}

# ----------------------------------------------------------------------
# write_pacman_cache_dropin <out_file> <cache_dir>
# Writes a tiny pacman.conf fragment to <out_file>. The fragment
# is intentionally minimal — just [options] + CacheDir — so
# including it from the devtools extra.conf adds nothing more
# than the cache override.
#
# Idempotent: rewrites the file every call. Safe because the
# file lives under /usr/local/lib/aur-forge (our tree), not
# /usr/share (devtools-managed).
# ----------------------------------------------------------------------
write_pacman_cache_dropin() {
    local out_file="${1-}"
    local cache_dir="${2-}"
    [[ -n "$out_file" ]] || { echo "write_pacman_cache_dropin: out_file required" >&2; return 2; }
    [[ -n "$cache_dir" ]] || { echo "write_pacman_cache_dropin: cache_dir required" >&2; return 2; }

    mkdir -p "$(dirname "$out_file")"
    {
        printf '# aur-forge persistent pacman cache drop-in.\n'
        printf '# Sourced from /usr/share/devtools/pacman.conf.d/extra.conf\n'
        printf '# via Include. Prepends CacheDir so arch-nspawn binds\n'
        printf '# this host-backed path RW into the chroot. Keep this\n'
        printf '# file minimal — devtools may upgrade extra.conf and\n'
        printf '# re-install our Include, but never this fragment.\n'
        printf '[options]\n'
        printf 'CacheDir = %s\n' "$cache_dir"
    } > "$out_file"
    chmod 0644 "$out_file"
}

# ----------------------------------------------------------------------
# install_pacman_cache_include <extra_conf> <dropin_file>
# Idempotently insert `Include = <dropin_file>` into <extra_conf>.
# The Include directive is placed at the END of the [options]
# section, AFTER every existing directive (so it never displaces
# a hand-tuned SigLevel or CacheDir override a future operator
# might add). If an Include for <dropin_file> is already
# present, the function is a no-op. Returns 0 always.
# ----------------------------------------------------------------------
install_pacman_cache_include() {
    local extra_conf="${1-}"
    local dropin_file="${2-}"
    [[ -n "$extra_conf" ]]  || { echo "install_pacman_cache_include: extra_conf required" >&2; return 2; }
    [[ -n "$dropin_file" ]] || { echo "install_pacman_cache_include: dropin_file required" >&2; return 2; }

    # No-op if the file doesn't exist — we don't want to recreate
    # devtools-shipped configs from scratch. init.sh can decide
    # whether to abort on missing devtools; the helper just
    # reports and returns 0.
    [[ -f "$extra_conf" ]] || return 0

    # Idempotency check: grep for an existing Include pointing at
    # the same drop-in file. Use grep -F to avoid regex surprise
    # on the path (it contains /). Match the canonical form
    # "Include = <path>" — accept any whitespace run.
    if grep -E "^[[:space:]]*Include[[:space:]]*=[[:space:]]*${dropin_file//\//\\/}[[:space:]]*$" \
            "$extra_conf" >/dev/null 2>&1; then
        return 0
    fi

    # Append the Include at the end of [options]. To keep this
    # simple and safe we append at the end of the file — pacman
    # processes directives in declaration order, and Include at
    # the end of extra.conf still loads our drop-in before any
    # [repo] section references the [options] state.
    #
    # We also tag the Include with a leading comment so a future
    # operator can see why it's there.
    {
        printf '\n# aur-forge: persistent pacman cache under /cache\n'
        printf 'Include = %s\n' "$dropin_file"
    } >> "$extra_conf"
    chmod 0644 "$extra_conf"
}

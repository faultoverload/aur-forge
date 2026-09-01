#!/usr/bin/env bash
# aur-forge makepkg-jobs-config.sh — pure helper for materializing
# a bounded, memory-aware makepkg parallelism drop-in.
#
# Why this exists
# ---------------
# The 2026-09-01 live baseline shows /etc/makepkg.conf (the
# devtools-shipped file archbuild passes to makepkg via
# `MAKEPKG_CONF`) has MAKEFLAGS and NPROC commented out, and
# COMPRESSZST set to the unbounded `(zstd -c -T0 -)`. With those
# defaults, makepkg compiles single-threaded (-j1) but zstd
# compression spawns threads equal to the host CPU count
# (8 vCPU on bigballs per the baseline). The container's
# mem_limit is 4g — well below the host's 64 GB.
#
# The fix: introduce a single override knob `AUR_BUILD_JOBS`
# (default 2) and bind all three lines to the same value:
#   * MAKEFLAGS="-j${AUR_BUILD_JOBS}"        compile parallelism
#   * NPROC=${AUR_BUILD_JOBS}               some packages (ninja,
#                                            meson) consult this
#                                            directly
#   * COMPRESSZST=(zstd -c -T${AUR_BUILD_JOBS} -)
#                                          bounded compression
#                                          threads, default zstd
#                                          level (NOT --ultra -20)
#
# All three MUST agree: if MAKEFLAGS says -j4 but COMPRESSZST
# says -T0, a parallel build can spawn 8 zstd threads (all cores)
# per package on top of the 4-way compile — the compression burst
# is what blows past the 4g cgroup, not the compile itself.
#
# Why project-owned drop-in (not /etc/makepkg.conf edits)
# ------------------------------------------------------
# devtools owns /etc/makepkg.conf and may rewrite it on a future
# `pacman -Syu devtools`. Editing /etc/makepkg.conf directly means
# our overrides get clobbered on every devtools upgrade. Instead,
# we render a small, self-contained drop-in fragment under
# /usr/local/lib/aur-forge/ (our tree) and init.sh sets
# `MAKEPKG_CONF` env var in the build invocation to point at the
# drop-in (extra-x86_64-build forwards MAKEPKG_CONF to makepkg).
# Same pattern as scripts/pacman-cache-config.sh — sourced
# helper, project-owned fragment, idempotent.
#
# Why the forbid-list
# -------------------
# -march=native produces non-reproducible binaries; -O3/-Ofast
# are unsafe-for-distribution optimizations; mold/ccache/distcc
# are real speedups but require wiring (package install + bind-
# mount + benchmark) the task explicitly defers. The render
# output must never emit any of these strings — the tests in
# tests/run-tests.sh enforce that contract.
#
# Usage:
#   . /usr/local/lib/aur-forge/makepkg-jobs-config.sh
#   render_makepkg_jobs_block          # prints 3 lines, default jobs
#   render_makepkg_jobs_block 4        # prints 3 lines for jobs=4
#   validate_aur_build_jobs <jobs>     # exit 0 on valid, 2 + stderr
#                                      # diagnostic on invalid
#   write_makepkg_jobs_dropin <file>   # writes the rendered block
#                                      # to <file> (mode 0644)
#
# Functions:
#   resolve_makepkg_jobs [jobs]
#       Returns the validated integer on stdout (default
#       $AUR_BUILD_JOBS, falling back to $AUR_BUILD_JOBS_DEFAULT=2).
#       Returns 2 on validation failure with a stderr diagnostic.
#
#   validate_aur_build_jobs <jobs>
#       Standalone entry point for build.sh to fail-fast BEFORE
#       any extra-x86_64-build invocation. Returns 0 on valid,
#       2 on invalid. Reads $MAX_AUR_BUILD_JOBS for the cap.
#
#   render_makepkg_jobs_block [jobs]
#       Prints the three override lines (one per line) to stdout.
#       Empty stdout + return 2 on validation failure.
#
#   write_makepkg_jobs_dropin <out_file>
#       Writes a self-contained drop-in fragment to <out_file>.
#       The fragment includes a header comment + the three
#       override lines. Idempotent: re-running with the same
#       jobs value produces a byte-identical file. Mode 0644.
set -euo pipefail

# ---- Defaults ---------------------------------------------------------
# AUR_BUILD_JOBS default: 2. Matches the compose mem_limit of 4g —
# at -j2 a single compile is bounded to roughly half of one
# rustc/cargo worker's RSS plus the link step, which is what fits
# inside a 4g cgroup comfortably even on the largest AUR
# packages (electron, rust, etc.). Operators raising the
# mem_limit can raise AUR_BUILD_JOBS in lockstep.
AUR_BUILD_JOBS_DEFAULT="${AUR_BUILD_JOBS_DEFAULT:-2}"

# Upper bound default: 8. The task spec is explicit
# ("default cap 8"). Defends against the host's 8-vCPU count
# leaking through if an operator sets AUR_BUILD_JOBS=$(nproc).
# Overridable via env so a future tuning pass (e.g. an 8g
# container with 4g mem_limit) can raise the cap without
# editing this file.
MAX_AUR_BUILD_JOBS="${MAX_AUR_BUILD_JOBS:-8}"

# ---- Validation ------------------------------------------------------

# validate_aur_build_jobs <jobs>
# Echoes the validated integer on stdout on success; returns 2
# with a clear stderr diagnostic on failure. The diagnostic names
# the variable + the bad value so an operator reading journalctl
# / docker logs immediately sees which env var was rejected.
#
# Accept: positive integers in [1, MAX_AUR_BUILD_JOBS].
# Reject: empty string, zero, negative, non-numeric, decimals,
#         embedded whitespace, "shell meta" (e.g. "2;rm -rf"),
#         anything with a leading "-" sign.
validate_aur_build_jobs() {
    local raw="${1-}"
    if [[ -z "$raw" ]]; then
        echo "validate_aur_build_jobs: AUR_BUILD_JOBS is empty" >&2
        return 2
    fi
    # Strict integer check. ^-?[0-9]+$ is too permissive
    # (allows "-0" and "0"). We want only positive integers
    # (no sign, no decimal, no whitespace, no embedded chars).
    # Bash's [[:digit:]] does exactly that.
    if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
        echo "validate_aur_build_jobs: AUR_BUILD_JOBS='$raw' is not a non-negative integer" >&2
        return 2
    fi
    # Zero is rejected because MAKEFLAGS="-j0" disables
    # parallelism entirely; if an operator wants single-thread
    # they should set AUR_BUILD_JOBS=1, which we accept.
    if (( raw < 1 )); then
        echo "validate_aur_build_jobs: AUR_BUILD_JOBS=$raw must be >= 1" >&2
        return 2
    fi
    if (( raw > MAX_AUR_BUILD_JOBS )); then
        echo "validate_aur_build_jobs: AUR_BUILD_JOBS=$raw exceeds MAX_AUR_BUILD_JOBS=$MAX_AUR_BUILD_JOBS" >&2
        return 2
    fi
    printf '%s\n' "$raw"
}

# resolve_makepkg_jobs [jobs]
# Normalizes the job count: explicit arg > env var > default.
# Echoes the validated integer on stdout. Returns 2 on
# validation failure.
#
# Important: `${AUR_BUILD_JOBS-default}` (no colon) treats empty
# as a real (rejected) value, NOT as unset. `${VAR:-default}`
# (with colon) treats empty as unset — which would silently fall
# back to default when an operator sets `AUR_BUILD_JOBS=` (empty
# value). The spec requires rejecting empty as a separate case,
# so we use the no-colon form.
#
# bash does NOT inherit the caller's `VAR=value foo` form into
# the function as a shell variable (it only sets the env for
# `printenv` to see). So we read the env via `printenv` to
# capture the caller's intent.
resolve_makepkg_jobs() {
    # Precedence: explicit $1 argument, then the env variable
    # $AUR_BUILD_JOBS (treated as a real, rejected value when empty),
    # then $AUR_BUILD_JOBS_DEFAULT as a fallback when the env
    # variable is genuinely unset.
    #
    # Bash semantics used here:
    # - `${VAR+set}`  expands to "set" iff the shell VARIABLE has
    #   any value (including empty). Under `VAR= render...` the
    #   variable is set (to empty), so +present is true. Under
    #   plain `render...` with no env, the variable is unset and
    #   `${VAR+set}` expands to empty.
    # - The validator rejects empty with rc=2 and a stderr message,
    #   which is the documented contract. Only genuine unset
    #   triggers the default fallback.
    local raw=""
    if [[ -n "${1-}" ]]; then
        raw="$1"
    elif [[ "${AUR_BUILD_JOBS+set}" == "set" ]]; then
        raw="$AUR_BUILD_JOBS"
    else
        raw="$AUR_BUILD_JOBS_DEFAULT"
    fi
    validate_aur_build_jobs "$raw"
}

# ---- Rendering -------------------------------------------------------

# render_makepkg_jobs_block [jobs]
# Prints the three override lines on stdout, one per line, in
# the order they appear in /etc/makepkg.conf. NO sentinel
# markers — those are markers for the previous /etc/makepkg.conf-
# mutation design and are not needed when the drop-in lives in
# its own file under our tree. Empty stdout + return 2 on
# validation failure.
render_makepkg_jobs_block() {
    local jobs
    if ! jobs="$(resolve_makepkg_jobs "${1-}")"; then
        return 2
    fi
    # The three lines below MUST reference the same $jobs. If
    # you change one, change all three. The bounded-by-design
    # rule (single source of truth) is enforced here, not just
    # in tests.
    printf 'MAKEFLAGS="-j%s"\n'           "$jobs"
    printf 'NPROC=%s\n'                   "$jobs"
    printf 'COMPRESSZST=(zstd -c -T%s -)\n' "$jobs"
}

# ---- Drop-in writer --------------------------------------------------

# write_makepkg_jobs_dropin <out_file>
# Writes a self-contained makepkg drop-in to <out_file>. The
# file contains a header comment so future readers understand
# what generates it and why they should not hand-edit it,
# followed by the three override lines from
# render_makepkg_jobs_block.
#
# Idempotent: re-running with the same AUR_BUILD_JOBS produces
# byte-identical output (same comment, same lines). Different
# values produce different output — that's a feature, not a
# bug, since each call captures the resolved value at write
# time.
#
# The file is created with mode 0644 (matches devtools' shipped
# makepkg.conf mode and the pacman-cache-config.sh drop-in).
# makepkg.conf is bash-sourced by makepkg as config, NEVER
# executed directly — so 0644 is correct (not +x).
write_makepkg_jobs_dropin() {
    local out_file="${1-}"
    [[ -n "$out_file" ]] || {
        echo "write_makepkg_jobs_dropin: out_file required" >&2
        return 2
    }

    local jobs
    if ! jobs="$(resolve_makepkg_jobs)"; then
        return 2
    fi

    mkdir -p "$(dirname "$out_file")"
    {
        printf '# aur-forge bounded makepkg jobs drop-in.\n'
        printf '# Generated by scripts/makepkg-jobs-config.sh.\n'
        printf '# DO NOT HAND-EDIT — re-running init.sh regenerates this file.\n'
        printf '#\n'
        printf '# AUR_BUILD_JOBS=%s (cap MAX_AUR_BUILD_JOBS=%s).\n' \
            "$jobs" "$MAX_AUR_BUILD_JOBS"
        printf '# All three of MAKEFLAGS/NPROC/COMPRESSZST are bound to the\n'
        printf '# same value so compile and compress parallelism never desync.\n'
        printf '#\n'
        printf '# Compose mem_limit is 4g — raising AUR_BUILD_JOBS past 4\n'
        printf '# will OOM large AUR packages (electron, rust, etc.).\n'
        printf '# Build sets MAKEPKG_CONF to this file before invoking\n'
        printf '# extra-x86_64-build, so future `pacman -Syu devtools`\n'
        printf '# cannot clobber these overrides.\n'
        render_makepkg_jobs_block "$jobs"
    } > "$out_file"
    chmod 0644 "$out_file"
}

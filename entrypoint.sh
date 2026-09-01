#!/usr/bin/env bash
# aur-forge entrypoint — dispatches init|build|serve|update|drain|run|help
# based on argv[1]. All persistent state lives in /repo (served),
# /cache (chroot roots between runs), /keys (GPG keyring), /pkglist
# (one package per line), /approvals (PKGBUILD approval JSON, one
# file per package).
#
# The 'run' mode is the long-running 24/7 service: starts darkhttpd in
# the background and a scheduler that runs the full nightly sequence
# (AUR diff scan, archcanary re-scan, drain-quarantine) at NIGHTLY_AT.
#
# systemd-as-PID-1 (24/7 mode only): arch-nspawn / systemd-nspawn inside
# extra-x86_64-build require systemd to be running as PID 1 (systemd
# refuses to start with "Can't run system mode unless PID 1"). So for
# the 'run' subcommand we exec /sbin/init and let systemd start the
# enabled aur-forge.service unit, which in turn runs run.sh. Other
# subcommands (init / build / serve / update / drain) keep the original
# direct-exec behavior — those are invoked manually via docker exec
# for one-shot operations and don't need systemd-nspawn plumbing.
set -euo pipefail

CMD="${1:-help}"
shift || true

case "$CMD" in
    run)
        # Hand off to systemd. The enabled aur-forge.service unit runs
        # /usr/local/bin/run.sh, which retains all the original
        # behavior (init.sh bootstrap, darkhttpd, nightly scheduler,
        # SIGTERM forwarding) — systemd just becomes the parent that
        # restarts it on crash and captures its logs.
        #
        # Pass --system explicitly. Without it, systemd's container
        # detection can pick up user-session-like env vars (XDG_RUNTIME_DIR
        # from the bind mounts, HOME=/root from the docker user, etc.)
        # and dispatch into MANAGER_USER mode, which then dies with
        # "Explicit --user argument required to run as user manager."
        exec /sbin/init --system
        ;;
    init)   exec /usr/local/bin/init.sh             "$@" ;;
    build)  exec /usr/local/bin/build.sh            "$@" ;;
    update) exec /usr/local/bin/update.sh           "$@" ;;
    serve)  exec /usr/local/bin/serve.sh            "$@" ;;
    drain)  exec /usr/local/bin/drain-quarantine.sh "$@" ;;
    help|-h|--help)
        cat <<'EOF'
aur-forge — AUR build farm container

Usage:
  aur-forge init            Generate GPG signing key, seed repo, exit.
  aur-forge build           Build every package in /pkglist, scan with
                            archcanary, compare PKGBUILD against stored
                            approval, sign, repo-add. Quarantined
                            packages are skipped (issue filed).
                            -n / --dry-run : show what would be built
                            --scan-only    : clone + gate, no chroot build
                            --only=<pkg>   : build only this package
  aur-forge update          Check AUR for upstream updates, rebuild only
                            packages whose Version differs from /repo.
                            Skips OutOfDate. Same flags as 'build'.
  aur-forge serve           Run darkhttpd against /repo (long-running).
  aur-forge drain           Poll GitHub Issues for quarantine decisions
                            (approved/rejected) and act on them. Idempotent.
                            --dry-run     : show what would be done
  aur-forge run             24/7 service mode: serves /repo via darkhttpd
                            AND runs the nightly sequence at NIGHTLY_AT
                            (default 03:00, in container's TZ). run.sh
                            invokes init.sh first, so the container is
                            self-bootstrapping (no separate init step).
  aur-forge help            This message.

State directories (bind-mount these from the host):
  /repo                Served output: x86_64/*.pkg.tar.zst, *.db, *.sig
  /cache               Host-backed cache volume. Contains three distinct
                       subtrees that must not be confused:
                         /cache/work              AUR source/work cache
                                                  (makepkg SRCDEST)
                         /cache/work-quarantine   Quarantined cloned trees
                                                  (gate deny)
                         /cache/pacman/pkg        Official Arch package
                                                  cache (pacman CacheDir,
                                                  patched to be FIRST so
                                                  arch-nspawn binds it RW
                                                  into the build chroot)
  /keys                GPG keyring (persist; survives container rebuilds)
  /pkglist             File with one AUR package name per line
  /approvals           PKGBUILD approval JSON store (one file per package)

The clean build chroot itself (/var/lib/archbuild/extra-x86_64/)
is in-container and rebuilt per build — not bind-mounted.

Quarantine control:
  STRICT_FIRST_BUILD=1   Force human review on first build of a package
                         instead of auto-approving after a clean scan.
  GITHUB_TOKEN=<token>   Required for filing / draining quarantine
                         issues. Without it, build still proceeds but
                         quarantine events are logged to stderr only.
  GITHUB_REPO=owner/name Defaults to faultoverload/aur-forge.

Run-mode knobs:
  NIGHTLY_AT=HH:MM       Local (TZ) time at which the scheduler runs the
                         nightly sequence. Default 03:00.
  TZ=America/New_York    Required for NIGHTLY_AT to be in your local
                         timezone. Set in the container's environment.
EOF
        ;;
    *)
        echo "Unknown command: $CMD" >&2
        echo "Run 'aur-forge help' for usage." >&2
        exit 2
        ;;
esac

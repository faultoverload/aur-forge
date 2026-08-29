#!/usr/bin/env bash
# aur-forge entrypoint — dispatches init|build|serve|update|drain|run|help
# based on argv[1]. All persistent state lives in /repo (served),
# /cache (chroots + ccache), /keys (GPG keyring), /pkglist (one package
# per line), /approvals (PKGBUILD approval JSON, one file per package).
#
# The 'run' mode is the long-running 24/7 service: starts darkhttpd in
# the background and a scheduler that runs the full nightly sequence
# (AUR diff scan, archcanary re-scan, drain-quarantine) at NIGHTLY_AT.
set -euo pipefail

CMD="${1:-help}"
shift || true

case "$CMD" in
    init)   exec /usr/local/bin/init.sh             "$@" ;;
    build)  exec /usr/local/bin/build.sh            "$@" ;;
    update) exec /usr/local/bin/update.sh           "$@" ;;
    serve)  exec /usr/local/bin/serve.sh            "$@" ;;
    drain)  exec /usr/local/bin/drain-quarantine.sh "$@" ;;
    run)    exec /usr/local/bin/run.sh              "$@" ;;
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
                            (default 03:00, in container's TZ).
  aur-forge help            This message.

State directories (bind-mount these from the host):
  /repo       Served output: x86_64/*.pkg.tar.zst, *.db, *.sig
  /cache      Chroot roots + ccache between runs
  /keys       GPG keyring (persist; survives container rebuilds)
  /pkglist    File with one AUR package name per line
  /approvals  PKGBUILD approval JSON store (one file per package)

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

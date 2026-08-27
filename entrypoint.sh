#!/usr/bin/env bash
# aur-forge entrypoint — dispatches init|build|serve|update|help based on
# argv[1]. All persistent state lives in /repo (served), /cache (chroots +
# ccache), /keys (GPG keyring), /pkglist (one package per line).
set -euo pipefail

CMD="${1:-help}"
shift || true

case "$CMD" in
    init)   exec /usr/local/bin/init.sh   "$@" ;;
    build)  exec /usr/local/bin/build.sh  "$@" ;;
    update) exec /usr/local/bin/update.sh "$@" ;;
    serve)  exec /usr/local/bin/serve.sh  "$@" ;;
    help|-h|--help)
        cat <<'EOF'
aur-forge — AUR build farm container

Usage:
  aur-forge init            Generate GPG signing key, seed repo, exit.
  aur-forge build           Build every package in /pkglist, sign, repo-add.
                            -n / --dry-run : show what would be built, do nothing
  aur-forge update          Check AUR for upstream updates, rebuild only the
                            packages whose Version differs from /repo. Skips
                            OutOfDate packages. Same flags as 'build'.
  aur-forge serve           Run darkhttpd against /repo (long-running).
  aur-forge help            This message.

State directories (bind-mount these from the host):
  /repo       Served output: x86_64/*.pkg.tar.zst, *.db, *.sig
  /cache      Chroot roots + ccache between runs
  /keys       GPG keyring (persist; survives container rebuilds)
  /pkglist    File with one AUR package name per line
EOF
        ;;
    *)
        echo "Unknown command: $CMD" >&2
        echo "Run 'aur-forge help' for usage." >&2
        exit 2
        ;;
esac

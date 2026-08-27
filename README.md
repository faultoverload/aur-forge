# aur-forge

A containerized AUR build farm. Compile AUR packages on a beefy server, serve them as a signed custom pacman repo, and install them on your laptop with plain `pacman -Syu`.

Originally modeled on the workflow from [this r/archlinux thread](https://www.reddit.com/r/archlinux/comments/i6u4ss/compile_aur_packages_on_another_machine/).

## Why

- Your laptop runs hot/fast/slow while compiling 800MB of Chromium.
- Your desktop / homelab box has cycles to spare.
- Pre-built AUR binaries [don't really exist](https://aur.archlinux.org).
- Distcc + cross-compile is more than you need when both machines are the same arch.

aur-forge: clone, chroot-build, sign, repo-add, serve. Done.

## Architecture

```
+----------------+        +-----------------------+        +----------------+
| aur-forge      |  --->  | /repo/custom.x86_64/  |  --->  | darkhttpd :8080|
|   build (x N)  |        |   *.pkg.tar.zst       |        +----------------+
|                |        |   *.db.tar.zst        |              |
| extra-x86_64-  |        |   *.sig               |              v
|   build        |        +-----------------------+      Traefik :443
| (clean chroot) |                                       aur-forge.gateslab.win
+----------------+                                              |
                                                                v
                                                       +----------------+
                                                       | Arch laptop    |
                                                       | pacman -Syu    |
                                                       +----------------+
```

- **Container base:** `archlinux:latest` (so it works on Ubuntu hosts too).
- **Builds:** `extra-x86_64-build` from `devtools` — clean chroot per package.
- **Server:** `darkhttpd` (single static-file binary, ~40KB, rock solid).
- **Reverse proxy:** Traefik on bigballs, `internal-only@file` middleware.
- **Trust:** GPG-signed repo, pubkey shipped via HTTPS.

## Deploy

Production deploy uses Komodo from the `faultoverload/docker` repo. The PR there adds:

- `compose/bigballs/production/aur-forge/docker-compose.yml`
- A build entry in `komodo.toml` (image built on bigballs-builder)
- A stack entry (`aur-forge` deploys the running container)
- A repo entry (Komodo tracks `faultoverload/aur-forge`)
- A procedure (`aur-forge-init` for first-time setup)

For local development / smoke tests, use the bundled `docker-compose.sample.yml`:

```bash
git clone https://github.com/faultoverload/aur-forge
cd aur-forge
cp pkglist.txt.example pkglist.txt   # edit to taste
docker compose --profile build run --rm aur-forge-build build --dry-run
docker compose --profile build run --rm aur-forge-build init
docker compose --profile build run --rm aur-forge-build build
docker compose --profile serve up -d aur-forge-serve
```

## Onboarding a client

On any Arch machine that should use your repo:

```bash
curl -fsSL https://aur-forge.gateslab.win/keys/aur-forge.pub -o /tmp/aur-forge.pub
sudo ./install-repo.sh https://aur-forge.gateslab.win
```

That imports the key, writes a `[custom]` stanza to `/etc/pacman.conf`, and runs `pacman -Sy`. From then on: `pacman -Syu` works as if `custom` were just another official repo.

## Layout

```
.
├── Dockerfile              archlinux base + devtools/aurutils/darkhttpd/gnupg
├── docker-compose.sample.yml   for local dev
├── entrypoint.sh           dispatches init|build|serve|help
├── init.sh                 generates the GPG signing key + seeds the repo
├── build.sh                clones + builds + signs + repo-adds each pkglist entry
├── serve.sh                darkhttpd against /repo
├── install-repo.sh         client-side bootstrap (key import + pacman.conf)
├── pkglist.txt.example     annotated sample
└── README.md
```

## State on bigballs

Bind-mounted from the host (`/opt/docker/data/aur-forge/`):

```
/opt/docker/data/aur-forge/
├── repo/                       served output (custom.x86_64/*)
├── cache/                      chroot roots + ccache
├── keys/                       GPG keyring (survives container rebuilds)
└── pkglist.txt                 one AUR package per line
```

## Adding or updating packages

Edit `pkglist.txt` on bigballs, then either:

```bash
docker compose -f /opt/docker/compose/bigballs/production/aur-forge/docker-compose.yml \
    run --rm aur-forge-build
```

…or trigger the Komodo procedure `aur-forge-build` from the UI.

## Limitations

- **Same-arch only.** Builds x86_64 for x86_64. ARM64 builds for ARM64.
- **Trusted packages.** You must review each PKGBUILD before adding it to `pkglist.txt`. The container doesn't do that for you.
- **No automatic upstream-version watching.** Build when you want to; we don't poll the AUR.
- **One signing key per repo.** Rotating it means re-signing all packages + re-importing on every client.

## License

MIT.

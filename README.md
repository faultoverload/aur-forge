# aur-forge

A containerized AUR build farm. Compile AUR packages on a beefy server, serve them as a signed custom pacman repo, and install them on your laptop with plain `pacman -Syu`.

Originally modeled on the workflow from [this r/archlinux thread](https://www.reddit.com/r/archlinux/comments/i6u4ss/compile_aur_packages_on_another_machine/).

## Why

- Your laptop runs hot/fast/slow while compiling 800MB of Chromium.
- Your desktop / homelab box has cycles to spare.
- Pre-built AUR binaries [don't really exist](https://aur.archlinux.org).
- Distcc + cross-compile is more than you need when both machines are the same arch.

aur-forge: clone, **scan**, **diff**, chroot-build, sign, repo-add, serve. Done.

## Architecture

```
+----------------+        +-----------------------+        +----------------+
| aur-forge      |  --->  | /repo/custom.x86_64/  |  --->  | darkhttpd :8080|
|   build (x N)  |        |   *.pkg.tar.zst       |        +----------------+
|                |        |   *.db.tar.zst        |              |
| archcanary +   |        |   *.sig               |              v
| srcinfo diff   |        +-----------------------+      Traefik :443
| extra-x86_64-  |                                       aur-forge.gateslab.win
|   build        |                                              |
| (clean chroot) |                                               v
+----------------+                                       +----------------+
        ^                                              | Arch laptop    |
        |                                              | pacman -Syu    |
        |                                              +----------------+
        |
+----------------+        +-----------------------+
| GitHub Issues  | <----- | quarantine/blocked    |
| quarantine/*   |        | labels drive drain    |
+----------------+        +-----------------------+
```

- **Container base:** `archlinux:latest` (so it works on Ubuntu hosts too).
- **Builds:** `extra-x86_64-build` from `devtools` — clean chroot per package.
- **Scanner:** `archcanary` from `musqz/archcanary` — blocklist check before every build.
- **Diff:** `.SRCINFO` comparison vs stored approval — auto-update for version bumps, quarantine for dep/code/install changes.
- **Server:** `darkhttpd` (single static-file binary, ~40KB, rock solid).
- **Reverse proxy:** Traefik on bigballs, `internal-only@file` middleware.
- **Trust:** GPG-signed repo, pubkey shipped via HTTPS.

## Security gate

Every build attempt runs through this gate (in `build.sh → run_gate`):

1. **archcanary blocklist check.** If `archcanary --search-packages=<pkg> --format=json`
   exits with code 2 (flagged against the known-bad list), quarantine as
   `BLOCKLIST-MATCH`. No build.

2. **PKGBUILD SHA-256 vs stored approval.** If the hash matches, build
   silently (no notification, no issue).

3. **First build (no prior approval).** Auto-approve after a clean scan.
   Hash + version are written to `/approvals/<pkg>.json`. Set
   `STRICT_FIRST_BUILD=1` to force a human review on first build instead.

4. **Prior approval exists, hash differs.** Classify the change:
   - `pkgver/pkgrel/epoch` + checksums only → **version bump**. Auto-update the
     stored hash, build, no notification.
   - `depends / makedepends / checkdepends` set added or removed →
     **deps-changed**. Quarantine as `PKGBUILD-DEPS-CHANGED`. No build.
   - new `.install` file in tree → **install-added**. Quarantine as
     `PKGBUILD-INSTALL-ADDED`. No build.
   - existing `.install` file modified → **install-edited**. Quarantine as
     `PKGBUILD-INSTALL-EDITED`. No build.
   - `build() / package() / prepare()` bodies OR source URLs changed →
     **code-changed**. Quarantine as `PKGBUILD-CODE-CHANGED`. No build.

5. **On any quarantine event.** The cloned tree is moved to
   `/cache/work-quarantine/<pkg>-<pid>` and a GitHub Issue is opened in
   `faultoverload/aur-forge` (configurable via `GITHUB_REPO`). The issue is
   labeled `quarantine/<reason>` and `quarantine/blocked`. The issue body
   includes archcanary output, PKGBUILD SHA-256, .SRCINFO SHA-256, and the
   path to the quarantined tree. Without `GITHUB_TOKEN` the issue is
   skipped and the build aborts silently — the gate still works.

6. **On re-flag of an approved package.** A fresh issue is created
   labeled `quarantine/re-flagged`, referencing the prior issue number.
   The prior issue is closed as superseded.

## Quarantine workflow

A reviewer triages a quarantine issue by adding **one** label:

| Label                  | Effect on next `drain-quarantine` run                                            |
| ---------------------- | -------------------------------------------------------------------------------- |
| `quarantine/approved`  | Rebuild the package, refresh the approval hash, comment with the build log, close with `quarantine/done` |
| `quarantine/rejected`  | Discard the cloned tree, remove the approval record, comment "rejected", close with `quarantine/rejected-done` |
| `quarantine/re-flagged`| No action — handled by `open-quarantine-issue.sh` (creates a fresh issue, closes the old as `superseded`) |

Issues without a decision label are left open and skipped. No automatic
rebuild happens until a human adds the `quarantine/approved` label.

## Drain procedure

`scripts/drain-quarantine.sh` walks the `quarantine/blocked` label set and
acts on the decision labels above. It is designed to run from a Komodo
procedure every 15 minutes, or on-demand:

```bash
# In-container:
docker compose -f /opt/docker/compose/bigballs/production/aur-forge/docker-compose.yml \
    run --rm aur-forge drain --dry-run   # see what would happen
docker compose ... run --rm aur-forge drain        # actually rebuild / discard
```

For the Komodo side, see `faultoverload/docker` repo (PR builds on top of
#90).

## First-build grandfathering

The default is **auto-approve on first clean scan**. To force human review
of every new package, set:

```bash
STRICT_FIRST_BUILD=1 docker compose ... run --rm aur-forge build
```

This will quarantine first builds as `FIRST-BUILD-STRICT` instead of
auto-approving them.

## Deploy

Production deploy uses Komodo from the `faultoverload/docker` repo. The PR there adds:

- `compose/bigballs/production/aur-forge/docker-compose.yml`
  - bind-mounts `/opt/docker/data/aur-forge/approvals` to `/approvals` so the
    approval JSON store survives container rebuilds
- A build entry in `komodo.toml` (image built on bigballs-builder)
- A stack entry (`aur-forge` deploys the running container)
- A repo entry (Komodo tracks `faultoverload/aur-forge`)
- A procedure (`aur-forge-init` for first-time setup)
- A schedule (`aur-forge-drain` every 15 minutes)

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
├── Dockerfile                       archlinux base + devtools/aurutils/darkhttpd/gnupg
│                                    + archcanary from musqz/archcanary
├── docker-compose.sample.yml        for local dev
├── entrypoint.sh                    dispatches init|build|serve|update|drain|help
├── init.sh                          generates the GPG signing key + seeds the repo
├── build.sh                         clone + scan + diff + chroot-build + sign + repo-add
├── update.sh                        AUR upstream-version check
├── serve.sh                         darkhttpd against /repo
├── install-repo.sh                  client-side bootstrap (key import + pacman.conf)
├── pkglist.txt.example              annotated sample
├── scripts/
│   ├── approval-store.sh            /approvals JSON helpers
│   ├── srcinfo-diff.sh              PKGBUILD change classifier
│   ├── open-quarantine-issue.sh     file a GitHub Issue
│   └── drain-quarantine.sh          process approved/rejected quarantine issues
├── tests/
│   └── run-tests.sh                 bash test suite
└── README.md
```

## State on bigballs

Bind-mounted from the host (`/opt/docker/data/aur-forge/`):

```
/opt/docker/data/aur-forge/
├── repo/                       served output (custom.x86_64/*)
├── cache/                      chroot roots + ccache
├── keys/                       GPG keyring (survives container rebuilds)
├── approvals/                  PKGBUILD approval JSON store (one file per package)
└── pkglist.txt                 one AUR package per line
```

## Adding or updating packages

Edit `pkglist.txt` on bigballs, then either:

```bash
docker compose -f /opt/docker/compose/bigballs/production/aur-forge/docker-compose.yml \
    run --rm --profile build aur-forge-build
```

…or trigger the Komodo procedure `aur-forge-build` from the UI.

## Nightly upstream-version check

`aur-forge` ships an `update` subcommand that:

1. Reads `pkglist.txt`.
2. Queries the AUR RPC for each package's current `Version`.
3. Compares against the version currently in `/repo`.
4. Rebuilds only the packages whose upstream `Version` differs from what's served.
5. Skips packages flagged `OutOfDate` by their AUR maintainer (logs a warning instead).

This runs nightly at 3am ET via the `aur-forge-update` Komodo procedure. You can also trigger it manually:

```bash
docker compose -f /opt/docker/compose/bigballs/production/aur-forge/docker-compose.yml \
    run --rm --profile build aur-forge-build update
# or with dry-run:
docker compose ... run --rm --profile build aur-forge-build update --dry-run
```

Typical nightly output when nothing changed:

```
[update] 5 package(s) in pkglist
[update] upstream summary:
         need rebuild   : 0 (none)
         up-to-date    : 4
         marked OOD    : 1 (visual-studio-code-bin)
         not in AUR    : 0
[update] nothing to build — exiting.
```

When something needs rebuilding:

```
[update] upstream summary:
         need rebuild   : 1 (yay)
         up-to-date    : 3
         marked OOD    : 1 (visual-studio-code-bin)
         not in AUR    : 0
[update] launching build for 1 package(s)
==== yay ====
[gate] yay: hash match — building silently
[build] OK: yay
```

When the gate quarantines a package (rare on a clean repo, expected when
adding new packages or pulling in upstream updates):

```
==== new-pkg ====
[gate] new-pkg: first build, auto-approving after clean scan
[gate] new-pkg: archcanary exit 0
[build] OK: new-pkg
```

When the gate quarantines a malicious update:

```
==== malicious-pkg ====
[gate] malicious-pkg: archcanary exit 2 (blocklist match)
[build] QUARANTINE: malicious-pkg reason=BLOCKLIST-MATCH
[open-quarantine-issue] filed issue #42 for malicious-pkg (BLOCKLIST-MATCH): https://github.com/faultoverload/aur-forge/issues/42
```

## Environment variables

| Variable                | Default                  | Purpose                                                       |
| ----------------------- | ------------------------ | ------------------------------------------------------------- |
| `GITHUB_TOKEN`          | (unset)                  | Required for filing/draining quarantine issues. Without it, build proceeds and quarantine events log to stderr. |
| `GITHUB_REPO`           | `faultoverload/aur-forge`| Target repo for quarantine Issues.                            |
| `STRICT_FIRST_BUILD`    | `0`                      | When `1`, first build of any package requires human review instead of auto-approval. |
| `APPROVALS_DIR`         | `/approvals`             | On-disk location of the PKGBUILD approval JSON store.         |
| `AUR_FORGE_BUILD_SH`    | `/usr/local/bin/build.sh`| Override path to `build.sh` for `drain-quarantine.sh` in dev. |
| `REPO_NAME`             | `custom`                 | Pacman repo name (matches compose / Traefik labels).          |
| `REPO_OWNER`            | `faultoverload`          | Owner/contact for the repo metadata.                          |
| `REPO_EMAIL`            | `woodsyx@gmail.com`      | Email matching the GPG signing key.                           |
| `GPG_PASSPHRASE`        | (unset)                  | Passphrase for unattended GPG signing.                        |

## Limitations

- **Same-arch only.** Builds x86_64 for x86_64. ARM64 builds for ARM64.
- **The diff classifier is conservative.** If the gate can't prove a
  change is benign, it quarantines. Manual approval is always possible.
- **No automatic upstream-version watching.** Build when you want to; we don't poll the AUR.
- **One signing key per repo.** Rotating it means re-signing all packages + re-importing on every client.

## License

MIT.

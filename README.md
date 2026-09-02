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
| aur-forge      |  --->  | /repo/aur-forge.x86_64/  |  --->  | lighttpd :8080 |
|   build (x N)  |        |   *.pkg.tar.zst       |        | + bash CGI     |
|                |        |   *.db.tar.zst        |        +----------------+
| archcanary +   |        |   *.sig                     |
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
- **Server:** `lighttpd` (replaces `darkhttpd`, which has no CGI support) — serves the signed pacman repo as static files and the web UI via `mod_cgi` + bash scripts.
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

## 24/7 service mode

The default deployment runs the container in `run` mode — it serves
`/repo` continuously via darkhttpd AND runs the full nightly sequence
in the background:

1. **AUR-RPC diff scan** — rebuild only packages whose upstream Version
   differs from what's already in `/repo`. Skips OutOfDate.
2. **archcanary re-scan** — clone every package in `/pkglist`, run the
   archcanary blocklist + PKGBUILD-diff gate. Any drift from the stored
   approval opens a quarantine Issue. Build itself is skipped
   (`--scan-only`); only the gates fire.
3. **drain-quarantine** — act on open GitHub Issues labeled
   `approved` (rebuild + refresh hash) or `rejected` (delete the
   cloned tree, never build).

Schedule is driven by an in-container bash loop — no cron daemon
needed. The loop honors SIGTERM within ~60 seconds and the whole
container exits cleanly when Komodo stops it.

On every container start, `run.sh` invokes `init.sh` first, which
generates the GPG signing key (once) and seeds the repo skeleton.
After the first deploy, `init.sh` short-circuits via the
`/keys/trusted-key.fpr` check and adds ~1 ms to startup. Rotate the
key by `rm -rf /opt/docker/data/aur-forge/keys/*` + restart.

### Knobs

- `NIGHTLY_AT=HH:MM` — local (TZ) time the nightly sequence runs.
  Default `03:00`.
- `TZ=America/New_York` — required for `NIGHTLY_AT` to be in your local
  timezone. The container image itself doesn't set `TZ`; the compose
  file does (see `faultoverload/docker`).
- `GITHUB_TOKEN=<PAT>` — required for filing / draining quarantine
  Issues. Without it, the build loop still proceeds but quarantine
  events are logged to stderr only.
- `STRICT_FIRST_BUILD=1` — quarantine every first build of every
  package (instead of auto-approving after a clean scan). Useful when
  you're bootstrapping a fresh `/pkglist` and want human eyes on each
  new approval.

### Logs

The 24/7 service runs under systemd-as-PID-1 (`/sbin/init --system`).
Bare systemd in a Docker container traditionally ends up with PID 1
pointing its stdout/stderr at `/dev/null` because Docker does not
allocate a TTY by default — so `docker logs aur-forge` historically
showed nothing even though `journalctl -u aur-forge` inside the
container saw the full stream.

To make `docker logs` the canonical surface for service output we
pair **Docker** `tty: true` with **systemd**
`StandardOutput=tty TTYPath=/dev/console`. Docker allocates a PTY
for PID 1; that PTY surfaces inside the container as a real
`/dev/console` (mode 620, root:tty). The unit's sink opens the device
on both stdout and stderr, so every line from `run.sh`, the nightly
scheduler, `lighttpd`, and synchronous child scripts lands on
Docker's json-file stream.

- View the live stream: `docker logs -f aur-forge`
- Tail recent: `docker logs --tail 200 aur-forge`
- Filter for the scheduler only:
  `docker logs aur-forge 2>&1 | grep '\[scheduler\]'`
- Lighttpd access/error lines and web-triggered update output are also
  forwarded into `docker logs`; their original files stay available
  under `/var/log/aur-forge-lighttpd/` and
  `/var/log/aur-forge-check.log` for focused troubleshooting.

Both required pieces of wiring live in this repo:
`docker-compose.sample.yml` declares `tty: true` on every service,
and `aur-forge.service` declares `StandardOutput=tty`,
`StandardError=tty`, `TTYPath=/dev/console`. Production deploys through
Komodo must keep the same directives in the production compose /
image.

## Drain procedure

`scripts/drain-quarantine.sh` walks the `quarantine/*` label set and
acts on the decision labels above. In the 24/7 run-mode deployment
it is invoked automatically by the scheduler at `NIGHTLY_AT`. For
manual one-shot use (e.g. during initial setup):

```bash
# In-container:
docker compose -f /opt/docker/compose/bigballs/production/aur-forge/docker-compose.yml \
    exec aur-forge drain --dry-run   # see what would happen
docker compose ... exec aur-forge drain        # actually rebuild / discard
```

For the Komodo side, see `faultoverload/docker` repo (PR #90).

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

- `compose/bigballs/production/aur-forge.yml`
  - single `aur-forge` service running in 24/7 `run` mode
  - bind-mounts `/opt/docker/data/aur-forge/{repo,cache,keys,approvals}` so
    all persistent state survives container rebuilds
- A build entry in `komodo.toml` (image built on bigballs-builder,
  tagged `localhost/aur-forge:latest`)
- A stack entry (`aur-forge` deploys the running container)
- A repo entry (Komodo tracks `faultoverload/aur-forge`)

**First deploy only:** pre-create the host-side data dirs so the
volume binds succeed:

```bash
ssh diana@bigballs
sudo mkdir -p /opt/docker/data/aur-forge/{repo,cache,keys,approvals}
sudo chmod 700 /opt/docker/data/aur-forge/keys
sudo touch /opt/docker/data/aur-forge/pkglist.txt
sudo chown -R diana:diana /opt/docker/data/aur-forge
exit
```

After that, `run` mode is self-bootstrapping: on every container
start, `run.sh` invokes `init.sh` which short-circuits if the GPG key
already exists (or generates one if it doesn't), exports the pubkey
to `/keys/aur-forge.pub`, and seeds the repo skeleton. **No separate
init step needed.**

For local development / smoke tests, use the bundled `docker-compose.sample.yml`
(still two-service for the dev loop, where iterating on `build` without
needing the nightly scheduler is convenient):

```bash
git clone https://github.com/faultoverload/aur-forge
cd aur-forge
cp pkglist.txt.example pkglist.txt   # edit to taste
docker compose -f docker-compose.sample.yml --profile build run --rm aur-forge-build init
docker compose -f docker-compose.sample.yml --profile build run --rm aur-forge-build build
docker compose -f docker-compose.sample.yml --profile serve up -d aur-forge-serve
```

## Onboarding a client

On any Arch machine that should use your repo:

```bash
curl -fsSL https://aur-forge.gateslab.win/keys/aur-forge.pub -o /tmp/aur-forge.pub
sudo ./install-repo.sh https://aur-forge.gateslab.win
```

That imports the key, writes a `[aur-forge]` stanza to `/etc/pacman.conf`, and runs `pacman -Sy`. From then on: `pacman -Syu` works as if `aur-forge` were just another official repo.

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
├── repo/                       served output (aur-forge.x86_64/*)
├── cache/                      host-backed cache volume (single bind mount);
│                               contains three distinct subtrees that must
│                               not be confused:
│   ├── cache/work/             AUR source/work cache (makepkg SRCDEST);
│   │                           cloned PKGBUILDs land here pre-build.
│   ├── cache/work-quarantine/  cloned trees the security gate denied;
│   │                           one timestamped dir per quarantined package.
│   └── cache/pacman/pkg/       official Arch package cache (pacman's
│                               CacheDir); persists across container
│                               rebuilds so incremental rebuilds don't
│                               re-download every dep. Patched into the
│                               devtools pacman.conf via a drop-in
│                               (scripts/pacman-cache-config.sh) so it
│                               becomes the FIRST CacheDir and the one
│                               devtools' arch-nspawn bind-mounts RW into
│                               the build chroot.
├── keys/                       GPG keyring (survives container rebuilds)
├── approvals/                  PKGBUILD approval JSON store (one file per package)
└── pkglist.txt                 one AUR package per line
```

The clean build chroot itself lives **in-container** at
`/var/lib/archbuild/extra-x86_64/` — not bind-mounted, not persisted.
Each `extra-x86_64-build -c` invocation wipes and re-bootstraps it via
pacstrap (see init.sh). That is intentional: a fresh chroot per build
is what makes the build hermetic.

### Why three caches, not one

They look similar (all under `/cache` or its neighbours) but they
serve different lifetimes and consumers — getting this wrong means
either re-downloading every dep on every rebuild, or keeping build
artifacts alive between unrelated builds:

| Path (in-container)              | Backing                  | Lifetime            | Purpose                                                              |
| -------------------------------- | ------------------------ | ------------------- | -------------------------------------------------------------------- |
| `/cache/work/`                   | bind-mount from host     | survives rebuilds   | AUR source tarballs (makepkg `SRCDEST`) — re-cloned PKGBUILDs land here |
| `/cache/work-quarantine/`        | bind-mount from host     | survives rebuilds   | Quarantined cloned trees (security gate deny) — one dir per package  |
| `/cache/pacman/pkg/`             | bind-mount from host     | survives rebuilds   | Official Arch package cache (pacman `CacheDir`) — incremental rebuilds reuse downloads |
| `/var/lib/archbuild/extra-x86_64/` | container overlay       | rebuilt per build   | Clean chroot root — wiped by `extra-x86_64-build -c`                 |

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
| `REPO_NAME`             | `aur-forge`                 | Pacman repo name (matches compose / Traefik labels).          |
| `REPO_OWNER`            | `faultoverload`          | Owner/contact for the repo metadata.                          |
| `REPO_EMAIL`            | `woodsyx@gmail.com`      | Email matching the GPG signing key.                           |
| `GPG_PASSPHRASE`        | (unset)                  | Passphrase for unattended GPG signing.                        |
| `PORT`                  | `8080`                   | TCP port lighttpd listens on (internal; Traefik fronts 443).  |
| `CSRF_SECRET_FILE`      | `/etc/aur-forge/csrf-secret` | Path to the CSRF secret. Auto-created at build time with mode 0600. Do NOT commit. |
| `AUR_BUILD_JOBS`        | `2`                      | Compile and zstd compression job count. Bound to the same value so `MAKEFLAGS=-jN`, `NPROC=N`, and `COMPRESSZST` stay in lockstep. Validated by `scripts/makepkg-jobs-config.sh`; anything outside `[1, MAX_AUR_BUILD_JOBS]` is rejected before the first `extra-x86_64-build`. |
| `MAX_AUR_BUILD_JOBS`     | `8`                      | Upper cap for `AUR_BUILD_JOBS`. The container's 4 GiB mem_limit and pid cap limit the safe value; raise only if you also raise `mem_limit` and confirm the cgroup survives a parallel build. |
| `AUR_FETCH_CLONE_POLICY` | `discard`               | How `scripts/aur-fetch-wrapper.sh` reconciles an existing `WORK` clone with upstream. Default `discard` resets local commits to `master@{upstream}` (safe for nightly rebuilds). Allowed: `discard` (default), `merge`, `rebase`, `auto`, `reset`. Invalid values log a warning and fall back to `discard`. |
| `AUR_FORGE_PACMAN_CACHE_DIR` | `/cache/pacman/pkg/` | Bind-mounted persistent pacman package cache. Set by `init.sh`; ensures `arch-nspawn`'s first-cache-dir bind points at host-backed storage instead of the overlay. |

## Pinned dependencies

The image picks up AUR-only packages through committed pins, never
unpinned `git clone`. Today the only pinned AUR dependency is
aurutils, tracked at the project root:

- `aurutils.version` — `AURUTILS_VERSION` (upstream tag),
  `AURUTILS_COMMIT` (40-char hex), `AURUTILS_SHA256` (64-char
  hex tarball hash), `AURUTILS_SOURCE_URL` (commit-pinned).
- `scripts/install-aurutils.sh` — fetches the upstream tarball
  by tag, asserts the SHA-256, builds via `makepkg --nocheck`,
  and stages `/usr/local/lib/aur-forge/aurutils.pin`.

To bump the pinned aurutils: update `aurutils.version` with the
new tag/commit/sha tuple and the new source URL, then rebuild
the image. The Dockerfile never unpinned-clones aurutils.

`archcanary` is also built from source in the Dockerfile; it is
cloned once with `--depth 1` from the maintained upstream and
built locally with `makepkg -si --skippgpcheck`. To bump archcanary,
update the upstream URL in the Dockerfile, not a version file.

## Web UI

`https://aur-forge.gateslab.win/` serves a small status page that shows every package in `pkglist.txt` with its current state. The same `lighttpd` instance that serves the signed pacman repo also handles three CGI endpoints:

| URL                          | Method | Behavior                                                                                                                                       |
| ---------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `/`                          | GET    | Renders the package table: built / building / quarantined / missing, with local version, AUR version, and OutOfDate flag. Embeds the install instructions and the two forms below. Rewritten to `/cgi-bin/index.cgi` via `mod_rewrite`. |
| `/cgi-bin/check.cgi`         | POST   | Background-spawns `/usr/local/bin/update.sh`. Rebuilds only the packages whose upstream AUR version differs from the local one. Returns immediately with a "queued" message — the build runs asynchronously and logs to `/var/log/aur-forge-check.log`. No-op if everything is already current. |
| `/cgi-bin/add.cgi`           | POST   | Validates the `packages` textarea (one name per line) against the Arch package-name regex, dedupes against the current `pkglist.txt`, and atomically appends new entries. Returns a summary page listing added / already-present / rejected / ignored names. |
| `/install.html`              | GET    | Standalone printable install instructions. Doesn't require a CSRF round-trip.                                                                  |
| `/style.css`                 | GET    | Dark retro stylesheet (also inlined into every CGI page via `cgi_html_doc`).                                                                   |
| `/keys/aur-forge.pub`        | GET    | The repo's public signing key. Symlinked from `/keys/aur-forge.pub` into `/repo/keys/` by `init.sh` so lighttpd serves it via the repo doc-root. |
| `/aur-forge.x86_64/...`         | GET    | The signed pacman repo, served as static files.                                                                                                |

### Why lighttpd (and not darkhttpd)

`darkhttpd` was the original server. It's tiny (~40 KB) and bulletproof, but its README states: "Only serves static content — no CGI." Verified against the upstream source on 2026-08-30. So `darkhttpd /repo --cgi /cgi-bin` would silently start a static-only server and 404 every `/cgi-bin/*` request.

`lighttpd` 1.4.85-1 (Arch `extra`, ~1.25 MiB installed) gives us `mod_cgi` + `mod_rewrite` in one package, zero new AUR deps, and zero open CVEs on the Arch security tracker as of 2026-08-30. The full server-pick rationale + empirical test results live at `Research/2026-08-30-aur-forge-web-server.md` in the vault.

### Security posture

The web UI is **public, no auth**. Server-side mitigation only:

1. **Regex validation.** Every package name in the `add` form is checked against `^[a-z0-9][a-z0-9._+-]{0,63}$` (the same regex pacman uses). Names containing `/`, `..`, whitespace, control chars, or longer than 64 chars are silently dropped.
2. **Dedup against `pkglist.txt`.** Duplicate names are rejected, not appended twice.
3. **Atomic write.** `add.cgi` writes the new pkglist to a temp file in the same directory and `mv -f`s it into place. Concurrent writes don't corrupt the file.
4. **CSRF token.** Every form carries a `<input type="hidden" name="csrf" value="nonce:hash">` where `hash = sha256(secret:nonce)` and `secret` is a 32-byte hex string generated at image build time and stored at `/etc/aur-forge/csrf-secret` (mode 0600, root-owned). The CGI recomputes the hash and compares. A drive-by bot without the secret cannot mint a matching token. **Not bulletproof against a determined attacker on the same network** — replace with real auth (Traefik basicAuth middleware, or Pocket-ID OIDC) if you ever expose this beyond a homelab.
5. **POST size cap.** `lighttpd.conf` sets `server.max-request-size = 1024` (1 KiB). The CSRF + a few package names fits; an attacker can't ship a 100 MB form body.
6. **Background spawn.** `check.cgi` background-spawns `update.sh` via `setsid nohup` so the CGI returns immediately and the build can't tie up the web worker.

### How to add the repo to a client

The UI shows the same content as `/install.html`:

```bash
# 1. Trust the signing key (fingerprint is on the main page)
sudo pacman-key --recv-keys <FPR>
sudo pacman-key --lsign-key <FPR>

# Or fetch it directly:
curl -fsSL https://aur-forge.gateslab.win/keys/aur-forge.pub \
    | sudo pacman-key --add -

# 2. Register the repo (drops /etc/pacman.d/aur-forge.conf)
curl -fsSL https://aur-forge.gateslab.win/install-repo.sh | sudo bash

# 3. Install
sudo pacman -Syu
pacman -Ss aur-forge
sudo pacman -S <package-name>
```

### Server reload

- `kill -HUP $(cat /var/run/aur-forge/lighttpd.pid)` — graceful reload after `lighttpd.conf` edits, in-flight requests finish.
- `systemctl restart aur-forge` — blunt option, drops in-flight requests.

### Local development

To run the tests:

```bash
bash tests/run-tests.sh        # existing: approval-store, srcinfo-diff, quarantine scripts
bash tests/run-webui-tests.sh  # new: lib-aur.sh, CGI scripts, live lighttpd smoke test
```

The web UI test suite skips the live lighttpd smoke test if `lighttpd` is not installed; the CGI unit cases still run.

## Limitations

- **Same-arch only.** Builds x86_64 for x86_64. ARM64 builds for ARM64.
- **The diff classifier is conservative.** If the gate can't prove a
  change is benign, it quarantines. Manual approval is always possible.
- **No automatic upstream-version watching.** Build when you want to; we don't poll the AUR.
- **One signing key per repo.** Rotating it means re-signing all packages + re-importing on every client.

## License

MIT.

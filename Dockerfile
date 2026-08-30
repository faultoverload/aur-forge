# aur-forge — containerized AUR build farm
#
# Build context for the AUR builder image. Uses archlinux:latest so the
# container runs a full Arch toolchain (pacman, makepkg, extra-x86_64-build,
# repo-add) regardless of the host OS (Ubuntu in our case).
#
# The build artifacts, repo output, GPG keyring, and package list are all
# bind-mounted from the host so they survive container rebuilds.

FROM archlinux:latest

LABEL org.opencontainers.image.title="aur-forge"
LABEL org.opencontainers.image.description="Containerized AUR build farm — builds AUR packages in clean chroots and serves a signed custom pacman repo."
LABEL org.opencontainers.image.source="https://github.com/faultoverload/aur-forge"

# Disable pacman's DownloadUser sandbox. Pacman 7+ sandboxes downloads
# under the unprivileged `alpm` user with landlock + seccomp. The default
# Docker seccomp profile blocks the syscalls landlock needs, so the
# sandbox fails to start and pacman errors out with:
#   "error restricting syscalls via seccomp: 22"
#   "error switching to sandbox user 'alpm' failed"
# Building aur-forge's container as --privileged or with a custom
# seccomp profile would also work, but the sandbox is purely a defense-
# in-depth feature for download extraction; it provides no value inside
# a build container we're already running as root. Disable it globally
# so every subsequent pacman / makepkg call inherits the setting.
RUN sed -i 's/^#DisableSandbox/DisableSandbox/' /etc/pacman.conf

# devtools     — extra-x86_64-build (clean chroot builds)
# darkhttpd    — static file server for the repo
# gnupg        — signing + keyring
# pinentry     — unattended passphrase via loopback/tty
# sudo         — makepkg refuses to build as root; we drop to a temp
#                user via `sudo -u tmpbuild` for the AUR package build.
#                archlinux:latest (= `base` meta) does NOT ship sudo.
# git, base-devel — needed by every AUR build
# jq, openssh, curl — gate pipeline (JSON manipulation + GitHub API)
# make, gcc — needed by archcanary's PKGBUILD
# pacutils, perl-json-xs — runtime deps of aurutils (AUR). Pre-install
#   them here so the makepkg-as-tmpuser step below doesn't have to
#   resolve deps mid-build.
#
# NOTE: aurutils itself is AUR-only and is installed below via makepkg.
RUN pacman -Syu --noconfirm \
    && pacman -S --noconfirm --needed \
        base-devel \
        devtools \
        sudo \
        darkhttpd \
        git \
        gnupg \
        jq \
        openssh \
        curl \
        pinentry \
        ca-certificates \
        pacutils \
        perl-json-xs \
 && pacman -Scc --noconfirm \
 && rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/*

# Install archcanary (musqz/archcanary) + aurutils (AUR helpers) from
# source. Both are AUR-only packages, never in [core]/[extra], so they
# can't be installed with pacman. We clone each repo, run `makepkg -si`
# as a non-root user, and rely on the deps we pre-installed above.
#
# Both packages are passed --skippgpcheck to disable makepkg's source-
# file signature verification. The AUR does not require PKGBUILD source
# signatures and missing PGP keys in a clean chroot otherwise cause the
# build to fail with "SIGNATURE NOT FOUND". The actual package
# artifacts are signed at build time by aur-forge's GPG key (see
# build.sh / repo-add), so this does not weaken repo integrity.
#
# Note: makepkg refuses to build as root, so we drop to a temp user,
# build, then install the resulting packages as root. This is the same
# pattern documented at https://wiki.archlinux.org/title/Makepkg#Building_as_a_different_user
RUN useradd -m -s /bin/bash tmpbuild \
    && passwd -d tmpbuild \
    && echo "tmpbuild ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/tmpbuild \
    && sudo -u tmpbuild bash -c 'set -euo pipefail; \
        cd /tmp && \
        git clone --depth 1 https://github.com/musqz/archcanary.git && \
        cd archcanary/packaging && \
        makepkg -si --noconfirm --skippgpcheck && \
        cd /tmp && \
        git clone --depth 1 https://aur.archlinux.org/aurutils.git && \
        cd aurutils && \
        makepkg -si --noconfirm --skippgpcheck' \
    && rm -rf /tmp/archcanary /tmp/aurutils \
    && userdel -r tmpbuild 2>/dev/null || true \
    && rm -f /etc/sudoers.d/tmpbuild \
    && archcanary --help >/dev/null || { echo "archcanary install failed"; exit 1; } \
    && command -v aur >/dev/null || { echo "aurutils install failed"; exit 1; }

# Make pacman + makepkg happy in a containerized chroot. makepkg runs
# extra-x86_64-build which creates its own chroot via pacstrap — no
# systemd / no kernel needed, but we do need /etc/mtab and unshare caps.
RUN ln -sf /proc/self/mounts /etc/mtab

# Initialize + populate the pacman keyring at build time. Without this,
# the first `extra-x86_64-build` invocation triggers `pacman -Sy` inside
# the new chroot and every package fails PGP signature verification
# ("missing required signature") because the trust database is empty.
# archlinux:latest ships with the keyring files but no trust signatures
# applied — pacman-key --populate is what makes the master keys trusted.
RUN pacman-key --init \
 && pacman-key --populate archlinux \
 && pacman -Sy --noconfirm \
 && rm -rf /var/lib/pacman/sync/*

# /etc/machine-id stays as the archlinux:latest placeholder for now;
# systemd will overwrite it with a real UUID at first boot. We tried
# pre-generating one with `cat /proc/sys/kernel/random/uuid` but
# /proc isn't always available in the Docker build context — leaving
# systemd to handle it is simpler.

# Build a non-root user for makepkg (makepkg refuses to run as root by
# default). The container's entrypoint runs as root and drops to this user
# for the build itself; signed packages get copied out as root.
RUN useradd -m -s /bin/bash builder \
 && echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder

# Darkhttpd will run as nobody for serving the static repo.
WORKDIR /repo

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY build.sh      /usr/local/bin/build.sh
COPY init.sh       /usr/local/bin/init.sh
COPY update.sh     /usr/local/bin/update.sh
COPY serve.sh      /usr/local/bin/serve.sh
COPY run.sh        /usr/local/bin/run.sh
COPY scripts/      /usr/local/lib/aur-forge/

# systemd-as-PID-1 setup for the 24/7 'run' mode.
# ------------------------------
# arch-nspawn / systemd-nspawn (invoked by extra-x86_64-build on
# every AUR build) require systemd to be running as PID 1 — systemd
# itself refuses to start with "Can't run system mode unless PID 1".
# We install systemd here, copy in our service unit, and enable it.
# When the entrypoint's `run` subcommand fires it exec's /sbin/init
# (which is /lib/systemd/systemd on Arch), systemd comes up as PID 1
# with our unit enabled, and run.sh runs as a managed service.
#
# `systemd-sysvcompat` provides the /sbin/init symlink. The base
# archlinux:latest image already includes /lib/systemd/systemd but
# not the symlink, the unit files, or the journald defaults — the
# -Syu below + systemctl enable wires all of that up.
#
# We disable systemd's default getty + multi-user.target defaults
# (sshd, etc.) because aur-forge is a single-purpose container;
# aur-forge.service is the only unit that should run.
# We mask systemd's firstboot / remount-fs / machine-id-setup
# services because they either try to write to /etc/machine-id (we
# already did that at build time) or assume a writable rootfs that
# the container doesn't provide. Failures here are non-fatal — the
# `|| true` lets the build proceed even if a unit name changes in
# a future systemd version.
RUN pacman -S --noconfirm --needed systemd-sysvcompat dbus \
 && systemctl mask \
        systemd-firstboot.service \
        systemd-remount-fs.service \
 || true

COPY aur-forge.service /etc/systemd/system/aur-forge.service
RUN systemctl enable aur-forge.service

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/build.sh \
              /usr/local/bin/init.sh /usr/local/bin/update.sh \
              /usr/local/bin/serve.sh /usr/local/bin/run.sh \
    && chmod +x /usr/local/lib/aur-forge/*.sh \
    && ln -sf /usr/local/lib/aur-forge/approval-store.sh      /usr/local/bin/approval-store.sh \
    && ln -sf /usr/local/lib/aur-forge/srcinfo-diff.sh        /usr/local/bin/srcinfo-diff.sh \
    && ln -sf /usr/local/lib/aur-forge/open-quarantine-issue.sh /usr/local/bin/open-quarantine-issue.sh \
    && ln -sf /usr/local/lib/aur-forge/drain-quarantine.sh    /usr/local/bin/drain-quarantine.sh

# darkhttpd serves on 8080 internally; Traefik in front publishes 443.
EXPOSE 8080

# Default to showing usage; argv[1] decides init|build|serve.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["help"]

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

# devtools     — extra-x86_64-build (clean chroot builds)
# darkhttpd    — static file server for the repo
# gnupg        — signing + keyring
# pinentry     — unattended passphrase via loopback/tty
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
        cd archcanary && \
        makepkg -si --noconfirm --skippgpcheck && \
        cd /tmp && \
        git clone --depth 1 https://aur.archlinux.org/aurutils.git && \
        cd aurutils && \
        makepkg -si --noconfirm --skippgpcheck' \
    && rm -rf /tmp/archcanary /tmp/aurutils \
    && userdel -r tmpbuild 2>/dev/null || true \
    && rm -f /etc/sudoers.d/tmpbuild \
    && archcanary --help >/dev/null || { echo "archcanary install failed"; exit 1; } \
    && aur sync --help >/dev/null || { echo "aurutils install failed"; exit 1; }

# Make pacman + makepkg happy in a containerized chroot. makepkg runs
# extra-x86_64-build which creates its own chroot via pacstrap — no
# systemd / no kernel needed, but we do need /etc/mtab and unshare caps.
RUN ln -sf /proc/self/mounts /etc/mtab

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

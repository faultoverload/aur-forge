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
# aurutils     — aur sync / aur search helpers
# darkhttpd    — static file server for the repo
# gnupg        — signing + keyring
# pinentry     — unattended passphrase via loopback/tty
# git, base-devel — needed by every AUR build
RUN pacman -Syu --noconfirm \
    && pacman -S --noconfirm --needed \
        base-devel \
        devtools \
        aurutils \
        darkhttpd \
        git \
        gnupg \
        jq \
        openssh \
        pinentry \
        ca-certificates \
 && pacman -Scc --noconfirm \
 && rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/*

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

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/build.sh /usr/local/bin/init.sh /usr/local/bin/update.sh /usr/local/bin/serve.sh

# darkhttpd serves on 8080 internally; Traefik in front publishes 443.
EXPOSE 8080

# Default to showing usage; argv[1] decides init|build|serve.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["help"]

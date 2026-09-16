# syntax=docker/dockerfile:1
#
# keel -- Andy's personal exe.dev base image.
#
# A ship's keel is the backbone laid down first; every frame and plank is built
# up from it. This image is what every exe.dev VM of mine starts as, and other
# machine images layer FROM it.
#
# Design rules, in full in ./README.md:
#   * The Containerfile installs BINARIES. chezmoi contributes CONFIG only --
#     `--exclude=scripts` stops the dotfiles' run_ scripts from apt/mise-installing
#     anything at apply time, `--exclude=encrypted` keeps every secret off the VM.
#   * No secrets are baked in or fetched at build time. Runtime secrets come from
#     1Password Connect through the exe.dev integration (see files/keel-secret).
#   * exe.dev-specific settings live here, never in the cross-platform dotfiles.
#
# Built only by .github/workflows/deploy-keel.yml -- there is no local build loop.
#
# Base pinned at :latest deliberately. exeuntu rebuilds itself weekly with
# --no-cache to absorb Ubuntu security updates, and a digest pin would freeze
# exactly the fixes that rebuild exists to deliver. The workflow's weekly
# schedule is what pulls them through into this image.
FROM ghcr.io/boldsoftware/exeuntu:latest

# Tools with no Ubuntu package. Pinned exactly; Renovate bumps them via the
# customManagers block in renovate.json.
ARG STARSHIP_VERSION=1.26.0
ARG ATUIN_VERSION=18.22.0
ARG GUM_VERSION=2.0.1
ARG JJ_VERSION=0.45.1
ARG CHEZMOI_VERSION=2.72.2
# Ubuntu noble ships borgbackup 1.2.8; rsync.net's server-side `borg14` and
# most 1.4.x clients speak a different `--match-archives 'sh:...'` syntax than
# 2.x, so this stays pinned below 2.0 until every client in use is upgraded
# together.
ARG BORG_VERSION=1.4.5

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

# ---------------------------------------------------------------------------
# 1. Packaged tools.
#
# Only what noble actually has -- security updates then ride the weekly rebuild
# with no version tracking of our own. Everything already in exeuntu (git, curl,
# jq, sqlite3, rsync, vim, neovim, ripgrep, fd, gh, uv, Go, Docker, Tailscale)
# is deliberately absent.
# ---------------------------------------------------------------------------
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --assume-yes --no-install-recommends \
        zsh \
        fish \
        bat \
        fzf \
        zoxide \
        just \
        git-delta \
        fd-find \
    && rm --recursive --force /var/lib/apt/lists/* \
    # Ubuntu renames both of these to avoid binary collisions (bacula, fdclone).
    # Without the symlinks, config expecting the upstream names silently no-ops.
    && ln --symbolic --force /usr/bin/batcat /usr/local/bin/bat \
    && ln --symbolic --force /usr/bin/fdfind /usr/local/bin/fd \
    # `ln -s` happily creates a dangling link, so prove both resolve. Otherwise a
    # renamed or dropped package leaves a broken binary that only shows up in use.
    && bat --version && fd --version

# ---------------------------------------------------------------------------
# 2. Unpackaged tools, from pinned upstream releases.
#
# amd64 only. See the README if an arm64 VM ever appears.
# ---------------------------------------------------------------------------
RUN <<'EOSH'
#!/usr/bin/env bash
set -euxo pipefail
tmp="$(mktemp --directory)"
cd "$tmp"

# Extract into a scratch dir and install the binary out of it, rather than
# targeting /usr/local/bin from tar directly. Layouts differ per project --
# starship ships a bare `starship`, atuin/gum a versioned top directory, jj a
# `./`-prefixed root -- and member-name matching across those is a tar
# implementation detail. Unpack, then pick, and none of that matters.
fetch_tar() { # url, path-of-binary-inside, name
    curl --fail --silent --show-error --location "$1" -o a.tgz
    rm --recursive --force x && mkdir x && tar --extract --gzip --file a.tgz --directory x
    install --mode=0755 "x/$2" "/usr/local/bin/$3"
    rm --force a.tgz
}
fetch_bin() { # url, name
    curl --fail --silent --show-error --location "$1" -o "/usr/local/bin/$2"
    chmod 0755 "/usr/local/bin/$2"
}

# starship -- the prompt. dot_zshrc.tmpl activates it behind a
# `command -v starship` guard, so this is what makes that guard fire.
fetch_tar "https://github.com/starship/starship/releases/download/v${STARSHIP_VERSION}/starship-x86_64-unknown-linux-musl.tar.gz" \
    "starship" starship

# atuin -- shell history. Installed for LOCAL history only; sync is
# deliberately off (no login, no key, no session, nothing to rotate).
fetch_tar "https://github.com/atuinsh/atuin/releases/download/v${ATUIN_VERSION}/atuin-x86_64-unknown-linux-musl.tar.gz" \
    "atuin-x86_64-unknown-linux-musl/atuin" atuin

fetch_tar "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_x86_64.tar.gz" \
    "gum_${GUM_VERSION}_Linux_x86_64/gum" gum

fetch_tar "https://github.com/jj-vcs/jj/releases/download/v${JJ_VERSION}/jj-v${JJ_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    "jj" jj

# chezmoi -- pinned rather than curl|sh from get.chezmoi.io, so the image is
# reproducible and Renovate can see the version.
fetch_bin "https://github.com/twpayne/chezmoi/releases/download/v${CHEZMOI_VERSION}/chezmoi-linux-amd64" chezmoi

# borg -- the official fat binary, not the distro package. See ARG above.
fetch_bin "https://github.com/borgbackup/borg/releases/download/${BORG_VERSION}/borg-linux-glibc235-x86_64-gh" borg

cd / && rm --recursive --force "$tmp"

# Fail the build here rather than on a VM at 01:00.
starship --version
atuin --version
gum --version
jj --version
chezmoi --version
borg --version
EOSH

# ---------------------------------------------------------------------------
# 3. exe.dev-specific configuration.
#
# These belong in the image precisely because they are exe.dev-specific: the
# chezmoi dotfiles are cross-platform and must stay that way.
# ---------------------------------------------------------------------------
# System git config: URL rewriting so `git clone https://github.com/andreweick/x`
# transparently uses the exe.dev GitHub integration. Read BEFORE ~/.gitconfig,
# so it composes with the chezmoi-managed one without touching it.
COPY files/gitconfig /etc/gitconfig

RUN chmod 0644 /etc/gitconfig

# ---------------------------------------------------------------------------
# 4. keel's own scripts, units and defaults.
# ---------------------------------------------------------------------------
COPY files/keel-secret files/keel-profile files/keel-backup /usr/local/bin/
COPY files/keel-profile.service files/keel-backup.service files/keel-backup.timer \
     /etc/systemd/system/
COPY files/etc-keel-secrets.conf /etc/keel/secrets.conf
COPY files/etc-keel-sqlite       /etc/keel/sqlite
COPY files/etc-keel-paths        /etc/keel/paths
COPY files/etc-keel-exclude      /etc/keel/exclude

RUN chmod 0755 /usr/local/bin/keel-secret /usr/local/bin/keel-profile /usr/local/bin/keel-backup \
    && chmod 0644 /etc/systemd/system/keel-*.service /etc/systemd/system/keel-*.timer \
    && chmod 0644 /etc/keel/* \
    && mkdir --parents /var/lib/keel/dumps \
    && chmod 0700 /var/lib/keel/dumps \
    # Enable keel-profile by hand rather than with `systemctl enable`: there is
    # no running systemd during a build.
    && ln --symbolic --force /etc/systemd/system/keel-profile.service \
        /etc/systemd/system/multi-user.target.wants/keel-profile.service
#
# keel-backup.timer is deliberately NOT enabled here. keel-profile turns it on
# at boot if, and only if, the VM carries the `backup` tag -- so a scratch box
# never runs a backup job, and promotion is `ssh exe.dev tag <vm> backup` with
# no rebuild.

# ---------------------------------------------------------------------------
# 5. Dotfiles -- config only.
#
#   --exclude=scripts    the repo's four run_ scripts would `sudo apt install`
#                        from aptfile.txt and run `mise install`/`upgrade` over
#                        ~25 tools at apply time. Installation belongs above.
#   --exclude=encrypted  keeps all 24 encrypted_*.age files off the VM. There is
#                        no age key here and there never will be, so this is
#                        defence in depth rather than the mechanism -- a keel VM
#                        must not receive a secret even if a key appears later.
#
# Applied at build time so a VM is fully configured the moment it boots, with no
# dependency on GitHub being reachable at first boot. `keel-update-dotfiles`
# refreshes without a rebuild.
# ---------------------------------------------------------------------------
USER exedev
WORKDIR /home/exedev
# GIT_CONFIG_NOSYSTEM=1 drops /etc/gitconfig for this one clone. That file
# rewrites github.com/andreweick/ to the exe.dev integration endpoint
# github.int.exe.xyz -- correct on a running VM, unroutable from the GitHub
# Actions runner that builds this image, where the clone just hangs until it
# times out. The rewrite still ships in the image, so `keel-update-dotfiles`
# on a VM keeps going through the integration.
RUN GIT_CONFIG_NOSYSTEM=1 \
    chezmoi init --apply --exclude=scripts,encrypted \
        https://github.com/andreweick/dotfiles.git \
    && test -f /home/exedev/.config/starship.toml \
    && test -f /home/exedev/.zshrc \
    && test ! -e /home/exedev/.config/age/key.txt

USER root

# One-line refresh of the dotfiles on a running VM, with the same exclusions --
# so nobody has to remember the flags and accidentally pull in a secret.
RUN printf '%s\n' '#!/bin/sh' \
      '# Refresh the chezmoi-managed dotfiles. Same exclusions as the image build:' \
      '# config only, no run_ scripts, no encrypted files.' \
      'exec chezmoi update --exclude=scripts,encrypted "$@"' \
      > /usr/local/bin/keel-update-dotfiles \
    && chmod 0755 /usr/local/bin/keel-update-dotfiles

# The configured shell should be the one you land in. exeuntu leaves exedev on
# bash; the dotfiles manage .zshrc/.zshenv and the fish tree, and notably do NOT
# manage .bashrc -- so exeuntu's own PATH/XDG_RUNTIME_DIR exports there stay
# intact either way.
RUN chsh --shell /bin/zsh exedev

# ---------------------------------------------------------------------------
# 6. LAST: re-empty the machine ID.
#
# exeuntu truncates /etc/machine-id as its final step so every VM generates its
# own, and warns that any later `apt-get install` bakes a new one back in. This
# image installs packages, so it must repeat the truncation -- and it is not
# cosmetic here: keel-backup.timer uses FixedRandomDelay=yes, which derives its
# per-host offset from the machine ID. A shared ID would make every VM built
# from this image pick the SAME backup slot and pile onto one exclusive
# repository lock.
#
# Any image layering on keel that installs packages must do this too.
# ---------------------------------------------------------------------------
RUN : > /etc/machine-id \
    && ln --symbolic --force /etc/machine-id /var/lib/dbus/machine-id

# No EXPOSE: exeuntu already declares 8000 and 9999, labels are inherited, and a
# base image has no business choosing a proxy port for every descendant.

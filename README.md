# `keel` — personal exe.dev base image

The image every exe.dev VM of mine starts as. A ship's **keel** is the backbone
laid down first — "laying the keel" is the literal first act of shipbuilding, and
every frame and plank is built up from it.

| | |
|---|---|
| Image | `ghcr.io/missionfocus/keel` |
| Base | [`ghcr.io/boldsoftware/exeuntu:latest`](https://github.com/boldsoftware/exeuntu) |
| Built by | [`.github/workflows/deploy-keel.yml`](.github/workflows/deploy-keel.yml) — **CI only, no local build** |

It carries dotfiles, shell tooling, the exe.dev GitHub wiring, and a daily Borg
backup that only runs where it is asked to. Nothing in it is a workload — other
exe.dev machine images layer `FROM` it, and VMs needing nothing else boot it
directly.

## The three rules

1. **The Containerfile installs binaries; chezmoi installs config.** The dotfiles
   are applied with `--exclude=scripts,encrypted`, so their `run_` scripts never
   `apt install` or `mise install` anything on a VM.
2. **No secrets on the VM, ever.** Nothing is baked in and nothing is fetched at
   build time. Runtime credentials come from 1Password Connect through the exe.dev
   integration, are used, and are gone.
3. **exe.dev-specific settings live in the image, not in the dotfiles.** The
   dotfiles are cross-platform and stay that way.

## Tags are the control surface

A VM's exe.dev tags decide what it becomes. `keel-profile.service` reads them at
boot from the Reflection integration (`reflection.int.exe.xyz/tags`) and switches
things on accordingly.

| Tag | Layer | Effect |
|---|---|---|
| `dev` / `prod` | platform | grants the `onepassword` integration — the VM *can* fetch secrets |
| `dev` | platform | grants the `gh-andreweick` / `gh-missionfocus` GitHub integrations |
| `backup` | keel | enables `keel-backup.timer` |

**`backup` is deliberately separate from `prod`.** "Is production" and "has data
worth keeping" are different questions, and both counterexamples exist: a
stateless production service should not run a nightly job archiving nothing while
holding live credentials to the shared repository, and a dev box can hold a
scratch database that took a day to populate and would hate to lose.

A VM needs **both** `backup` and `dev`/`prod` to actually back up. That is not
redundancy: `backup` alone fails loudly at secret fetch, which is visible in the
journal, rather than silently doing nothing.

## Build

There is no local build loop — no Docker or podman on the laptop, by choice.

```sh
just build      # gh workflow run deploy-keel.yml
just watch      # follow it
just digest     # the digest of the resulting :latest
```

The workflow also runs on every push/PR, and **weekly on a schedule**. That
schedule is load-bearing, not housekeeping: exeuntu rebuilds itself weekly with
`--no-cache` to absorb Ubuntu security updates, and keel consumes it as a bare
`:latest`, which Renovate cannot bump because there is no version to compare. The
weekly run is the only thing that pulls those fixes through. Without it, keel
silently pins whatever exeuntu shipped the day it last built.

## Launch: two ways

`just new` boots the full pre-built image. `just new-fast` boots the small stock
`exeuntu` image and configures itself live via a generated `--setup-script`. Same
end result for a dev box; different trade-off.

Measured directly against the published registry manifests (no VM needed --
just registry API inspection): `keel`'s own genuinely-new content —
apt packages, starship/atuin/gum/jj/chezmoi/borg, dotfiles, keel's own scripts —
is only **~114 MiB**. The other **~1.5 GiB** is byte-identical to `exeuntu`'s own
base layers, since `FROM exeuntu:latest` just references them verbatim. In
principle a registry pull should reuse those shared layers regardless of which
image asks for them. In practice, `exeuntu` is exe.dev's own default and is
presumably kept warm across the fleet; a private-turned-public *derivative* isn't,
even with byte-identical layers — so `just new` still tends to pay for the full
~1.6 GiB, while `just new-fast` only pays for `exeuntu`'s pull (same story) plus
~100–150 MiB of live `apt`/GitHub/git fetches. That gap is what makes the second
path worth having, confirmed empirically as multiple minutes faster in practice.

### A. Pre-built image (`just new`)

Everything is already resolved and installed — no live `apt-get`, no live
`curl` to GitHub, no live git clone at boot. The trade is size: one big,
already-resolved pull.

```sh
# a dev box
ssh exe.dev new --name mybox --image=ghcr.io/missionfocus/keel:latest --tag dev

# a box that also backs up
ssh exe.dev new --name mybox --image=ghcr.io/missionfocus/keel:latest --tag dev,backup
```

or `just new mybox dev,backup`. No PAT needed — the package published public by
default from this public repo.

Pin a digest instead of `:latest` (`just digest`) when you want a VM to stay put
across image rebuilds.

Promote or demote an existing VM without rebuilding anything:

```sh
just enable-backup mybox     # tag + restart, so keel-profile re-reads the tags
just disable-backup mybox
```

### B. Setup script (`just new-fast`)

Boots the stock `exeuntu` image, then resolves and installs everything live at
first boot (`render-setup.sh`, built from `files/*` and the Containerfile's
pinned versions — nothing hand-duplicated). One command, no PAT ever, blocks
until the box is actually ready — send it off and walk away:

```sh
just new-fast mybox dev
```

**Dev-only.** exe.dev caps `--setup-script` at 10 KiB, which is not enough room
for borg + `keel-backup` + its units + `/etc/keel/*` on top of the dev tooling.
A VM that needs `backup` capability needs path A instead — `backup` is already
a deliberate, less-common promotion (`just enable-backup`), not the common case
this optimizes for.

## Use

**APT catalogs are included.** Keel retains `/var/lib/apt/lists` after installing
its tools, so a new VM does not start with an empty package catalog. This trades
a slightly larger image for less first-use setup when installing extra packages;
it does not retain downloaded `.deb` installers. The catalog reflects build time,
not launch time: run `sudo apt update` to refresh it, especially if an install
fails because a recorded package version is no longer available.

**GitHub just works.** `/etc/gitconfig` rewrites both of my owners to the
integration host, so ordinary URLs work with no token on the VM:

```sh
git clone https://github.com/andreweick/spouterinn.git    # -> github.int.exe.xyz
git clone https://github.com/missionfocus/edc.git
gh repo view andreweick/spouterinn
```

`gh` itself picks up `GH_HOST=github.int.exe.xyz` from the dotfiles' `.zshrc`
(guarded to the `exedev`/`/home/exedev` case), not from anything in this image.

The rewrite is owner-scoped on purpose. A blanket `github.com` rewrite would push
public third-party clones through the integration too, and a repo with no matching
integration fails rather than falling through to the public endpoint.

For a repo to resolve, its owner's integration must list it and be attached to a
tag the VM carries — the image never learns repo names, so adding one is a
lobby-side edit with no rebuild:

```sh
ssh exe.dev integrations edit gh-andreweick --repository andreweick/newrepo
```

**Secrets** are fetched by reference, never stored:

```sh
keel-secret op://keel/borg-fleet/passphrase
```

**Dotfiles** refresh in place, with the image's exclusions already applied so you
cannot accidentally pull a secret onto the VM:

```sh
keel-update-dotfiles
```

**Backups** (only on a `backup`-tagged VM, so path A only — see Launch above):

```sh
systemctl list-timers keel-backup.timer   # when this VM's slot is
systemctl start keel-backup.service       # run one now
journalctl -u keel-backup -n 100
```

## Backups in detail

Declare what matters on each VM, in `/etc/keel/`:

| File | Holds |
|---|---|
| `sqlite` | one absolute DB path per line — each gets a daily `VACUUM INTO` snapshot |
| `paths` | extra backup roots beyond the defaults |
| `exclude` | borg exclude patterns |
| `secrets.conf` | `op://` references and the repo URL — never secrets |

**Scope is defined by exclusion, not inclusion.** The roots are `/home/exedev`,
`/opt` and `/var/lib` — everything you made, plus systemd service state, which
lives outside `$HOME`. The reasoning is asymmetric failure modes: a forgotten
*include* is discovered at restore time and the gap is permanent, while a
forgotten *exclude* just makes the archive bigger and is noticed within a day.
So sweep everything and subtract what is provably rebuildable.

**Never let borg read a live SQLite file** — that is the classic WAL-corruption
trap, and it matters more with a broad sweep than with named paths. Declaring a
database in `sqlite` does double duty: it is snapshotted with `VACUUM INTO` *and*
added to the exclude list along with its `-wal`/`-shm` siblings. Do not also list
it in `exclude`.

**Timing is deterministic, not random.** Every backup VM writes to one repository
with an exclusive lock, so the timer uses `RandomizedDelaySec=3h` with
`FixedRandomDelay=yes` — the offset derives from `/etc/machine-id`, so each VM
claims a slot once and keeps it across 01:00–04:00 UTC. `--lock-wait 3600` absorbs
any residual collision.

**This VM cannot delete anything.** Its rsync.net key is restricted to
`borg serve --append-only`, so a compromised VM cannot destroy the fleet's
history. There is deliberately no `prune` or `compact` here.

### Retention — run from the steward, not the VMs

The steward is a workstation holding the *full-access* rsync.net key (it already
has `Host rsyncnet` in `~/.ssh/config.d/`). Weekly:

```sh
export BORG_REPO='ssh://de4596@de4596.rsync.net/./borg-fleet'
export BORG_REMOTE_PATH=borg14

for host in $(borg list --format '{hostname}{NL}' | sort -u); do
    borg prune --match-archives "sh:${host}-*" \
        --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 1
done
borg compact          # prune alone frees no space in borg 1.2+
```

and monthly `borg check`.

> **Prune must be scoped per host, every time.** Unscoped, prune evaluates
> retention across the whole fleet and deletes *other hosts'* archives — a
> single unstable archive-name prefix is enough to let a stale run's archives
> silently accumulate instead of getting pruned. Scope every prune invocation
> explicitly, always.

`--keep-daily 14` is what gives per-day retrieval for two weeks:

```sh
borg list | grep mybox                     # find the day
borg extract "::mybox-2026-09-05T01:47:00" --strip-components 0
```

## Extend

To layer a service image on `keel`:

```dockerfile
FROM ghcr.io/missionfocus/keel:latest
COPY --from=app /usr/local/bin/myservice /usr/local/bin/myservice
COPY myservice.service /etc/systemd/system/myservice.service
RUN ln -sf /etc/systemd/system/myservice.service \
      /etc/systemd/system/multi-user.target.wants/myservice.service
EXPOSE 8080
```

Three things to get right:

1. **`systemctl enable` does not work at build time** — there is no running
   systemd. Create the `multi-user.target.wants` symlink yourself, as above.
2. **If you `apt-get install`, re-truncate the machine ID as your last step:**
   ```dockerfile
   RUN : > /etc/machine-id && ln -sf /etc/machine-id /var/lib/dbus/machine-id
   ```
   exeuntu empties it so each VM generates its own, and any package install bakes
   a new one back in. A shared machine ID makes every VM compute the same
   `FixedRandomDelay` offset and pile onto one repository lock at the same instant.
3. **`EXPOSE` belongs in your image, not in keel.** exe.dev picks the proxy port
   from the exposed set; a base image has no business choosing that for every
   descendant.

To add a tool to keel itself: apt if noble packages it (security updates then ride
the weekly rebuild for free), otherwise a pinned `ARG <TOOL>_VERSION` in the
Containerfile, bumped by hand for now (no Renovate on this repo yet).

Note Ubuntu renames two binaries to avoid collisions — `bat` installs as
`batcat`, `fd-find` as `fdfind`. The Containerfile symlinks both; anything else
you add with the same problem needs the same treatment.

The image is **amd64 only**. If an arm64 VM ever appears, each release download
in section 2 of the Containerfile needs an arch case (exeuntu's own `fd` install
shows the pattern).

## Update

| What | How |
|---|---|
| exeuntu security fixes | automatic — the weekly workflow run |
| pinned tool versions | by hand, `ARG` lines in the Containerfile (no Renovate on this repo yet) |
| apt packages | automatic — the weekly rebuild re-resolves them |
| dotfiles on a running VM | `keel-update-dotfiles` |
| dotfiles baked into the image | rebuild (`just build`) |
| what a VM backs up | edit `/etc/keel/*` on the VM |
| whether a VM backs up | `just enable-backup <vm>` — no rebuild |

`unattended-upgrades` is deliberately **not** installed. exeuntu masks it and
removes its timers, taking the position that the weekly image rebuild is the
update mechanism — and since keel rebuilds weekly on the same cadence, adding it
back would duplicate the machinery and fight the image for package ownership.

## Gotchas

- **`GH_HOST` is global.** It's set in the dotfiles' `.zshrc`, not this image, so
  every `gh` call from an interactive shell routes through the aggregate
  integration host, including against public repos with no integration, which
  fail rather than falling back. It does not reach non-interactive shells or
  systemd services, since those don't source `.zshrc`.
- **`.ssh/config.d/rsyncnet.conf` arrives from the dotfiles** and points at
  `~/.ssh/andy-anywhere` with `StrictHostKeyChecking ask`. That key does not
  exist on a VM and `ask` would hang a systemd unit forever, so `keel-backup`
  passes its own agent and `-o StrictHostKeyChecking=yes` against
  `~/.ssh/known_hosts_ca` (dotfiles-managed, holds the pinned rsync.net host
  key) rather than using that block.
- **atuin is installed but not logged in.** Local history only — no key, no
  session, nothing to rotate. An exe.dev integration could not have helped:
  atuin's encryption key is client-side end-to-end and must be a local file,
  and integrations only inject credentials into HTTPS requests at the edge.

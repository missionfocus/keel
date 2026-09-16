set fallback

# keel is built ONLY by .github/workflows/deploy-keel.yml -- there is no local
# build. These recipes are the things you actually do from a workstation.

image := 'ghcr.io/missionfocus/keel'

# Show what's here and how to build it.
default:
    @just --list

# Kick off a build in CI (the only way keel gets built).
build:
    gh workflow run deploy-keel.yml
    @echo "watch with: just watch"

# Follow the running build.
watch:
    gh run watch $(gh run list --workflow=deploy-keel.yml --limit 1 --json databaseId -q '.[0].databaseId')

# The digest of the current :latest, for pinning a `new` command.
digest:
    @crane digest {{image}}:latest 2>/dev/null || \
      docker buildx imagetools inspect {{image}}:latest --format '{{{{.Manifest.Digest}}'

# Syntax-check the scripts and units exactly as CI does.
check:
    #!/usr/bin/env bash
    set -euo pipefail
    for s in files/keel-secret files/keel-profile files/keel-backup; do
        bash -n "$s" && echo "ok: $s"
    done
    ./render-setup.sh | bash -n /dev/stdin && echo "ok: render-setup.sh output"
    size=$(./render-setup.sh | wc -c | tr -d ' ')
    [ "$size" -lt 10240 ] && echo "ok: render-setup.sh size ($size bytes, under exe.dev's 10 KiB --setup-script cap)" \
        || { echo "FAIL: render-setup.sh is $size bytes -- exe.dev's --setup-script cap is 10240" >&2; exit 1; }

# Print the generated --setup-script (files/* + Containerfile ARG versions,
# rendered for the stock exeuntu image). See render-setup.sh and the README
# for why this exists as a second launch path alongside the pre-built image.
render-setup:
    ./render-setup.sh

# Create a new VM from the pre-built image. Tags decide what it becomes:
#   dev / prod  -> grants the onepassword integration (and gh on dev)
#   backup      -> keel enables the daily borg timer
# The GHCR package needs to be public (repo Settings -> Packages, after the
# first build) for this to need no --registry-auth. Until then, pass one:
#   ssh exe.dev new --name mybox --image={{image}}:latest \
#       --registry-auth <user>:<PAT with read:packages> --tag dev
new name tags='dev':
    ssh exe.dev new --name {{name}} --image={{image}}:latest --tag {{tags}}

# Boot the stock (public, likely pre-warmed) exeuntu image instead of pulling
# the custom keel image, and reproduce keel via --setup-script at first boot
# (dev-only -- no backup capability, see render-setup.sh). `ssh exe.dev new`
# returns as soon as the VM exists and is SSH-reachable, NOT when the setup
# script finishes -- so this blocks afterward, polling for render-setup.sh's
# own completion marker (~/.keel-setup-done, written as its last line).
# Bounded to 5 minutes with visible progress, so a genuinely failed setup
# script fails loud instead of hanging forever indistinguishably from "just
# slow".
new-fast name tags='dev':
    #!/usr/bin/env bash
    set -euo pipefail
    ./render-setup.sh | ssh exe.dev new --name {{name}} \
        --image=ghcr.io/boldsoftware/exeuntu:latest \
        --tag {{tags}} --setup-script /dev/stdin
    printf 'waiting for %s.exe.xyz setup to finish ' "{{name}}"
    for i in $(seq 1 100); do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
                {{name}}.exe.xyz '[ -e "$HOME/.keel-setup-done" ]' 2>/dev/null; then
            echo
            echo "{{name}}.exe.xyz ready"
            exit 0
        fi
        printf '.'
        sleep 3
    done
    echo
    echo "{{name}}.exe.xyz: not ready after 5 minutes -- check what's actually happening:" >&2
    echo "  ssh {{name}}.exe.xyz sudo journalctl -u exe-setup.service --no-pager" >&2
    exit 1

# Add the backup tag to an existing VM and restart so keel-profile re-reads it.
enable-backup vm:
    ssh exe.dev tag {{vm}} backup
    ssh exe.dev restart {{vm}}

# Remove the backup tag and restart.
disable-backup vm:
    ssh exe.dev tag -d {{vm}} backup
    ssh exe.dev restart {{vm}}

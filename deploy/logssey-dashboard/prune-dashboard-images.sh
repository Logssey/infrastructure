#!/bin/bash
# Remove old dashboard images from the host. Runs as root from /opt/logssey/prune-dashboard-images.sh,
# once a day through logssey-image-prune.timer.
#
# deploy.sh pulls a new image by digest on every deploy and never removes the one it replaced, so the root
# volume (OS and Docker images) fills up: a pull then fails with "no space left on device" and the deploy rolls back.
#
# What goes: images of the dashboard repositories (ECR .../logssey/dashboard-*) that no container uses and that
#   were built more than LOGSSEY_IMAGE_KEEP_HOURS (72) ago.
# What stays: the image of every container, running or stopped (docker refuses to remove it); the last three days
#   of images, so that deploy.sh can roll back without pulling; every other image (postgres, neo4j, and
#   cartography, which `compose run --rm` leaves without a container between its daily runs).
# It waits for deploy.sh (.deploy.lock) and never runs under a deploy.
#
#   prune-dashboard-images.sh             remove
#   prune-dashboard-images.sh --dry-run   only print what would go
set -euo pipefail

DIR=${LOGSSEY_DIR:-/opt/logssey}
KEEP_HOURS=${LOGSSEY_IMAGE_KEEP_HOURS:-72}
PATTERN=${LOGSSEY_IMAGE_PATTERN:-/logssey/dashboard-}
LOCK_WAIT=${LOGSSEY_LOCK_WAIT:-1800}

dry_run=false
case ${1:-} in
  '') ;;
  --dry-run) dry_run=true ;;
  *) echo "usage: prune-dashboard-images.sh [--dry-run]" >&2; exit 2 ;;
esac
[[ $KEEP_HOURS =~ ^[0-9]+$ ]] || { echo "LOGSSEY_IMAGE_KEEP_HOURS is not a number: $KEEP_HOURS" >&2; exit 2; }

cd "$DIR"
exec 9> .deploy.lock
flock -w "$LOCK_WAIT" 9 || { echo "a deploy is still running; nothing removed" >&2; exit 1; }

cutoff=$(( $(date +%s) - KEEP_HOURS * 3600 ))
removed=0 kept_recent=0 kept_in_use=0

# one line per repository reference: <repository>@<digest> <image id>
# --all: an image pulled by digest has no tag, and newer Docker versions leave some of those out of the plain list
while read -r ref id; do
  [[ $ref == *"$PATTERN"* && $ref != *"<none>"* ]] || continue
  created=$(date -d "$(docker image inspect --format '{{.Created}}' "$id")" +%s)
  if (( created > cutoff )); then
    kept_recent=$((kept_recent + 1))
    continue
  fi
  if $dry_run; then
    echo "would remove $ref (built $(date -u -d "@$created" +%F))"
    removed=$((removed + 1))
  # without --force docker removes nothing that a container uses
  elif docker image rm "$ref" > /dev/null 2>&1; then
    echo "removed $ref (built $(date -u -d "@$created" +%F))"
    removed=$((removed + 1))
  else
    kept_in_use=$((kept_in_use + 1))
  fi
done < <(docker image ls --all --digests --no-trunc --format '{{.Repository}}@{{.Digest}} {{.ID}}' | sort -u)

if $dry_run; then
  echo "dry run: $removed to remove (a container may still use some), $kept_recent newer than ${KEEP_HOURS}h"
else
  echo "removed $removed, in use $kept_in_use, newer than ${KEEP_HOURS}h $kept_recent"
fi
df -h / | awk 'NR == 2 {print "root volume: " $4 " free, " $5 " used"}'

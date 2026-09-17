#!/bin/bash
# inspect_orphan.sh
#
# Read-only inspection of an orphaned Longhorn replica directory by
# loop-mounting its disk image and listing the filesystem inside.
#
# Why this instead of grepping the .img files: Longhorn replica images are
# SPARSE. A replica holding 430MB of real data typically has an apparent
# size equal to the full volume size (e.g. 15GB), so `grep` reads gigabytes
# of holes and appears to hang. Mounting reads only what it needs.
#
# Safety: the loop device is attached read-only (losetup -r) and the
# filesystem is mounted with `ro,noload`. `noload` is important - without it
# ext4 would replay the journal, which is a WRITE to the image. Nothing in
# this script modifies the replica data.
#
# SNAPSHOT CHAINS: a replica whose volume.meta shows a non-empty Parent is
# an overlay - the head only holds blocks changed since its parent, so
# mounting it alone shows a corrupt or partial filesystem. This script
# refuses to do that.
#
# For those, pass --base. Every chain terminates in a base snapshot whose
# own .img.meta has no parent, and that base IS a complete standalone
# filesystem image. Mounting it shows the volume as of the oldest snapshot -
# an older point in time than the head, but almost always enough to identify
# WHICH APPLICATION the orphan belongs to, which is the goal at this stage.
#
# Identification only. Do not treat a --base mount as the recoverable
# dataset; the real recovery hands the whole chain to Longhorn and lets its
# engine assemble it (see Step 3 in the runbook).
#
# Usage (as root, on the node holding the replica):
#   ./inspect_orphan.sh pvc-48fcfe2e-6766-4574-89ed-e432ace94d9d-a731c574
#   ./inspect_orphan.sh --base pvc-74dab4f9-f4e0-46d8-befb-1d23a8d454f4-86c1d9da
#
# Set KEEP=1 to leave the filesystem mounted afterwards for manual poking
# instead of unmounting on exit:
#   sudo KEEP=1 ./inspect_orphan.sh --base <dir>
#   # ... explore /mnt/longhorn-inspect ...
#   sudo umount /mnt/longhorn-inspect && sudo losetup -d /dev/loopN

set -eu

REPLICAS_DIR="/var/lib/longhorn/replicas"
MNT="/mnt/longhorn-inspect"

USE_BASE=0
USE_HEAD=0
case "${1:-}" in
  --base) USE_BASE=1; shift ;;
  # --head forces mounting the head even though it is an overlay. Worth
  # trying when the base turns out not to be a filesystem: whichever layer
  # last wrote block 0 is the one carrying the superblock, and that is not
  # always the base.
  --head) USE_HEAD=1; shift ;;
esac

if [ "$#" -ne 1 ]; then
  echo "usage: $0 [--base|--head] <replica-dir-name>" >&2
  exit 1
fi

DIR="$REPLICAS_DIR/$1"
[ -d "$DIR" ] || { echo "error: $DIR not found" >&2; exit 1; }

META="$DIR/volume.meta"
[ -f "$META" ] || { echo "error: no volume.meta in $DIR" >&2; exit 1; }

echo "meta: $(cat "$META")"

# Read the "Parent" field out of a Longhorn .img.meta / volume.meta file.
parent_of() {
  sed -n 's/.*"Parent":"\([^"]*\)".*/\1/p' "$1"
}

parent=$(parent_of "$META")

if [ -z "$parent" ] || [ "$USE_HEAD" -eq 1 ]; then
  head_img=$(sed -n 's/.*"Head":"\([^"]*\)".*/\1/p' "$META")
  IMG="$DIR/$head_img"
  if [ -z "$parent" ]; then
    echo "no snapshot chain - head is a complete image"
  else
    echo "--head forced: mounting the overlay head directly."
    echo "If it mounts, the head carries the superblock and the view is"
    echo "usable for identification; if it does not, neither layer is"
    echo "standalone and only Longhorn can assemble the chain."
  fi
else
  if [ "$USE_BASE" -eq 0 ]; then
    echo
    echo "WARNING: this replica has a snapshot chain (Parent=$parent)."
    echo "The head is an overlay; mounting it alone shows a partial filesystem."
    echo "Re-run with --base to mount the chain's base snapshot instead,"
    echo "which is a complete image and enough to identify the application."
    exit 2
  fi

  # Find the base directly rather than walking parent links one at a time.
  # Chains here run to 100+ snapshots, and a link-by-link walk is both slow
  # and needs an arbitrary depth guard. The base is simply the snapshot
  # whose own .meta records no parent, so scan for it.
  total=$(ls -1 "$DIR"/volume-snap-*.img.meta 2>/dev/null | wc -l)
  echo
  echo "snapshot chain length: $total"

  bases=""
  for m in "$DIR"/volume-snap-*.img.meta; do
    [ -f "$m" ] || continue
    if [ -z "$(parent_of "$m")" ]; then
      b=$(basename "$m" .meta)
      bases="$bases $b"
    fi
  done

  set -- $bases
  if [ "$#" -eq 0 ]; then
    echo "error: no parentless snapshot found - chain may be broken" >&2
    exit 1
  fi
  if [ "$#" -gt 1 ]; then
    echo "note: $# parentless snapshots found (removed snapshots can orphan"
    echo "      branches). Trying each until one mounts."
  fi

  # Prefer the largest parentless snapshot: a base that actually holds a
  # filesystem is far bigger than a stray fragment left by snapshot removal.
  BASE_CANDIDATES=$(du -s $(for b in "$@"; do echo "$DIR/$b"; done) 2>/dev/null \
                    | sort -rn | cut -f2)
  IMG=$(echo "$BASE_CANDIDATES" | head -1)
  echo "base snapshot: $(basename "$IMG")"
  echo
  echo "NOTE: mounting BASE snapshot - this is an older point in time than the"
  echo "      head. Use it to identify the app, not as the recovery dataset."
fi

[ -f "$IMG" ] || { echo "error: image $IMG not found" >&2; exit 1; }

echo "image: $IMG"
echo "apparent size: $(du -h --apparent-size "$IMG" | cut -f1)  actual on disk: $(du -h "$IMG" | cut -f1)"
echo

LOOP=""
cleanup() {
  mountpoint -q "$MNT" && umount "$MNT" || true
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

LOOP=$(losetup -r -f --show "$IMG")
echo "attached read-only at $LOOP"

mkdir -p "$MNT"
if ! mount -o ro,noload "$LOOP" "$MNT" 2>/dev/null; then
  echo "mount with noload failed - retrying without it (still read-only)"
  if ! mount -o ro "$LOOP" "$MNT" 2>/dev/null; then
    echo
    echo "MOUNT FAILED - no valid filesystem at the start of this image."
    echo "Superblock check:"
    dumpe2fs -h "$LOOP" 2>&1 | head -15 || true
    echo
    echo "This usually means the image is an overlay fragment rather than a"
    echo "complete filesystem - common when snapshots have been coalesced or"
    echo "removed. The data is not necessarily lost: hand the whole chain to"
    echo "Longhorn (Step 3 in the runbook) and let its engine assemble it,"
    echo "which is the only thing that reads these layers correctly."
    exit 3
  fi
fi

# Everything below is reporting, not logic. `set -e` is disabled for it:
# du/find/grep routinely return non-zero on a recovered filesystem (an
# unreadable subdirectory, no matches) and must not abort the report - that
# silently truncated output for one replica during this incident.
set +e

echo "=================================================================="
echo "TOP LEVEL:"
ls -la "$MNT"
echo
echo "USAGE:"
du -sh "$MNT" 2>/dev/null || echo "  (du incomplete - unreadable subdirs)"
echo
echo "IDENTIFYING MARKERS:"
for marker in \
  PG_VERSION pgdata pg_wal postgresql.conf base global \
  .minio.sys grafana.db loki index chunks \
  core sys logical audit \
  data mysql ibdata1; do
  [ -e "$MNT/$marker" ] && echo "  FOUND: $marker"
done
echo
echo "TWO LEVELS DEEP:"
find "$MNT" -maxdepth 2 -not -path '*/lost+found*' 2>/dev/null | head -40

# --- application-specific identification -------------------------------
# Knowing it's "a Postgres" isn't enough when three clusters are missing;
# CloudNativePG stamps the cluster name into the config as the PostgreSQL
# cluster_name GUC, which is what actually distinguishes them.
PGDATA=""
[ -d "$MNT/pgdata" ] && PGDATA="$MNT/pgdata"
[ -f "$MNT/PG_VERSION" ] && PGDATA="$MNT"

if [ -n "$PGDATA" ]; then
  echo
  echo "--- POSTGRES DETAIL ---"
  echo "version: $(cat "$PGDATA/PG_VERSION" 2>/dev/null || echo '?')"
  echo "cluster_name / identity:"
  grep -rhoE "cluster_name[[:space:]]*=[[:space:]]*'[^']*'" \
    "$PGDATA"/*.conf 2>/dev/null | sort -u | sed 's/^/  /' \
    || echo "  (cluster_name not set in *.conf)"
  echo "CNPG markers in config:"
  grep -rhoE "(cnpg|epr|q-flow|qflow|ubutumwa|bugufi)[a-z0-9_.-]*" \
    "$PGDATA"/*.conf 2>/dev/null | sort -u | head -15 | sed 's/^/  /' \
    || echo "  (none found)"
  echo "database directories (base/<oid>, size indicates real content):"
  du -sh "$PGDATA"/base/* 2>/dev/null | sort -rh | head -10 | sed 's/^/  /'
  echo "WAL segments: $(ls -1 "$PGDATA/pg_wal" 2>/dev/null | grep -c '^[0-9A-F]\{24\}$' || echo 0)"
  echo "last modified: $(stat -c '%y' "$PGDATA/global/pg_control" 2>/dev/null || echo '?')"
fi

if [ -d "$MNT/.minio.sys" ]; then
  echo
  echo "--- MINIO DETAIL ---"
  echo "buckets:"
  find "$MNT" -maxdepth 1 -mindepth 1 -type d \
    -not -name '.minio.sys' -not -name 'lost+found' 2>/dev/null | sed 's/^/  /'
  echo "object count (xl.meta files): $(find "$MNT" -name 'xl.meta' 2>/dev/null | wc -l)"
  echo "payload size excluding .minio.sys:"
  du -sh --exclude=.minio.sys --exclude=lost+found "$MNT" 2>/dev/null | sed 's/^/  /'
fi

if [ -d "$MNT/core" ] && [ -d "$MNT/sys" ]; then
  echo
  echo "--- VAULT DETAIL (file backend) ---"
  echo "core/ entries:  $(ls -1 "$MNT/core" 2>/dev/null | wc -l)"
  # Vault's file backend prefixes storage entries with an underscore, so
  # core/_keyring - NOT core/keyring - is the real path. Checking the
  # unprefixed name reports "no keyring" on a perfectly recoverable Vault,
  # which is how a recoverable Vault gets written off as lost. Accept both.
  for entry in keyring seal-config master shamir-kek; do
    if [ -e "$MNT/core/_$entry" ]; then
      echo "  core/_$entry: PRESENT"
    elif [ -e "$MNT/core/$entry" ]; then
      echo "  core/$entry: PRESENT (unprefixed)"
    else
      echo "  core/$entry: absent"
    fi
  done
  echo "logical/ entries (secret engines): $(ls -1 "$MNT/logical" 2>/dev/null | wc -l)"
  echo "auth/ present: $([ -d "$MNT/auth" ] && echo YES || echo no)"
  echo
  echo "  _keyring + _seal-config present means this Vault can be UNSEALED"
  echo "  with the existing recovery keys - no 'vault operator init' needed."
fi
# Grafana keeps UI-created dashboards in a SQLite database. If dashboards
# are provisioned from ConfigMaps instead, they come back on their own and
# this volume does not matter - check for ConfigMaps labelled
# grafana_dashboard before assuming a restore is needed.
if [ -f "$MNT/grafana.db" ]; then
  echo
  echo "--- GRAFANA DETAIL ---"
  echo "grafana.db size: $(du -h "$MNT/grafana.db" 2>/dev/null | cut -f1)"
  echo "modified:        $(stat -c '%y' "$MNT/grafana.db" 2>/dev/null)"
  echo "dashboard titles found in the database:"
  # No sqlite3 on these hosts; dashboard JSON is stored as text in the file,
  # so titles are greppable directly.
  grep -a -o -E '"title":"[^"]{3,60}"' "$MNT/grafana.db" 2>/dev/null \
    | sed 's/"title":"//; s/"$//' | sort -u | head -30 | sed 's/^/    /'
  n=$(grep -a -o -E '"title":"[^"]{3,60}"' "$MNT/grafana.db" 2>/dev/null | sort -u | wc -l)
  echo "  distinct titles: $n"
  echo "  (0 titles means an empty Grafana - not necessarily the wrong volume)"
  [ -d "$MNT/plugins" ] && echo "  plugins installed: $(ls -1 "$MNT/plugins" 2>/dev/null | wc -l)"
fi

# Loki's boltdb-shipper layout: index_* directories plus chunks.
if [ -d "$MNT/loki" ] || [ -d "$MNT/chunks" ] || [ -d "$MNT/boltdb-shipper-active" ]; then
  echo
  echo "--- LOKI DETAIL ---"
  for d in loki chunks index boltdb-shipper-active boltdb-shipper-cache wal; do
    [ -e "$MNT/$d" ] && echo "  $d/ = $(du -sh "$MNT/$d" 2>/dev/null | cut -f1)"
  done
fi

echo "=================================================================="

if [ "${KEEP:-0}" = "1" ]; then
  trap - EXIT
  echo
  echo "KEEP=1 set - leaving mounted at $MNT on $LOOP for manual inspection."
  echo "Clean up with:  umount $MNT && losetup -d $LOOP"
fi

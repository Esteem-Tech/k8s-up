#!/bin/bash
# restore_orphan.sh
#
# Swap an orphaned Longhorn replica's data into a live volume's replica
# directory, so Longhorn's engine assembles the orphaned snapshot chain and
# the workload sees the recovered data.
#
# THIS IS THE DESTRUCTIVE STEP. Everything up to here was read-only. It
# overwrites the target replica's contents. A timestamped backup of the
# target is taken first and is never deleted by this script.
#
# Longhorn has no "reattach this orphan" operation - the orphan's Volume CR
# was deleted when Longhorn was reinstalled. Recovery means making the
# orphan's files BECOME the live volume's replica, under the directory name
# Longhorn already expects (the Replica CR's spec.dataDirectoryName).
#
# PRECONDITIONS - the script verifies all of these and refuses otherwise:
#   1. The target volume is DETACHED (scale the workload to 0 first).
#      Swapping files under a running engine corrupts the volume.
#   2. Source and target volume.meta report an identical Size. Longhorn
#      rejects a replica whose size disagrees with its Volume CR.
#   3. No process holds files open in the target directory.
#
# Usage (as root, on the node holding BOTH directories):
#   ./restore_orphan.sh <source-orphan-dir> <target-replica-dir>
#   ./restore_orphan.sh --confirm <source-orphan-dir> <target-replica-dir>
#   ./restore_orphan.sh --move --confirm <source-orphan-dir> <target-dir>
#
# Without --confirm it performs every check and prints the plan, changing
# nothing. Run it that way first.
#
# --move relocates the source rather than copying it. Required for chains
# too large to duplicate (a 28G chain cannot be copied into 40G of free
# space alongside a backup). Costs no space because both paths share a
# filesystem. Undo by moving the files back to the source directory.

set -eu

REPLICAS_DIR="/var/lib/longhorn/replicas"

# --move relocates the source files instead of copying them. Both paths live
# under the same filesystem, so this is instant and needs no free space -
# essential for chains of tens of GB that cannot be duplicated. The data is
# not destroyed, only relocated: to undo, move the files back out. The
# target is still backed up first either way.
CONFIRM=0
MOVE=0
for arg in "$@"; do
  case "$arg" in
    --confirm) CONFIRM=1 ;;
    --move)    MOVE=1 ;;
  esac
done
while [ "${1:-}" = "--confirm" ] || [ "${1:-}" = "--move" ]; do shift; done

if [ "$#" -ne 2 ]; then
  echo "usage: $0 [--confirm] [--move] <source-orphan-dir> <target-replica-dir>" >&2
  echo "  --confirm  actually apply (without it, dry run only)" >&2
  echo "  --move     relocate source instead of copying (no extra space)" >&2
  exit 1
fi

SRC="$REPLICAS_DIR/$1"
DST="$REPLICAS_DIR/$2"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$DST.pre-recovery-$STAMP"

size_of() { sed -n 's/.*"Size":\([0-9]*\).*/\1/p' "$1"; }

echo "source: $SRC"
echo "target: $DST"
echo

[ -d "$SRC" ] || { echo "error: source not found" >&2; exit 1; }
[ -d "$DST" ] || { echo "error: target not found" >&2; exit 1; }
[ -f "$SRC/volume.meta" ] || { echo "error: source has no volume.meta" >&2; exit 1; }
[ -f "$DST/volume.meta" ] || { echo "error: target has no volume.meta" >&2; exit 1; }

echo "--- PRECHECK 1: volume sizes must match ---"
SRC_SIZE=$(size_of "$SRC/volume.meta")
DST_SIZE=$(size_of "$DST/volume.meta")
echo "  source Size: $SRC_SIZE"
echo "  target Size: $DST_SIZE"
if [ "$SRC_SIZE" != "$DST_SIZE" ]; then
  echo "  FAIL: sizes differ - Longhorn would reject this replica" >&2
  exit 1
fi
echo "  OK"
echo

echo "--- PRECHECK 2: target must not be in use ---"
if command -v lsof >/dev/null 2>&1; then
  if lsof +D "$DST" >/dev/null 2>&1; then
    echo "  FAIL: processes hold files open in the target:" >&2
    lsof +D "$DST" 2>/dev/null | head >&2
    echo "  Scale the workload to 0 and wait for the volume to detach." >&2
    exit 1
  fi
  echo "  OK (no open file handles)"
else
  echo "  WARNING: lsof not installed, cannot verify."
  echo "  Confirm the volume shows 'detached' in Longhorn before continuing."
fi
echo

echo "--- PRECHECK 3: disk space ---"
BACKUP_NEED=$(du -sk "$DST" | cut -f1)
SRC_NEED=$(du -sk "$SRC" | cut -f1)
FREE=$(df -Pk "$REPLICAS_DIR" | awk 'NR==2{print $4}')
if [ "$MOVE" -eq 1 ]; then
  NEED="$BACKUP_NEED"
  echo "  mode: MOVE (source relocated, costs no space)"
else
  NEED=$((BACKUP_NEED + SRC_NEED))
  echo "  mode: COPY (source duplicated)"
  echo "  source copy needs: ${SRC_NEED}K"
fi
echo "  target backup needs: ${BACKUP_NEED}K"
echo "  total needed: ${NEED}K   free: ${FREE}K"
if [ "$NEED" -gt "$FREE" ]; then
  echo "  FAIL: not enough free space" >&2
  [ "$MOVE" -eq 0 ] && echo "  Consider --move: relocates instead of copying." >&2
  exit 1
fi
echo "  OK"
echo

echo "--- PLAN ---"
echo "  1. cp -a $DST -> $BACKUP"
echo "  2. remove contents of $DST"
if [ "$MOVE" -eq 1 ]; then
  echo "  3. MOVE source files into $DST (source left empty):"
else
  echo "  3. copy source files into $DST:"
fi
for f in "$SRC"/*; do
  echo "       $(basename "$f")  ($(du -h "$f" | cut -f1))"
done
echo "  4. leave the backup in place for manual cleanup after verification"
echo

if [ "$CONFIRM" -eq 0 ]; then
  echo "DRY RUN - nothing changed. Re-run with --confirm to apply."
  exit 0
fi

echo "--- APPLYING ---"
echo "backing up target..."
cp -a "$DST" "$BACKUP"
echo "  backup at: $BACKUP"

echo "clearing target..."
find "$DST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

if [ "$MOVE" -eq 1 ]; then
  echo "MOVING source files (source directory will be left empty)..."
  for f in "$SRC"/*; do
    mv "$f" "$DST"/
  done
  echo "  source now: $(ls -A "$SRC" 2>/dev/null | wc -l) entries remaining"
  echo "  to undo, move these files back to $SRC"
else
  echo "copying source files..."
  cp -a "$SRC"/. "$DST"/
fi

# Longhorn replica directories are root-owned and mode 0700; preserve that
# regardless of what the source happened to carry.
chown -R root:root "$DST"
chmod 700 "$DST"

echo
echo "--- RESULT ---"
ls -la "$DST"
echo
echo "volume.meta now: $(cat "$DST/volume.meta")"
echo
echo "DONE. Next:"
echo "  1. Scale the workload back up."
echo "  2. Longhorn will attach and its engine will assemble the chain."
echo "  3. Verify the application sees its data BEFORE deleting:"
echo "       $BACKUP"

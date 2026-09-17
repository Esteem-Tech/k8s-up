#!/bin/bash
# identify_orphans.sh
#
# Read-only content fingerprinting for orphaned Longhorn replica directories.
#
# Context: if Longhorn is reinstalled (Volume/Replica CRDs recreated from
# scratch) while the underlying replica data directories on disk survive,
# Longhorn no longer knows those old directories belong to any volume. They
# sit under /var/lib/longhorn/replicas/<pvc-uuid>-<replica-id>/ as "orphans" -
# real data, no owning Volume CR.
#
# This script does NOT mount, write, or modify anything. It greps the raw
# .img snapshot chain files for filename/content signatures typical of the
# apps this cluster runs (Postgres, MySQL, MinIO, Grafana/SQLite, Loki,
# Vault, Mongo, Redis) so you can tell which orphaned directory belongs to
# which app before attempting any recovery.
#
# Usage (run as root on the node that hosts /var/lib/longhorn/replicas):
#   ./identify_orphans.sh                 # scan every directory found
#   ./identify_orphans.sh pvc-abc-xyz ...  # scan only the given directories
#
# See docs/runbooks/longhorn-disaster-recovery.md for the full recovery
# procedure once you know which orphan is which.

set -u

REPLICAS_DIR="/var/lib/longhorn/replicas"
cd "$REPLICAS_DIR" || { echo "error: $REPLICAS_DIR not found - is this the right node?" >&2; exit 1; }

if [ "$#" -gt 0 ]; then
  DIRS="$*"
else
  DIRS=$(ls -1)
fi

SIGNATURES='PG_VERSION|pg_wal|postgresql\.conf|pg_control|MySQL|ibdata1|\.minio\.sys|xl\.meta|grafana\.db|SQLite format 3|boltdb-shipper|loki_index|core/keyring|core/seal-config|sys/policy|logical/|vault-file-backend|mongodb|WiredTiger|redis-check|dump\.rdb'

for d in $DIRS; do
  [ -d "$d" ] || continue
  echo "=================================================================="
  echo "DIR: $d  (size: $(du -sh "$d" 2>/dev/null | cut -f1))"
  meta="$d/volume.meta"
  if [ -f "$meta" ]; then
    echo "meta: $(cat "$meta")"
  fi
  echo "------------------------------------------------------------------"
  hits=$(grep -a -o -E "$SIGNATURES" "$d"/*.img 2>/dev/null | sort -u)
  if [ -z "$hits" ]; then
    echo "(no recognizable signature found in a quick pass)"
  else
    echo "$hits"
  fi
  echo
done

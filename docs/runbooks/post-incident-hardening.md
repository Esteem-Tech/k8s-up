# Post-incident hardening plan

Written 2026-08-24, after recovering Vault, three Postgres clusters, MinIO
and Grafana from orphaned Longhorn replicas. See
[longhorn-disaster-recovery.md](longhorn-disaster-recovery.md) for the
incident itself.

## The uncomfortable summary

Everything was recovered. **None of it was recovered from a backup.** It was
recovered because a Longhorn reinstall happened to leave the old replica
directories on disk, and because nothing had garbage-collected them in the
hours before we looked. That is luck, not resilience.

Three independent things had to be true for the data to survive, and none
of them were designed:

1. Longhorn's reinstall recreated CRDs but did not wipe `/var/lib/longhorn/replicas/`.
2. The `orphan-auto-deletion` setting was unset, so Longhorn did not reap them.
3. Nobody ran `vault operator init`, which would have made Vault's data
   permanently unreadable even though the ciphertext was intact.

## P0 - Backups that actually exist

### The current state is worse than "no backups"

| what exists | why it does not protect you |
|---|---|
| `ScheduledBackup` ×2 (`q-flow`, `ubutumwa-bugufi`) | never ran once - empty `lastScheduleTime` |
| on-demand `Backup` ×2 | both in `failed` phase |
| `epr` | no `spec.backup` at all |
| `VolumeSnapshotClass longhorn-snap` | **`type: snap`** - a LOCAL snapshot on the same disk |
| Longhorn `backup-target` | unset |

The last row is the important one. `type: snap` means a CNPG "backup" is a
Longhorn snapshot sitting on the same physical disk as the volume it
protects. This incident would have destroyed those snapshots along with
everything else. A backup that shares a failure domain with its source is
not a backup.

### What to do

**1. Give Longhorn an off-cluster backup target.** S3-compatible object
storage in a different failure domain - Backblaze B2, Wasabi, AWS S3. Do
**not** point it at the in-cluster MinIO: MinIO's own volumes are Longhorn
volumes, so it would be backing up onto the thing it is meant to survive.

```bash
kubectl -n longhorn-system create secret generic longhorn-backup-secret \
  --from-literal=AWS_ACCESS_KEY_ID=<key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<secret> \
  --from-literal=AWS_ENDPOINTS=https://<endpoint>

kubectl -n longhorn-system patch settings.longhorn.io backup-target \
  --type=merge -p '{"value":"s3://<bucket>@<region>/"}'
kubectl -n longhorn-system patch settings.longhorn.io backup-target-credential-secret \
  --type=merge -p '{"value":"longhorn-backup-secret"}'
```

**2. Add a `type: bak` VolumeSnapshotClass** and point CNPG at it. This is
the one-line change that turns the existing (broken) CNPG backup config
into something real:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-backup
driver: driver.longhorn.io
deletionPolicy: Retain      # do not let a deleted CR destroy the backup
parameters:
  type: bak                 # exports to backup-target, NOT a local snapshot
```

Then set `spec.backup.volumeSnapshot.className: longhorn-backup` on all
three clusters - **including `epr`, which currently has no backup stanza.**

**3. Add recurring Longhorn backup jobs** for volumes CNPG does not cover
(Vault, MinIO, Grafana):

```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: daily-backup
  namespace: longhorn-system
spec:
  cron: "0 2 * * *"
  task: backup
  groups: ["default"]
  retain: 14
  concurrency: 1
```

**4. Verify a restore, not just a backup.** A backup nobody has restored is
a hypothesis. Once backups run, restore one into a scratch namespace and
confirm the data. Put a reminder in the calendar to repeat quarterly.

## P1 - Restore redundancy

**All six recovered volumes are at `numberOfReplicas: 1`.** That was
necessary during recovery (see the runbook - surplus empty replicas
outvote a restored one) but it means a single disk failure now loses
everything we just recovered.

Blocking issue: the control-plane disk is `schedulable=False`, so a second
replica has nowhere to go. It needs **3.03 GB** more free space:

```
CurrentAvailable = 39216742400  <  MinimalAvailable = 42242912256 (25% of max)
```

Two ways to close that gap:

```bash
# a) reclaim: delete control-plane orphans already recovered elsewhere
#    pvc-48fcfe2e-…-a731c574   (MinIO drive 1 - restored onto the worker)
#    pvc-692b6f7b-…-7527d465   (epr 2nd replica - already recovered)
#    pvc-a0c88fc3-…-639d04c9   (MongoDB - SEE P3 BEFORE DELETING)

# b) or lower the floor, since /var/lib/longhorn shares the root filesystem
kubectl -n longhorn-system patch settings.longhorn.io \
  storage-minimal-available-percentage --type=merge -p '{"value":"20"}'
```

Then, once the control-plane accepts replicas:

```bash
for v in <the six volume names>; do
  kubectl patch volumes.longhorn.io $v -n longhorn-system \
    --type=merge -p '{"spec":{"numberOfReplicas":2}}'
done
```

Confirm replicas actually land on **different nodes** afterwards - three
replicas on one node, which is what this cluster had before, is not
redundancy.

## P2 - Detection

**There is no Alertmanager.** 35 `PrometheusRule` objects exist with
nowhere to send anything. Every failure in this incident was silent:
backups that never ran, a `k3s-agent` crash-looping at every boot, disks
that had been unschedulable for hours.

Deploy Alertmanager (the kube-prometheus-stack chart already supports it -
set `alertmanager.enabled=true`) with a route to Slack or email, then add
rules for the things that were silently broken:

| alert | condition | why |
|---|---|---|
| `LonghornBackupTooOld` | no successful backup in 36h | the failure that made this incident severe |
| `LonghornVolumeDegraded` | `robustness != healthy` for 15m | replica loss before it becomes data loss |
| `LonghornDiskUnschedulable` | disk `Schedulable=False` for 30m | the state that silently prevents replication |
| `LonghornVolumeReplicaCountLow` | `numberOfReplicas < 2` | catches exactly the state we are in now |
| `VaultSealed` | `vault_core_unsealed == 0` for 10m | Vault sealed = every dependent app is broken |
| `NodeSystemdUnitFailed` | any failed unit | would have caught `k3s-agent` at 11:42 |

The last one matters most for recurrence: the boot-time `k3s-agent` failure
was visible in systemd for hours and nothing surfaced it.

## P3 - Reduce blast radius

**1. Grafana dashboards belong in Git.** The `grafana-sc-dashboard` sidecar
is already running and there are **zero** ConfigMaps labelled
`grafana_dashboard`. Dashboards live only in `grafana.db`, which is why
recovering them needed raw disk forensics. Export each dashboard's JSON
into a ConfigMap under `k8s/monitoring/dashboards/` and they become
immune to storage loss entirely.

**2. Give Longhorn a dedicated disk.** `/var/lib/longhorn` is on `/dev/vda2`
- the root filesystem - on both nodes. That is why both nodes report an
identical 157 GiB `storageMaximum` despite being sized 40 GB and 80 GB, why
Longhorn's 30% reserve fights the OS, and why the control-plane disk keeps
crossing the schedulability floor. Attach dedicated block storage and
migrate Longhorn onto it.

**3. Investigate the MongoDB orphan.** `pvc-a0c88fc3` contains a
`data/db` MongoDB directory (449M, 2-way replicated) and **no MongoDB
workload exists anywhere in the cluster**. Either it was decommissioned
deliberately, or an application did not come back from the redeploy and
nobody has noticed. Resolve this before deleting the orphan.

**4. `heza-website-service-chart` in `prod` is in `ImagePullBackOff`** and
has been throughout. Unrelated to storage - a registry/credentials issue -
but it is a production workload that is down.

**5. Snapshot retention.** `snapshot-max-count` is at its default of 250,
and the recovered chains had hit 249 - which is why two 10Gi volumes
occupied 28G each. The recurring jobs that created them no longer exist
(they were part of the old deployment), so when you recreate backup jobs,
set an explicit `retain:` and keep `snapshot-max-count` well under the cap.

## Cleanup (only after the applications are exercised)

Table sizes and object counts prove blocks came back. They do not prove
EPR can render a letter or Ubutumwa can send to a contact list. Use the
applications first, then reclaim roughly 57 GB:

```bash
# on the worker
ls -d /var/lib/longhorn/replicas/*pre-recovery*     # review, then remove
ls -d /var/lib/longhorn/replicas/pvc-6fe3d5ad*      # emptied orphan dirs
```

Keep the `.pre-recovery-*` directories until you are confident. They are
the only undo path for the swaps.

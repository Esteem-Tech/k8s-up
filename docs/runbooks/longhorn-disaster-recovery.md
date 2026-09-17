# Runbook: Longhorn volume loss / recovering orphaned replica data

## When to use this

Every currently-attached Longhorn volume on the cluster shows a recent
`creationTimestamp` (hours old, not weeks), workloads that should have
persistent data (Vault, databases, MinIO) come up empty/uninitialized, and
`/var/lib/longhorn/replicas/` on one or more nodes contains replica
directories that are *older* than the currently-registered volumes and don't
match any `volumes.longhorn.io` object.

That combination means Longhorn's CRDs (Volume/Replica/Engine objects) were
recreated from scratch — most likely because Longhorn itself was
reinstalled — while the actual data on disk survived. The old data isn't
gone, it's just orphaned: Longhorn no longer has any record that those
directories belong to a volume.

## Incident: 2026-08-24

**What actually happened** (confirmed by direct inspection, not assumed):

### Root cause (established by forensics, 2026-08-29)

**A latent misconfiguration on the control-plane, exposed by a routine
reboot. The provider did nothing wrong and nothing was ever deleted.**

What Strettch actually did: powered off the VMs, powered off the
hypervisor, added physical RAM, powered the hypervisor back on, brought the
VMs back up. A clean power cycle that touches no disks.

Evidence that **no re-image or disk rollback occurred**:

| artifact | mtime | meaning |
|---|---|---|
| `/etc/machine-id` | 2025-11-02 | a re-image regenerates this |
| `/etc/ssh/ssh_host_rsa_key` | 2025-11-02 | ditto |
| `/etc/hostname` | 2025-11-02 | ditto |
| `/var/lib/rancher/k3s/server/token` | present, with `agent-token`/`node-token` symlinks intact | **the token was never missing from disk** |
| July Longhorn replicas on control-plane | still present | a wiped node would not have them |

Boot history confirms the timeline:

```
reboot  6.8.0-138  Sat Aug 22 22:54   still running     <- maintenance
reboot  6.8.0-136  Fri Jul 31 00:55 - Aug 22 21:55      <- previous uptime
```

The outage began **Aug 22 22:54**, not Aug 24 — the cluster was down for
roughly 37 hours before recovery started. Workload data corroborates it:
Vault's `core/` and every Postgres `pg_control` timestamp fall in
Aug 22 21:28–21:55, immediately before shutdown.

**The actual failure**, from the journal at the first post-maintenance
boot:

```
Aug 22 22:55:09  Error: failed to create listener:
                 failed to listen on 127.0.0.1:6444: bind: address already in use
Aug 22 22:55:09  k3s.service: Failed with result 'exit-code'
Aug 22 22:55:09  Failed to start k3s.service - Lightweight Kubernetes
```

Both `k3s.service` and `k3s-agent.service` were enabled on this node
(unit files dated 2025-11-02, so the misconfiguration had existed for nine
months). At boot they start concurrently. The agent binds
`127.0.0.1:6444` for its apiserver proxy; the server needs that same port
for its own apiserver. Whichever wins the race, the other fails.

**Why it only broke now:** the race had resolved in the server's favour on
every previous boot — Nov 26, Dec 13, Dec 16, Mar 10, Jul 31. Adding
physical RAM changed boot timing enough to flip the outcome. The defect was
always present; the hardware change merely made it manifest. This is why
"it worked before the maintenance" is true and yet the maintenance is not
the cause.

**On "no token on disk":** the token file was there the whole time. What
was missing was `/etc/rancher/k3s/config.yaml`, which had never existed on
this node — it was installed with env-var flags, not a config file. Its
absence was normal, not damage.

**On `failed to normalize server token`:** this error most plausibly
appeared *during* recovery, not before it. Generating a fresh token while
the datastore still held bootstrap data encrypted under the old one
produces exactly that failure. (Journal queries to pin the first occurrence
timed out; treat this specific point as well-supported inference rather
than established fact.)

### What actually destroyed the data

Nothing in the maintenance did. The chain was:

1. k3s server could not start (port conflict) — recoverable, no data at risk.
2. Recovery attempts escalated: a new token was generated, then
   `k3s server --cluster-reset` was run.
3. The datastore lost its Kubernetes objects, so every PVC, PV and Longhorn
   Volume CR disappeared.
4. GitOps redeployed the workloads, which created **brand-new empty
   volumes** (all timestamped 12:28–12:39 on Aug 24).
5. The real data survived only as orphaned replica directories that
   Longhorn no longer had any record of.

The data was never deleted by the provider, by the reboot, or by k3s. It
was orphaned by a recovery procedure aimed at the wrong diagnosis.
- Longhorn was reinstalled (v1.10.1 engine, despite an earlier session
  believing it was v1.7.2), which recreated all Volume/Replica CRDs from
  scratch. Every PVC-backed workload got a brand-new, empty replica:

  | namespace | PVC | size | new volume created at |
  |---|---|---|---|
  | vault | `data-vault-0` | 10Gi | 2026-08-24T12:38:25Z |
  | database | `epr-1` | 10Gi | 2026-08-24T12:39:14Z |
  | database | `q-flow-1` | 10Gi | 2026-08-24T12:39:12Z |
  | database | `ubutumwa-bugufi-1` | 10Gi | 2026-08-24T12:39:10Z |
  | minio | `export-minio-0` | 15Gi | 2026-08-24T12:28:47Z |
  | minio | `export-minio-1` | 15Gi | 2026-08-24T12:28:47Z |
  | monitoring | `grafana` | 5Gi | 2026-08-24T12:35:55Z |
  | monitoring | `storage-loki-stack-0` | 5Gi | 2026-08-24T12:37:52Z |

- A "228MB Vault volume, data intact" read from an earlier debugging
  session was a **false positive**: that figure was ext4 filesystem
  overhead on the newly-formatted disk (`du -sh /vault/data` inside the pod
  showed 20K, just `lost+found`; Vault reports `Initialized: false`, not
  "sealed with data").
- `/var/lib/longhorn/replicas/` holds **11 orphaned replica directories
  dated Jul 31** — pre-incident — that don't correspond to any current
  volume. These are the actual recovery target:

  | node | orphaned replica dir | volume size | on-disk |
  |---|---|---|---|
  | worker | `pvc-1227e3f5-…-1c39fd1e` | 5Gi | 6.6G |
  | worker | `pvc-66d207ff-…-0bf3443b` | 5Gi | 541M |
  | worker | `pvc-692b6f7b-…-78a496ee` | 10Gi | 1.4G |
  | worker | `pvc-6fe3d5ad-…-a88ac732` | 15Gi | 430M |
  | worker | `pvc-74dab4f9-…-86c1d9da` | 10Gi | **29.8G** |
  | worker | `pvc-a0c88fc3-…-669a6785` | 5Gi | 2.0G |
  | worker | `pvc-b4b14e3e-…-d169553b` | 10Gi | **27.7G** |
  | worker | `pvc-d2510248-…-e30f12fa` | 10Gi | 409M |
  | control-plane | `pvc-48fcfe2e-…-a731c574` | 15Gi | 430M |
  | control-plane | `pvc-692b6f7b-…-7527d465` | 10Gi | — |
  | control-plane | `pvc-a0c88fc3-…-639d04c9` | 5Gi | — |

  `pvc-692b6f7b` and `pvc-a0c88fc3` appear on **both** nodes (different
  replica suffixes) — those volumes were genuinely 2-way replicated.
  `pvc-48fcfe2e` (control-plane) and `pvc-6fe3d5ad` (worker) are both 15Gi
  and are most likely the two pre-incident MinIO volumes.

  The control-plane still holding July replica data is further evidence
  against the "provider re-imaged this node" theory — a wiped node would
  not have it.

  Roughly **69 GB of orphaned data sits on the worker**, which is the
  direct cause of its overcommitment (see below).

## Confirmed data state: everything is empty, no backups exist

Verified directly, not inferred:

- **All three CloudNativePG databases are empty.** Every database on every
  cluster reports exactly `7830 kB` — the size of a freshly-`initdb`'d
  Postgres database. `epr` (`postgres`, `app`, `epr-demo`, `epr-dev`),
  `ubutumwa-bugufi` (`postgres`, `app`), and `q-flow` were all bootstrapped
  from scratch via `spec.bootstrap.initdb` when the clusters were
  recreated, not restored from anything.
- **Vault is uninitialized** (`Initialized: false`), `/vault/data` contains
  only `lost+found`.
- **No CNPG backup has ever succeeded.** The two `ScheduledBackup` objects
  (`q-flow-daily-backup`, `ubutumwa-bugufi-daily-backup`) have an empty
  `lastScheduleTime`. Both on-demand backups are in `failed` phase
  (`while ensuring target pod is healthy: no status found for target pod`).
  `kubectl get volumesnapshots -A` returns nothing.
- **`epr` has no `spec.backup` configured at all** — no backup was ever
  even attempted for it.

Consequences:

1. There is **no backup restore path**. The orphaned Longhorn replicas are
   the only possible source of pre-incident data.
2. Conversely, because the live volumes contain *nothing of value*, there
   is **no reconciliation problem** — swapping recovered data in cannot
   overwrite newer good data. This makes the recovery in Step 3 materially
   safer than it would normally be.

### Identification results (2026-08-24)

Confirmed by read-only loop-mount of each replica's base snapshot:

| orphan | node | identity | evidence | content |
|---|---|---|---|---|
| `pvc-74dab4f9-…-86c1d9da` | worker | **`q-flow`** Postgres 18 | `cluster_name='q-flow'`, `q-flow-1-initdb`, `q-flow-rw` | 617M, 249-snapshot chain, base 2025-12-15 |
| `pvc-692b6f7b-…-78a496ee` | worker | **`epr`** Postgres 18 | `cluster_name='epr'`, `epr-1-initdb`, `epr-rw` | 609M, base 2026-07-30 |
| `pvc-b4b14e3e-…-d169553b` | worker | **`ubutumwa-bugufi`** Postgres 18 | `cluster_name='ubutumwa-bugufi'`, `ubutumwa-bugufi-rw` | 610M, 249-snapshot chain, base 2025-12-13 |
| `pvc-d2510248-…-e30f12fa` | worker | **Vault** (file backend) | `core/_keyring`, `core/_seal-config`, `core/_master`, `core/_shamir-kek`, `sys/policy`, 3 secret engines under `logical/` | head mounts, `core/` modified **2026-08-22** |
| `pvc-48fcfe2e-…-a731c574` | control-plane | **MinIO** drive | `.minio.sys`, bucket `epr-documents` | 16M (`letters/`, `applications/`) |
| `pvc-6fe3d5ad-…-a88ac732` | worker | **MinIO** drive (pair of above) | `.minio.sys`, same bucket | 16M |
| `pvc-1227e3f5`, `pvc-66d207ff`, `pvc-a0c88fc3` | worker | not yet inspected | 5Gi each | presumed Grafana / Loki / one retired volume |

**Vault is recoverable.** `core/_keyring` and `core/_seal-config` both exist,
so the existing unseal/recovery keys still work — `vault operator unseal`,
never `vault operator init`. Note the underscore: Vault's file backend
prefixes storage entries, so `core/_keyring` is the real path. Checking for
`core/keyring` reports a false "no keyring" on a perfectly recoverable
Vault; the first version of `inspect_orphan.sh` made exactly that mistake.

Vault's `core/` directory is dated **2026-08-22**, two days before the
incident — so this replica holds essentially current secrets, not a stale
copy. (The replica *directory* mtime reads Jul 31 because directory mtime
tracks entry creation, not content writes.)

Notes:

- **The base snapshot is not the recoverable dataset.** `q-flow`'s base is
  from December 2025; its head is current. Recovery must hand the whole
  chain to Longhorn, which is the only thing that reads the layers
  correctly. The base mount answers *which app*, nothing more.
- **`pvc-d2510248`'s base is not a filesystem** (`Bad magic number in
  super-block`) despite a chain length of 1. Try `--head` — whichever layer
  last wrote block 0 holds the superblock, and it is not always the base.
  A fragment here does not imply data loss.
- **The 249-snapshot chains are themselves a defect.** They are why two
  10Gi volumes occupy 29.8G and 27.7G — roughly 57G of the worker's 69G of
  orphaned data is snapshot history from a recurring snapshot job with no
  retention limit. Fix the retention policy alongside the backups.

**Fix the backup gap as part of recovery** — a working ScheduledBackup is
what turns the next incident into a restore instead of a forensic
investigation.

## Storage misconfiguration (the real "disks are unavailable" cause)

Separately from the data loss, Longhorn on this cluster cannot schedule new
replicas **on either node**, for two different reasons:

| node | why unschedulable | margin |
|---|---|---|
| control-plane (cpu2) | free 36.9 GiB < required 39.3 GiB (25% of max) | short by ~2.4 GiB |
| worker (cpu1) | 190 GiB scheduled vs 110 GiB usable limit | 72% overcommitted |

Contributing settings:

```
default-replica-count                       = 3      # on a TWO node cluster
storage-over-provisioning-percentage        = 100
storage-minimal-available-percentage        = 25
storage-reserved-percentage-for-default-disk= 30
replica-soft-anti-affinity                  = true
```

The failure chain:

1. `default-replica-count = 3` on a 2-node cluster — three replicas can
   never be placed with correct anti-affinity across two nodes.
2. The control-plane disk sits just under the 25% free-space floor, so
   Longhorn marks it unschedulable.
3. Every replica therefore piles onto the worker, pushing it to 72%
   overcommitted.
4. Neither disk can accept a new replica →
   `precheck new replica failed: disks are unavailable`.

**`/var/lib/longhorn` is on the root filesystem** (`/dev/vda2`, 158G, 80%
used) on both nodes — not a dedicated data disk. This is why both nodes
report an identical `storageMaximum` of 157 GiB despite their hostnames
advertising 40 GB and 80 GB, and why Longhorn's 30% reserve is competing
with the OS for the same partition. Consider attaching dedicated block
storage for Longhorn rather than sharing root.

Dropping every volume from 3 replicas to 2 reduces the cluster-wide
requirement from 220 GiB to 150 GiB (~75 GiB/node), which fits under the
110 GiB per-node limit:

```bash
kubectl patch settings.longhorn.io default-replica-count -n longhorn-system \
  --type=merge -p '{"value":"{\"v1\":\"2\",\"v2\":\"2\"}"}'
```

Do this **after** orphan recovery — lowering a replica count deletes
replicas, and nothing should be deleted while on-disk data is still being
identified. Clearing the orphans afterwards frees ~69 GB on the worker and
~4 GB on the control-plane, which resolves the scheduling failure on its
own.

## Step 0 — stop making it worse

- **Never run `k3s server` by hand while `k3s.service` is enabled.** During
  this incident that was done to check for duplicate processes; the two
  servers contended for the same ports and the same etcd datastore, the API
  server went down for several minutes, and the CloudNativePG operator lost
  its leader lease and entered `CrashLoopBackOff`. etcd survived
  (`initial corruption checking passed; no corruption`) but concurrent
  writers on one datastore is exactly how a recoverable incident becomes an
  unrecoverable one. To check for duplicates, read instead of run:
  ```bash
  ps aux | grep -c '[k]3s server'    # expect exactly 1
  sudo journalctl -u k3s --no-pager | grep -iE "address already in use|already running"
  ```
- Fix the control-plane dual-role misconfiguration so this doesn't recur:
  ```bash
  sudo systemctl disable --now k3s-agent
  sudo systemctl status k3s-agent --no-pager   # confirm disabled + inactive
  ```
- For any workload whose fresh/empty volume may already be accepting
  writes (a database re-initializing its schema, MinIO re-creating
  buckets), scale it to 0 until the matching orphan is identified and
  swapped in — otherwise every extra write to the *new* volume is one more
  thing to reconcile against the recovered *old* data:
  ```bash
  kubectl scale statefulset <name> -n <namespace> --replicas=0
  ```

## Step 1 — inventory

```bash
kubectl get pvc -A -o custom-columns='NAMESPACE:.metadata.namespace,PVC:.metadata.name,VOLUME:.spec.volumeName,SIZE:.spec.resources.requests.storage,AGE:.metadata.creationTimestamp'

kubectl get volumes.longhorn.io -n longhorn-system \
  -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp,ACTUALSIZE:.status.actualSize,ROBUSTNESS:.status.robustness,PVC:.status.kubernetesStatus.pvcName,NS:.status.kubernetesStatus.namespace'
```

On each node that hosts Longhorn disks, list replica directories and flag
ones that don't match a volume above:

```bash
ls -la /var/lib/longhorn/replicas/
du -sh /var/lib/longhorn/replicas/*/
```

## Step 2 — identify each orphan (read-only)

Run this on **every** node that holds Longhorn disks — orphans exist on
both the worker and the control-plane, with different replica suffixes for
the same volume.

### Preferred: loop-mount and look

[`scripts/longhorn-recovery/inspect_orphan.sh`](../../scripts/longhorn-recovery/inspect_orphan.sh)
attaches the replica's disk image to a read-only loop device
(`losetup -r`) and mounts it `ro,noload`, then lists what's inside.
`noload` matters — without it ext4 replays the journal, which writes to the
image.

```bash
scp scripts/longhorn-recovery/inspect_orphan.sh root@<node>:~/
ssh root@<node> 'chmod +x inspect_orphan.sh && ./inspect_orphan.sh <replica-dir>'
```

A replica whose `volume.meta` shows `Parent:""` mounts directly — its head
is a complete image. Replicas with a snapshot chain are refused by default,
because the head is only an overlay of changed blocks.

For those, pass `--base`. Every chain ends in a base snapshot with no
parent of its own, and that base is a complete standalone filesystem:

```bash
./inspect_orphan.sh --base pvc-74dab4f9-f4e0-46d8-befb-1d23a8d454f4-86c1d9da
```

The base shows the volume at an older point in time than the head — enough
to identify **which application** the orphan belongs to, which is all Step 2
needs. Do not treat it as the recoverable dataset; the actual recovery in
Step 3 hands the entire chain to Longhorn and lets its engine assemble the
layers natively.

In this incident only two orphans had `Parent:""` — `pvc-48fcfe2e`
(control-plane) and `pvc-6fe3d5ad` (worker), the two MinIO drives. All four
10Gi candidates (three databases + Vault) have chains and need `--base`.

**Beware `du` on a mounted image.** `pvc-48fcfe2e` occupies 430M on disk but
its filesystem holds only 16M of real content — the rest is ext4 metadata
and journal. Mistaking allocation size for payload size is what produced the
false "Vault's data is safe, 229MB intact" conclusion early in this
incident. Always measure the mounted content, never the image file.

### Fallback: raw signature grep

[`identify_orphans.sh`](../../scripts/longhorn-recovery/identify_orphans.sh)
greps the raw `.img` files for app signatures without mounting. **It is
very slow**: replica images are sparse, so a directory holding 430MB of
real data can have a 15GB apparent size, and `grep` reads every byte
including the holes. Use it only for replicas that can't be mounted, and
scan one directory at a time.

Cross-reference each orphan's `volume.meta` `Size` against the PVC sizes
from Step 1 to narrow candidates before trusting any content match.

## Step 3 — recover one volume at a time

> **Verified working 2026-08-24 on Vault.** The procedure below is not
> theoretical; it restored `data-vault-0` from orphan
> `pvc-d2510248-…-e30f12fa` in a single pass. Use
> [`restore_orphan.sh`](../../scripts/longhorn-recovery/restore_orphan.sh),
> which performs the swap with prechecks and an automatic backup.
>
> Worked example, start to finish:
>
> ```bash
> # 1. detach: scale the workload to 0 and WAIT for state=detached
> kubectl scale statefulset vault -n vault --replicas=0
> kubectl get volumes.longhorn.io <vol> -n longhorn-system \
>   -o jsonpath='{.status.state}'          # must read: detached
>
> # 2. find the target directory - it is the Replica CR's
> #    spec.dataDirectoryName, NOT the volume name
> kubectl get replicas.longhorn.io -n longhorn-system \
>   -l longhornvolume=<vol> -o jsonpath='{.items[*].spec.dataDirectoryName}'
>
> # 3. dry run on the node holding both directories, then apply
> sudo ./restore_orphan.sh <orphan-dir> <target-dir>
> sudo ./restore_orphan.sh --confirm <orphan-dir> <target-dir>
>
> # 4. scale back up; Longhorn attaches and assembles the chain
> kubectl scale statefulset vault -n vault --replicas=1
> ```
>
> Observed result: volume `actualSize` rose from 239337472 (empty) to
> 428466176, `/vault/data` gained `auth/ core/ logical/ sys/`, and
> `vault status` flipped from `Initialized: false` to
> `Initialized: true, Sealed: true, Total Shares: 5, Threshold: 3`.
> Three `vault operator unseal` calls with the **existing** keys completed
> the recovery. `vault operator init` was never run.
>
> **The assembled volume is larger than any single layer.** Mounting the
> head alone showed 496K; after Longhorn merged base + head, `/vault/data`
> held 3.2M. Never judge recoverable content from one layer of a chain -
> in either direction.

### CloudNativePG databases: two extra steps

Verified on `epr`, 2026-08-24. Databases differ from Vault in two ways
that will destroy the recovery if missed.

**1. Multiple replicas can outvote the recovered one.** Vault ran
`numberOfReplicas=1`. The databases run 3. Swapping a single replica
directory leaves two empty replicas that Longhorn treats as authoritative,
and it rebuilds the swapped one from them - silently discarding the
recovered data. Setting `numberOfReplicas: 1` does **not** prune
immediately; Longhorn defers deletion and, in this incident, still had all
three replicas after detaching. So **swap every replica directory with the
same orphan chain**. Identical replicas are exactly what a healthy volume
looks like, and whichever one Longhorn keeps is then the right one.

**2. Stop the cluster with hibernation, not by scaling.** CNPG owns its
pods; a StatefulSet scale is the wrong lever.

```bash
kubectl annotate cluster.postgresql.cnpg.io <cluster> -n database \
  cnpg.io/hibernation=on                    # stops instance, releases PVC
# ... swap ALL replica dirs on the node holding them ...
kubectl annotate cluster.postgresql.cnpg.io <cluster> -n database \
  cnpg.io/hibernation=off --overwrite
```

Postgres will run crash recovery on wake - the pgdata was never cleanly
shut down. That is expected: look for `database system was not properly
shut down; automatic recovery in progress`, then `redo done`, then
`database system is ready to accept connections`.

### MinIO: map drives before restoring

Verified on `export-minio-0` / `export-minio-1`, 2026-08-24.

MinIO erasure-codes objects across drives and records each drive's identity
and set position in `.minio.sys/format.json`. Restoring an orphan onto the
wrong PVC gives a drive claiming a position that does not match, and MinIO
refuses to start or heals against a mismatched set.

Read `format.json` from each orphan first (both had `Parent:""`, so they
mount directly):

```json
{"xl":{"this":"<this drive uuid>","sets":[["<uuid drive0>","<uuid drive1>"]]}}
```

The index of `this` within `sets[0]` **is** the pod ordinal. In this
incident:

| orphan | node | `this` | index | target |
|---|---|---|---|---|
| `pvc-6fe3d5ad-…-a88ac732` | worker | `8ed34fba…` | 0 | `export-minio-0` |
| `pvc-48fcfe2e-…-a731c574` | control-plane | `3b2d861e…` | 1 | `export-minio-1` |

Also confirm the orphans share one deployment `id`, and that `version` /
`xl.version` match the live deployment - a mismatch means a format
migration, which is a different problem.

**Restore both drives or neither.** One old drive beside one fresh drive is
an inconsistent set. Verify afterwards that `format.json` reports the OLD
deployment id, not the new one.

MinIO is a plain StatefulSet, so `kubectl scale` stops it - no hibernation
annotation.

**Cross-node copies: do not use plain `scp`.** It has no sparse-file
support and expanded a 430M replica image into 15G of real zeros on the
destination. Use `rsync -S`, or `tar -S`, or repair afterwards with
`fallocate -d <file>` to punch the zero regions back into holes.

### Verifying a recovery - tools that lie

Three separate checks during this incident reported "no data" on
recoveries that were completely fine. Every time, the tool was wrong - not
the data. Distrust a negative result before you distrust the recovery:

- **`information_schema.tables WHERE table_schema='public'`** returns 0
  when the application uses its own schema (here, `epr`). Query without
  the schema filter, or group by `table_schema`.
- **`pg_stat_user_tables.n_live_tup` reads 0 after crash recovery.** Those
  are collector statistics and Postgres resets them on an unclean restart.
  They are not row counts. Use a real `COUNT(*)`.
- **`find` does not exist in the MinIO container image.** `find ... | wc -l`
  with stderr redirected away reports `0` objects on a drive holding 41 of
  them. Verify the tool exists before believing its answer, and never
  discard stderr on a verification command.

A fourth, from the session that preceded this one: `du` on a replica image
reporting 229MB was read as "Vault's data is intact" when the figure was
ext4 overhead on an empty filesystem. Allocation size is not payload size,
in either direction.

Trustworthy checks instead:

```bash
# real row counts across every table in a schema
psql -U postgres -d <db> -tAc "
SELECT format('%s = %s', c.relname,
  (xpath('/row/c/text()', query_to_xml(
    format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname),
    false, true, '')))[1]::text::int)
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='<schema>' AND c.relkind='r';"
```

Strongest evidence the data is genuinely pre-incident:

- `pg_controldata`'s `pg_control last modified` timestamp (here
  `2026-08-22 21:28:04`, two days before the outage)
- an application migration table with real history (here
  `_prisma_migrations`, 18 rows, latest applied `2026-08-22 21:23`)

**Filesystem size is not payload size.** The `epr` orphan measured 609M on
its mounted base, but ~560M of that was 35 × 16MB WAL segments; actual
table data is ~10MB. Misreading allocation as payload is what produced the
original false "Vault's 229MB of data is intact" conclusion.

Longhorn has no "reattach this orphan" button — the Volume CR for the old
data doesn't exist anymore. Recovery means making an orphaned directory
*become* the replica for the current (empty) volume, on disk:

1. **Back up the current (fresh) replica directory first**, in case the app
   already wrote something worth keeping since the incident, or the
   identified orphan turns out to be wrong:
   ```bash
   cp -a /var/lib/longhorn/replicas/<current-replica-dir> \
         /var/lib/longhorn/replicas/<current-replica-dir>.pre-recovery-backup
   ```
2. Scale the workload to 0 (if not already) and detach the volume in
   Longhorn (UI: Volume → Detach, or delete the workload's pod and let
   Longhorn release the attachment).
3. Stop the replica's instance-manager process for that volume so nothing
   has the files open.
4. Swap the data: replace the current replica directory's `.img` files and
   `volume.meta` with the orphan's, keeping the directory *name* Longhorn
   already expects (rename the orphan's files into place, or replace file
   contents — don't rename the whole directory, Longhorn keys off the
   existing replica directory name).
5. Restart the instance-manager / trigger Longhorn to rescan the disk so it
   picks up the real (old) size instead of the cached-empty one.
6. Reattach the volume, scale the workload back to its normal replica
   count, and verify from inside the app (e.g. for Vault: `Initialized:
   true`, then `vault operator unseal` with the real recovery keys; for a
   database: connect and check expected tables/rows exist).
7. Only after the app confirms the data is correct, remove the
   `.pre-recovery-backup` directory from step 1.

**Do this for the highest-value volumes first** (application databases,
then Vault), and treat Grafana/Loki as lowest priority — dashboards are
normally reprovisioned via GitOps/config and Loki log retention is not a
source of truth.

## Outcome (2026-08-24)

Five of five attempted recoveries succeeded. Nothing was lost.

| target | recovered from | verified content |
|---|---|---|
| Vault | `pvc-d2510248-…-e30f12fa` | unsealed with original keys; `core/_keyring` intact |
| `epr` | `pvc-692b6f7b-…-78a496ee` | 27 applications, 34 users, 387 audit logs, 18 migrations |
| `q-flow` | `pvc-74dab4f9-…-86c1d9da` | inventory/sales schema — `reservation`, `sale`, `transaction` |
| `ubutumwa-bugufi` | `pvc-b4b14e3e-…-d169553b` | **131 MB** — `contact_list_memberships` 73 MB, `contacts` 58 MB |
| MinIO ×2 | `pvc-48fcfe2e`, `pvc-6fe3d5ad` | 41 objects — 20 `letters/`, 21 `applications/`, 16M |

Every recovered Postgres reported a `pg_control last modified` of
2026-08-22, hours before the outage — current data, not a stale snapshot.

### Still outstanding

1. **Backups have never worked.** This is the finding that mattered most:
   `ScheduledBackup` objects with empty `lastScheduleTime`, both on-demand
   backups `failed`, `epr` with no `spec.backup` at all, and zero
   `VolumeSnapshot` objects. A working backup turns the next incident into
   a restore instead of a forensic dig through raw replica images.
2. **Snapshot retention is unbounded** — 249-snapshot chains inflated 10Gi
   volumes to ~28G each. Set a retention limit on the recurring job.
3. **Both Longhorn disks still report `schedulable=False`**, and
   `/var/lib/longhorn` shares the root filesystem on both nodes. Give
   Longhorn dedicated block storage rather than competing with the OS.
4. **Replica counts are now 1** for the six recovered volumes (they were
   3). Raise to 2 once disk pressure is resolved — 1 replica means no
   redundancy.
5. **Cleanup pending**: `.pre-recovery-*` backup directories and the
   now-empty orphan directories. Only remove these after the applications
   have been exercised in anger, not merely observed to start.

## Related

- [scripts/longhorn-recovery/identify_orphans.sh](../../scripts/longhorn-recovery/identify_orphans.sh)
- [scripts/longhorn-recovery/inspect_orphan.sh](../../scripts/longhorn-recovery/inspect_orphan.sh)
- [scripts/longhorn-recovery/restore_orphan.sh](../../scripts/longhorn-recovery/restore_orphan.sh)

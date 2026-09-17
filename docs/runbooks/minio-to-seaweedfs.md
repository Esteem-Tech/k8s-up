# MinIO → SeaweedFS migration

Written 2026-09-17. Status: **code merged, migration not yet executed.**
Tick the boxes as you go.

## Why

MinIO's community edition is over. Official binaries/images stopped in
October 2025, the repo went to "maintenance mode" in December 2025 and was
archived in April 2026. The code is still AGPLv3 but nothing is being
patched; the only supported product is AIStor (Free/Enterprise).

What we run today is `RELEASE.2024-12-18T13-15-44Z` via chart `minio-5.4.0`,
a frozen December 2024 build with its API **and** console on the public
internet (`minio.test…`, `minio-console.test…`). At least two 2025 MinIO
advisories (signature-validation bypass; IAM/service-account privilege
escalation) post-date it. That is the actual reason to move; the licence
is just why there is no upgrade path.

SeaweedFS: Apache-2.0, actively maintained, official Helm chart, speaks the
same S3 API. Garage would be a lighter fit but has no official chart or UI;
RustFS is the drop-in-format option but still alpha.

## What is being migrated

Inventory taken 2026-09-17 on the live cluster:

| | |
|---|---|
| Buckets | one: `epr-documents` (`applications/`, `letters/`) |
| Objects | 49, **35 MB** total |
| IAM | 3 users, 2 service accounts (one of these is what the EPR app uses) |
| In-cluster consumers | **none** - the EPR app talks to the public ingress |
| Storage | 2 × 15Gi Longhorn PVCs (`export-minio-0/1`), erasure-coded pair |

## Target

One Deployment, one PVC. The chart's `allInOne` mode runs
`weed server -master -volume -filer -s3` in a single pod on a single 15Gi
Longhorn PVC, plus a small `weed admin` StatefulSet for the web UI.

Durability is Longhorn's two replicas plus the off-cluster backup below -
the same model MinIO effectively had, minus MinIO's own erasure coding,
which on a two-node cluster where both drives were already Longhorn
volumes was doubling the write cost for no extra failure domain.

| | MinIO | SeaweedFS |
|---|---|---|
| S3 endpoint | `https://minio.test.k8s.iradukunda.me` | `https://s3.test.k8s.iradukunda.me` |
| Web UI | `https://minio-console.test.k8s.iradukunda.me` | `https://s3-admin.test.k8s.iradukunda.me` |
| Namespace | `minio` | `seaweedfs` |
| Chart | `minio/minio` (unpinned) | `seaweedfs/seaweedfs` **4.47.0** (pinned) |
| Values | `k8s/minio/minio-values.yml` | `k8s/seaweedfs/values.yml` |
| Identities | created by hand in the console | `k8s/secrets/seaweedfs-s3-config.yml`, rendered from GitHub secrets |
| Metrics | ServiceMonitor in `monitoring` ns | ServiceMonitor in `seaweedfs` ns (Prometheus scrapes all namespaces) |

Two S3 identities, least privilege:

- `admin` - full control. For operators: this migration, bucket admin.
- `epr` - `Read/Write/List/Tagging` on `epr-documents` **only**. The EPR
  app gets this one. MinIO was most likely handing the app root or a
  broad user; this is the chance to fix that.

Both hostnames already resolve: `*.test.k8s.iradukunda.me` is a wildcard.
No DNS work.

## 0. Prerequisites - GitHub secrets

Per environment (`production`, `test`, `development`) that will run the
workflow. Generate the keys; do not reuse the MinIO ones.

```bash
# access keys: 20 chars, secret keys: 40 chars, same shape as AWS
openssl rand -hex 10   # -> SEAWEEDFS_ADMIN_ACCESS_KEY
openssl rand -hex 20   # -> SEAWEEDFS_ADMIN_SECRET_KEY
openssl rand -hex 10   # -> SEAWEEDFS_EPR_ACCESS_KEY
openssl rand -hex 20   # -> SEAWEEDFS_EPR_SECRET_KEY
openssl rand -base64 24  # -> SEAWEEDFS_ADMIN_UI_PASSWORD
```

- [ ] `SEAWEEDFS_ADMIN_ACCESS_KEY`
- [ ] `SEAWEEDFS_ADMIN_SECRET_KEY`
- [ ] `SEAWEEDFS_EPR_ACCESS_KEY`
- [ ] `SEAWEEDFS_EPR_SECRET_KEY`
- [ ] `SEAWEEDFS_ADMIN_UI_PASSWORD` (login `admin`)

Rotating any of these later: change the GitHub secret and re-run the
workflow. The S3 gateway reads its identities file at start-up only, so
the workflow restarts the pod when the secret changes (~10 s of downtime,
it is a `Recreate` Deployment).

## 1. Deploy SeaweedFS alongside MinIO

- [ ] Run the deploy workflow. MinIO is untouched; SeaweedFS comes up next
      to it.
- [ ] Confirm:

```bash
kubectl -n seaweedfs get deploy,sts,pvc,ingress
kubectl -n seaweedfs logs deploy/seaweedfs-all-in-one | grep -iE 'error|fatal' || echo "clean"
curl -sI https://s3.test.k8s.iradukunda.me/ | head -1     # 403 from S3 = auth is on, endpoint is up
kubectl -n seaweedfs get job                                # bucket hook should be gone (hook-succeeded)
```

- [ ] Log in to `https://s3-admin.test.k8s.iradukunda.me` and check the
      `epr-documents` bucket exists (created by the chart's post-install
      hook, empty).

## 2. Copy the data

35 MB - this takes seconds. Run from your laptop with `rclone` against
both public endpoints; that also proves the new endpoint works from outside
the cluster exactly as the EPR app will see it.

```ini
# ~/.config/rclone/rclone.conf  (delete when done - it holds admin keys)
[minio]
type = s3
provider = Minio
endpoint = https://minio.test.k8s.iradukunda.me
access_key_id = <MINIO_ACCESS_KEY>
secret_access_key = <MINIO_SECRET_KEY>

[sw]
type = s3
provider = SeaweedFS
endpoint = https://s3.test.k8s.iradukunda.me
access_key_id = <SEAWEEDFS_ADMIN_ACCESS_KEY>
secret_access_key = <SEAWEEDFS_ADMIN_SECRET_KEY>
```

- [ ] Dry run, then copy, then verify:

```bash
rclone sync minio:epr-documents sw:epr-documents --dry-run
rclone sync minio:epr-documents sw:epr-documents -P
rclone check minio:epr-documents sw:epr-documents
# If check reports hash mismatches on larger files (multipart ETags differ
# between implementations) but sizes agree, that is expected:
rclone check minio:epr-documents sw:epr-documents --size-only
rclone size sw:epr-documents            # expect 49 objects / ~35 MB
```

- [ ] Prove the scoped `epr` identity works and is actually scoped. Add a
      third remote `[epr]` with the EPR keys and:

```bash
rclone ls epr:epr-documents | head            # works
rclone mkdir epr:should-fail                  # must be denied
echo hi | rclone rcat epr:epr-documents/_probe.txt && rclone delete epr:epr-documents/_probe.txt   # write+delete ok
```

## 3. Cut the EPR app over

The app needs four settings changed, nothing else:

| setting | value |
|---|---|
| endpoint | `https://s3.test.k8s.iradukunda.me` |
| access / secret key | `SEAWEEDFS_EPR_*` |
| region | anything (`us-east-1`); SeaweedFS ignores it but SDKs insist |
| addressing | **path-style** (`endpoint/bucket/key`). Virtual-host style (`bucket.endpoint`) is not configured; same as MinIO was. |

- [ ] Deploy the app config change.
- [ ] Watch for writes landing on the new side and *not* on the old:

```bash
rclone size sw:epr-documents      # grows
rclone size minio:epr-documents   # frozen at 49 / 35 MB
```

- [ ] If anything is wrong: flip the app config back. MinIO is still up
      and untouched. Any objects the app wrote to SeaweedFS in between:
      `rclone sync sw:epr-documents minio:epr-documents`.

## 4. Freeze MinIO, then remove it

- [ ] Once the app has been on SeaweedFS for a few days with no
      complaints, stop MinIO but keep its volumes:

```bash
kubectl -n minio scale sts minio --replicas=0
```

  This is the point of no easy return for anyone still pointed at the old
  hostname - if something breaks now, it was still using MinIO.

- [ ] A week later, remove it for good. In this order:

  1. In all three workflows (`deploy.yml`, `deploy-dev.yml`,
     `deploy-test.yml`) delete the four MinIO steps, the `MINIO_*` env
     lines and the `envsubst … minio-values.yml` line. In `deploy-dev.yml`
     the "Ensure monitoring namespace exists" and "Deploy Prometheus
     Operator CRDs" steps stay - SeaweedFS' ServiceMonitor needs the CRDs.
  2. `git rm -r k8s/minio/`
  3. `helm -n minio uninstall minio && kubectl delete ns minio` - this
     deletes the PVCs and, with them, the Longhorn volumes.
  4. Delete the `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` GitHub secrets.
  5. Delete the `[minio]` remote from your rclone config.

  `scripts/longhorn-recovery/*` keep their `.minio.sys` signatures on
  purpose - they identify orphaned replicas from *any* past workload.

## Longhorn off-cluster backup (done in the same change)

The SeaweedFS PVC is a Longhorn volume like everything else, so it is only
as safe as Longhorn's backups - which, per
[post-incident-hardening.md](post-incident-hardening.md), still do not
exist: `backuptargets.longhorn.io/default` has an empty URL.

The "Deploy Longhorn Storage Class" workflow step now sets the target
declaratively when these GitHub secrets are present, and installs the
nightly `RecurringJob` in `k8s/longhorn/recurring-backup.yml`:

| secret | example |
|---|---|
| `LONGHORN_BACKUP_TARGET` | `s3://<bucket>@<region>/` (the `@region` is Longhorn syntax, not a typo) |
| `LONGHORN_BACKUP_ACCESS_KEY` | |
| `LONGHORN_BACKUP_SECRET_KEY` | |
| `LONGHORN_BACKUP_ENDPOINT` | `https://s3.<region>.backblazeb2.com` - omit for real AWS |

The bucket must be **off-cluster** - Backblaze B2, Wasabi, AWS. Not
SeaweedFS: that would be backing Longhorn up onto a Longhorn volume.

- [ ] Create the bucket + a key scoped to it, add the four secrets, re-run
      the workflow.
- [ ] Verify:

```bash
kubectl -n longhorn-system get backuptargets.longhorn.io   # AVAILABLE=true
kubectl -n longhorn-system get recurringjobs.longhorn.io    # daily-backup
# after 02:00 the next day:
kubectl -n longhorn-system get backups.longhorn.io
```

- [ ] Restore one backup into a scratch namespace and read a file from it.
      A backup nobody has restored is a hypothesis.

Note: the `kubectl patch settings.longhorn.io backup-target` commands in
the hardening runbook are from Longhorn ≤ 1.8 and no longer work on 1.10;
the BackupTarget is a CR now and the chart values above populate it.

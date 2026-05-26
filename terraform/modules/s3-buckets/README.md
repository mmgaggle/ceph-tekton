# `s3-buckets` module

Creates the artifact, tooling, and analytics buckets ceph-tekton needs
(see [`PLAN.md`](../../../PLAN.md) §"Artifact storage" and
[`docs/architecture.md`](../../../docs/architecture.md#artifact-storage)):

| Bucket                   | Lifecycle class                                                | Object-lock              | Public read |
| ------------------------ | -------------------------------------------------------------- | ------------------------ | ----------- |
| `ceph-artifacts-dev`     | 30d object expiry                                              | none                     | yes (mirror) |
| `ceph-artifacts-branch`  | keep latest N per (branch, distro, arch) + 180d hard ceiling   | none, versioning enabled | yes (mirror) |
| `ceph-artifacts-release` | indefinite (object-lock retention)                             | GOVERNANCE, 7y default   | yes (mirror) |
| `ceph-grype-db`          | 30d expiry (≈ keep last 30 dailies)                            | none, no versioning      | yes (consumers) |
| `ceph-tekton-events`     | configurable (default 0 = never expire); issue #63             | none, no versioning      | **no — private** |

## Why the AWS provider against every backend

We use the `hashicorp/aws` provider for every target backend —
AWS S3 (parity proxy), zgw-posix (local dev), real Ceph RGW
(dev-rgw + Sepia) — with `endpoints.s3` overridden per environment.

The alternative is a backend-specific Terraform provider per
flavour. We chose the single AWS provider because:

1. The bucket / lifecycle / object-lock resources we exercise are
   1:1 with the S3 API verbs RGW already speaks
   (`PutBucketLifecycleConfiguration`, `PutObjectLockConfiguration`,
   `PutBucketVersioning`). RGW and zgw-posix are S3-API-compatible
   by design — that is the contract Ceph ships.
2. Using one provider means one resource graph, one set of `import`
   commands, and one mental model for operators. The differences
   between backends become *variables*
   (`enable_versioning`, `enable_lifecycle`,
   `enable_public_access_block`, `enable_bucket_ownership_controls`)
   rather than divergent code paths.
3. The local-dev `apply` exercises exactly the same Terraform graph
   that runs against Sepia RGW. That's the whole reason we have a
   dev env — to catch provider-level surprises before they hit
   Sepia. The capability gap between backends shows up as which
   `enable_*` flags are true; the resource graph itself is
   identical.

## "Keep latest N per (branch, distro, arch)" — design note

The S3 lifecycle API has no native "keep latest N" primitive. It can
expire by age (`Expiration.Days`), by *count of noncurrent versions*
under versioning (`NoncurrentVersionExpiration.NewerNoncurrentVersions`),
and by tag/prefix filter — but it cannot say "keep the N most recent
objects whose key prefix matches X".

The keep-N rule we need is per-tuple, where the tuple is encoded in
the object key:

```
ceph-artifacts-branch/<branch>/<sha>/<distro>/<arch>/<artifact>
```

Two options were considered:

1. **Bucket-versioning + `NewerNoncurrentVersions = N`.**
   Requires `<sha>` to NOT be part of the key (so successive builds
   on the same branch overwrite the same key). We need the sha *in*
   the URL convention (third parties reference
   `https://artifacts.ceph.com/<bucket>/<branch>/<sha>/...`), so this
   doesn't fit.

2. **Pruner in `publish-repo`.**
   The publish-repo Tekton Task already has S3 credentials and is the
   single writer per `(branch, distro, arch)`. After each successful
   publish, it lists `<branch>/.../sha-index`, sorts by build time
   (a Tekton-Result-stamped metadata key, not LastModified — to
   survive re-upload), and deletes everything past index `N`.
   The bucket's lifecycle config provides the safety net:
   `branch_expiration_days = 180` puts a hard age ceiling on
   everything regardless of whether the pruner ran, and
   `branch_noncurrent_version_expiration_days = 7` reaps versions
   that the pruner soft-deletes (it issues a `DeleteObject`, which
   under versioning creates a delete marker rather than freeing space
   immediately).

We chose option 2 because it preserves the URL convention and keeps
all the keep-N policy logic in one place that humans can read.

The module's responsibility is: enable versioning so that the
pruner's `DeleteObject` is reversible for the noncurrent-expiration
window, and enforce a hard ceiling so that a broken pruner doesn't
fill the bucket forever.

## "Object-lock GOVERNANCE 7y" — design note

`object_lock_enabled = true` on the bucket creation call is *not*
the same as PutObjectLockConfiguration. The former is a one-shot
opt-in at bucket-create time that lets you ever turn object-lock on
(it cannot be added later). The latter sets the default retention
applied to every PUT.

The module sets both:

- `aws_s3_bucket.release.object_lock_enabled = true` — opts in.
- `aws_s3_bucket_object_lock_configuration.release` — declares
  GOVERNANCE mode, 7y default retention.

GOVERNANCE (vs COMPLIANCE) lets a holder of
`s3:BypassGovernanceRetention` (e.g. an audited break-glass role)
delete an object before its retention expires — useful for the
"someone tagged the wrong commit by accident" case. COMPLIANCE
allows no override, period. Switch to COMPLIANCE only when you're
sure no human will ever need to take it back.

## "Why no public-access block / ownership controls by default"

Both `PutPublicAccessBlock` and `PutBucketOwnershipControls` are
AWS-specific extensions. zgw-posix and older RGW return
`NotImplemented`; Squid+ RGW + AWS S3 implement them. The
`enable_public_access_block` and `enable_bucket_ownership_controls`
variables let the Sepia env opt in once RGW support is confirmed,
without breaking the local-dev env.

## Public-mirror semantics

Ceph artifact buckets need anonymous public read so that `apt-get`,
`dnf`, `podman pull`, and `curl` work against the canonical URLs (this
is what `download.ceph.com` / `chacra.ceph.com` do today). Per-bucket
`*_public_read` variables flip this on:

```hcl
module "artifacts" {
  source = "../../modules/s3-buckets"

  dev_public_read     = true
  branch_public_read  = true
  release_public_read = true

  # Default `["*"]` exposes the entire bucket. Narrow this when the
  # publish-repo task introduces an internal `staging/` prefix.
  # public_read_prefixes = ["repodata/*", "packages/*", "dists/*"]
}
```

The implementation grants `s3:GetObject` + `s3:GetObjectVersion` to
`Principal: "*"` via an `aws_s3_bucket_policy` — *not* via object
ACLs. Object ACLs stay blocked everywhere the operator has enabled
`enable_public_access_block` (which is also flipped permissive on
`block_public_policy` / `restrict_public_buckets` for public buckets,
so the bucket policy can take effect).

`ListBucket` is **not** granted publicly — only object reads. Anyone
who knows the key can fetch it (which is the chacra model); browsing
the bucket contents requires authentication.

Object-lock on the release bucket is orthogonal: it controls whether
objects can be deleted or overwritten, not whether they can be read.
A release object is simultaneously world-readable AND undeletable
until its retention expires.

## Inputs

See [`variables.tf`](variables.tf) for the full list. Most callers
only need to set:

```hcl
module "artifacts" {
  source = "../../modules/s3-buckets"

  # Bucket naming is per-env: Sepia uses the plain names; per-developer
  # envs may want a namespace prefix to coexist with other tests.
  dev_bucket_name      = "ceph-artifacts-dev"
  branch_bucket_name   = "ceph-artifacts-branch"
  release_bucket_name  = "ceph-artifacts-release"
  grype_db_bucket_name = "ceph-grype-db"

  # AWS-only hardening — leave off for zgw-posix and older RGW; on for
  # AWS S3 and Squid+ RGW.
  enable_public_access_block       = false
  enable_bucket_ownership_controls = false
}
```

## Outputs

- `dev_bucket`, `branch_bucket`, `release_bucket` — individual names.
- `buckets` — map keyed by class (`dev` / `branch` / `release`).
- `release_object_lock` — effective `{mode, years}` on the release
  bucket, so the calling env can echo it in its outputs.
- `public_read` — `{buckets, prefixes}` where `buckets` is the
  per-class bool of the `*_public_read` inputs and `prefixes` is the
  effective `public_read_prefixes` list.

# `dev-rgw` environment

Applies the `s3-buckets` module against a **real Ceph RGW test user's
account**. Sits between the `dev` env (MinIO, no RGW-specific behavior)
and the `sepia` env (production stub, intentionally not applied).

Use this when you have a test user on a real Ceph cluster and want to
verify the bits MinIO can't: object-lock retention across the real
chain, public bucket policies served by the gateway, public-access-block /
bucket-ownership-controls (Squid+ only).

> **Lifecycle currently disabled.** This env sets `enable_lifecycle =
> false` until an upstream RGW bug is fixed. The bug: RGW's
> `GetBucketLifecycleConfiguration` handler downgrades a V2
> `<Filter></Filter>` PUT to legacy V1 `<Prefix></Prefix>` on GET, which
> prevents the AWS terraform provider 5.x from converging its post-PUT
> consistency wait. Reproducer in
> [`notes/rgw-lifecycle-empty-filter-v1-downgrade.md`](../../../notes/rgw-lifecycle-empty-filter-v1-downgrade.md);
> re-enable tracked by [issue #57](https://github.com/mmgaggle/ceph-tekton/issues/57).

## Why not MinIO

MinIO covers ~80% of the S3 API but quietly diverges on the bits we
care about most:

- Lifecycle: MinIO accepts the config but its scanner is gentler than
  RGW's — timing-sensitive rules won't fire on the same cadence.
- Object-lock: MinIO honors per-object retention but the default-rule
  semantics differ from RGW's.
- Bucket-ownership-controls and public-access-block: MinIO returns
  `NotImplemented`.

For phase 1 we accept MinIO for the basic verification (`hack/verify-s3-module.sh`)
and use this env for higher-fidelity checks against the real codebase.

## Why not zgw-posix

We evaluated `quay.io/dparkes/zgw-posix:latest` (Ceph RGW with the POSIX
backend driver, a strict S3-API parity claim). The basic path works
(bucket create, object PUT/GET) but lifecycle and versioning calls
**crash the gateway** rather than return NotImplemented. The driver is
explicitly experimental, and our terraform module depends on lifecycle +
versioning + object-lock — all of which it doesn't support. The decision
trail is in `terraform/README.md`.

When zgw-posix's S3 API surface grows to cover lifecycle, we'll
reconsider — it would be the ideal local target (real RGW code paths,
no external cluster needed).

## Prerequisites

1. A Ceph cluster reachable from your machine with RGW exposed.
2. An RGW account + user (per the Ceph admin guide:
   `radosgw-admin account create` + `radosgw-admin user create
   --account-id=...`). Capture the access key + secret key.
3. Permission for that user to: create buckets, configure lifecycle,
   configure versioning, configure object-lock, set bucket policy.
   Most "user with full S3 ops" caps include this; check with the
   admin if `terraform apply` returns AccessDenied on a sub-API.

## Apply runbook

```sh
cd terraform/environments/dev-rgw

export TF_VAR_rgw_endpoint="https://s3.your-test-cluster.example.com"
export TF_VAR_rgw_access_key="..."
export TF_VAR_rgw_secret_key="..."
# Optional: namespace your buckets (default `devtest-`)
export TF_VAR_bucket_prefix="kyle-"

terraform init
terraform plan
terraform apply
```

`terraform output` returns the resulting bucket names + the RGW
endpoint, suitable for piping into the verify script (a future
iteration of `hack/verify-s3-module.sh` will accept this env as a
target).

## Tear down

```sh
terraform destroy
```

Release-bucket objects under active object-lock retention will block
destroy. Either wait for retention to expire (`release_object_lock_years`,
default 1y) or override with governance bypass:

```sh
aws --endpoint-url "$TF_VAR_rgw_endpoint" \
    s3api list-object-versions --bucket "${TF_VAR_bucket_prefix}ceph-artifacts-release" \
  | jq -r '.Versions[] | "\(.Key) \(.VersionId)"' \
  | while read k v; do
      aws --endpoint-url "$TF_VAR_rgw_endpoint" \
          s3api delete-object \
          --bucket "${TF_VAR_bucket_prefix}ceph-artifacts-release" \
          --key "$k" --version-id "$v" --bypass-governance-retention
    done
terraform destroy
```

## State

Local state by default. To share state across teammates, see the
commented backend stanza in `versions.tf` — point at the same
`ceph-tekton-tfstate` bucket the sepia env documents, with a
`bucket_prefix`-scoped key.

# `dev-rgw` environment

Applies the `s3-buckets` module against a **real Ceph RGW test user's
account**. Sits between the `dev` env (`quay.io/dparkes/zgw-posix:latest`
— RGW with the experimental POSIX backend driver; versioning + lifecycle
still crash the gateway there) and the `sepia` env (production stub,
intentionally not applied).

Use this when you have a test user on a real Ceph cluster and want to
verify the bits the local-dev backend can't: object-lock retention
across the real chain, lifecycle scanner timing, versioned PUT/DELETE
semantics, public-access-block + bucket-ownership-controls (Squid+
only). For lifecycle specifically, see the note below — there's a
current RGW bug that gates that on a follow-up.

> **Lifecycle currently disabled.** This env sets `enable_lifecycle =
> false` until an upstream RGW bug is fixed. The bug: RGW's
> `GetBucketLifecycleConfiguration` handler downgrades a V2
> `<Filter></Filter>` PUT to legacy V1 `<Prefix></Prefix>` on GET, which
> prevents the AWS terraform provider 5.x from converging its post-PUT
> consistency wait. Reproducer in
> [`notes/rgw-lifecycle-empty-filter-v1-downgrade.md`](../../../notes/rgw-lifecycle-empty-filter-v1-downgrade.md);
> re-enable tracked by [issue #57](https://github.com/mmgaggle/ceph-tekton/issues/57).

## Relationship to the `dev` env

The `dev` env uses `quay.io/dparkes/zgw-posix:latest` — Ceph RGW with
the experimental POSIX backend driver. It runs the same RGW codebase
this env points at, so the S3-API surface tested locally is the same
code that runs on Sepia. What it CAN'T do today:

- `PutBucketVersioning` crashes the gateway (driver is explicitly
  experimental) — the dev env therefore sets `enable_versioning = false`
  in the module, which also disables object-lock on the release bucket
  (object-lock requires versioning).
- `PutBucketLifecycleConfiguration` likewise crashes the gateway —
  `enable_lifecycle = false`.
- The AWS-only sub-APIs (`PutBucketOwnershipControls`,
  `PutPublicAccessBlock`) aren't implemented and are flagged off.

What `dev` CAN exercise: bucket create, object PUT/GET/DELETE, and the
public-read bucket-policy path. That's enough to validate the
download-mirror semantics — exactly what `dnf install ceph` traverses
against production — against the same RGW code that ships to Sepia.

When zgw-posix's S3 API surface grows to cover versioning + lifecycle
without crashing, the `dev` env's `enable_*` flags can flip back on
and this env becomes a redundant step. Until then, `dev-rgw` is the
higher-fidelity validation layer.

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

Auth is via a standard AWS credentials file — the same one `aws` CLI
reads (`~/.aws/credentials` by default). Add a profile section for
your test RGW:

```sh
# One-time: add a profile for this RGW (or edit ~/.aws/credentials manually).
mkdir -p ~/.aws
cat >> ~/.aws/credentials <<'EOF'
[my-test-rgw]
aws_access_key_id = <admin-issued key>
aws_secret_access_key = <admin-issued secret>
EOF
```

Then apply:

```sh
cd terraform/environments/dev-rgw

export TF_VAR_rgw_endpoint="https://s3.your-test-cluster.example.com"
export TF_VAR_credentials_profile="my-test-rgw"
# Optional: override credentials_path if the file isn't at ~/.aws/credentials
# export TF_VAR_credentials_path="/path/to/my/aws-credentials"
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
# The aws CLI reads the SAME credentials file terraform does — pass
# the same profile via --profile so terraform and the cleanup speak
# to RGW with the same identity.
aws --endpoint-url "$TF_VAR_rgw_endpoint" --profile "$TF_VAR_credentials_profile" \
    s3api list-object-versions --bucket "${TF_VAR_bucket_prefix}ceph-artifacts-release" \
  | jq -r '.Versions[] | "\(.Key) \(.VersionId)"' \
  | while read k v; do
      aws --endpoint-url "$TF_VAR_rgw_endpoint" --profile "$TF_VAR_credentials_profile" \
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

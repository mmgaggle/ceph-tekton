# `terraform/` — out-of-cluster state

Out-of-cluster infrastructure for ceph-tekton, per
[`PLAN.md`](../PLAN.md) §"Bootstrap" → "terraform (out-of-cluster)".

Phase-1 scope is just the artifact buckets (issue #6). Future
workstreams add RGW OIDC trust + per-role policies (#?), the GitHub
App (#?), and Vault transit-engine config (#?).

## Layout

```
terraform/
├── modules/
│   └── s3-buckets/        # 4 buckets: dev, branch, release, grype-db
└── environments/
    ├── dev/               # MinIO target, local backend (full local cycle)
    ├── dev-rgw/           # Real RGW test-user target, local backend (high-fidelity local cycle)
    └── sepia/             # Sepia RGW target, S3 backend (STUB — not applied)
```

## The artifact-buckets module

See [`modules/s3-buckets/README.md`](modules/s3-buckets/README.md)
for the design notes:

- Why the AWS provider is pointed at MinIO and RGW (single resource
  graph; backend differences become variables).
- Why "keep latest N per (branch, distro, arch)" is enforced by the
  publish-repo task with a lifecycle safety net, not by lifecycle
  alone (S3 has no keep-N primitive).
- Why the release bucket needs `object_lock_enabled` at creation AND
  `aws_s3_bucket_object_lock_configuration` (two different things).

## State backends

| Env     | Backend | Why                                                                                   |
| ------- | ------- | ------------------------------------------------------------------------------------- |
| dev     | `local` | Ephemeral MinIO; developer can `terraform destroy` + `rm -rf` to start over.          |
| dev-rgw | `local` | Per-developer test scope; `bucket_prefix` variable namespaces resources so multiple devs share the same RGW without collisions. Backend stanza in `versions.tf` shows how to promote to shared state. |
| sepia   | `s3`    | RGW-hosted `ceph-tekton-tfstate` bucket. Backend block in `versions.tf` is commented out until the bucket is bootstrapped — see `environments/sepia/README.md`. |

The Sepia state bucket is created out-of-band (chicken-and-egg) with
versioning enabled and no object-lock.

## Running the dev env

The dev env spins up against a local MinIO. The one-shot way:

```sh
./hack/verify-s3-module.sh
```

That script (from the repo root) starts MinIO in docker/podman,
runs `terraform init && apply` against `terraform/environments/dev/`,
asserts the lifecycle and object-lock policies, exercises the
object-lock retention with a write-then-delete test, and tears
everything down. Single-command verification, no leftover state.

To iterate manually (useful when developing the module):

```sh
# Start MinIO yourself (port 9000, defaults minioadmin/minioadmin):
docker run -d --name ceph-tekton-minio \
  -p 9000:9000 -p 9001:9001 \
  quay.io/minio/minio:latest \
  server /data --console-address ":9001"

# Apply:
cd terraform/environments/dev
terraform init
terraform apply -auto-approve

# Inspect:
aws --endpoint-url http://127.0.0.1:9000 \
    --region us-east-1 \
    s3api list-buckets
aws --endpoint-url http://127.0.0.1:9000 \
    --region us-east-1 \
    s3api get-bucket-lifecycle-configuration \
    --bucket ceph-artifacts-dev

# Tear down:
terraform destroy -auto-approve
docker rm -f ceph-tekton-minio
```

MinIO admin credentials default to `minioadmin` / `minioadmin`. The
`aws` CLI calls above expect them in `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` (or `~/.aws/credentials`).

## Running the dev-rgw env

For higher-fidelity validation against a real Ceph cluster's RGW —
catches lifecycle scanner behavior, real object-lock retention
enforcement, and Squid+-only features (public-access-block,
bucket-ownership-controls) that MinIO and zgw-posix can't exercise.

See [`environments/dev-rgw/README.md`](environments/dev-rgw/README.md)
for the apply runbook. Short version: provision a test user on a
real RGW, export `TF_VAR_rgw_endpoint` / `rgw_access_key` /
`rgw_secret_key` / `bucket_prefix`, then `terraform apply`.

### Why not zgw-posix as a local target

We evaluated `quay.io/dparkes/zgw-posix:latest` — Ceph's RGW with the
experimental POSIX backend driver, intended as a lightweight
RGW-on-a-laptop. Basic bucket + object ops work, but
`PutBucketLifecycleConfiguration` and `PutBucketVersioning` **crash
the gateway** rather than return a clean error. Our module depends
on both, so zgw-posix can't substitute for MinIO (or a real cluster)
in `hack/verify-s3-module.sh` today. Revisit when the POSIX driver
covers the broader S3 sub-API surface — at that point it'd be the
ideal local target (real RGW code paths, no external cluster needed).

## Running the Sepia env

Don't, until the four prerequisites in
[`environments/sepia/README.md`](environments/sepia/README.md) are
met. The stub exists so module changes diff against a real call
site that mirrors Sepia values, not so it can be applied today.

## Caveats

- **MinIO + bucket-default object-lock retention.** Recent MinIO
  releases support PutObjectLockConfiguration; older ones return
  NotImplemented. The verification script emits a `CAVEAT` line if
  it can't fully exercise the release bucket's GOVERNANCE block,
  and falls back to per-object retention assertions in that case.
- **No DynamoDB locking on RGW.** Sepia's backend won't have S3
  state locking; the operating model is "one operator changes
  terraform at a time, coordinated in #ceph-infra". Workable for a
  small team; revisit if it ever becomes a problem.
- **`force_destroy` on the release bucket is a footgun.** Even with
  `force_destroy = true`, S3 will refuse to delete objects still
  under object-lock retention — but the bucket-delete call will
  fail confusingly. Don't set it true in any env where the release
  bucket has real data.

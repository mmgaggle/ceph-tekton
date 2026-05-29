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
    ├── dev/               # zgw-posix target, local backend (full local cycle)
    ├── dev-rgw/           # Real RGW test-user target, local backend (high-fidelity local cycle)
    └── sepia/             # Sepia RGW target, S3 backend (STUB — not applied)
```

## The artifact-buckets module

See [`modules/s3-buckets/README.md`](modules/s3-buckets/README.md)
for the design notes:

- Why the AWS provider is pointed at every backend (single resource
  graph; backend differences become variables).
- Why "keep latest N per (branch, distro, arch)" is enforced by the
  publish-repo task with a lifecycle safety net, not by lifecycle
  alone (S3 has no keep-N primitive).
- Why the release bucket needs `object_lock_enabled` at creation AND
  `aws_s3_bucket_object_lock_configuration` (two different things).

## State backends

| Env     | Backend | Why                                                                                   |
| ------- | ------- | ------------------------------------------------------------------------------------- |
| dev     | `local` | Ephemeral zgw-posix; developer can `terraform destroy` + `rm -rf` to start over.      |
| dev-rgw | `local` | Per-developer test scope; `bucket_prefix` variable namespaces resources so multiple devs share the same RGW without collisions. Backend stanza in `versions.tf` shows how to promote to shared state. |
| sepia   | `s3`    | RGW-hosted `ceph-tekton-tfstate` bucket. Backend block in `versions.tf` is commented out until the bucket is bootstrapped — see `environments/sepia/README.md`. |

The Sepia state bucket is created out-of-band (chicken-and-egg) with
versioning enabled and no object-lock.

## Running the dev env

The dev env spins up against a local `quay.io/dparkes/zgw-posix:latest`
container — Ceph's RGW running against the experimental POSIX backend
driver. The one-shot way:

```sh
./hack/verify-s3-module.sh
```

That script (from the repo root) starts zgw-posix in docker/podman,
runs `terraform init && apply` against `terraform/environments/dev/`,
asserts the bucket-create + PUT/GET + public-read paths, and tears
everything down. Single-command verification, no leftover state.

The dev env intentionally sets `enable_versioning = false`,
`enable_lifecycle = false`, `enable_public_access_block = false`, and
`enable_bucket_ownership_controls = false` because zgw-posix's POSIX
driver doesn't yet implement those sub-APIs cleanly
(`PutBucketVersioning` and `PutBucketLifecycleConfiguration` crash
the gateway). For validation of those load-bearing features, the
`dev-rgw` env points at a full RGW (e.g. vstart) — see the next
section.

To iterate manually (useful when developing the module):

```sh
# Start zgw-posix yourself (port 8000, dev creds cephtekton/cephtekton):
mkdir -p /tmp/zgw-posix-data
docker run -d --name ceph-tekton-zgw-posix \
  -p 8000:8000 \
  -v /tmp/zgw-posix-data:/data \
  -e RGW_ACCESS_KEY=cephtekton \
  -e RGW_SECRET_KEY=cephtekton \
  quay.io/dparkes/zgw-posix:latest

# One-time: add a [zgw-posix] profile to your AWS credentials file
# (terraform reads this; the AWS CLI calls below can use --profile
# zgw-posix too):
mkdir -p ~/.aws
cat >> ~/.aws/credentials <<'EOF'
[zgw-posix]
aws_access_key_id = cephtekton
aws_secret_access_key = cephtekton
EOF
export TF_VAR_credentials_profile="zgw-posix"

# Apply:
cd terraform/environments/dev
terraform init
terraform apply -auto-approve

# Inspect:
aws --endpoint-url http://127.0.0.1:8000 \
    --region default \
    --profile zgw-posix \
    s3api list-buckets

# Tear down:
terraform destroy -auto-approve
docker rm -f ceph-tekton-zgw-posix
```

If you prefer not to touch `~/.aws/credentials`, the AWS provider also
honors `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars (they
take precedence over `shared_credentials_files`), which is the path
`hack/verify-s3-module.sh` takes — it exports those before invoking
terraform, so the credentials-file step isn't needed for the one-shot
script.

## Running the dev-rgw env

For higher-fidelity validation against a real Ceph cluster's RGW —
catches lifecycle scanner behavior, versioning + object-lock retention
enforcement, and Squid+-only features (public-access-block,
bucket-ownership-controls) that the local zgw-posix dev env can't
exercise.

See [`environments/dev-rgw/README.md`](environments/dev-rgw/README.md)
for the apply runbook. Short version: provision a test user on a
real RGW (vstart on a build host works; any production-like RGW works
better), add the user's access/secret pair as a named profile in
`~/.aws/credentials`, export `TF_VAR_rgw_endpoint` +
`TF_VAR_credentials_profile` + `TF_VAR_bucket_prefix`, then
`terraform apply`.

## Running the Sepia env

Don't, until the four prerequisites in
[`environments/sepia/README.md`](environments/sepia/README.md) are
met. The stub exists so module changes diff against a real call
site that mirrors Sepia values, not so it can be applied today.

## Caveats

- **zgw-posix surface is intentionally small.** `verify-s3-module.sh`
  against the dev env only asserts bucket-create + object PUT/GET
  + public-read; it does NOT cover versioning, lifecycle, or
  object-lock because the POSIX driver crashes the gateway on
  those calls. Higher-fidelity validation of those features lives
  in `environments/dev-rgw/` against real RGW.
- **No DynamoDB locking on RGW.** Sepia's backend won't have S3
  state locking; the operating model is "one operator changes
  terraform at a time, coordinated in #ceph-infra". Workable for a
  small team; revisit if it ever becomes a problem.
- **`force_destroy` on the release bucket is a footgun.** Even with
  `force_destroy = true`, S3 will refuse to delete objects still
  under object-lock retention — but the bucket-delete call will
  fail confusingly. Don't set it true in any env where the release
  bucket has real data.

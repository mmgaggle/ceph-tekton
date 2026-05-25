# Sepia environment — stub

This directory configures the three artifact buckets on **Sepia Ceph
RGW**. It is **documented but NOT applied** as part of this issue.

Bringing it up requires four prerequisites that are out of scope for
issue #6:

1. **A Sepia RGW endpoint and admin-issued bootstrap credential.**
   The endpoint URL, region, and a single-use access/secret pair must
   be set via `TF_VAR_rgw_endpoint`, `TF_VAR_rgw_access_key`, and
   `TF_VAR_rgw_secret_key` (or a `terraform.tfvars` file kept out of
   git). These long-lived keys are temporary — see prerequisite 4.

2. **A pre-created `ceph-tekton-tfstate` bucket on the same RGW.**
   Chicken-and-egg: the state backend for *this* terraform lives on
   the same RGW it's managing. Bootstrap with:

   ```sh
   aws --endpoint-url "$RGW_ENDPOINT" s3api create-bucket \
     --bucket ceph-tekton-tfstate
   aws --endpoint-url "$RGW_ENDPOINT" s3api put-bucket-versioning \
     --bucket ceph-tekton-tfstate \
     --versioning-configuration Status=Enabled
   ```

3. **The S3 backend stanza in `versions.tf` uncommented** with the
   real endpoint. Then `terraform init -migrate-state` once.

4. **The RGW OIDC trust + per-role policies from issue #2.** Once
   that lands, the long-lived bootstrap keys above are deleted and
   future runs use `AssumeRoleWithWebIdentity` from a CI SA token.

## Apply runbook (for the operator who eventually does this)

```sh
cd terraform/environments/sepia

# Edit versions.tf to uncomment the backend stanza and fill in the
# RGW endpoint. Then:
terraform init

# Sanity-check the plan against what the README documents.
terraform plan

# Apply behind a four-eyes review.
terraform apply
```

The release bucket's object-lock retention is **7 years**. Once an
object is PUT, the only ways to delete it before then are:

- A holder of `s3:BypassGovernanceRetention` (audited break-glass
  role) issuing a `DeleteObject` with `--bypass-governance-retention`.
- Switching from GOVERNANCE to COMPLIANCE was NOT done — COMPLIANCE
  has no override at all. If you ever flip the mode, that is a
  one-way door.

## Why this stub is here at all

So that diffs against the dev env (`terraform/environments/dev/`)
make the prod-vs-dev value drift legible — when someone changes the
module, the reviewer can see what Sepia will get without running
terraform.

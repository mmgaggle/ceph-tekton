# RGW lifecycle: empty V2 `<Filter/>` is silently downgraded to V1 `<Prefix></Prefix>` on GET

Draft of a tracker.ceph.com / upstream report. Not yet filed.

## Summary

When `PutBucketLifecycleConfiguration` is called with a rule whose
`<Filter>` element is **empty** (the documented "match every object" V2
idiom), RGW persists and returns the rule in legacy V1 `<Prefix>` form on
the subsequent `GetBucketLifecycleConfiguration`. The two forms are
semantically equivalent ("match all"), but the round-trip is not
shape-preserving, which breaks structural-diff tooling such as the
Terraform AWS provider 5.x.

Rules with **non-empty** `<Filter>` (e.g. `<Filter><Prefix>logs/</Prefix></Filter>`
or `<Filter><ObjectSizeGreaterThan>0</ObjectSizeGreaterThan></Filter>`)
round-trip correctly. The bug is scoped to the empty-filter case.

## Affected version

```
ceph version f1708d290f (bf1708d290f0126c5310649ac7b512766921aa6a) umbrella (dev - Debug)
```

Branch under test: `pr-G-s3files-restmgr-skeleton` (commit `bf1708d29...`).
Build is umbrella-dev; the bug is in the lifecycle GET handler so
presumably present in current `main`. Confirm against released versions
before classifying as regression vs. long-standing.

## Reproducer

vstart cluster on a single host, RGW on `http://localhost:8000`, account
+ user created per the `radosgw-admin account create` + `user create
--account-root` pattern. Replace the access/secret keys below with your
own.

### Case 1: empty `<Filter/>` (BUG — round-trip downgrade)

PUT (sent):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Rule>
    <ID>test-empty-filter</ID>
    <Status>Enabled</Status>
    <Filter></Filter>
    <Expiration><Days>30</Days></Expiration>
  </Rule>
</LifecycleConfiguration>
```

Equivalent AWS CLI invocation:

```sh
export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...
aws --endpoint-url http://localhost:8000 s3api create-bucket --bucket lc-bug-probe

aws --endpoint-url http://localhost:8000 s3api put-bucket-lifecycle-configuration \
  --bucket lc-bug-probe \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "test-empty-filter",
        "Status": "Enabled",
        "Filter": {},
        "Expiration": {"Days": 30}
      }
    ]
  }'

aws --endpoint-url http://localhost:8000 s3api get-bucket-lifecycle-configuration \
  --bucket lc-bug-probe
```

GET (received):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Rule>
    <ID>test-empty-filter</ID>
    <Prefix></Prefix>
    <Status>Enabled</Status>
    <Expiration><Days>30</Days></Expiration>
  </Rule>
</LifecycleConfiguration>
```

Note: `<Filter/>` was replaced by `<Prefix></Prefix>`. This is the V1
lifecycle rule shape, not the V2 shape that was PUT.

### Case 2: `<Filter><Prefix>logs/</Prefix></Filter>` (CORRECT — preserved)

PUT a non-empty prefix Filter:

```sh
aws --endpoint-url http://localhost:8000 s3api put-bucket-lifecycle-configuration \
  --bucket lc-bug-probe \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "prefix-filter",
        "Status": "Enabled",
        "Filter": {"Prefix": "logs/"},
        "Expiration": {"Days": 30}
      }
    ]
  }'
```

GET (received):

```json
{
  "Rules": [
    {
      "Expiration": {"Days": 30},
      "ID": "prefix-filter",
      "Filter": {"Prefix": "logs/"},
      "Status": "Enabled"
    }
  ]
}
```

V2 `<Filter>` shape preserved. Good.

### Case 3: `<Filter><ObjectSizeGreaterThan>0</ObjectSizeGreaterThan></Filter>` (CORRECT — preserved)

```sh
aws --endpoint-url http://localhost:8000 s3api put-bucket-lifecycle-configuration \
  --bucket lc-bug-probe \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "size-filter",
        "Status": "Enabled",
        "Filter": {"ObjectSizeGreaterThan": 0},
        "Expiration": {"Days": 30}
      }
    ]
  }'
```

GET (received):

```json
{
  "Rules": [
    {
      "Expiration": {"Days": 30},
      "ID": "size-filter",
      "Filter": {"ObjectSizeGreaterThan": 0},
      "Status": "Enabled"
    }
  ]
}
```

V2 `<Filter>` shape preserved. Good.

## Expected behavior

GET should return the V2 `<Filter></Filter>` shape that was PUT. AWS S3
preserves the empty-Filter shape on round-trip; RGW should too, for API
fidelity.

## Actual behavior

RGW returns V1 `<Prefix></Prefix>` instead of V2 `<Filter></Filter>` for
the empty-filter case. Internally it appears RGW is matching the empty
`<Filter>` against the legacy "rule has a Prefix but no Filter" code
path and serializing back through the V1 emitter.

## Tooling impact

### Terraform AWS provider (`hashicorp/aws` 5.30+)

The `aws_s3_bucket_lifecycle_configuration` resource performs a
post-PUT consistency wait: it polls `GetBucketLifecycleConfiguration`
and `DeepEqual`-compares the returned rules against the rules it just
PUT, with a 3-minute timeout. When the rule contains an empty `Filter`,
the comparison never converges (V2 in, V1 out), and `terraform apply`
fails with:

```
Error: creating S3 Bucket (...) Lifecycle Configuration
  While waiting: timeout while waiting for state to become 'true'
  (last state: 'false', timeout: 3m0s)
```

The lifecycle config IS applied — the bucket honors the rule — but the
provider can't confirm convergence and tears the resource out of state.

This is the bug that surfaced the issue. The terraform module in
`ceph-tekton` (`terraform/modules/s3-buckets/main.tf`) uses
`filter {}` for the "apply to all objects" idiom, which is the form
the AWS provider documents and the form AWS S3 itself round-trips
correctly.

### Other tooling potentially affected

Any S3 client that does structural comparison between PUT-input and
GET-output on lifecycle configurations: AWS SDK retry/idempotence
helpers, CDK, Pulumi (which wraps the same provider), and custom
operator reconciliation loops that compare desired vs. actual state.

Tooling that does semantic-equivalence comparison (or no comparison)
is unaffected: the lifecycle rule itself is honored by the RGW
scanner.

## Workarounds

1. **Switch the V2 empty `<Filter/>` to a non-empty filter that
   preserves "match all" semantics**, e.g.
   `<Filter><ObjectSizeGreaterThan>0</ObjectSizeGreaterThan></Filter>`.
   This is the workaround the ceph-tekton terraform module will likely
   adopt until the RGW side is fixed.

2. **PUT the V1 form directly** (`<Prefix></Prefix>` at the rule level,
   no `<Filter>` block at all). The Terraform AWS provider 5.x does
   not support emitting V1 — this only works for hand-written clients.

3. **Use an S3 provider that normalizes to V1 on send** — none of the
   common ones do this; the V2 form is the documented modern API.

## Suggested fix

RGW's `GetBucketLifecycleConfiguration` handler should preserve the
shape that was PUT. Specifically: if the rule was PUT with an empty
`<Filter>` (no `<Prefix>` at the rule level, no Filter contents), the
GET response should emit `<Filter></Filter>`, not `<Prefix></Prefix>`.

A minimal fix: track whether the rule was parsed from a V2 PUT (had a
`<Filter>` element at any point) and emit accordingly. A more thorough
fix: normalize V1 PUTs to V2 internally and always emit V2 — V1 is the
deprecated shape and the long-term direction is V2-only.

## Reference

Test sequence captured in the ceph-tekton repo at `notes/` (this
document) and reproduced against the vstart cluster on the build host
during the dev-rgw terraform validation work (issue #56 follow-up).

Downstream tracking issue:
[mmgaggle/ceph-tekton#57](https://github.com/mmgaggle/ceph-tekton/issues/57)
— re-enable lifecycle in dev-rgw once this bug is fixed upstream and
shipped to the test cluster.

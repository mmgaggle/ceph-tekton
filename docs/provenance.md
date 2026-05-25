# Provenance — Tekton Chains + SLSA + Sigstore

ceph-tekton signs every build artifact with a SLSA Provenance v1.0 in-toto
attestation, then logs the signature to a public transparency log. Anyone,
anywhere, can verify a Ceph build's provenance using only public Sigstore
infrastructure and `cosign` — no Sepia-side trust required.

This page covers the **dev cluster** install + smoke test. The production
Sepia configuration (Fulcio keyless signing — see [`PLAN.md`](../PLAN.md))
is a one-flag overlay on top of this base; see "Promoting to Fulcio
keyless" below.

## Why two signing modes

| | Dev (kind) | Sepia (OpenShift) |
|---|------------|-------------------|
| Signer | cosign x509 key in a k8s Secret | Fulcio short-lived cert (keyless) |
| Identity | "holder of cosign.key" — opaque | SA `ceph-pipeline-sa` in ns `sepia-pipelines` |
| Key management | one cosign keypair, rotate manually | none — per-run certs |
| Why split | Fulcio must reach the cluster's OIDC discovery endpoint to verify the SA token; a NAT'd kind cluster can't satisfy that | Sepia OpenShift has a publicly-reachable issuer |

Both modes produce the same attestation format (SLSA v1) and log to the
same public Rekor — so the verification command is identical and any
smoke-test you can do here also exercises the production code path.

## Prerequisites

In addition to the dev-cluster prereqs from
[`contributing-locally.md`](contributing-locally.md):

```sh
brew install cosign   # >= 2.2
brew install rekor-cli
```

## Install

After `make dev-up` (which only installs Tekton Pipelines):

```sh
./hack/dev-chains-setup.sh
```

This script:

1. `kubectl apply -k kustomize/base/tekton-chains/` — installs the Chains
   controller + an opinionated `chains-config` ConfigMap (SLSA v1 format,
   storage=tekton, cosign x509 signer, transparency to public Rekor).
2. `cosign generate-key-pair k8s://tekton-chains/signing-secrets` —
   generates a fresh ed25519 keypair and stores it in the Secret Chains
   looks for by convention. Uses an empty passphrase for dev; production
   uses a secret-managed passphrase.
3. Restarts the Chains controller so it picks up the new key.

The script is idempotent: re-running on a live cluster only reconciles
state. If the Secret already has a `cosign.key`, it isn't regenerated.

## Smoke test

```sh
kubectl apply -f pipelines/chains-smoke-test.yaml
tkn pipeline start chains-smoke-test \
  --workspace name=sbom,emptyDir="" \
  --showlog
```

The `chains-smoke-test` pipeline runs two Tasks:

1. **`build`** — emits `IMAGE_URL` + `IMAGE_DIGEST` as Tekton Results
   (claiming a fake dev image). Gives Chains a subject to sign.
2. **`sbom`** — runs `syft` against a real, small public image
   (`alpine:3.19` by default), writes an SPDX-JSON SBOM into the shared
   `sbom` workspace, and emits the type-hinted Results
   `IMAGE_URL` / `IMAGE_DIGEST` / `SBOM_URL` / `SBOM_DIGEST` /
   `SBOM_MEDIATYPE`. Chains picks those up and attaches an SPDX
   descriptor to the attestation it then signs.

Chains observes the completed TaskRuns, generates an in-toto SLSA
Provenance attestation (format `slsa/v2alpha4`) describing the subject
plus the SBOM as a resolved dependency, signs it with the cosign key,
and posts the entry to public Rekor.

The build image reference is intentionally fake — we want to validate
the Chains plumbing, not pay for a real container build in dev. The
SBOM target is a real public image so the SPDX shape is realistic.
Real per-package SBOMs against `dpkg-buildpackage`/`rpmbuild` outputs
land in #50; real container attestations in #23. Same Chains config
observes all of them.

## Verify

After the smoke-test PipelineRun finishes:

```sh
# Find the TaskRun name
TR=$(tkn taskrun list --output=name | head -1)

# Pull the attestation off the TaskRun annotation
kubectl get "$TR" -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/payload-taskrun-[a-z0-9-]+}' \
  | base64 -d \
  | tee /tmp/attestation.intoto.jsonl

# Pull the signature
kubectl get "$TR" -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signature-taskrun-[a-z0-9-]+}' \
  | base64 -d \
  | tee /tmp/attestation.sig

# Verify the signature with the public key from signing-secrets
kubectl -n tekton-chains get secret signing-secrets \
  -o jsonpath='{.data.cosign\.pub}' | base64 -d > /tmp/cosign.pub

cosign verify-blob \
  --key /tmp/cosign.pub \
  --signature /tmp/attestation.sig \
  /tmp/attestation.intoto.jsonl
```

You should see `Verified OK`.

To confirm the Rekor transparency-log entry:

```sh
rekor-cli search --public-key /tmp/cosign.pub --pki-format x509
# returns the log indices; then:
rekor-cli get --log-index <index>
```

## Inspecting the attestation

```sh
cat /tmp/attestation.intoto.jsonl | jq '.payload | @base64d | fromjson'
```

You'll see the SLSA Provenance v1 structure:

- `subject` — list of `{name, digest}` for the artifacts produced
- `predicate.buildDefinition` — what build was run (image, source URI, parameters)
- `predicate.runDetails.builder` — the Tekton Chains builder identity
- `predicate.runDetails.metadata` — start/end times, invocation ID

This is the provenance that downstream consumers (teuthology, Ceph users)
can verify against the source code that was supposedly built.

## SBOM

Every PipelineRun also emits a parseable SPDX-JSON SBOM as part of the
SLSA attestation. The `chains-smoke-test` pipeline's `sbom` Task runs
`syft` against a small public image and surfaces the SBOM via Tekton
Chains' **type-hinted Result** convention. Real Ceph package and
container pipelines plug into the same convention as they land (#23,
#50) — no Chains-side changes needed.

### How it lands in the attestation

Chains 0.22 has no separate "enable SBOM" knob. It looks at every
TaskRun's Results for the type-hint grammar:

| Result name | What it means |
| --- | --- |
| `IMAGE_URL` (or `<NAME>_IMAGE_URL`) | Subject — what was built / scanned. |
| `IMAGE_DIGEST` (or `<NAME>_IMAGE_DIGEST`) | Subject digest, `sha256:...`. |
| `SBOM_URL` (or `<NAME>_SBOM_URL`) | Where the SBOM file lives. |
| `SBOM_DIGEST` (or `<NAME>_SBOM_DIGEST`) | `sha256:...` of the SBOM bytes. |
| `SBOM_MEDIATYPE` (or `<NAME>_SBOM_MEDIATYPE`) | `application/spdx+json` for SPDX. |

When these are present together, Chains adds an entry under
`predicate.buildDefinition.resolvedDependencies` in the
`slsa/v2alpha4` predicate:

```json
{
  "predicate": {
    "buildDefinition": {
      "resolvedDependencies": [
        {
          "uri": "workspace://sbom/sbom.spdx.json",
          "digest": { "sha256": "9e1c…" },
          "name": "SBOM",
          "mediaType": "application/spdx+json"
        }
      ]
    }
  }
}
```

The `enable-deep-inspection` flag on the `chains-config` ConfigMap
(`artifacts.pipelinerun.enable-deep-inspection: "true"`) is what makes
the *PipelineRun*-level attestation roll up child TaskRun Results;
without it Chains only sees what the Pipeline itself re-exposes.

### Why SPDX (not CycloneDX)

Chains 0.22 is format-agnostic — it copies whatever `SBOM_MEDIATYPE`
the Task emits into the descriptor verbatim. We pin **SPDX-JSON
(`application/spdx+json`, spec version 2.3)** because:

- it's what the M-22-18 / M-23-16 federal procurement guidance calls
  out by name (alongside CycloneDX, but SPDX is the ISO/IEC 5962
  standard);
- syft emits clean, validator-passing SPDX-JSON out of the box; and
- `spdx-tools` and `syft scan` parse the same bytes — no second tool
  chain to maintain.

CycloneDX is reachable from the same Task by adding a second `-o`
flag and a second result trio; we're not doing that until a consumer
needs it.

### Extract and verify the SBOM

Once the smoke-test PipelineRun finishes, the per-TaskRun attestation
annotations carry the SBOM descriptor and the workspace carries the
SBOM bytes:

```sh
# 1. Find the sbom TaskRun.
SBOM_TR=$(tkn taskrun list --output=name | grep -m1 chains-smoke-sbom)

# 2. Pull its attestation and inspect resolvedDependencies.
kubectl get "$SBOM_TR" \
  -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/payload-taskrun-[a-z0-9-]+}' \
  | base64 -d \
  | jq -r '.payload | @base64d | fromjson
           | .predicate.buildDefinition.resolvedDependencies'

# 3. Read the SBOM_DIGEST + SBOM_URL Results directly.
tkn taskrun describe "${SBOM_TR##*/}" -o json \
  | jq -r '.status.results[] | select(.name|startswith("SBOM"))'
```

The descriptor `uri` is a `workspace://` URL while we're in dev (storage
= tekton, no OCI registry). In Sepia (OCI mode, deferred) the SBOM is
pushed as an [OCI referrer](https://github.com/opencontainers/distribution-spec/blob/main/spec.md#listing-referrers)
alongside the image and the `uri` becomes a registry reference; the
descriptor schema is unchanged.

To pull the raw SBOM file out of the workspace (kind dev cluster, where
the workspace is an emptyDir):

```sh
# Re-mount the sbom workspace with a debug pod and copy the file out,
# OR run a tiny inline `cat` step inside the pipeline that exfiltrates
# to a Result the next time you iterate. In Sepia the SBOM is fetched
# via `oras pull <ref>` from the OCI referrer.
kubectl cp <pod>:/workspace/sbom/sbom.spdx.json /tmp/sbom.spdx.json
```

Verify the file matches the digest Chains attested:

```sh
sha256sum /tmp/sbom.spdx.json
# compare against the SBOM_DIGEST Result and against
# predicate.buildDefinition.resolvedDependencies[].digest.sha256
```

Then re-parse it with syft or `spdx-tools`:

```sh
# syft round-trips SPDX-JSON; non-zero exit on schema errors.
syft scan spdx-json:/tmp/sbom.spdx.json -o table

# Or with the upstream SPDX tools:
pip install spdx-tools
pyspdxtools -i /tmp/sbom.spdx.json
```

Both should succeed with no schema errors. The cosign verification
from the section above (`cosign verify-blob ...`) is unchanged — the
SBOM lives inside the same signed payload, so the same signature
covers it.

### Local-only sanity check (no cluster)

You can prove the syft step itself produces a clean SPDX without
spinning up Tekton at all:

```sh
podman run --rm -v /tmp:/out anchore/syft:v1.18.0 \
  scan registry:docker.io/library/alpine:3.19 \
  --output spdx-json=/out/sbom.spdx.json --quiet

syft scan spdx-json:/tmp/sbom.spdx.json -o table   # parses, exit 0
```

That's the same `syft scan` invocation the Task runs.

## Per-build package SBOMs

The `SBOM` section above covers the **container image** path: one image
subject, one SPDX-JSON SBOM, attached via Chains' type-hint Result
convention. For **packages** (`.deb`, `.rpm`) the same Chains plumbing
is reused but with three deliberate differences:

1. **One SBOM per artifact** — a single `build-package` TaskRun (#16)
   can emit a handful of `.deb`s and a handful of `.rpm`s. Each one
   gets its own CycloneDX SBOM and its own subject in the attestation.
2. **CycloneDX-JSON, not SPDX-JSON** — see "Why CycloneDX (for
   packages)" below.
3. **S3 storage, not OCI referrers** — packages don't live in a
   registry, so the SBOM lives next to the `.deb` / `.rpm` in the
   build-output S3 prefix (same lifecycle, same access controls).

The `generate-sbom` Task (`tasks/generate-sbom/task.yaml`) is the
mechanism. It ships standalone today and gets `runAfter`'d by the real
package pipeline once #16 lands.

### Why CycloneDX (for packages)

Same operating principle as SPDX-for-images (#46): Chains is
format-agnostic and copies `SBOM_MEDIATYPE` verbatim into the
attestation's `resolvedDependencies[].mediaType`. Format choice is a
**consumer-fit** decision, not a Chains constraint. We picked the split
because:

| | SPDX 2.3 JSON | CycloneDX 1.6 JSON |
|---|---|---|
| Best for | Compliance / license inventories | Dependency graphs + vuln correlation |
| Native dependency edges | flat `relationships[]` | first-class `dependencies[]` tree |
| Ecosystem fit | M-22-18/M-23-16 federal asks, ISO/IEC 5962 | OWASP Dependency-Track, GitHub Dependency Graph, Snyk, Grype |
| Per-package SBOM ergonomics | works; verbose | tighter — components + deps grouped per pkg |
| What ceph consumers actually run | image-pull verifiers, fed-procurement audits | `grype <sbom.cdx.json>` against the vuln DB (#51) |

For container images the consumer is "fed procurement / cosign verify"
→ SPDX wins. For packages the consumer is "Grype + Dependency-Track
correlating CVEs against the deb / rpm payload" → CycloneDX wins. Both
are signed-into the same SLSA attestation; downstream tooling reads
`SBOM_MEDIATYPE` and dispatches.

### The multi-subject Chains type-hint grammar

Container SBOM uses the **bare-name** form
(`IMAGE_URL` + `IMAGE_DIGEST` + `SBOM_URL` + `SBOM_DIGEST` +
`SBOM_MEDIATYPE` — one subject per TaskRun). Packages can't use that
form because there are N subjects per TaskRun and Tekton's
declared-results rule
([tektoncd/pipeline#7140](https://github.com/tektoncd/pipeline/issues/7140))
means we can't surface `<NAME>_*` Results whose `<NAME>` is only known
at scan time.

[`tektoncd/chains/docs/slsa-provenance.md`](https://github.com/tektoncd/chains/blob/main/docs/slsa-provenance.md)
documents two declared plural Results that handle multi-subject
TaskRuns cleanly, and `generate-sbom` emits BOTH:

| Result name | Shape | What Chains does with it |
| --- | --- | --- |
| `IMAGES` | newline-separated `<url>@sha256:<digest>` pairs | Promotes each pair to a separate subject in the SLSA attestation. Works on every Chains version since 0.13. |
| `ARTIFACT_OUTPUTS` | JSON array of `{name, uri, digest, sbom:{uri,digest,mediaType}}` | Reads the nested `sbom` block (Chains 0.20+) and populates one `predicate.buildDefinition.resolvedDependencies[]` entry per artifact with the CycloneDX descriptor. |

The Task also exposes three contract-level Results that aren't part of
the Chains grammar but are useful for verifier tooling, dashboards,
and the smoke test:

- **`SBOM_NAMES`** — newline-separated list of slug names (one per
  artifact, derived from the basename: uppercase, non-alnum replaced
  with `_`, prefixed `PKG_`). Lets a human grep TaskRun output without
  having to JSON-parse `ARTIFACT_OUTPUTS`. Example:

  ```
  fake-pkg-a_1.0.tar                   -> PKG_FAKE_PKG_A_1_0_TAR
  ceph-mds_19.2.0_arm64.deb            -> PKG_CEPH_MDS_19_2_0_ARM64_DEB
  ceph-common-19.2.0-1.el10.x86_64.rpm -> PKG_CEPH_COMMON_19_2_0_1_EL10_X86_64_RPM
  ```

- **`SBOM_COUNT`** — decimal count of (artifact, SBOM) pairs. Zero is
  a fatal misconfiguration; the Task fails before emitting in that
  case (the smoke test asserts this).
- **`SBOM_MEDIATYPE`** — `application/vnd.cyclonedx+json`, the per-Task
  CycloneDX commitment.

Chains' deep-inspection (the same
`artifacts.pipelinerun.enable-deep-inspection: "true"` ConfigMap flag
that the container path needs) walks the PipelineRun's child TaskRuns,
pulls the `IMAGES` + `ARTIFACT_OUTPUTS` Results, and rolls up one
attestation with **N subjects + N SBOM descriptors** for an N-package
build.

### Extracting a specific package's SBOM from an attestation

The attestation lives on the PipelineRun (deep-inspection rolls up
child TaskRun Results). Pull it the same way as the container path,
then filter `resolvedDependencies` by `mediaType` and `name`:

```sh
# 1. Pull the PipelineRun-level attestation.
PR=$(tkn pipelinerun list --output=name | grep -m1 sbom-pkg-smoke-test)
kubectl get "$PR" \
  -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/payload-pipelinerun-[a-z0-9-]+}' \
  | base64 -d \
  | jq -r '.payload | @base64d | fromjson' > /tmp/att.json

# 2. List every CycloneDX SBOM descriptor in the attestation.
jq '.predicate.buildDefinition.resolvedDependencies[]
    | select(.mediaType == "application/vnd.cyclonedx+json")' \
  /tmp/att.json

# 3. Find the SBOM_URL for a specific package by its basename.
BN=ceph-mds_19.2.0_arm64.deb
tkn pipelinerun describe "${PR##*/}" -o json \
  | jq -r ".status.childReferences[].name" \
  | while read -r tr; do
      tkn taskrun describe "$tr" -o json \
        | jq -r --arg n "$BN" '
            (.status.results[]? | select(.name == "ARTIFACT_OUTPUTS")).value
            | fromjson
            | .[] | select(.name == $n) | .sbom.uri'
    done

# 4. Fetch the SBOM and re-parse it. The S3 layout is
#    s3://<bucket>/<branch>/<sha>/<distro>/<arch>/sboms/<basename>.cdx.json
aws s3 cp \
  s3://ceph-artifacts-branch/main/<sha>/centos10/x86_64/sboms/ceph-mds_19.2.0_arm64.deb.cdx.json \
  /tmp/
syft scan cyclonedx-json:/tmp/ceph-mds_19.2.0_arm64.deb.cdx.json -o table
```

The downstream `SBOM_DIGEST` you saw in step 2 should match `sha256sum
/tmp/ceph-mds_19.2.0_arm64.deb.cdx.json` exactly — same Chains-attested
integrity guarantee as the container path.

### OIDC S3 upload path

The `generate-sbom` Task's `upload` step has three credentials modes
(matches `reproducibility-check`, in priority order):

1. **`s3-credentials` workspace mounted** with `AWS_ACCESS_KEY_ID` /
   `AWS_SECRET_ACCESS_KEY` / optional `AWS_SESSION_TOKEN` files. Dev
   path — same shape contributors use for the reproducibility smoke.
2. **Projected SA token + `AWS_ROLE_ARN` env var** — production /
   Sepia path. The step runs
   `aws sts assume-role-with-web-identity --role-arn $AWS_ROLE_ARN
   --web-identity-token $(cat /var/run/secrets/openshift/serviceaccount/token)`
   to mint creds with TTL ≤ 1h, scoped by the RGW-side role to the
   correct bucket + prefix. No long-lived S3 keys touch the pod —
   matches the architecture decision in
   [`docs/architecture.md`](architecture.md) "S3 credentials: STS
   OIDC via SA-token".
3. **`s3-bucket` empty** — short-circuit: SBOMs stay in the `sboms`
   workspace and `SBOM_URL` Results point at `workspace://...`. Smoke
   tests, kind dev, and the `sbom-pkg-smoke-test` pipeline run in
   this mode.

Production S3 layout (mirrors the package upload prefix from
`PLAN.md` "Artifact storage"):

```
s3://ceph-artifacts-<class>/<branch>/<sha>/<distro>/<arch>/
├── ceph-mds_19.2.0_arm64.deb        <- build-package (#16)
├── ceph-common_19.2.0_arm64.deb     <- build-package (#16)
├── ...
└── sboms/
    ├── ceph-mds_19.2.0_arm64.deb.cdx.json     <- generate-sbom
    └── ceph-common_19.2.0_arm64.deb.cdx.json  <- generate-sbom
```

The SBOMs live in a `sboms/` sibling of the artifacts so consumers
that walk the prefix can list packages and SBOMs separately, and so
that the lifecycle/object-lock policies governing the `.deb` / `.rpm`
files apply identically to their SBOMs (same `<branch>/<sha>` parent
prefix, no separate retention story).

### Wiring into build-package (#16)

When [#16](https://github.com/mmgaggle/ceph-tekton/issues/16) lands,
the package-build pipeline appends `generate-sbom` after
`build-package` with shared workspaces:

```yaml
tasks:
  - name: build-package
    taskRef: { name: build-package }
    workspaces:
      - { name: source,        workspace: source }
      - { name: build-output,  workspace: build-output }
  - name: generate-sbom
    runAfter: [build-package]
    taskRef: { name: generate-sbom }
    params:
      - { name: artifact-glob, value: "*.deb" }   # or "*.rpm" per distro
      - { name: s3-bucket,     value: "$(params.s3-bucket)" }
      - { name: s3-branch,     value: "$(params.branch)" }
      - { name: s3-sha,        value: "$(params.sha)" }
      - { name: s3-distro,     value: "$(params.distro)" }
      - { name: s3-arch,       value: "$(params.arch)" }
      - { name: subject-prefix, value: "https://artifacts.ceph.com/$(params.s3-bucket)/$(params.branch)/$(params.sha)/$(params.distro)/$(params.arch)/" }
    workspaces:
      - { name: artifacts,        workspace: build-output }
      - { name: sboms,            workspace: build-output }
      - { name: s3-credentials,   workspace: s3-credentials }
```

No changes to `tasks/generate-sbom/task.yaml` are needed for the
real-build path; only the `artifact-glob`, `subject-prefix`, and S3
params switch from smoke defaults to real values.

### Smoke test

```sh
kubectl apply -f tasks/generate-sbom/task.yaml
kubectl apply -f pipelines/sbom-pkg-smoke-test.yaml
tkn pipeline start sbom-pkg-smoke-test \
  --workspace name=artifacts,emptyDir="" \
  --workspace name=sboms,emptyDir="" \
  --showlog
```

The pipeline:
- seeds two deterministic `.tar` files into the artifacts workspace,
- runs `generate-sbom` to produce one CycloneDX SBOM per artifact,
- runs `assert-results` to verify `SBOM_COUNT=2`, the right
  `SBOM_MEDIATYPE`, and that `SBOM_NAMES` contains both per-artifact
  prefixes (`FAKE_PKG_A` + `FAKE_PKG_B`).

PipelineRun success = the Chains type-hint contract is intact.

## Promoting to Fulcio keyless (Sepia)

When the `overlays/sepia/` chains patch lands (deferred), it will:

1. Set `signers.x509.fulcio.enabled=true` in `chains-config`.
2. Add `signers.x509.fulcio.address=https://fulcio.sigstore.dev`.
3. Add `signers.x509.fulcio.issuer=$CLUSTER_OIDC_ISSUER` — the
   publicly-reachable URL of Sepia OpenShift's SA token issuer
   discovery doc.
4. Add `transparency.url=https://rekor.sigstore.dev` (already in dev).
5. Stop creating `signing-secrets` — Fulcio mints per-run certs.

The smoke-test flow is identical. Only verification changes: instead of
`cosign verify-blob --key`, use:

```sh
cosign verify-attestation \
  --certificate-identity-regexp 'https://sepia\.ceph\.io.*/serviceaccount/ceph-pipeline-sa' \
  --certificate-oidc-issuer 'https://sepia.ceph.io/...' \
  <image-ref>
```

That gives the third-party verifier a binding: "I trust this attestation
because Fulcio asserted it came from the `ceph-pipeline-sa` ServiceAccount
in the `sepia-pipelines` namespace of the Sepia OpenShift cluster."

## What's not in the dev install

The dev install intentionally cuts these corners — Sepia gets them via
overlays as their issues land:

- **OCI referrer storage** (#26). Dev uses `storage=tekton` (attestation
  as TaskRun annotation) so no writable registry is needed. Sepia flips
  to `storage=oci` and pushes to quay.io / in-cluster registry.
- **Per-arch container attestation in the manifest list** (#25 + #26).
  Multi-arch attestations follow once the buildah pipeline lands.
- **Package attestation in S3** (#27). Sibling `.intoto.jsonl` upload
  pairs with the publish-repo task.
- **Fulcio keyless** — see the previous section.

## Troubleshooting

### `signing-secrets` Secret missing after script run

The cosign CLI prompts interactively for a passphrase if one isn't piped.
Re-run with an explicit empty passphrase:

```sh
COSIGN_PASSWORD="" cosign generate-key-pair k8s://tekton-chains/signing-secrets
```

### Chains controller never produces an attestation

Check the chains controller logs:

```sh
kubectl -n tekton-chains logs -l app.kubernetes.io/part-of=tekton-chains -f
```

Common causes:

- TaskRun has no `IMAGE_URL` / `IMAGE_DIGEST` Results — Chains has nothing
  to attest about.
- `signing-secrets` doesn't have `cosign.key` (script step failed).
- ConfigMap wasn't picked up — restart the controller via the script.

### Attestation has no `resolvedDependencies` / no SBOM descriptor

The SBOM type-hint convention is strict: Chains only attaches an SBOM
descriptor when *all four* paired Results land on the same TaskRun:
`IMAGE_URL`, `IMAGE_DIGEST`, `SBOM_URL`, `SBOM_DIGEST` (plus optional
`SBOM_MEDIATYPE`). If `IMAGE_*` and `SBOM_*` are split across two
TaskRuns, Chains can't correlate them. Check:

```sh
kubectl get taskrun <name> -o jsonpath='{.status.results[*].name}'
```

For a PipelineRun-level attestation that includes the SBOM, also
confirm `artifacts.pipelinerun.enable-deep-inspection: "true"` is set
in the `chains-config` ConfigMap. Without it, the PipelineRun
attestation only sees Pipeline-level Results.

### Rekor upload fails behind a proxy

Public Rekor is at `rekor.sigstore.dev`. If your network blocks it, set
`transparency.enabled=false` in `chains-config` (loses the public
transparency property — only acceptable for offline dev).

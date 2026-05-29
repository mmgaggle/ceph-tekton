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
# Issue #68: single-resource files. Apply Tasks first, then the Pipeline.
kubectl apply -f pipelines/tasks/chains-smoke-build.yaml
kubectl apply -f pipelines/tasks/chains-smoke-sbom.yaml
kubectl apply -f pipelines/pipelines/chains-smoke-test.yaml
tkn pipeline start chains-smoke-test \
  --workspace name=sbom,emptyDir="" \
  --showlog
```

The `chains-smoke-test` pipeline runs two Tasks:

1. **`build`** — emits `IMAGE_URL` + `IMAGE_DIGEST` as Tekton Results
   (claiming a fake dev image). Gives Chains a subject to sign.
2. **`sbom`** — runs `syft` against a real, small public image
   (`alpine:3.19` by default), writes an SPDX-JSON SBOM into the shared
   `sbom` workspace, and emits the Chains-recognized Results
   `IMAGE_URL` + `IMAGE_DIGEST` (the alpine subject) plus a
   `sbom-ARTIFACT_OUTPUTS` object Result (the SBOM byproduct).

Chains observes the completed TaskRuns, generates an in-toto SLSA
Provenance attestation (format `slsa/v2alpha4`) describing the subject
plus the SBOM byproduct under `predicate.runDetails.byproducts[]`,
signs it with the cosign key, and posts the entry to public Rekor.

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

Chains 0.26 recognizes a small set of [output type-hint Result
patterns](https://github.com/tektoncd/chains/blob/v0.26.0/docs/slsa-provenance.md#output-artifacts) —
**there is no dedicated SBOM convention**:

| Result name pattern | Role in the attestation |
| --- | --- |
| `*IMAGE_URL` + `*IMAGE_DIGEST` | Subject — what was built / scanned. |
| `IMAGES` | Multi-subject (newline- or comma-separated `uri@digest`). |
| `*ARTIFACT_URI` + `*ARTIFACT_DIGEST` | Subject when paired; byproduct otherwise. |
| `*ARTIFACT_OUTPUTS` | Object `{uri, digest, isBuildArtifact}`. Subject when `isBuildArtifact: "true"`; byproduct otherwise. |

Result names not matching one of these patterns are ignored by Chains.
SBOMs land via `*ARTIFACT_OUTPUTS` with `isBuildArtifact: "false"`,
which Chains records at `predicate.runDetails.byproducts[]` of the
slsa/v2alpha4 attestation (note: lowercase `byproducts` under
`runDetails`, distinct from the SLSA spec's top-level
`predicate.byProducts`). The Result's JSON value is
**base64-encoded** into the `content` field:

```json
{
  "predicate": {
    "runDetails": {
      "byproducts": [
        {
          "name": "taskRunResults/<taskrun-name>/sbom-ARTIFACT_OUTPUTS",
          "mediaType": "application/json",
          "content": "<base64 of {uri, digest, isBuildArtifact}>"
        }
      ]
    }
  }
}
```

The `mediaType: application/json` on the `byproducts[]` entry
describes the **Result wrapper**, not the SBOM itself — the SBOM's
own mediaType (`application/spdx+json`) is not recorded anywhere in
the attestation. Verifiers either trust the URI suffix
(`.spdx.json`) or fetch the file and content-sniff.

**For a fully-typed SBOM attachment** (mediaType in the attestation,
discoverable from the image's OCI referrer index, independently
verifiable with `cosign verify-attestation --type spdx`), the
canonical path is **`cosign attach sbom`** after the build — tracked
as a follow-up to #46 alongside the e2e harness in #54.

The `enable-deep-inspection` flag on the `chains-config` ConfigMap
(`artifacts.pipelinerun.enable-deep-inspection: "true"`) is what makes
the *PipelineRun*-level attestation roll up child TaskRun Results;
without it Chains only sees what the Pipeline itself re-exposes.

### Why SPDX (not CycloneDX)

Chains 0.26 is format-agnostic — it copies whatever `SBOM_MEDIATYPE`
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
annotations carry the SBOM byproduct entry and the workspace carries
the SBOM bytes:

```sh
# 1. Find the sbom TaskRun (use the most recent if you've run several).
SBOM_TR=$(kubectl get taskrun -l tekton.dev/pipelineTask=sbom \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')

# 2. Find the chains payload annotation key (uid-suffixed) and decode.
ANN_KEY=$(kubectl get taskrun "$SBOM_TR" -o json \
  | jq -r '.metadata.annotations | keys[]' \
  | grep '^chains.tekton.dev/payload-taskrun-')

# Chains storage=tekton stores the raw in-toto Statement directly
# in the annotation (no DSSE wrapper) — single base64 decode gets
# you the Statement JSON.
kubectl get taskrun "$SBOM_TR" -o json \
  | jq -r ".metadata.annotations.\"$ANN_KEY\"" \
  | base64 -d > /tmp/att.json

# 3. Inspect the SBOM byproduct — it lands at
#    .predicate.runDetails.byproducts[] with name suffix
#    `/sbom-ARTIFACT_OUTPUTS`. The `content` field is the
#    base64-encoded Result value.
jq '.predicate.runDetails.byproducts[]
    | select(.name | endswith("/sbom-ARTIFACT_OUTPUTS"))' /tmp/att.json
jq -r '.predicate.runDetails.byproducts[]
       | select(.name | endswith("/sbom-ARTIFACT_OUTPUTS"))
       | .content' /tmp/att.json \
  | base64 -d | jq .
# -> {"uri":"workspace://sbom/sbom.spdx.json","digest":"sha256:...","isBuildArtifact":"false"}

# 4. The same uri + digest are also in the TaskRun's Results.
kubectl get taskrun "$SBOM_TR" \
  -o jsonpath='{.status.results}' \
  | jq '.[] | select(.name == "sbom-ARTIFACT_OUTPUTS")'
```

The byproduct `uri` is a `workspace://` URL while we're in dev (storage
= tekton, no OCI registry). In Sepia (OCI mode, deferred) the SBOM is
pushed as an [OCI referrer](https://github.com/opencontainers/distribution-spec/blob/main/spec.md#listing-referrers)
alongside the image via `cosign attach sbom` and the byproduct entry
becomes a registry reference; the `content` shape (uri + digest) is
unchanged.

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
# compare against the .digest field of the
# .predicate.runDetails.byproducts[] entry decoded above
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

The `SBOM` section above covers the **container image** path: one
image subject, one SPDX-JSON SBOM, surfaced via Chains type-hint
Results AND attached as an OCI referrer by `cosign attach sbom` (see
[Container SBOM attachment via `cosign attach sbom`](#container-sbom-attachment-via-cosign-attach-sbom)
below). For **packages** (`.deb`, `.rpm`) the same Chains plumbing
is reused but with three deliberate differences:

1. **One SBOM per artifact** — a single `build-package` TaskRun (#16)
   can emit a handful of `.deb`s and a handful of `.rpm`s. Each one
   gets its own CycloneDX SBOM and its own subject in the
   attestation.
2. **CycloneDX-JSON, not SPDX-JSON** — see "Why CycloneDX (for
   packages)" below.
3. **S3 storage, not OCI referrers** — packages don't live in a
   registry, so the SBOM lives next to the `.deb` / `.rpm` in the
   build-output S3 prefix. `cosign attach sbom` doesn't apply.

The `generate-sbom` Task (`tasks/generate-sbom/task.yaml`) is the
mechanism. It ships standalone today and gets `runAfter`'d by the
real package pipeline once #16 lands.

### Why CycloneDX (for packages)

Format choice is a **consumer-fit** decision. We picked the split
because:

| | SPDX 2.3 JSON | CycloneDX 1.6 JSON |
|---|---|---|
| Best for | Compliance / license inventories | Dependency graphs + vuln correlation |
| Native dependency edges | flat `relationships[]` | first-class `dependencies[]` tree |
| Ecosystem fit | M-22-18/M-23-16 federal asks, ISO/IEC 5962 | OWASP Dependency-Track, GitHub Dependency Graph, Snyk, Grype |
| Per-package SBOM ergonomics | works; verbose | tighter — components + deps grouped per pkg |
| What ceph consumers actually run | image-pull verifiers, fed-procurement audits | `grype <sbom.cdx.json>` against the vuln DB (#51) |

For container images the consumer is "fed procurement / `cosign
download sbom`" → SPDX wins. For packages the consumer is "Grype +
Dependency-Track correlating CVEs against the deb / rpm payload" →
CycloneDX wins. Containers get their mediaType from the cosign-attach
referrer manifest; packages convey it via the `.cdx.json` filename
extension recorded in the signed `IMAGES` / `SBOM_IMAGES` /
`sbom-ARTIFACT_OUTPUTS` subjects.

### The Chains-valid type-hint grammar `generate-sbom` emits

Chains 0.26 supports a fixed type-hint set (documented in
[`tektoncd/chains/docs/slsa-provenance.md`](https://github.com/tektoncd/chains/blob/v0.26.0/docs/slsa-provenance.md#output-artifacts)):
`*IMAGE_URL` / `*IMAGE_DIGEST`, `IMAGES`, `*ARTIFACT_URI` /
`*ARTIFACT_DIGEST`, and `*ARTIFACT_OUTPUTS` (object with `uri`,
`digest`, `isBuildArtifact` — **no** `mediaType`, **no** nested
`sbom`). The `generate-sbom` Task surfaces exactly the subset Chains
will sign:

| Result name | Shape | What Chains does with it |
| --- | --- | --- |
| `IMAGES` | newline-separated `<artifact-url>@sha256:<digest>` pairs | Promotes each pair to a separate subject in the SLSA attestation. Works on every Chains version since 0.13. |
| `SBOM_IMAGES` | newline-separated `<sbom-url>@sha256:<digest>` pairs, one per per-artifact SBOM file | Same Chains grammar as `IMAGES`; distinct Result name lets verifier tooling separate artifact subjects from SBOM subjects on the attestation subject list. |
| `sbom-ARTIFACT_OUTPUTS` | object `{uri, digest, isBuildArtifact: "false"}` for the rollup SBOM file | Lifts into `predicate.runDetails.byproducts[]` of the slsa/v2alpha4 attestation (same shape as the existing `sbom-ARTIFACT_OUTPUTS` Result on `pipelines/chains-smoke-test.yaml`'s sbom step). |

> Earlier revisions of this Task (the original #50 shape) declared
> three additional Result names — `SBOM_NAMES`, `SBOM_COUNT`,
> `SBOM_MEDIATYPE` — and packed an `ARTIFACT_OUTPUTS` value with a
> nested `sbom: {uri, digest, mediaType}` block. None of those are
> part of the Chains 0.26 grammar; Chains silently ignored them.
> Issue [#55](https://github.com/mmgaggle/ceph-tekton/issues/55)
> removed them and re-shaped the Task onto the Chains-valid grammar
> above.

Chains' deep-inspection
(`artifacts.pipelinerun.enable-deep-inspection: "true"` ConfigMap
flag) walks the PipelineRun's child TaskRuns, pulls the
`IMAGES` + `SBOM_IMAGES` Results, and rolls up one attestation with
**2N subjects** for an N-package build (N artifacts + N SBOMs), plus
one `byproducts[]` entry for the rollup SBOM.

### Extracting a specific package's SBOM from an attestation

The attestation lives on the PipelineRun (deep-inspection rolls up
child TaskRun Results). The signed subject list carries both the
package URIs and the SBOM URIs; filter by the `.cdx.json` suffix to
get the SBOMs:

```sh
# 1. Pull the PipelineRun-level attestation.
PR=$(tkn pipelinerun list --output=name | grep -m1 sbom-pkg-smoke-test)
kubectl get "$PR" \
  -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/payload-pipelinerun-[a-z0-9-]+}' \
  | base64 -d \
  | jq -r '.payload | @base64d | fromjson' > /tmp/att.json

# 2. List every SBOM subject in the attestation (URI ends in .cdx.json).
jq '.subject[] | select(.name | endswith(".cdx.json"))' /tmp/att.json

# 3. List the rollup SBOM byproduct (under runDetails.byproducts[]).
jq '.predicate.runDetails.byproducts[]
    | select(.uri | endswith(".cdx.json"))' \
  /tmp/att.json

# 4. Fetch the SBOM and re-parse it. The S3 layout is
#    s3://<bucket>/<branch>/<sha>/<distro>/<arch>/sboms/<basename>.cdx.json
aws s3 cp \
  s3://ceph-artifacts-branch/main/<sha>/centos10/x86_64/sboms/ceph-mds_19.2.0_arm64.deb.cdx.json \
  /tmp/
syft scan cyclonedx-json:/tmp/ceph-mds_19.2.0_arm64.deb.cdx.json -o table

# 5. Confirm the SBOM bytes match the digest the attestation signed.
sha256sum /tmp/ceph-mds_19.2.0_arm64.deb.cdx.json
# -> must match the sha256 next to that URI in step 2 / step 3 output.
```

The Chains-signed `sha256` of the SBOM file is the integrity binding
— if `sha256sum` of the downloaded file doesn't match, the SBOM is
not the one this build produced.

### Container SBOM attachment via `cosign attach sbom`

For container images the per-build SBOM has a SECOND distribution
path on top of the Chains attestation: the `attach-sbom` Task
(`tasks/attach-sbom/task.yaml`) runs

```text
cosign attach sbom \
  --sbom /workspace/sboms/<file>.cdx.json \
  --type cyclonedx \
  <repo>@sha256:<digest>
```

against the built image's OCI registry. The SBOM lands as a cosign
referrer carrying its mediaType (`application/vnd.cyclonedx+json`)
natively in the referrer manifest, discoverable via

```sh
cosign download sbom <repo>@sha256:<digest>
```

This closes the M-22-18 §4(e) / CIS SSC §3 "mediaType embedded in
the attestation surface" gap the original #50 design missed without
inventing a Chains-grammar extension. The Task takes the image
reference BY DIGEST (not tag) so the SBOM is unambiguously bound to
the exact image bytes; the `precheck` step rejects tag-only refs.

> **Why `cosign attach sbom` and not
> `cosign attest --predicate <file> --type spdxjson`:**
> `cosign attach sbom` writes the SBOM as an OCI referrer with the
> right mediaType, round-tripping via `cosign download sbom`. That's
> the consumer flow `anchore`, GitHub container provenance, and
> Sigstore docs are built around. `cosign attest --predicate` would
> wrap the SBOM in an in-toto Statement — a different signed claim,
> useful when a verifier needs the SBOM inside an in-toto envelope,
> but NOT what `cosign download sbom` looks for. We picked attach
> because Chains' own slsa/v2alpha4 attestation already wraps the
> SBOM URI + content digest as a signed byproduct (the
> `sbom-ARTIFACT_OUTPUTS` Result above), so the cryptographic
> binding is covered; what attach adds is the in-registry mediaType-
> typed referrer that the standard SBOM-discovery tooling reads.
> `cosign attach sbom` is marked "deprecated" in cosign 2.x release
> notes only for the legacy `.sbom`-tag fallback path; against a
> registry advertising the OCI 1.1 referrers API (Quay does), the
> command writes a modern referrer and works through at least
> cosign v2.4.x.

Packages do NOT use the cosign-attach path — there is no OCI
registry for `.deb` / `.rpm`. They keep the S3-sibling + signed-
byproduct convention above, and the file extension on the
`SBOM_IMAGES` / `sbom-ARTIFACT_OUTPUTS.uri` values (`*.cdx.json`)
conveys the mediaType.

### Per-package SLSA attestations as S3 siblings (#27)

The Chains SLSA attestation that signs each `build-package`
PipelineRun is exposed by the Chains controller on the PipelineRun
itself as

```
metadata.annotations:
  chains.tekton.dev/payload-pipelinerun-<uid>:  <base64 in-toto Statement>
  chains.tekton.dev/signature-pipelinerun-<uid>: <base64 DSSE envelope>
```

with `artifacts.pipelinerun.enable-deep-inspection: "true"` rolling
every child TaskRun's `IMAGES` Results up into one PipelineRun-level
Statement whose `subject[]` lists every `.deb` / `.rpm` the matrix
produced (one entry per `<uri>@sha256:<digest>` line).

The `publish-repo` Task (deferred — lands alongside the
`build-package` Task in the package-build pipeline slice) reads
that annotation off its own enclosing PipelineRun and writes one
`.intoto.jsonl` sibling object per artifact next to the package in
S3:

```
s3://ceph-artifacts-<class>/<branch>/<sha>/<distro>/<arch>/
├── ceph-mds_19.2.0_arm64.deb               <- build-package
├── ceph-common_19.2.0_arm64.deb            <- build-package
├── ...
├── sboms/
│   ├── ceph-mds_19.2.0_arm64.deb.cdx.json
│   └── ceph-common_19.2.0_arm64.deb.cdx.json
└── attestations/
    ├── ceph-mds_19.2.0_arm64.deb.intoto.jsonl     <- publish-repo (this slice)
    └── ceph-common_19.2.0_arm64.deb.intoto.jsonl  <- publish-repo (this slice)
```

The path `<branch>/<sha>/<distro>/<arch>/attestations/<package>.intoto.jsonl`
matches issue #27's "Stored as sibling objects" AC verbatim. One
attestation per package; the publish-repo Task splits the
PipelineRun-level Statement (N subjects) into N single-subject
Statements before upload so each `.deb` / `.rpm` has a self-
contained in-toto file that `cosign verify-blob-attestation` (the
#28 verifier path) can validate independently.

The Chains config that produces the upstream PipelineRun
annotation is in **`kustomize/overlays/sepia/tektonconfig-pruner.yaml`**
under `spec.chain.*`: SLSA v1.0 (`slsa/v2alpha4`), Fulcio keyless
signing (cluster SA-token OIDC → short-lived X.509 cert), public
Rekor transparency. The block is the operator pass-through to the
`chains-config` ConfigMap — same keys as the dev install's
`kustomize/base/tekton-chains/chains-config.patch.yaml`, with
`signers.x509.fulcio.enabled` flipped to `"true"` for Sepia.

Why not configure Chains to write directly to S3: Chains 0.26
ships a `gcs` file-storage backend and no `s3` backend; using
`gcs` here would couple Sepia to Google infrastructure (the whole
point of running on Sepia Ceph S3 is to keep the build pipeline
on the same RGW). Keeping Chains at `storage=tekton` and letting
the publish-repo Task do the S3 PUT keeps Chains stateless and
keeps the S3 credential surface (STS OIDC role + RGW trust
policy) co-located with every other publish-repo upload.

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
# Issue #68: single-resource files. Apply Tasks first, then the Pipeline.
kubectl apply -f tasks/generate-sbom/task.yaml
kubectl apply -f pipelines/tasks/sbom-pkg-smoke-seed.yaml
kubectl apply -f pipelines/tasks/sbom-pkg-smoke-assert.yaml
kubectl apply -f pipelines/pipelines/sbom-pkg-smoke-test.yaml
tkn pipeline start sbom-pkg-smoke-test \
  --workspace name=artifacts,emptyDir="" \
  --workspace name=sboms,emptyDir="" \
  --showlog
```

The pipeline:
- seeds two deterministic `.tar` files into the artifacts workspace,
- runs `generate-sbom` to produce one CycloneDX SBOM per artifact,
- runs `assert-results` to verify `IMAGES` has one
  `<url>@sha256:<hex>` line per seeded artifact, `SBOM_IMAGES` has
  one matching `*.cdx.json@sha256:<hex>` line per SBOM file, and the
  `sbom-ARTIFACT_OUTPUTS` object Result carries a well-formed
  `{uri, digest, isBuildArtifact=false}` triplet.

PipelineRun success = the Chains-valid type-hint contract is intact.

The container path (`cosign attach sbom`) is exercised separately:
`pipelines/chains-smoke-test.yaml` covers the image attestation, and
when an image build pipeline lands (#23, #26) it will `runAfter`
the build with the `attach-sbom` Task to push the SBOM into the
registry as a cosign referrer.

## Promoting to Fulcio keyless (Sepia)

The Sepia chain wiring lives on the operator-managed `TektonConfig`
at `kustomize/overlays/sepia/tektonconfig-pruner.yaml` under
`spec.chain.*` (issue #27). Versus the dev install above, the
Sepia block:

1. Flips `signers.x509.fulcio.enabled` to `"true"`.
2. Adds `signers.x509.fulcio.address: "https://fulcio.sigstore.dev"`.
3. Adds `signers.x509.fulcio.provider: "kubernetes"` so Chains
   uses the in-cluster SA-token convention (the alternative,
   `spiffe`, would require SPIRE).
4. Leaves `signers.x509.fulcio.issuer` unset so Fulcio reads the
   issuer URL from the SA token's `iss` claim — the cluster's
   `--service-account-issuer` value. A future overlay can pin
   it (e.g. for an air-gapped Fulcio) by adding the key.
5. Keeps `transparency.enabled: "true"` + `transparency.url:
   "https://rekor.sigstore.dev"` (same as dev).
6. Does NOT create `signing-secrets` — Fulcio mints per-run certs,
   so the dev cosign-key Secret has no Sepia analog.

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

## End-to-end verifier — `hack/verify-build.sh` (#28)

For the external-consumer flow ("I have a published Ceph artifact URL;
prove to me, using only public Sigstore infra, that Sepia signed it") the
project ships a single bash script:

```sh
hack/verify-build.sh \
  --certificate-identity \
    'https://kubernetes.default.svc.cluster.local/namespaces/sepia-pipelines/serviceaccounts/ceph-pipeline-sa' \
  --certificate-oidc-issuer \
    'https://kubernetes.default.svc' \
  <artifact-url>
```

`<artifact-url>` is either an OCI image reference (preferably by digest
— `quay.io/ceph/ceph@sha256:...`) or an HTTPS URL to a `.deb` / `.rpm`
package on the artifacts mirror. The script auto-detects which mode to
run from the URL suffix (`*.deb` / `*.rpm` → package, otherwise OCI);
the `--type IMAGE|PACKAGE` flag forces a choice when the suffix is
ambiguous.

### What it checks

Both modes assert the same chain — only the cosign sub-command
differs:

| Mode | cosign invocation | What it proves |
|---|---|---|
| IMAGE | `cosign verify` + `cosign verify-attestation --type slsaprovenance1` | The image carries (a) a Sigstore signature, (b) a SLSA Provenance v1.0 in-toto attestation; both signed by a Fulcio cert with the expected identity + OIDC issuer, with Rekor inclusion proof. |
| PACKAGE | `cosign verify-blob-attestation --type slsaprovenance1 --bundle <pkg>.intoto.jsonl <pkg>` | The package's sibling `.intoto.jsonl` (under `<prefix>/attestations/<basename>.intoto.jsonl`, the layout the "Per-package SLSA attestations as S3 siblings" section above documents) is a SLSA v1.0 in-toto Statement, signed by a Fulcio cert with the expected identity + OIDC issuer, with Rekor inclusion proof. |

Both modes additionally run `rekor-cli search --sha sha256:<hex>`
against the same Rekor instance to surface the transparency-log entry
to the operator log — the explicit "I can find this in Rekor"
demonstration the [#28](https://github.com/mmgaggle/ceph-tekton/issues/28)
AC calls out by name. cosign's own verify path already requires the
Rekor inclusion proof; the extra `rekor-cli search` step is
independent evidence using a different tool.

The `--type slsaprovenance1` alias is what cosign 2.x calls the SLSA
Provenance v1.0 predicate. The unsuffixed `slsaprovenance` alias is
SLSA v0.2 and would be rejected by cosign against a v1 payload — the
same predicate-type pin the in-cluster `verify-image-signature` Task
and `hack/e2e/lib.sh` use.

### External-consumer posture

The script's invariant is "runs on a machine with no Sepia network
access". Concretely:

- No `kubectl`. Cluster signing identity is supplied as a CLI flag (or
  env var `CEPH_VERIFY_BUILD_CERT_IDENTITY` /
  `CEPH_VERIFY_BUILD_CERT_OIDC_ISSUER`); the script never asks any
  cluster what it claims to be.
- No `aws s3` / no Sepia AWS creds. Artifacts must be reachable over
  HTTPS via the public artifacts mirror; `s3://` URLs are rejected
  with a helpful pointer to the HTTPS equivalent.
- Pure public Sigstore. `cosign verify` reaches Fulcio's
  TUF-distributed root + Rekor public-good
  (`https://rekor.sigstore.dev` by default; override with `--rekor-url`
  for a future in-Sepia Rekor instance).

### Prerequisites

```sh
brew install cosign rekor jq    # macOS
# or per-distro packages on Linux; curl is preinstalled everywhere.
```

That's the entire dependency surface — no Go toolchain, no kubectl,
no aws-cli.

### Why an "any-identity" mode is refused

The script hard-errors if neither `--certificate-identity` nor
`--certificate-identity-regexp` is set. Keyless verification's whole
point is binding the signature to a specific signer; an unconstrained
verify would accept any Fulcio-issued cert — including one for an
attacker's GitHub Actions workflow that ran `cosign sign` against the
same image. Forcing the operator to name the expected identity is the
explicit design choice that keeps "verified" meaningful.

### Verifying older / non-keyless artifacts

`hack/verify-build.sh` only handles the **keyless** path — it is the
end-to-end demonstration of the Sepia Fulcio+Rekor chain. For artifacts
produced by the **dev** install (keyed cosign signing, `signing-secrets`
Secret), use the in-cluster `verify-image-signature` Task or the
`cosign verify --key`-based snippet in the "Verify" section above.

## What's not in the dev install

The dev install intentionally cuts these corners — Sepia gets them via
overlays as their issues land:

- **OCI referrer storage** (#26). Dev uses `storage=tekton` (attestation
  as TaskRun annotation) so no writable registry is needed. Sepia flips
  to `storage=oci` and pushes to quay.io / in-cluster registry.
- **Per-arch container attestation in the manifest list** (#25 + #26).
  Multi-arch attestations follow once the buildah pipeline lands.
- **Package attestation in S3** (#27). The Chains-side wiring (SLSA
  v1.0 attestation per `build-package` PipelineRun, Fulcio keyless,
  public Rekor) ships on Sepia in `kustomize/overlays/sepia/tektonconfig-pruner.yaml`
  `spec.chain.*` — see the "Per-package SLSA attestations as S3
  siblings" section above. The S3 sibling `.intoto.jsonl` upload
  itself is part of the `publish-repo` Task and lands when that Task
  does (alongside `build-package`, #16-adjacent). Verification with
  `cosign verify-blob-attestation` ships as `hack/verify-build.sh`
  (#28); see the "End-to-end verifier" section above.
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

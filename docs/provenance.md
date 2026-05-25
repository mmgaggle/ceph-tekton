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

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
tkn pipeline start chains-smoke-test --showlog
```

The `chains-smoke-test` pipeline runs a trivial Task that emits
`IMAGE_URL` + `IMAGE_DIGEST` as Tekton Results. Chains observes the
completed TaskRun, generates an in-toto SLSA Provenance v1 attestation
describing the (claimed) artifact, signs it with the cosign key, and
posts the entry to public Rekor.

The image reference in the smoke test is intentionally fake — we want
to validate the Chains plumbing, not pay for a real build in dev. Real
container/package attestations land in the build pipelines (#10, #19,
#23). The same Chains config observes them all.

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

### Rekor upload fails behind a proxy

Public Rekor is at `rekor.sigstore.dev`. If your network blocks it, set
`transparency.enabled=false` in `chains-config` (loses the public
transparency property — only acceptable for offline dev).

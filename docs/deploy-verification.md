# Deploy-time signature verification — Kyverno

ceph-tekton publishes cosign-signed container images. This page is for
the **downstream consumer** — a cluster operator running ceph-csi or
ceph daemon containers — who wants to enforce, at admission time, that
no Ceph image runs on their cluster unless it carries a valid Sigstore
signature from the official Ceph build pipeline.

The enforcement layer is [Kyverno](https://kyverno.io)'s `verifyImages`
rule. The same rule shape works for both signing modes ceph-tekton
publishes — the dev kind cluster (cosign x509 key) and the Sepia
production cluster (Fulcio keyless) — so adopting the policy is one
`kubectl apply` regardless of which mode the producer is in this week.

For the upstream signing side of the loop, see
[`docs/provenance.md`](provenance.md). For the architectural decision
that picked Kyverno over OPA Gatekeeper, see the Decision Log in
[`docs/architecture.md`](architecture.md) (entry to be added when the
sepia overlay lands; phase 1 picks Kyverno for `verifyImages`-native
ergonomics and PolicyReport CRDs).

## What this policy enforces

For every Pod create or update whose `.spec.containers[].image` (init,
regular, or ephemeral) matches `quay.io/ceph/*`:

1. There MUST be a cosign signature attached to the image (as an OCI
   referrer in the registry).
2. That signature MUST verify against one of:
   - **dev policy:** the cosign public key in the
     `tekton-chains/signing-secrets` Secret on the consuming cluster
     (intended for dev clusters smoke-testing the same Chains key
     they're signing with).
   - **sepia policy:** a Fulcio-issued short-lived X.509 certificate
     whose SAN matches the OIDC identity
     `*/serviceaccount/ceph-pipeline-sa` issued by the Sepia
     OpenShift SA-token endpoint.
3. The signature's Rekor transparency-log entry MUST be retrievable
   from the public-good Rekor instance (`rekor.sigstore.dev`). If
   you've deployed a private Sigstore stack, point the `rekor.url`
   field at your TUF mirror.

If any of those conditions fail, Kyverno's admission webhook rejects
the Pod create with a message identifying the policy and the cosign
failure reason.

## What this policy does NOT enforce

The verify-ceph-image-signatures policies are intentionally narrow.
They give you signature integrity and identity binding. They do not
give you:

| Concern | Status | Tracking issue |
|---|---|---|
| **SBOM presence** — every image carries a CycloneDX/SPDX SBOM | Not enforced | #50 (Chains-side SBOM emission) |
| **Vulnerability scan freshness** — block on critical CVEs | Not enforced | #51 (Trivy/Grype scan attestation) |
| **Reproducible-build attestation** — image rebuildable from source | Not enforced | #48 (reproducible-builds workstream) |
| **Provenance content validation** — buildType, builder identity, source URI all match expected values | Not enforced (we only check the signature, not the predicate) | #49 (SLSA verifier wrap) |
| **Non-Ceph images** — sidecars, csi-provisioner, etc. | Not enforced | scope by design — extend per your org policy |
| **Already-running Pods** | Not enforced — admission-only | enable Kyverno background scan (`background: true`) for re-evaluation |

As the tracking issues land, the policies in `kustomize/base/kyverno-policies/`
gain additional rules in parallel — extend instead of replace, so the
signature gate keeps protecting you while the richer checks roll in.

## Adopting the policy on your own cluster

### 1. Install Kyverno

If you don't already run Kyverno:

```sh
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version 3.3.7
```

The chart's defaults are fine for evaluation. For production we
recommend the HA stance captured in `charts/kyverno/values-sepia.yaml`
in this repo: 3 replicas of every controller, `failurePolicy: Fail`,
PodDisruptionBudgets, anti-affinity. Copy that file and adjust the
namespace-exclusion list for your environment.

### 2. Apply the verification policy

For the Sepia-signed Ceph release images (Fulcio keyless), use the
sepia policy directly:

```sh
kubectl apply -f https://raw.githubusercontent.com/mmgaggle/ceph-tekton/main/kustomize/base/kyverno-policies/verify-ceph-image-signatures-sepia.yaml
```

Then label the namespaces where you want enforcement so the policy's
`preconditions` block matches:

```sh
kubectl label namespace <your-ceph-namespace> ceph-tekton.io/cluster=sepia
```

(Or vendor a copy of the policy into your repo and strip the
`preconditions` block to enforce everywhere — see "Trimming the
mutual-exclusion guard" below.)

If you're operating a *dev* cluster where you sign with a local
cosign key, use the dev policy instead and ensure the Secret it
references exists in your cluster:

```sh
kubectl apply -f https://raw.githubusercontent.com/mmgaggle/ceph-tekton/main/kustomize/base/kyverno-policies/verify-ceph-image-signatures-dev.yaml
```

### 3. Verify enforcement

Try to admit a known-unsigned image:

```sh
kubectl run unsigned-test --image=quay.io/ceph/ceph:smoke-test-deliberately-unsigned --dry-run=server
```

The expected output is a rejection from
`validation.kyverno.svc.cluster.local` mentioning cosign / signature
verification. The full smoke-test pipeline this repo ships at
`pipelines/kyverno-smoke-test.yaml` exercises both admit and reject
paths and asserts the rejection reason.

## Rolling out safely

Going straight to `validationFailureAction: Enforce` on a production
cluster can take down workloads that pull images you didn't realize
weren't signed. The recommended phasing:

1. **Audit mode** — apply the policy with `validationFailureAction: Audit`
   for one release cycle. Kyverno generates a `PolicyReport` per
   resource but doesn't block. Inspect them:
   ```sh
   kubectl get policyreport -A
   kubectl get clusterpolicyreport
   ```
2. **Triage findings** — for each unsigned image you see, decide:
   adopt the signed version, whitelist with a per-namespace
   exception (see below), or fix the producer's signing.
3. **Enforce** — flip to `validationFailureAction: Enforce` once
   the report is clean.

The same phasing applies whenever you add a new rule (SBOM, vuln
scan, ...) to the policy — never roll a new gate straight to enforce
in production.

## Extending the policy as more attestations land

When ceph-tekton starts emitting SBOM and scan attestations (#50, #51),
add `verifyImages` entries that require those attestations in addition
to the signature. The chained shape:

```yaml
verifyImages:
  - imageReferences: ["quay.io/ceph/*"]
    failureAction: Enforce
    attestors:
      - entries:
          - keyless:
              subjectRegExp: ".*/serviceaccount/ceph-pipeline-sa$"
              issuerRegExp: "https://.*\\.sepia\\.ceph\\.io.*"
    # NEW: require the SBOM attestation (issue #50)
    attestations:
      - type: https://cyclonedx.org/schema
        attestors:
          - entries:
              - keyless:
                  subjectRegExp: ".*/serviceaccount/ceph-pipeline-sa$"
                  issuerRegExp: "https://.*\\.sepia\\.ceph\\.io.*"
        conditions:
          - all:
              - key: "{{ components | length(@) }}"
                operator: GreaterThan
                value: 0
```

A policy with both `attestors` and `attestations` requires both: the
image signature *and* the (validly-signed) attestation. That lets you
incrementally raise the bar without ever loosening the existing
signature check.

For reproducible-build verification (#48), the same chained shape
takes an `attestations` entry of type `https://slsa.dev/provenance/v1`
plus a condition asserting `buildType` equals the expected ceph-tekton
build type URI.

## Common failure modes

### "no signatures found" on every Ceph image

Kyverno fetched the image but found no cosign signature OCI referrer.

- **Most likely cause:** the producer never signed the image. Confirm
  with `cosign verify --key cosign.pub quay.io/ceph/ceph:<tag>` from
  your laptop. If that fails too, the upstream Chains pipeline
  didn't run or failed silently — file an issue against
  `mmgaggle/ceph-tekton` with the image tag.
- **Less likely:** your cluster has no egress to `quay.io` or
  `rekor.sigstore.dev`. Kyverno's admission controller logs will say
  so — `kubectl -n kyverno logs -l app.kubernetes.io/component=admission-controller`.

### "signature verification failed" on what should be a signed image

Signature found, but didn't verify against the configured attestor.

- **dev policy:** the cosign public key in your
  `tekton-chains/signing-secrets` is NOT the same key the image was
  signed with. The dev policy is only useful when you're verifying
  artefacts your own Chains install produced; downstream consumers
  should use the sepia policy.
- **sepia policy:** the cert SAN / issuer don't match the regex.
  Inspect the offending signature:
  ```sh
  cosign download signature quay.io/ceph/ceph:<tag>
  cosign verify --certificate-identity-regexp '...' \
                --certificate-oidc-issuer-regexp '...' \
                quay.io/ceph/ceph:<tag>
  ```
  If your regex was overly narrow, widen it; if the producer's
  signing identity drifted, file an issue.

### Kyverno admission webhook is timing out

Symptom: Pod creates hang for ~30s then admit anyway (when
`failurePolicy: Ignore`) or fail with `webhook ... timeout` (when
`failurePolicy: Fail`).

- Check that Kyverno's egress to `quay.io` and `rekor.sigstore.dev` is
  fast. Fetching a signature + Rekor lookup adds up to seconds.
- Raise `admissionController.webhookTimeoutSeconds` to 30 (the
  cluster-wide max) and confirm fix.
- For high-traffic admission, enable Kyverno's image verification
  cache (default ttl 1h, see
  [Kyverno docs](https://kyverno.io/docs/writing-policies/verify-images/sigstore/#image-verification-cache)).

### A specific workload needs to ship with an unsigned image

You're running a downstream fork, doing a quick PoC, or pulling a
canary image that hasn't been signed yet.

The two safe ways to whitelist:

1. **Per-namespace exclusion.** Add the namespace to the policy's
   `exclude.any[].resources.namespaces` list. That suspends ALL
   image-signature checks for that namespace. Suitable for an
   isolated dev/test namespace, not for prod.
2. **Per-image exclusion via a higher-priority allow policy.** Write
   a sibling ClusterPolicy that *skips* verification for a narrow
   image glob, and let Kyverno's policy-merge skip the signature
   check for just that image. Suitable for a single canary image
   whose origin you've otherwise vetted out-of-band.

```yaml
# Example: skip verification for one canary tag, keep everything else enforced.
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: allow-canary-unsigned
spec:
  rules:
    - name: skip-canary
      match:
        any:
          - resources: { kinds: [Pod] }
      verifyImages:
        - imageReferences: ["quay.io/ceph/ceph:wip-canary-*"]
          failureAction: Audit  # do not enforce on this tag
          skipImageReferences:
            - "quay.io/ceph/ceph:wip-canary-*"
```

Document the exception in a comment with a sunset date so it doesn't
outlive its reason for existence.

### "Trimming the mutual-exclusion guard"

The policies in this repo each carry a `preconditions` block that
gates enforcement on a `ceph-tekton.io/cluster` label, so the dev
and sepia policies can ship side-by-side without ever fighting each
other. If you're vendoring just one of them into your own cluster
and want unconditional enforcement, drop the `preconditions:` block
entirely — the resulting policy enforces on every namespace it isn't
otherwise excluded from.

## Reference

- Kyverno verifyImages docs: <https://kyverno.io/docs/writing-policies/verify-images/sigstore/>
- Sigstore cosign: <https://docs.sigstore.dev/cosign/>
- ceph-tekton Chains config: [`docs/provenance.md`](provenance.md)
- This policy's chart pin + day-2 ops: [`charts/kyverno/README.md`](../charts/kyverno/README.md)
- Smoke-test pipeline: [`pipelines/kyverno-smoke-test.yaml`](../pipelines/kyverno-smoke-test.yaml)

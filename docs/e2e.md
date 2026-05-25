# End-to-end testing

ceph-tekton's CI gauntlet is the same harness a contributor runs against
their laptop kind cluster — no CI-only assertions, no laptop-only
shortcuts. This page covers running it, what each assertion checks,
and how to debug a failure.

The workflow definition is [`.github/workflows/e2e.yaml`](../.github/workflows/e2e.yaml);
the harness is under [`hack/e2e/`](../hack/e2e/).

## What runs

Per push to `main` or per PR (open / synchronize / reopened):

1. Bring up a single-node kind cluster from `hack/e2e/kind-config.yaml`.
2. `kubectl apply -k kustomize/overlays/dev-local/` — Tekton Pipelines.
3. `hack/dev-chains-setup.sh` — Tekton Chains + cosign keypair into
   `tekton-chains/signing-secrets`.
4. `hack/dev-vault-up.sh` — Vault helm install + transit engine +
   Kubernetes auth method + `ceph-test-signer` SA in `vault-test` ns.
5. `hack/dev-kyverno-up.sh` — Kyverno helm install + the
   `verify-ceph-image-signatures-dev` ClusterPolicy.
6. `bash hack/e2e/run-all.sh` — every assertion, in order, fail-fast.

A green run takes **15–20 minutes** on `ubuntu-latest`. The biggest
single cost is the helm wait on Vault's pod (~2 min cold) and the
syft image pull (~30 s). The actual assertion CPU work is sub-minute.

To opt a PR out of e2e (docs-only changes, etc.), put `[skip e2e]` in
the PR title. Pushes to `main` always run.

## Tool pins

All pinned in the workflow's `env:` block. Bump in a PR after running
the harness locally with the new version first.

| Tool         | Version    | Why this version                                          |
|--------------|------------|-----------------------------------------------------------|
| kind         | `v0.24.0`  | Last release before the cgroupv2 driver-check tightening. |
| kindest/node | `v1.31.0`  | k8s line Tekton v1.6.0 is tested against.                 |
| kubectl      | `v1.31.0`  | ±1 minor with the apiserver above.                        |
| helm         | `v3.15.4`  | Current stable; Vault and Kyverno charts require helm 3.  |
| tkn          | `0.39.1`   | Has `pipeline start --output=name` in the shape lib.sh expects (0.40 renamed it). |
| cosign       | `v2.4.1`   | 2.x is required for the verification flags we use.        |
| rekor-cli    | `v1.3.6`   | Matches the current public-good Rekor service line.       |
| syft         | `v1.18.0`  | Matches the syft image the smoke pipelines pin.           |
| Tekton Pipelines | `v1.6.0` | Pinned in `kustomize/base/tekton-pipelines/kustomization.yaml`. |
| Tekton Chains    | `v0.26.0` | Pinned in `kustomize/base/tekton-chains/kustomization.yaml`.    |
| Vault chart      | `0.28.1`  | Pinned in `hack/dev-vault-up.sh`.                         |
| Kyverno chart    | `3.3.7`   | Pinned in `hack/dev-kyverno-up.sh` (Kyverno v1.13.4).     |

## Running the harness locally

```sh
# 1. Bring up a dev cluster + every component.
make dev-up
make dev-chains-up
make dev-vault-up
make dev-kyverno-up

# 2. Run the full e2e gauntlet against the dev cluster.
#    By default it targets the `e2e` kind cluster; point it at your
#    dev cluster instead by overriding the context.
E2E_KIND_CLUSTER=ceph-tekton-dev \
E2E_KUBE_CONTEXT=kind-ceph-tekton-dev \
  bash hack/e2e/run-all.sh
```

Or run just one assertion (useful when iterating on a single component):

```sh
E2E_KUBE_CONTEXT=kind-ceph-tekton-dev \
  bash hack/e2e/assert-chains-smoke.sh
```

Skip slow assertions you don't care about right now:

```sh
E2E_KUBE_CONTEXT=kind-ceph-tekton-dev \
E2E_SKIP="vault-smoke reproducibility-smoke" \
  bash hack/e2e/run-all.sh
```

Captured failure artefacts land at `${E2E_ARTIFACTS}` (default:
`$TMPDIR/ceph-tekton-e2e-artifacts/`). In CI they're uploaded under
the artifact name `e2e-artifacts-<run-id>-<attempt>`.

## Environment variables

| Var                       | Default                                       | Used by      |
|---------------------------|-----------------------------------------------|--------------|
| `E2E_KIND_CLUSTER`        | `e2e`                                         | every script |
| `E2E_KUBE_CONTEXT`        | `kind-${E2E_KIND_CLUSTER}`                    | every script |
| `E2E_ARTIFACTS`           | `$TMPDIR/ceph-tekton-e2e-artifacts`           | every script |
| `E2E_PIPELINERUN_TIMEOUT` | `600s`                                        | wait helpers |
| `E2E_SKIP`                | (empty)                                       | run-all.sh   |
| `E2E_CONTINUE_ON_FAIL`    | `false` — stop at the first failed assertion  | run-all.sh   |
| `E2E_KYVERNO_STRICT_ADMIT`| `false` — see assert-kyverno-smoke.sh header   | assert-kyverno-smoke.sh |

## Per-assertion pass criteria

Read this section when a CI log says `[FAIL] assert-<name>` and you
need to know what the script was checking.

### `assert-hello-world.sh`

- `pipelines/hello-world.yaml` PipelineRun condition `Succeeded=True`
  within `E2E_PIPELINERUN_TIMEOUT`.
- The `greet` TaskRun's logs contain the substring
  `hello, ceph — from ceph-tekton`.

Likely causes of failure: Tekton Pipelines controller not Ready
(`make dev-up` didn't finish), Docker Hub rate-limit on
`docker.io/library/busybox`, hello.yaml's greeting text drifted.

### `assert-chains-smoke.sh`

- `pipelines/chains-smoke-test.yaml` PipelineRun reaches Succeeded.
- The `sbom` TaskRun gets a `chains.tekton.dev/payload-taskrun-*`
  annotation (the in-toto Statement) AND a sibling
  `chains.tekton.dev/signature-taskrun-*` annotation within ~120s of
  the TaskRun finishing.
- Decoded Statement's `predicateType == https://slsa.dev/provenance/v1`.
- Statement's `.subject[0].digest` equals the TaskRun's `IMAGE_DIGEST`
  Result value.
- `cosign verify-blob --key cosign.pub --signature <sig> <statement>`
  exits 0.
- `rekor-cli search --public-key cosign.pub --pki-format x509` returns
  ≥ 1 log index (retried 3× with backoff to handle Rekor transients).
- The Statement has a `predicate.runDetails.byproducts[]` entry whose
  name ends `/sbom-ARTIFACT_OUTPUTS`, with the documented shape
  (uri starts `workspace://`, digest starts `sha256:`,
  `isBuildArtifact == "false"`).

Likely causes of failure: `signing-secrets` missing
`cosign.{key,pub}` (re-run `make dev-chains-up`); chains controller
not picking up the ConfigMap (restart the deployment); Rekor
unreachable from CI (check `rekor.sigstore.dev` status); `sbom`
TaskRun didn't emit `IMAGE_DIGEST` (look at the TaskRun logs in the
captured artefacts).

### `assert-vault-smoke.sh`

- `pipelines/vault-smoke-test.yaml` PipelineRun reaches Succeeded,
  scheduled in `vault-test` ns with SA `ceph-test-signer`.
- The `sign` TaskRun's logs contain the terminal substring
  `OK: vault verified the signature`.

Likely causes of failure: `make dev-vault-up` didn't run (no
`vault-test` namespace); transit key not created; Vault k8s-auth
role bound to the wrong SA; the smoke pipeline running in the wrong
namespace (must be `vault-test`).

### `assert-kyverno-smoke.sh`

- `pipelines/kyverno-smoke-test.yaml` PipelineRun starts.
- HARD GATE: the `reject-unsigned-ceph` TaskRun reaches Succeeded AND
  its logs include a rejection message matching
  `cosign|signature|verify-ceph-image-signatures` (proves the rejection
  came from our ClusterPolicy, not from kubelet image-pull or a
  different admission controller).
- SOFT GATE: the `admit-signed-ceph` TaskRun reaches Succeeded with
  `OK: pod was admitted as expected`. This half is intentionally
  non-fatal by default — there is no real Chains-signed
  `quay.io/ceph/ceph` image whose signature the dev cosign.pub can
  verify until issue #25 lands. Override
  `E2E_KYVERNO_STRICT_ADMIT=true` once such an image exists.

Likely causes of failure: ClusterPolicy not Ready (`kubectl describe
clusterpolicy verify-ceph-image-signatures-dev`); the policy didn't
match the `quay.io/ceph/*` image glob (was a different
test image used?); rejection happened but for the wrong reason
(non-Kyverno admission controller blocked first).

### `assert-reproducibility-smoke.sh`

Runs `pipelines/reproducibility-check.yaml` twice against the
`tasks/reproducibility-check/examples/timestamps/` example targets:

- Run #1 (`make broken`): PipelineRun Succeeds with
  `pct_match < 100` (wall-clock `__DATE__`/`__TIME__` macros embed in
  the binary, so two builds one second apart MUST diverge).
- Run #2 (`make fixed`): PipelineRun Succeeds with `pct_match == 100`
  (`-D__DATE__=…`/`-D__TIME__=…` overrides driven by
  `SOURCE_DATE_EPOCH` make the build deterministic).

Likely causes of failure: `gcc:13-bookworm` image not pullable
(unlikely); broken target returning 100% match (the diff-counter is
broken — `pct_match` arithmetic regression in
`tasks/reproducibility-check/task.yaml`); fixed target returning <
100% (a real reproducibility regression — investigate the example or
the env-prep stanza).

### `assert-generate-sbom-smoke.sh`

- `pipelines/sbom-pkg-smoke-test.yaml` PipelineRun reaches Succeeded
  (the pipeline's own `assert-results` Task is what verifies the
  Chains-grammar Result shapes; we re-check the file half here).
- Each `<basename>.cdx.json` SBOM the `generate-sbom` Task wrote into
  the `sboms` workspace parses cleanly with
  `syft scan cyclonedx-json:<file>` (exit 0).

To get the SBOM files out of the cluster the script binds the `sboms`
workspace to an RWO PVC, then mounts that PVC into a one-shot busybox
pod and `kubectl exec`s a `cat` to stream the bytes to the test
runner. The PVC is cleaned up in a trap.

**Deliberately not asserted** by this smoke: "the SBOM file URI/digest
landed in the Chains attestation." Chains 0.26 does not consume the
`SBOM_NAMES` / `SBOM_COUNT` / `SBOM_MEDIATYPE` Results the
`generate-sbom` Task emits — see issue [#55](https://github.com/mmgaggle/ceph-tekton/issues/55)
for the rewrite onto `cosign attach sbom`. The e2e harness will get
an SBOM-in-attestation assertion when #55 ships.

Likely causes of failure: PVC unsatisfiable on the kind cluster (look
for `Pending` events on the PVC); syft format-detection broke (the
SBOM bytes won't round-trip — capture the file and run `syft scan`
manually).

## Failure artefact bundle

On any assertion failure the workflow uploads a directory containing:

```
e2e-artifacts/
├── pipelineruns/
│   └── <pipelinerun-name>/
│       ├── pipelinerun.yaml          # full PipelineRun object
│       ├── pipelinerun.describe.txt  # kubectl describe output
│       ├── taskrun-<n>.yaml          # full TaskRun object per Task
│       ├── taskrun-<n>.log           # tkn taskrun logs --all per Task
│       └── taskrun-<n>.attestation.json  # decoded Chains attestation
│                                         # (if storage=tekton wrote one)
├── cluster/
│   ├── pods.txt                      # kubectl get pods -A -o wide
│   ├── events.txt                    # kubectl get events -A sorted
│   ├── chains-controller.log         # tekton-chains controller tail
│   ├── pipelines-controller.log      # tekton-pipelines controller tail
│   ├── kyverno-admission.log         # kyverno admission controller tail
│   ├── vault-0.log                   # vault pod log
│   ├── helm-releases.txt             # helm list -A
│   └── describe-<ns>-<pod>.txt       # kubectl describe for every
│                                     # non-Running pod
├── cosign.pub                        # the dev cosign public key (so
│                                     # you can re-verify locally)
├── cosign-verify-blob-fail.txt       # cosign output when verification
│                                     # fails (chains smoke only)
├── rekor-search.txt                  # rekor-cli search output
├── sboms/
│   └── *.cdx.json + *.syft.err       # generate-sbom smoke files
└── hello-world-<tr>.log              # per-assertion captured logs
```

Download from the Actions run summary page → "Artifacts" section. The
GH Actions retention is set to 14 days.

## Re-running a single assertion locally

Every assertion is a standalone bash script. After bringing up your
dev cluster (or pointing at an existing one via `E2E_KUBE_CONTEXT`),
invoke one directly:

```sh
E2E_KUBE_CONTEXT=kind-ceph-tekton-dev \
  bash hack/e2e/assert-chains-smoke.sh
```

Each prints `[PASS]` / `[FAIL]` lines suitable for grep-driven
debugging.

## What this harness deliberately does NOT cover

- **PaC end-to-end** (#3 is installable but isn't bootstrapped in
  `make dev-*-up`; needs a GitHub App secret). Once the secret is in
  the dev overlay we'll add `assert-pac-noop.sh`.
- **SBOM in attestation** (covered in #55, not #54 — see the
  generate-sbom assertion header).
- **Multi-arch / aarch64**. The runner is single-arch (x86_64); the
  Sepia path will need its own e2e job.
- **Real package builds** (`dpkg-buildpackage`, `rpmbuild`). Those
  live in `build-package` (#16) and have their own smoke pipelines
  once the Task ships.

These are tracked in the issue backlog under the relevant component
issue, not here.

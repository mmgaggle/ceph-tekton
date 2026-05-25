# Running ceph-tekton locally

The Tekton manifests in this repo are designed to run on **Sepia OpenShift**
*and* on a contributor's laptop via **kind**. This page walks through the
laptop side: bootstrap a single-node kind cluster, install Tekton Pipelines
(plus, optionally, Pipelines-as-Code / Chains / Vault / Kyverno), and run
the smoke-test pipelines that exercise each component.

If you only want to read one section, read [Contribution flow](#contribution-flow)
— it links into the rest as you need it. If you already know the flow,
skip to the [Quick reference](#quick-reference) at the bottom.

## Contribution flow

A new contributor's dev loop, end to end:

### 1. Fork, clone, set upstream

```sh
# On GitHub: fork mmgaggle/ceph-tekton into your account.
git clone git@github.com:<your-handle>/ceph-tekton.git
cd ceph-tekton
git remote add upstream https://github.com/mmgaggle/ceph-tekton.git
git fetch upstream
```

Keep `main` tracking upstream; do your work on topic branches and rebase
on `upstream/main` before opening a PR.

### 2. Branch and commit conventions

- **Branch name:** `wip-<short-topic>` or `<issue-number>-<short-topic>`
  (e.g. `wip-chains-sbom`, `36-contrib-guide`). The leading `wip-` is
  the same convention `ceph/ceph` uses, and matches the dev artifact
  bucket's 30-day expiry rule.
- **Commit subject:** imperative mood, < 72 chars, prefixed with the
  area touched (`docs:`, `kustomize:`, `tasks/reproducibility-check:`,
  `chains-smoke-test:`, etc.). Look at `git log --oneline -20` for the
  in-repo style.
- **Commit body:** wrap at 72 columns, explain the *why*. Reference the
  issue (`closes #N` for the issue this PR resolves, `refs #N` for
  related work).
- **Assisted-by trailer:** if you used a coding assistant, end the
  commit message with the kernel-style trailer

  ```
  Assisted-by: <agent-name>:<model-version>
  ```

  (e.g. `Assisted-by: Claude:claude-opus-4-7`) — format per
  <https://docs.kernel.org/process/coding-assistants.html>. Don't add a
  `Co-Authored-By:` line for AI assistance, and don't add `Signed-off-by:`
  on the AI's behalf — only the human author DCO-signs.

### 3. Edit, validate, exercise

The cheap inner loop, in order of latency:

```sh
# (a) Render-only: catches kustomize/YAML errors without a cluster.
make kustomize-validate

# (b) Server-side dry-run against the dev cluster (needs make dev-up first).
make pipelines-validate

# (c) Spin up only the component(s) you touched and run its smoke test.
#     See the per-component sections below.
```

Pick the smallest cluster footprint that covers your change. If you're
editing a Task that only needs Tekton Pipelines, you don't need Vault or
Kyverno running.

### 4. Push: what CI will check

When you push to your fork and open a PR against `mmgaggle/ceph-tekton`,
the e2e workflow (`.github/workflows/e2e.yaml`, see issue #54) runs the
suite from `hack/e2e/` against a real kind cluster. It will:

- Bring up kind + Tekton Pipelines (`make dev-up`).
- Run `make dev-test` (hello-world Pipeline).
- Per component touched by your diff, bring it up and run its smoke
  pipeline — `chains-smoke-test`, `vault-smoke-test`,
  `kyverno-smoke-test`, `reproducibility-check`, `sbom-pkg-smoke-test`.
- Assert that each PipelineRun ends `Succeeded` and that the expected
  side effects landed (Rekor entry, signed-image admit + unsigned-image
  reject, transit signature, etc.).

Local fast iteration uses the same `make` targets and smoke pipelines —
nothing in CI is invisible from the laptop.

### 5. Open the PR

Use this body template (the project doesn't enforce a CODEOWNERS-driven
template yet, but reviewers expect this shape):

```markdown
Closes #<issue-number>.

<one-paragraph summary — what changed and why>

## Test plan

- [ ] `make kustomize-validate`
- [ ] `make dev-up && make dev-test`
- [ ] <per-component smoke commands you ran locally>
- [ ] <any manual assertion the e2e suite covers — list them so a
       reviewer can re-run by hand>
```

Don't add tool-attribution footers to the PR body or comments — keep
those in the commit `Assisted-by:` trailer only.

---

## Prerequisites

| Tool                       | Install (macOS / Linux)               |
|----------------------------|---------------------------------------|
| kubectl >= 1.30            | `brew install kubectl`                |
| kind >= 0.24               | `brew install kind`                   |
| tkn (Tekton CLI) >= 0.39   | `brew install tektoncd-cli`           |
| docker **or** podman       | `brew install --cask docker` *or* `brew install podman` |
| GNU make                   | preinstalled on macOS; `apt install make` on Debian/Ubuntu |
| helm >= 3.14               | `brew install helm` (for Vault + Kyverno) |
| cosign >= 2.2              | `brew install cosign` (for Chains)    |
| rekor-cli                  | `brew install rekor-cli` (for verifying attestations) |

The `make dev-up` target detects whether you have docker or podman and
sets `KIND_EXPERIMENTAL_PROVIDER=podman` automatically when needed. On
macOS with podman you also need `podman machine start` (the script will
attempt this for you).

If you work on multiple ceph-tekton checkouts in parallel, set
`KIND_CLUSTER_NAME=<unique>` so they don't collide on the default
`ceph-tekton-dev` name.

## Bootstrap (Tekton Pipelines only)

From the repo root:

```sh
make dev-up
```

This will:

1. Verify required tools are on `PATH`.
2. Create a single-node kind cluster named `ceph-tekton-dev` if one
   doesn't already exist.
3. Apply the `kustomize/overlays/dev-local/` overlay, which pulls in the
   pinned Tekton Pipelines release manifest.
4. Wait for the tekton-pipelines controller pod to report `Ready`.

The Tekton version is pinned via `TEKTON_PIPELINES_VERSION` in the top
level `Makefile`. Bump it in a PR after testing the new version against
the smoke-test pipeline.

## Smoke-test

```sh
make dev-test
```

Applies `pipelines/hello-world.yaml` (a single-Task `hello-world` Pipeline)
and starts it. `tkn` streams the TaskRun logs until completion. You should
see:

```
[greet : say-hello] hello, ceph — from ceph-tekton
```

The PipelineRun ends `Succeeded` and `kubectl -n default get pipelinerun`
lists it.

## Inspect

```sh
make dev-status          # cluster nodes + tekton-pipelines pods
tkn pipelinerun list     # all PipelineRuns
tkn pipelinerun logs -L  # tail the latest PipelineRun's logs
```

## Tear down

```sh
make dev-down            # deletes the kind cluster + everything in it
```

---

## Per-component dev loops

Each component layers onto the `make dev-up` baseline. Bring up only the
ones you're iterating on — they're independent except where noted.

### Tekton Pipelines

Already covered above (`make dev-up`, `make dev-test`). Debug with:

```sh
kubectl -n tekton-pipelines get pods
kubectl -n tekton-pipelines logs deploy/tekton-pipelines-controller
tkn pipelinerun describe <name>
tkn taskrun logs <name> -f
```

### Pipelines-as-Code

Full walkthrough: [`pipelines-as-code.md`](pipelines-as-code.md).

Three-bullet summary:

- `kubectl apply -k kustomize/base/pipelines-as-code/` installs the PaC
  controller, webhook, and watcher into the `pipelines-as-code` namespace.
- Webhook ingress in dev is via [smee.io](https://smee.io) — create a
  channel, forward it to your laptop with `smee -u <channel> -t http://localhost:8080`
  port-forwarded to the PaC controller Service. The doc walks through it.
- You need a **personal-fork-scoped GitHub App** (separate from the
  real `ceph/ceph` app, which is tracked in issue #9) — the doc covers
  how to create one in 5 minutes and wire its secrets into PaC.
- Smoke test: push a branch to your fork with
  `pipelines/noop-pull-request.yaml` referenced from `.tekton/`, open a
  PR, watch the PaC controller spawn a `noop-pull-request` PipelineRun.

Debug: `kubectl -n pipelines-as-code logs deploy/pipelines-as-code-controller`
plus the smee.io request log in your browser.

### Tekton Chains

Full walkthrough: [`provenance.md`](provenance.md).

Three-bullet summary:

- `make dev-chains-up` runs `hack/dev-chains-setup.sh`: installs Chains
  via `kustomize/base/tekton-chains/`, generates a cosign keypair into
  `tekton-chains/signing-secrets` (with `COSIGN_PASSWORD=""` — dev only),
  and restarts the Chains controller to pick up the key.
- Smoke test: `kubectl apply -f pipelines/chains-smoke-test.yaml &&
  tkn pipeline start chains-smoke-test --workspace name=sbom,emptyDir="" --showlog`
  builds a fake subject, runs syft for an SBOM byproduct, and Chains
  signs the resulting SLSA v1 attestation to public Rekor.
- Verify with `cosign verify-attestation --key k8s://tekton-chains/signing-secrets …`
  and `rekor-cli search` — see `provenance.md` for the full verification
  recipe.

Debug: `kubectl -n tekton-chains logs deploy/tekton-chains-controller`
and `kubectl -n tekton-chains get cm chains-config -o yaml` (the
strategic-merge patch ordering matters — see the troubleshooting matrix
below).

### Vault

Full walkthrough: [`vault.md`](vault.md).

Three-bullet summary:

- `make dev-vault-up` runs `hack/dev-vault-up.sh`: installs the
  `hashicorp/vault` chart in dev mode (root token literally `root`,
  storage in RAM), enables the transit secrets engine, creates an
  ed25519 key `ceph-test-key`, and wires Kubernetes auth so the
  `vault-test/ceph-test-signer` ServiceAccount can sign through it.
- Smoke test: `kubectl apply -f pipelines/vault-smoke-test.yaml &&
  tkn pipeline start vault-smoke-test --serviceaccount ceph-test-signer
  -n vault-test --showlog` — a pod authenticates with its projected SA
  token, signs a known payload via `transit/sign/ceph-test-key`, and
  asserts the response contains a signature.
- Real GPG-key import + publish-repo integration is issue #19 and not
  in this dev install yet.

Debug: `kubectl -n vault exec vault-0 -- vault status` and
`kubectl -n vault exec vault-0 -- vault read auth/kubernetes/role/ceph-test-signer`.
**Dev mode does not persist** — if `vault-0` restarts, re-run
`hack/dev-vault-up.sh`.

### Kyverno

Full walkthrough: [`deploy-verification.md`](deploy-verification.md).

Three-bullet summary:

- **Depends on Chains** — `hack/dev-kyverno-up.sh` checks that
  `tekton-chains/signing-secrets` has a `cosign.pub` field and aborts
  with a clear message if not. Run `make dev-chains-up` first.
- `make dev-kyverno-up` installs the `kyverno/kyverno` chart and applies
  the `verify-ceph-image-signatures-dev` ClusterPolicy, which requires
  every Pod with a `quay.io/ceph/*` image to carry a valid cosign
  signature from that same Chains key.
- Smoke test: `kubectl apply -f pipelines/kyverno-smoke-test.yaml &&
  tkn pipeline start kyverno-smoke-test --showlog` — one TaskRun pulls
  a signed image (admit expected), another pulls an unsigned image
  (reject expected). Confirm with `kubectl get policyreport -A`.

Debug: `kubectl describe clusterpolicy verify-ceph-image-signatures-dev`
and `kubectl -n kyverno logs deploy/kyverno-admission-controller`.

### Reproducibility check

Full walkthrough: [`reproducibility.md`](reproducibility.md).

Three-bullet summary:

- No extra cluster bootstrap needed — the `reproducibility-check` Task
  in `tasks/reproducibility-check/` runs on the baseline Tekton install
  from `make dev-up`.
- Iterate without Tekton at all using the synthetic examples under
  `tasks/reproducibility-check/examples/timestamps/`: `make demo-broken`
  prints two different sha256s (NON-REPRODUCIBLE), `make demo-fixed`
  prints two identical sha256s — on Linux. (macOS caveat in the
  troubleshooting matrix below.)
- For the Tekton path, point the Task's `build-command` and
  `output-glob` parameters at an example — see the snippet at the top
  of `tasks/reproducibility-check/examples/README.md`.

Debug: read the `pct_match` Result (size-weighted reproducibility
percentage) and the HTML diffoscope report on the workspace.

---

## Iterating on a Task

Edit a Task or Pipeline YAML under `tasks/` or `pipelines/`, then:

```sh
kubectl apply -f pipelines/<your-file>.yaml
tkn pipeline start <pipeline-name> --showlog
```

For the full PaC-driven loop (a personal fork of `ceph/ceph` whose
`.tekton/` PRs trigger your local Pipelines), see
[`pipelines-as-code.md`](pipelines-as-code.md).

---

## Troubleshooting matrix

| Symptom | Likely cause | First thing to check | Escalation |
|---|---|---|---|
| Tekton controller pod stuck in `ImagePullBackOff` | Pinned image tag was retagged upstream, or a registry path got mangled by a kustomize patch | `kubectl describe pod -n tekton-pipelines <pod>` — the events list the actual pull error | Bump `TEKTON_PIPELINES_VERSION` in the `Makefile` per the comments at the top of `kustomize/base/tekton-pipelines/kustomization.yaml`, re-run `make dev-up` |
| `make dev-up` fails to start podman machine | First-time podman use on macOS, VM not initialized | `podman machine list` | `podman machine init && podman machine start`, re-run `make dev-up` |
| `cosign generate-key-pair` fails interactively asking for a passphrase | `dev-chains-setup.sh` was bypassed and run by hand without `COSIGN_PASSWORD=""` | Re-run the script: `make dev-chains-up` | If you need to run the cosign command yourself, prefix it with `COSIGN_PASSWORD=""` |
| Chains controller never produces an attestation | `chains-config` ConfigMap keys not applied — strategic-merge patch ordering ate them | `kubectl get cm -n tekton-chains chains-config -o jsonpath='{.data}'` and confirm `artifacts.taskrun.format=slsa/v2alpha4`, `artifacts.taskrun.storage=tekton`, `transparency.enabled=true` are present | See `provenance.md` "Chains controller never produces an attestation" — usually fixed by re-applying the base then restarting the controller |
| `make demo-fixed` on macOS reports `NON-REPRODUCIBLE` | ld64 stamps a random `LC_UUID` Mach-O load command that doesn't honour `SOURCE_DATE_EPOCH` — macOS-only | Run inside a Linux container: `podman run --rm -v "$(pwd)":/work -w /work docker.io/library/gcc:13-bookworm make demo-fixed` | Already documented in `tasks/reproducibility-check/examples/README.md` |
| Vault sealed (or `transit/` paths return 503) after a pod restart | Dev mode stores keys in RAM and does NOT persist across restarts | `kubectl -n vault exec vault-0 -- vault status` shows `Sealed: true` (or the pod restarted recently) | Re-run `hack/dev-vault-up.sh` — it's idempotent and re-bootstraps everything |
| kind cluster name collisions between repos | Multiple ceph-tekton checkouts all default to `ceph-tekton-dev` | `kind get clusters` lists conflicting entries | Set `KIND_CLUSTER_NAME=<unique>` in the env (or in the make invocation) before `make dev-up` |
| Kyverno admission rejects everything with "no signatures found" on Ceph images | Either Chains hasn't signed anything yet, OR the cosign public key Kyverno is checking against doesn't match the one that signed the image | `kubectl get policyreport -A` shows the rejection reason; `cosign verify --key <pub> <image>` reproduces it out-of-cluster | See `deploy-verification.md` "Common failure modes"; usually fixed by re-running `make dev-chains-up` then `make dev-kyverno-up` so both sides use the same key |
| PaC controller crash-looping right after `kubectl apply` | The GitHub App secret hasn't been created yet — controller can't start without it | `kubectl -n pipelines-as-code logs deploy/pipelines-as-code-controller` | Create the App + secret per `pipelines-as-code.md` "Wire the GitHub App to PaC" before applying the overlay |

---

## Quick reference

### Make targets

| Target | What it does | Doc |
|---|---|---|
| `make help` | List all targets with descriptions | — |
| `make dev-up` | Create kind cluster + install Tekton Pipelines | this doc |
| `make dev-down` | Delete the kind cluster | this doc |
| `make dev-status` | Show cluster + Tekton install status | this doc |
| `make dev-test` | Run the hello-world Pipeline and stream logs | this doc |
| `make dev-chains-up` | Install Tekton Chains + bootstrap cosign signing keys | [`provenance.md`](provenance.md) |
| `make dev-vault-up` | Install Vault (helm) + enable transit + k8s auth | [`vault.md`](vault.md) |
| `make dev-kyverno-up` | Install Kyverno (helm) + apply ceph-image-signature ClusterPolicy | [`deploy-verification.md`](deploy-verification.md) |
| `make kustomize-validate` | Render every kustomize overlay (no apply) | this doc |
| `make pipelines-validate` | Server-side dry-run of pipeline manifests against the dev cluster | this doc |

### `hack/` scripts (invoked by the targets above)

| Script | Purpose | Doc |
|---|---|---|
| `hack/dev-up.sh` | Create kind cluster + install Tekton Pipelines | this doc |
| `hack/dev-test.sh` | Apply + start `hello-world` PipelineRun | this doc |
| `hack/dev-chains-setup.sh` | Install Chains + generate cosign keypair | [`provenance.md`](provenance.md) |
| `hack/dev-vault-up.sh` | Install Vault + enable transit + k8s auth | [`vault.md`](vault.md) |
| `hack/dev-kyverno-up.sh` | Install Kyverno + apply ClusterPolicies | [`deploy-verification.md`](deploy-verification.md) |

### Smoke pipelines

| Pipeline | What it exercises | Doc |
|---|---|---|
| `pipelines/hello-world.yaml` | Tekton Pipelines baseline | this doc |
| `pipelines/noop-pull-request.yaml` | Pipelines-as-Code resolution + run | [`pipelines-as-code.md`](pipelines-as-code.md) |
| `pipelines/chains-smoke-test.yaml` | Chains signing + Rekor + SBOM byproduct | [`provenance.md`](provenance.md) |
| `pipelines/vault-smoke-test.yaml` | Vault transit signing via k8s auth | [`vault.md`](vault.md) |
| `pipelines/kyverno-smoke-test.yaml` | Signed-image admit, unsigned-image reject | [`deploy-verification.md`](deploy-verification.md) |
| `pipelines/reproducibility-check.yaml` | SOURCE_DATE_EPOCH + diffoscope, % match metric | [`reproducibility.md`](reproducibility.md) |
| `pipelines/sbom-pkg-smoke-test.yaml` | Per-package CycloneDX SBOM generation | [`provenance.md`](provenance.md) |

### Per-component docs

- [`architecture.md`](architecture.md) — system overview + Decision Log
- [`pipelines-as-code.md`](pipelines-as-code.md) — PaC install + GitHub App
- [`provenance.md`](provenance.md) — Chains + SLSA + Sigstore
- [`vault.md`](vault.md) — transit signing
- [`deploy-verification.md`](deploy-verification.md) — Kyverno
- [`reproducibility.md`](reproducibility.md) — SOURCE_DATE_EPOCH harness
- [`reproducibility-status.md`](reproducibility-status.md) — current % match + work log

---

## What's in (and not in) the dev cluster

`make dev-up` installs **only Tekton Pipelines**. Each other component is
opt-in via its own `make dev-*-up` target so contributors who don't need
it don't pay the install cost:

| Component | Bootstrap | Optional / dependencies |
|---|---|---|
| Tekton Pipelines | `make dev-up` | required baseline |
| Pipelines-as-Code | `kubectl apply -k kustomize/base/pipelines-as-code/` | needs a GitHub App secret first (see [`pipelines-as-code.md`](pipelines-as-code.md)) |
| Tekton Chains | `make dev-chains-up` | independent |
| Vault | `make dev-vault-up` | independent |
| Kyverno | `make dev-kyverno-up` | depends on Chains (uses its cosign public key) |

Phase-1 items still pending a dev-cluster on-ramp:

- `ceph-builds-api` (#29) — shaman API shim
- Real GPG key import for Vault publish-repo signing (#19)
- Real-cluster e2e harness in CI (#54)

Each lands as its issue closes. Until then, the laptop cluster is
intentionally minimal — enough to develop and unit-smoke every Task and
Pipeline, not a full production replica.

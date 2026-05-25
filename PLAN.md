# ceph-tekton — Plan

A Tekton-based replacement for the Ceph upstream build infrastructure
(`jenkins` + `chacra` + `shaman`), with SLSA provenance via Tekton Chains.

This document is the design + delivery plan. It is the source of truth for
breaking work into issues.

---

## Goals

- **Replace** jenkins (build executor), chacra (artifact server), and shaman
  (metadata/UI/lookup API) for the `ceph/ceph` repo.
- **Provenance:** SLSA v1.0 attestations for every package and container,
  signed via Sigstore keyless (Fulcio), logged to Rekor.
- **Portable:** the same Tekton manifests run on Sepia OpenShift *and* on a
  contributor's local k3s/kind cluster. No OpenShift-only CRDs in `base/`.
- **Parity from day one** with the existing trigger model, matrix, and
  teuthology consumption pattern — this is a production replacement, not a
  POC.

## Non-goals (phase 1)

- Adjacent jenkins jobs (`ceph-csi`, dashboard, docs, teuthology infra) — phase 2.
- Helm-based operator wrapping the stack (`CephCIPlatform` CRD via
  operator-sdk helm mode) — phase 2.
- Crossplane providers for out-of-cluster state — phase 2.
- Argo CD reconciliation — phase 2 (helm charts and kustomize bases stay
  clean enough to be consumed by Argo later).
- External Secrets Operator sync — phase 2.
- Make check sharding (per-component or by ctest label) — only if single-pod
  p95 becomes a pain point.

---

## Architecture

### Platform

| Concern | Decision |
| --- | --- |
| Tekton cluster | OpenShift in Sepia, co-located with the Ceph cluster providing S3 |
| Portability | Same manifests run on k3s/kind via kustomize overlays (`overlays/sepia/`, `overlays/dev-local/`, `overlays/dev-kind/`) |
| Bootstrap | `make` + `helm` (in-cluster) + `terraform` (out-of-cluster) |
| Continuous reconciliation | None in phase 1; helm charts kept Argo-CD-ready for phase 2 |

### Artifact storage (chacra replacement)

- **S3 on Sepia Ceph RGW**, terraform-managed.
- Three buckets by lifecycle class:
  - `ceph-artifacts-dev` — wip-* branches, 30d expiry, no object-lock
  - `ceph-artifacts-branch` — main + release branches, keep latest 20 per
    `(branch, distro, arch)` + 180d ceiling
  - `ceph-artifacts-release` — tags, **object-lock governance mode**, 7-year
    retention
- **No long-lived S3 credentials.** Terraform registers the OpenShift SA
  token issuer as an OIDC provider on RGW, defines per-bucket roles, and
  build pods get short-lived creds via `AssumeRoleWithWebIdentity` using
  projected SA tokens.
- URL convention:
  `https://artifacts.ceph.com/<bucket>/<branch>/<sha>/<distro>/<arch>/`
- Atomic `<branch>/latest` prefix pointer updated per successful build.

### Triggers (shaman parity)

| Event | Pipeline |
| --- | --- |
| PR push (from fork or org) | `make check` matrix (gating) |
| Push to ceph/ceph branch (`main`, release branches, `wip-*`) | Full package matrix + container build |
| Tag | Release-channel package + container build → `ceph-artifacts-release` |

PRs from forks do **not** trigger package builds — mirrors today's wip-*
convention where org members push to a wip- branch to get teuthology-
installable packages.

### Build matrix

- **Arches:** x86_64, aarch64 — both on native arch worker nodes, no qemu.
- **Distros:** CentOS Stream 9, CentOS Stream 10, Ubuntu 22.04 (jammy),
  Ubuntu 24.04 (noble), Fedora rawhide (non-gating).
- **Per-branch matrix** lives in `matrix.yaml` at the source ref — reef's
  matrix differs from main's. A `compute-matrix` Task reads it and emits a
  JSON array as a Tekton Result; downstream `build` and `publish` tasks fan
  out via Tekton native `matrix:`.

### Build mechanics

- **Pre-baked builder images** per `(distro, arch)`: `ceph-builder:centos10-x86_64`,
  etc. Built by a dedicated `builder-images` pipeline that rebuilds nightly
  and on `install-deps.sh` changes. Pushed to the in-cluster registry.
- Build tasks run `dpkg-buildpackage` (DEB) / `rpmbuild` (RPM) directly
  inside the builder image — no mock/pbuilder layer.
- **ccache** via `sccache` with S3 backend (better Tekton ergonomics than
  native ccache S3). Cache namespace per `(branch, distro, arch)`. Branch
  builds fill, wip-* and PR builds reuse.

### Repo metadata + signing

- **Dedicated `publish-repo` task per `(distro, arch)`**, runs after build:
  uploads raw packages to a staging prefix, runs `createrepo_c` (RPM) or
  `reprepro` (DEB) in a distro-native container, atomically swaps staging→live.
- **GPG signing** of repodata/Release files: the GPG key lives in
  **Vault's transit engine** and *never leaves Vault*. The publish task
  calls Vault's sign API. Defense in depth — even a compromised publish pod
  cannot exfiltrate the key.

### Container images (daemon)

- **Buildah**, one build per arch on the native arch worker (avoids qemu's
  10× slowdown).
- Two parallel tasks (`build-image-x86_64`, `build-image-aarch64`), final
  `manifest-assemble` task pushes the multi-arch index.
- Published to `quay.io/ceph/ceph` — keeps existing user `podman pull` URLs
  working.

### Container registries

- **In-cluster registry** for builder images (high pull volume, no public
  bandwidth, no creds-leak risk).
- **quay.io** for published daemon images (existing consumer URLs, free for
  OSS, OCI referrers for Chains attestations).

### Tekton Chains (provenance)

| Concern | Decision |
| --- | --- |
| Attestation format | SLSA Provenance v1.0 (in-toto) |
| Container storage | OCI referrers in the destination registry |
| Package storage | Sibling `<sha>.intoto.jsonl` objects in S3 |
| Transparency log | Sigstore public-good Rekor |
| Signing | **Fulcio keyless** — per-PipelineRun SA OIDC → Fulcio short-lived cert → cosign → Rekor |
| Dev k3s overlay | Swaps Fulcio for an in-cluster cosign key |

Identity-bound provenance: a third party can verify "built by SA
`ceph-pipeline-sa` in namespace `sepia-pipelines` at `<time>`" with no
long-lived signing key to manage or rotate.

### GitHub integration

- **Pipelines-as-Code (PaC)** — ships with OpenShift Pipelines, installable
  on vanilla k8s/k3s.
- GitHub App for auth (one app, scoped permissions).
- Posts rich GitHub Checks; supports `/test`, `/retest` PR comments.
- **Phase 1:** PaC files live in `ceph-tekton/pipelines/`, remote-resolved
  by PaC. Lets us iterate without ceph/ceph review cycles.
- **Phase 2:** move PaC files to `ceph/ceph/.tekton/` so CI changes flow
  through code review alongside the code that needs them.

### Shaman replacement

- **Human UI:** PaC GitHub Checks (per-PR/branch) + Tekton Dashboard (ops view).
- **Machine API:** small Go service `ceph-builds-api` reads Tekton Results,
  answers `GET /builds?branch=X&distro=Y&arch=Z` with `(latest sha, repo
  URL, provenance link)`. Implements a **backwards-compat shim** for
  shaman's existing API surface so teuthology needs zero changes initially.

### Secrets (phase 1)

| Secret | Storage |
| --- | --- |
| GPG repo-signing key | Vault transit engine (never extracted) |
| GitHub App private key | Plain k8s Secret created by terraform |
| quay.io robot token | Plain k8s Secret created by terraform |
| S3 access | STS via SA-token OIDC — no creds |
| Cosign signing | Fulcio keyless — no creds |

ESO sync of long-lived secrets is deferred to phase 2.

### Make check execution

- **Single fat pod per `(distro, arch)`** — ~32 CPU / 64 GB RAM.
  `run-make-check.sh` + `ctest -j$(nproc)` inside.
- Warm sccache: ~25–40 min total. Cold: add the build time.
- x86_64 is gating; aarch64 runs in parallel and is informational initially.

---

## Repo layout (monorepo)

```
ceph-tekton/
├── Makefile                    # top-level deploy / test / rollback targets
├── README.md
├── PLAN.md                     # this document
├── tasks/                      # reusable Tekton Tasks (resolved by PaC)
│   ├── compute-matrix/
│   ├── build-package/
│   ├── publish-repo/
│   ├── build-container/
│   ├── manifest-assemble/
│   └── make-check/
├── pipelines/                  # PaC pipeline files (phase 1 location)
│   ├── pull-request.yaml
│   └── branch-push.yaml
├── images/
│   └── builders/               # ceph-builder:<distro>-<arch>
│       ├── Dockerfile.centos9
│       ├── Dockerfile.centos10
│       ├── Dockerfile.ubuntu-jammy
│       ├── Dockerfile.ubuntu-noble
│       ├── Dockerfile.fedora-rawhide
│       └── pipeline.yaml       # builder-image build pipeline
├── charts/
│   ├── ceph-tekton-stack/      # umbrella: tekton-operator, pac, chains, vault
│   └── ceph-builds-api/
├── kustomize/
│   ├── base/
│   └── overlays/
│       ├── sepia/
│       ├── dev-local/
│       └── dev-kind/
├── terraform/
│   ├── modules/
│   │   ├── s3-buckets/
│   │   ├── rgw-oidc/
│   │   └── github-app/
│   └── environments/
│       ├── sepia/
│       └── dev/
├── services/
│   └── ceph-builds-api/        # Go service source
├── hack/
│   ├── shadow-diff.sh          # rpm/deb output diff vs jenkins
│   └── install-deps.sh
└── docs/
```

---

## Cutover plan (~3–6 months)

| Phase | What | Exit criteria |
| --- | --- | --- |
| **A. Shadow** | New stack builds in parallel; jenkins authoritative; `hack/shadow-diff.sh` compares rpm/deb outputs | ≥4 weeks of zero unexplained diffs across the matrix |
| **B. Dual-publish** | New stack also publishes via shaman URL conventions (or shaman publishes pointers to new S3); teuthology can pull from either | Teuthology canary jobs pass against new-stack URLs |
| **C. Flip authority** | `ceph-builds-api` shim becomes authoritative shaman API; jenkins jobs disabled in order of confidence: make check → packages (start with most-built combos) → containers → release-tag pipelines | All ceph/ceph PRs and branch pushes gated by new stack for 2 weeks |
| **D. Decommission** | Old jenkins jobs deleted, chacra/shaman shut down, DNS pointed to new endpoints | jenkins.ceph.com, chacra.ceph.com, shaman.ceph.com decommissioned |

---

## Delivery workstreams

Issues map to these workstreams. Each is a tracer-bullet vertical slice
where possible.

1. **Bootstrap & cluster install** — OpenShift install in Sepia, helm charts
   for Tekton operator + PaC + Chains + Vault, `make deploy`, k3s/kind dev
   overlay.
2. **Terraform & out-of-cluster state** — S3 buckets with lifecycle +
   object-lock, RGW OIDC provider + roles/policies, GitHub App creation,
   Vault initialization + transit engine config.
3. **Builder images** — Dockerfiles per `(distro, arch)`, builder-image
   pipeline, in-cluster registry push, nightly schedule + install-deps.sh
   trigger.
4. **Make check pipeline** — first tracer-bullet end-to-end build on one
   `(distro, arch)`, then matrix-expand. PaC trigger from PR.
5. **Package matrix pipeline** — `build-package` Task, sccache integration,
   per-distro variants, matrix fan-out from `compute-matrix`.
6. **Publish-repo pipeline** — `publish-repo` Task, createrepo_c / reprepro,
   Vault transit GPG signing, atomic staging→live S3 swap.
7. **Container image pipeline** — buildah per-arch, manifest-assemble,
   quay.io push.
8. **Tekton Chains setup** — keyless signing config, Rekor wiring, in-toto
   attestation collection for Tasks, OCI referrers + S3 sibling artifacts.
9. **ceph-builds-api service** — Go service, Tekton Results reader, shaman
   API compat shim, deployment chart.
10. **Shadow-mode & migration tooling** — `shadow-diff.sh`, dashboards
    comparing jenkins vs new-stack outcomes, dual-publish wiring.
11. **Documentation** — operator runbook, contributor "run it locally on
    k3s" guide, architecture reference.

---

## Open / phase-2 items

- Helm-based operator wrapping the stack (`CephCIPlatform` CRD via operator-sdk helm mode)
- Crossplane providers for out-of-cluster state
- Argo CD reconciliation
- ESO sync of all long-lived secrets
- Make check sharding (per-component or ctest label)
- Adjacent jenkins jobs: ceph-csi, dashboard, docs, teuthology infra
- Move PaC files from `ceph-tekton/pipelines/` to `ceph/ceph/.tekton/`

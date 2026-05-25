<p align="center">
  <img width="460" height="300"
  src="https://github.com/mmgaggle/ceph-tekton/blob/main/ceph-tekton.png">
</p>

A Tekton-based replacement for the Ceph upstream build infrastructure
(`jenkins` + `chacra` + `shaman`), with SLSA provenance via Tekton Chains.

- **Phase 1 plan:** [`PLAN.md`](PLAN.md)
- **Backlog:** [GitHub Issues](https://github.com/mmgaggle/ceph-tekton/issues)

## Goals

- **Replace** jenkins (build executor), chacra (artifact server), and shaman
  (metadata/UI/lookup API) for the `ceph/ceph` repo.
- **Provenance** for every package and container — SLSA v1.0 attestations,
  Sigstore keyless signing (Fulcio + workload OIDC), Rekor transparency log.
- **Portable** — the same Tekton manifests run on Sepia OpenShift *and* on a
  contributor's local k3s/kind cluster.
- **Parity from day one** with the existing trigger model, build matrix, and
  teuthology consumption pattern.

---

## Supply-chain compliance posture

The provenance pipeline (SLSA v1.0 attestations + Sigstore Fulcio
keyless signing + public Rekor transparency log + Vault-resident
repodata signing) is a foundation that helps satisfy a number of
software-supply-chain regimes increasingly being asked of upstream
projects and downstream consumers. What ceph-tekton *contributes*
toward each — overclaim warning: signing is necessary, not sufficient,
for any of these. Compliance also depends on the consumer's process,
SBOM coverage, vulnerability handling, and policy enforcement.

| Regime | What this satisfies | What still needs work |
|---|---|---|
| **[SLSA Build L3](https://slsa.dev/spec/v1.0/levels)** | Build platform (Tekton + Chains) generates provenance the producer cannot tamper with; signed by an independent identity (Fulcio); transparency-logged (Rekor); hardened build environment (RBAC #38, NetworkPolicy #39). | Reproducible builds (would need pinned timestamps + verification harness); isolated builds per matrix cell (already true). |
| **[NIST SP 800-218 SSDF](https://csrc.nist.gov/Projects/ssdf)** | PS.1.1 (protect from tampering: RBAC, Vault transit, STS), PS.3.1 (verifiable provenance: SLSA + cosign verify), PW.4.1 (secured dev environment), PO.5.1 (archive + protect each release: object-lock release bucket). | RV.1.3 (vulnerability analysis: SBOM + scanning pipeline not in phase 1), PW.4.4 (verify third-party components: would need Rekor checks on pulled deps). |
| **US EO 14028 + OMB [M-22-18](https://www.whitehouse.gov/wp-content/uploads/2022/09/M-22-18.pdf) / [M-23-16](https://www.whitehouse.gov/wp-content/uploads/2023/06/M-23-16-Update-to-M-22-18.pdf)** | Producer side: SLSA-aligned attestations + signed releases give federal procurement consumers (national labs, USGS, anyone running Ceph in fed contexts) what their SSDF self-attestation forms ask for. | SBOM in CycloneDX/SPDX form (Tekton Chains supports this with extra config; not enabled phase 1). |
| **[EU Cyber Resilience Act](https://eur-lex.europa.eu/eli/reg/2024/2847/oj) (CRA)** | Annex I §1.2(f) integrity protection (signed artifacts), (h) tamper-evidence (Rekor), Article 13 documentation (provenance is third-party-verifiable). | Article 11 coordinated vulnerability disclosure + Annex II §2 vulnerability handling — orthogonal to signing, but consumed alongside it. |
| **[CIS Software Supply Chain Security](https://www.cisecurity.org/insights/white-papers/cis-software-supply-chain-security-guide) Benchmark** | §2 (build pipeline hardening), §4.2 (artifact signing), §4.3 (attestation of build steps). | §3 (dependency management — SBOM + scanning), §4.4 (signature verification at deploy — Kyverno/OPA policy at pull time). |
| **[OpenSSF Scorecard](https://github.com/ossf/scorecard) signed-releases** | "Signed-Releases" check passes when tags publish SLSA attestations + cosign signatures (we do). | Other Scorecard checks (Branch-Protection, Code-Review, etc.) are orthogonal repo-governance items. |

The pieces explicitly *not* in phase 1 — SBOM generation, vulnerability
scanning, deploy-time signature verification (Kyverno/OPA), reproducible
builds — are tracked as phase-2 candidates and can layer onto the same
Chains attestation + Rekor + cosign foundation without disturbing the
phase-1 surface.

---

## Architecture overview

GitHub events (PR, branch push, tag) are turned into PipelineRuns by
Pipelines-as-Code. Tekton fans out a per-`(distro, arch)` matrix of
build + publish tasks, pushes packages and repodata to lifecycle-tiered
RGW S3 buckets, and pushes multi-arch container images to
`quay.io/ceph/ceph`. Tekton Chains observes every completed
PipelineRun, mints a short-lived Sigstore identity from the workload's
projected ServiceAccount token, and logs a SLSA v1 attestation to Rekor
alongside the artifact.

A small `ceph-builds-api` service reads Tekton Results and serves the
shaman-compatible lookup API that teuthology already speaks, so the
cutover from jenkins/chacra/shaman needs zero teuthology change on
day one.

```mermaid
flowchart LR
  subgraph GH["github.com"]
    PR["PR push"]
    BR["branch push<br/>(main, wip-*, release/*)"]
    TAG["tag push<br/>(vX.Y.Z)"]
  end

  subgraph Sepia["Sepia OpenShift"]
    PAC["Pipelines-as-Code"]
    TK["Tekton Pipelines"]
    CH["Tekton Chains"]
    VAULT[("Vault<br/>transit engine<br/>GPG key")]
    REG[("In-cluster<br/>registry<br/>builder images")]
    API["ceph-builds-api<br/>(shaman shim)"]
  end

  subgraph CephRGW["Sepia Ceph RGW"]
    DEV[("ceph-artifacts-dev<br/>30d expiry")]
    BRANCH[("ceph-artifacts-branch<br/>keep-20 + 180d")]
    REL[("ceph-artifacts-release<br/>object-lock 7y")]
  end

  subgraph Sigstore["Sigstore public-good"]
    FULCIO["Fulcio"]
    REKOR["Rekor"]
  end

  QUAY[("quay.io/ceph/ceph<br/>multi-arch")]
  TEU["teuthology"]

  PR -->|webhook| PAC
  BR -->|webhook| PAC
  TAG -->|webhook| PAC
  PAC --> TK
  TK -->|pull| REG
  TK -->|sign repodata via API| VAULT
  TK -->|push pkgs + repodata| DEV
  TK -->|push pkgs + repodata| BRANCH
  TK -->|push pkgs + repodata| REL
  TK -->|push multi-arch| QUAY
  TK -.observes.-> CH
  CH -->|OIDC SA token| FULCIO
  FULCIO -->|short-lived cert| CH
  CH -->|attestation| REKOR
  CH -->|OCI referrer| QUAY
  CH -->|.intoto.jsonl| BRANCH
  TK -->|results| API
  TEU -->|GET /builds| API
  API -.points at.-> BRANCH
```

The full architectural reference — trigger model, build matrix, build
pipeline sequence, provenance + trust model, artifact storage, component
map, cutover plan, and the design Decision Log — lives in
[`docs/architecture.md`](docs/architecture.md).

---

## Repo layout

```
ceph-tekton/
├── Makefile                    # deploy / test / rollback targets
├── README.md                   # this file
├── PLAN.md                     # phase-1 design + cutover plan
├── tasks/                      # reusable Tekton Tasks (PaC-resolved)
│   ├── compute-matrix/
│   ├── build-package/
│   ├── publish-repo/
│   ├── build-container/
│   ├── manifest-assemble/
│   └── make-check/
├── pipelines/                  # PaC pipeline files (phase 1 location)
│   ├── pull-request.yaml
│   ├── branch-push.yaml
│   └── tag-push.yaml
├── images/
│   └── builders/               # ceph-builder:<distro>-<arch>
├── charts/
│   ├── ceph-tekton-stack/      # umbrella: tekton, pac, chains, vault
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
│   │   ├── rgw-roles/
│   │   └── github-app/
│   └── environments/
│       ├── sepia/
│       └── dev/
├── services/
│   └── ceph-builds-api/        # Go service
├── hack/
│   ├── shadow-diff.sh          # jenkins vs new-stack parity check
│   └── verify-build.sh         # SLSA verification
└── docs/
    ├── architecture.md
    ├── contributing-locally.md
    ├── runbook.md
    ├── provenance.md
    └── observability.md
```

---

## Getting started

> **Status:** scaffolding underway. See the [issue backlog](https://github.com/mmgaggle/ceph-tekton/issues)
> for what's grabbable.

Spin up a local kind cluster + Tekton Pipelines and run the smoke-test
pipeline:

```sh
make dev-up        # create kind cluster, install Tekton Pipelines
make dev-test      # apply + run the hello-world pipeline, stream logs
make dev-down      # tear it all down
```

Prerequisites and the full dev-loop walkthrough live in
[`docs/contributing-locally.md`](docs/contributing-locally.md).

For Sepia operators, see `docs/runbook.md` once #37 lands.

---

## Phase 2 (deferred)

- Helm-based operator with a `CephCIPlatform` CRD (operator-sdk helm mode)
- Crossplane providers for out-of-cluster state
- Argo CD reconciliation (helm charts kept Argo-ready)
- External Secrets Operator sync of long-lived secrets
- Move PaC files from `ceph-tekton/pipelines/` to `ceph/ceph/.tekton/` so
  CI changes flow through code review alongside the code that needs them
- Adjacent jenkins jobs: ceph-csi, dashboard, docs, teuthology infra
- Make check sharding (per-component or by ctest label)

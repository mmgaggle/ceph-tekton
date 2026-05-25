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

## Architecture overview

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

---

## Trigger model (shaman parity)

```mermaid
flowchart TD
  Event{GitHub event}
  Event -->|PR push| MC[make-check pipeline]
  Event -->|push to branch<br/>main, wip-*, release/*| PKG[package + container pipelines]
  Event -->|tag push vX.Y.Z| REL[release-channel pipeline]

  MC --> MC_R[GitHub Check posted]
  PKG --> PKG_R[artifacts to<br/>ceph-artifacts-dev or<br/>ceph-artifacts-branch]
  REL --> REL_R[artifacts to<br/>ceph-artifacts-release<br/>object-lock applied]
```

PRs from **forks** only run make check — they do not trigger package builds.
Devs who need teuthology-installable packages push a `wip-*` branch to
`ceph/ceph` directly, mirroring today's convention for org members.

---

## Build matrix

```mermaid
flowchart LR
  MX[matrix.yaml at source ref]
  MX --> CM[compute-matrix Task]
  CM -->|JSON Result| FAN{Tekton matrix:}

  FAN --> C9X[centos9 / x86_64]
  FAN --> C9A[centos9 / aarch64]
  FAN --> C10X[centos10 / x86_64]
  FAN --> C10A[centos10 / aarch64]
  FAN --> UJX[ubuntu-jammy / x86_64]
  FAN --> UJA[ubuntu-jammy / aarch64]
  FAN --> UNX[ubuntu-noble / x86_64]
  FAN --> UNA[ubuntu-noble / aarch64]
  FAN -.non-gating.-> FRX[fedora-rawhide / x86_64]
  FAN -.non-gating.-> FRA[fedora-rawhide / aarch64]
```

Matrix is **branch-versioned** — reef's `matrix.yaml` differs from main's, so
older release branches keep building the OS targets they shipped on.

---

## Build pipeline (per matrix cell)

```mermaid
sequenceDiagram
  participant GH as GitHub
  participant PaC as Pipelines-as-Code
  participant TK as Tekton
  participant SCC as sccache (S3)
  participant V as Vault transit
  participant S3 as Sepia Ceph S3
  participant Q as quay.io
  participant CH as Tekton Chains
  participant FU as Fulcio
  participant RK as Rekor

  GH->>PaC: webhook (branch push)
  PaC->>TK: instantiate PipelineRun
  TK->>TK: compute-matrix
  par per (distro, arch)
    TK->>SCC: assume role via SA-token OIDC
    TK->>TK: build-package (uses warm sccache)
    TK->>S3: upload pkgs to staging prefix
    TK->>V: sign repodata via transit API
    TK->>S3: atomic swap staging → live
    TK->>S3: update branch/latest pointer
  end
  par for container image
    TK->>Q: buildah push per-arch
    TK->>Q: manifest-assemble multi-arch index
  end
  TK-->>CH: PipelineRun completed
  CH->>FU: OIDC SA token → short-lived cert
  CH->>CH: sign SLSA v1 attestation
  CH->>RK: log entry
  CH->>Q: attestation as OCI referrer
  CH->>S3: .intoto.jsonl sibling
  TK->>GH: post GitHub Check
```

---

## Provenance & trust model

```mermaid
flowchart TB
  subgraph BUILD["Build pod"]
    SA["ServiceAccount<br/>ceph-pipeline-sa"]
    TOK["projected SA token<br/>(short-lived)"]
    SA --> TOK
  end

  TOK -->|AssumeRoleWithWebIdentity| RGW[RGW OIDC trust]
  RGW -->|temp S3 creds<br/>≤ 1h| BUILD

  TOK -->|Kubernetes auth| VAULT[Vault]
  VAULT -->|sign via transit API<br/>key never extracted| BUILD

  TOK -->|OIDC token| FU[Fulcio]
  FU -->|short-lived X.509 cert<br/>identity = SA| BUILD
  BUILD -->|cosign sign<br/>SLSA v1 attestation| RK[Rekor public-good]
  BUILD -->|attestation + cert| ARTIFACT[OCI referrer / S3 sibling]

  VERIFY[third-party verifier]
  VERIFY -->|cosign verify-attestation| ARTIFACT
  ARTIFACT --> VERIFY
  VERIFY -->|check inclusion| RK
```

**Trust properties**

- No long-lived signing key — identity-bound provenance (`built by SA X in
  namespace Y at <time>`).
- GPG repo-signing key **never leaves Vault** — even a compromised publish
  pod cannot exfiltrate it.
- S3 access via short-lived STS creds — no long-lived S3 keys anywhere.
- Anyone, anywhere, can verify a Ceph build's provenance using only public
  Sigstore infrastructure and cosign.

---

## Artifact storage

```mermaid
flowchart TB
  subgraph S3["Sepia Ceph S3 (terraform-managed)"]
    DEV[ceph-artifacts-dev<br/>wip-* branches<br/>30d expiry<br/>no object-lock]
    BR[ceph-artifacts-branch<br/>main + release branches<br/>keep latest 20 + 180d ceiling]
    REL[ceph-artifacts-release<br/>tags<br/>object-lock governance<br/>7-year retention]
  end

  subgraph URL["URL convention"]
    PATH["https://artifacts.ceph.com/&lt;bucket&gt;/&lt;branch&gt;/&lt;sha&gt;/&lt;distro&gt;/&lt;arch&gt;/"]
    LATEST["&lt;branch&gt;/latest/manifest.json<br/>{ sha, timestamp, attestation_url }"]
  end

  S3 --> URL
```

---

## Component map

```mermaid
flowchart TB
  subgraph IN["In-cluster (helm-installed)"]
    TKO[Tekton Operator]
    PaC[Pipelines-as-Code]
    CH[Tekton Chains]
    V[Vault + transit engine]
    LOK[Loki + Promtail]
    PROM[Prometheus + Grafana]
    REG[In-cluster registry]
    API[ceph-builds-api]
  end

  subgraph OUT["Out-of-cluster (terraform-managed)"]
    S3[3 × S3 buckets<br/>lifecycle + object-lock]
    OIDC[RGW OIDC trust<br/>+ roles + policies]
    APP[GitHub App<br/>+ webhook]
  end

  subgraph PUB["External public infra"]
    GH[GitHub]
    Q[quay.io]
    FU[Fulcio]
    RK[Rekor]
  end

  PaC <--> GH
  PaC <--> APP
  CH <--> FU
  CH <--> RK
  CH --> Q
  CH --> S3
  TKO --> REG
  TKO <--> V
  TKO --> S3
  TKO --> OIDC
  TKO --> Q
  API <--> S3
```

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

## Cutover plan

```mermaid
flowchart LR
  A[Phase A<br/>Shadow] --> B[Phase B<br/>Dual-publish]
  B --> C[Phase C<br/>Flip authority]
  C --> D[Phase D<br/>Decommission]

  A -.->|"≥4 weeks zero<br/>unexplained diffs"| B
  B -.->|"teuthology canary<br/>passes against new"| C
  C -.->|"2 weeks gating<br/>on new stack"| D
```

See [`PLAN.md`](PLAN.md) for phase exit criteria and the per-component
cutover order.

---

## Getting started

> **Status:** scaffolding underway. See the [issue backlog](https://github.com/mmgaggle/ceph-tekton/issues)
> for what's grabbable.

Once issue #1 ("Hello-world Tekton on local k3s/kind") lands:

```sh
# Bootstrap a local dev cluster
make dev-up

# Point your fork's PaC at the local cluster
# (see docs/contributing-locally.md)

# Iterate on a Task
tkn task start make-check ...
```

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

# Builder images — the `(distro, arch)` matrix and how it gets built

ceph-tekton builds `ceph/ceph` packages inside **pre-baked builder
images**, one per `(distro, arch)` cell of the build matrix. The
builder image carries the C++ toolchain (gcc, cmake, ninja, ccache),
python deps, and the output of upstream `ceph/ceph/install-deps.sh`
against a pinned SHA — so per-build PipelineRuns don't re-run
`install-deps.sh` and don't depend on package-repo availability on
the hot path. See [`architecture.md` § "Build mechanics: pre-baked
builder images"](architecture.md#build-mechanics-pre-baked-builder-images-not-install-deps-per-build)
for the decision and rejected alternatives.

This page describes the **first** builder image
(`ceph-builder:centos10-x86_64`, issue
[#10](https://github.com/mmgaggle/ceph-tekton/issues/10)), the Tekton
machinery that builds it, the contract it presents to downstream
consumers, and the reproducibility caveats. The full matrix expansion
(centos9, ubuntu-jammy, ubuntu-noble, fedora-rawhide × x86_64,
aarch64) lands in
[#11](https://github.com/mmgaggle/ceph-tekton/issues/11); the
nightly + install-deps.sh-change triggers in
[#12](https://github.com/mmgaggle/ceph-tekton/issues/12). This file
documents what's shipped TODAY — the centos10-x86_64 starter — and
notes where #11/#12 will extend it.

If you want the higher-level Chains / SLSA story (signing,
attestations, Rekor), read [`provenance.md`](provenance.md) first.

## Matrix layout

The phase-1 target matrix:

|              | x86_64 | aarch64 |
|--------------|:------:|:-------:|
| centos9      |  #11   |  #11    |
| **centos10** | **shipped (#10)** | #11 |
| ubuntu-jammy |  #11   |  #11    |
| ubuntu-noble |  #11   |  #11    |
| fedora-rawhide (non-gating) | #11 | #11 |

Each cell produces one image tagged
`ceph-builder:<distro>-<arch>-<sha>` plus a moving
`<distro>-<arch>-latest` tag. The `<sha>` is the **ceph-tekton commit
SHA** that built the recipe — *not* `ceph/ceph`'s SHA. The
ceph/ceph SHA the image's `install-deps.sh` came from lives in the
`org.ceph.builder-image.ceph-sha` OCI label, fetchable via
`skopeo inspect docker://<ref>`.

Native-arch builds only — no qemu. aarch64 cells (when #11 lands)
schedule onto an arm64 worker node via `nodeSelector`. See
[`architecture.md` § "Container images: buildah per-arch on native
nodes"](architecture.md#container-images-buildah-per-arch-on-native-nodes-no-qemu).

## What lives where

```
ceph-tekton/
├── images/
│   └── builders/
│       ├── Dockerfile.centos10     # shipped (#10)
│       ├── build-package.sh        # entrypoint wrapper
│       └── pipeline.yaml           # the Pipeline that drives the build
└── tasks/
    └── build-builder-image/
        └── task.yaml               # buildah build + push + Chains-Results
```

`Dockerfile.centos10` is architecture-agnostic — the same recipe
builds both `centos10-x86_64` and `centos10-aarch64` (when #11 lands);
dnf picks the right arch packages from the CentOS mirrors based on
the host kernel.

## Building it

Interactive (against a `tkn`-reachable dev cluster):

```sh
tkn pipeline start build-builder-image \
  --param=output-image=ghcr.io/mmgaggle/ceph-builder:centos10-x86_64-$(git rev-parse --short HEAD) \
  --param=output-image-latest=ghcr.io/mmgaggle/ceph-builder:centos10-x86_64-latest \
  --param=source-revision=$(git rev-parse HEAD) \
  --workspace=name=source,claimName=<your-source-pvc> \
  --workspace=name=registry-credentials,secret=ghcr-token \
  --showlog
```

For a smoke run that doesn't push to ghcr.io, leave
`registry-credentials` empty and target the kind in-cluster registry:

```sh
tkn pipeline start build-builder-image \
  --param=output-image=registry.e2e-registry.svc:5000/ceph-builder:centos10-x86_64-dev \
  --param=tls-verify=false \
  --workspace=name=source,claimName=<your-source-pvc> \
  --workspace=name=registry-credentials,emptyDir="" \
  --showlog
```

The hands-off path is `hack/e2e/assert-build-builder-image.sh` — it
spins up a registry:2 Deployment, stages the Containerfile onto a
PVC, runs the Pipeline, and asserts the Chains-grammar Results. With
`E2E_BUILDER_IMAGE_FULL_BUILD=true` it runs the real centos10
recipe (~10-20 min, ~3GB intermediate); default uses a synthetic
Containerfile that exercises the same Task code paths in seconds.

## Overriding the install-deps.sh SHA

The Containerfile's `CEPH_SHA` ARG selects which `ceph/ceph` commit's
`install-deps.sh` is fetched and run. Override it via the Pipeline's
`ceph-sha` param:

```sh
tkn pipeline start build-builder-image \
  --param=ceph-sha=<your-ceph-sha> \
  ...
```

When #12 ships, the install-deps.sh-change PaC trigger from
`ceph/ceph` will set this to the PR's HEAD; the nightly CronJob will
refresh it to current `main`. Today (issue #10), it defaults to the
SHA baked into the Containerfile (current `ceph/ceph` main HEAD at
file-creation time).

## Overriding the Containerfile path

The Pipeline's `dockerfile-path` param accepts any path under the
`source` workspace. The matrix expansion (#11) threads
`images/builders/Dockerfile.<distro>` per cell — until then, the
default `images/builders/Dockerfile.centos10` is what runs.

## Reproducibility caveats

The builder image's reproducibility story has three knobs and three
unavoidable sources of drift:

1. **`SOURCE_DATE_EPOCH`** — threaded into both the Containerfile
   build-arg AND `buildah --timestamp`. With it set, layer mtimes are
   deterministic. Without it, buildah stamps each layer with the
   current clock and the digest drifts run-to-run. The
   reproducibility-check Task (#48) sets this to the ceph-tekton
   commit's unix timestamp; ad-hoc `tkn pipeline start` runs leave
   it unset and accept the drift.

2. **`install-deps.sh` SHA** — pinned via `ceph-sha` param. A given
   SHA produces the same set of `dnf install` lines, but…

3. **CentOS Stream 10 yum mirrors** — CentOS Stream is a rolling
   distribution. Today's `dnf install gcc` resolves to a different
   NEVRA than tomorrow's. We deliberately do **NOT** pin every
   package by NEVRA: pinning against a moving upstream produces
   `nothing provides` failures faster than it produces reproducible
   builds. The practical contract is "same digest given identical
   mirror state + identical SOURCE_DATE_EPOCH + identical CEPH_SHA",
   which is what the upstream-dep verification work (#49, HITL)
   builds toward.

4. **Kernel headers + glibc** — `install-deps.sh` for centos pulls
   `kernel-headers` and the glibc devel package; these track the
   running CentOS Stream 10 base image, so a base-image refresh
   (which the nightly trigger #12 picks up) can change them.

5. **Python wheel cache** — `install-deps.sh` runs the per-tox-ini
   wheel preloader (`preload_wheels_for_tox`); these wheels are
   pulled from PyPI and pinned per the requirements files in
   `ceph/ceph`. PyPI's content-addressed CDN makes this stable in
   practice, but PyPI mirror restamping has caused drift historically
   — track via the per-build SBOM the package-build Pipeline emits.

The reproducibility story for the THING THIS IMAGE BUILDS — `ceph`
itself — is the one that matters; that's tracked separately in #53
and uses the reproducibility-check Task (#48) to diff actual ceph
build artefacts. This image being "reproducible" is a means to that
end, not the end itself.

## Downstream consumption

### The package-build Pipeline (#13–#21 range, in flight)

Pulls the image by **digest** (not tag) so the build pin can't be
silently changed under it:

```yaml
spec:
  steps:
    - name: build
      image: ghcr.io/mmgaggle/ceph-builder@sha256:<digest>
      script: |
        # SOURCE_DATE_EPOCH + LC_ALL + TZ env stanza...
        dpkg-buildpackage -us -uc -b   # or rpmbuild ...
```

The digest comes from the builder-image Pipeline's `IMAGE_DIGEST`
Result. The matrix-builder Pipeline (#11) emits a JSON manifest of
(distro, arch) → digest mappings that downstream Pipelines consume.

### Signature verification at deploy (#47, shipped)

The Kyverno `ClusterPolicy` shipped in #47 verifies cosign signatures
on `quay.io/ceph/*` images. The builder images live in the in-cluster
registry / ghcr.io, not on quay.io — so today's #47 policy DOES NOT
apply to them. Extending the policy to cover the builder-image
namespace is a follow-up (file separately as phase-2 work). For now,
the build pod's image-pull is the trust boundary; the in-cluster
registry's RBAC limits who can push.

### Reproducibility-check (#53, blocks on this image)

Issue #53 ("drive reproducibility diffoscope output toward empty on
real ceph builds") needs a real builder image to run inside. With
#10 shipped, #53 can take the centos10-x86_64 image, invoke
`dpkg-buildpackage`/`rpmbuild` twice with the same
`SOURCE_DATE_EPOCH`, and diffoscope the outputs. Until #10, #53 was
running against trivial cmake hello-world examples.

## OCI labels

The image surfaces these labels for human / auditor consumption:

| Label                                  | Value example                                                 |
|----------------------------------------|---------------------------------------------------------------|
| `org.opencontainers.image.source`      | `https://github.com/mmgaggle/ceph-tekton`                     |
| `org.opencontainers.image.revision`    | ceph-tekton commit SHA at build time                          |
| `org.opencontainers.image.created`     | RFC 3339 timestamp (= `date -u -d @$SOURCE_DATE_EPOCH`)       |
| `org.opencontainers.image.title`       | `ceph-builder-centos10`                                       |
| `org.opencontainers.image.description` | "CentOS Stream 10 builder image for ceph/ceph..."             |
| `org.opencontainers.image.licenses`    | `LGPL-2.1-or-later`                                           |
| `org.ceph.builder-image.version`       | `0.1.0-centos10` (the recipe version)                         |
| `org.ceph.builder-image.ceph-sha`      | the ceph/ceph SHA install-deps.sh was fetched from            |
| `org.ceph.builder-image.distro`        | `centos10`                                                    |
| `org.ceph.builder-image.for-make-check`| `true` / `false` — whether make-check deps were installed     |

Inspect any pushed image with:

```sh
skopeo inspect docker://ghcr.io/mmgaggle/ceph-builder:centos10-x86_64-latest \
  | jq '.Labels'
```

## Chains-grammar Results (contract for downstream Pipelines)

The Task `build-builder-image` and the Pipeline `build-builder-image`
both expose these Results (the Pipeline re-exposes the Task's set
verbatim so a PipelineRun-level Chains attestation sees the same
grammar):

| Result            | Type   | Shape                                                                  |
|-------------------|--------|------------------------------------------------------------------------|
| `IMAGE_URL`       | string | full image ref (registry + repo + tag)                                  |
| `IMAGE_DIGEST`    | string | `sha256:<64-hex>`                                                       |
| `IMAGES`          | string | newline-separated `<url>@<digest>` line(s)                              |
| `ARTIFACT_OUTPUTS`| string | JSON: `{"uri":"<url>","digest":"sha256:...","isBuildArtifact":"true"}`  |
| `image-tags`      | string | newline-separated list of every tag pushed                              |

`isBuildArtifact == "true"` is critical: it tells Chains to promote
the image to the attestation's `subject[]` array (the image IS the
build artefact), distinct from vuln-scan's `"false"` which lands
findings under `predicate.runDetails.byproducts[]`. See
[`provenance.md`](provenance.md) for the byproduct vs subject walkthrough.

## Decision log

Each entry below follows the same shape as
[`architecture.md` § "Decision Log"](architecture.md#decision-log) —
durable, append-on-revisit, three-to-five-line rationale.

### Containerfile path: `images/builders/Dockerfile.<distro>`

- **Decision:** Single Containerfile per distro in `images/builders/`,
  named `Dockerfile.<distro>`. Architecture-agnostic — the same
  recipe builds both x86_64 and aarch64 via native worker scheduling.
- **Rejected alternatives:** Per-arch Containerfile
  (`Dockerfile.centos10-x86_64`); per-distro subdir
  (`images/builders/centos10/Dockerfile`); single `Containerfile`
  with a giant `if [ "$DISTRO" = "..." ]; then` ladder.
- **Reason:** The architecture difference (`dnf` picking the right
  arch) is handled by the kernel, not the recipe; per-distro
  subdirs duplicate the shared `build-package.sh` `COPY`. The
  ladder approach makes every distro's recipe harder to read and
  loses the per-distro git-blame signal.

### Build tool: buildah (not docker, not kaniko, not img)

- **Decision:** Use buildah (`quay.io/buildah/stable`) as the image-
  build primitive. Same Task pattern as the upstream `tektoncd/catalog`
  buildah Task.
- **Rejected alternatives:** Docker via DinD; kaniko; img; ko.
- **Reason:** OpenShift Pipelines bundles buildah as the supported
  primitive on Sepia. Rootless inside the pod (no daemon-socket
  mount), native OCI output (same digest across pulls), and the
  PLAN.md "Container images" decision already named buildah for
  daemon images — using the same primitive for builder images keeps
  the build mechanic identical across image classes.

### Pinning: name+major for the base, ARG for install-deps SHA

- **Decision:** Pin the base image by name (`quay.io/centos/centos:stream10`)
  — not by digest. Pin the `ceph/ceph` SHA for `install-deps.sh` via
  a Containerfile ARG (`CEPH_SHA=…`) so the nightly trigger (#12) can
  bump it without a recipe diff. Do NOT pin every yum package by NEVRA.
- **Rejected alternatives:** Digest-pin the base
  (`quay.io/centos/centos@sha256:…`); freeze the ceph-tekton-side
  CEPH_SHA at recipe-creation time; pin every dnf package by full
  NEVRA against a mirror snapshot.
- **Reason:** CentOS Stream 10 is rolling by design — the moving
  `stream10` tag IS the right anchor for nightly rebuilds, which is
  exactly what #12 will trigger. Per-NEVRA pinning against a
  moving mirror produces `nothing provides` failures faster than it
  produces reproducible builds. The "reproducibility" property we
  care about is the BUILT-CEPH-PACKAGES reproducibility (#48, #53),
  not byte-identical builder-image digests across mirror updates.

### Build user: non-root `builder` (UID 1000)

- **Decision:** Image runs as `builder:builder` (UID/GID 1000:1000)
  via `USER builder`. `install-deps.sh` runs at image-build time as
  root (it has to: dnf needs it), but the resulting image's runtime
  user is the unprivileged `builder`.
- **Rejected alternatives:** Run as root at runtime (current jenkins
  posture); use a random UID per build; mount `runAsUser` from the
  Pipeline's `securityContext` only and leave the image USER unset.
- **Reason:** OpenShift's default SCC and the issue brief both call
  for non-root build pods. UID 1000 dodges the common host-side
  root collision when a build pod runs `runAsNonRoot: true`.
  Image-level USER means the Pipeline can omit the per-step
  `securityContext` boilerplate and still get the right user.

### Entrypoint shape: `build-package.sh` router (interactive + headless)

- **Decision:** `/usr/local/bin/build-package.sh` is the ENTRYPOINT.
  With no args it drops to interactive bash; one arg runs it as
  `bash -c "$1"` (the reproducibility-check shape); two-or-more args
  with first as a directory does `cd $1 && bash -c "${@:2}"` (the
  package-build Task's shape); else it execs the args literally.
- **Rejected alternatives:** No ENTRYPOINT (let the Pipeline set
  `command:`); ENTRYPOINT=bash with CMD=help; a Python-based
  argparse'd launcher.
- **Reason:** The interactive path matters for `tkn pipeline start
  --showlog` dev iteration; the headless paths matter for #16 and
  #48. A 30-line `case "$#" in ... esac` is shorter, more auditable,
  and has fewer failure modes than a Python launcher.

### One-Task-per-image (no multi-arch manifest assembly in this Task)

- **Decision:** Build one (distro, arch) image per Task invocation;
  emit one digest. The multi-arch manifest assembly belongs in a
  separate Task wrapped by the matrix-builder Pipeline (#11).
- **Rejected alternatives:** Build x86_64 + aarch64 in one Task via
  buildah's multi-arch manifest support; cross-build under qemu in a
  single Task to dodge needing arm64 workers.
- **Reason:** qemu adds ~10× slowdown (same reasoning as the daemon-
  image decision in `architecture.md`); single-Task per-arch fans
  out naturally via Tekton's `matrix:` field; collapsing the manifest
  assembly into this Task would tightly couple #10 and #11 and make
  it harder to add the per-cell node affinity #11 needs.

### Shared `/var/lib/containers` between buildah steps

- **Decision:** The Task declares a Pod-level `volumes:` list with
  two emptyDirs (`varlibcontainers` mounted at `/var/lib/containers`
  and `varruncontainers` at `/run/containers`) and the build / tag /
  push steps all bind both. Storage is wiped with the Pod.
- **Rejected alternatives:** Collapse build + tag + push into a
  single step (loses per-step log boundaries and the per-step
  retry-on-flake we want later); use a Workspace for the buildah
  storage (couples Task params to caller's volume infrastructure);
  pipe the OCI layout through `oci-archive:` between steps
  (works, but adds a serialization round-trip per layer).
- **Reason:** Each Tekton step is its own container — buildah's
  default `/var/lib/containers/storage` lives in the step
  container's writable layer and is invisible to subsequent steps.
  Observed failure mode: `step-build` succeeds writing the image,
  `step-tag` immediately fails with `image not known`. A Pod-level
  emptyDir gives all three buildah steps the same view of the
  storage tree without leaking it to the Task workspace.

### Privileged step securityContext for buildah

- **Decision:** Every buildah step (build / tag / push) in the
  `build-builder-image` Task sets `securityContext.privileged: true`.
- **Rejected alternatives:** Try to run buildah with only
  `CAP_SYS_ADMIN`+`CAP_SETUID`+`CAP_SETGID`; rely on rootless +
  fuse-overlayfs (needs `/etc/subuid` + `/etc/subgid` propagated into
  the build pod); use kaniko (which doesn't need privileged but pays
  a 2-3× build-time tax and has a different attestation surface).
- **Reason:** buildah's layer-apply step calls `remount(2)` on its
  storage tree (vfs and overlay drivers both do this), which fails
  with `EPERM` on un-CAP_SYS_ADMIN'd pods — observed on k3s on
  Ubuntu, also observed on stock kind. Matches upstream
  `tektoncd/catalog`'s buildah Task and OpenShift Pipelines' Buildah
  ClusterTask, which both set `privileged: true`. The pod is still
  schedule-gated by the cluster's PSA / SCC: on Sepia the
  `pipelines-scc` (or equivalent) plus a SA RoleBinding decide
  whether the request is granted; on kind / k3s smoke runs the
  default namespace's PSA is `privileged` so it Just Works.

### E2E smoke: `--use-param-defaults` for tkn pipeline start

- **Decision:** `hack/e2e/assert-build-builder-image.sh` passes
  `--use-param-defaults` to `tkn pipeline start`, so optional Pipeline
  params the smoke doesn't override (`source-date-epoch`,
  `source-url`, `subject-prefix`, `buildah-image`) take their
  defaults non-interactively.
- **Rejected alternatives:** Pass every optional param explicitly
  (couples the smoke to the Pipeline's param list — every new
  Pipeline param breaks the smoke); strip optional params from the
  Pipeline (removes per-cell knobs the matrix Pipeline #11 needs).
- **Reason:** Without the flag, `tkn pipeline start` drops into
  interactive `? Value for param ...` prompts on any param without
  a value — which silently hangs the smoke until its 600s timeout.
  Documented here because the failure mode is non-obvious (the smoke
  appears to "start" but the PipelineRun never gets created).

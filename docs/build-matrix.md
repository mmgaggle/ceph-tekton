# The build matrix

ceph-tekton fans out package + container builds across an N-cell matrix
of `(distro, arch)` combinations. The matrix is **branch-versioned** —
each branch of `ceph/ceph` ships its own `matrix.yaml` at the repo
root, so an older release branch keeps building the OS targets it
shipped on even after `main` drops them.

This document covers the cradle-to-grave contract:

  * The `matrix.yaml` schema source pipelines read.
  * The `compute-matrix` Task that turns it into a Tekton Result.
  * How downstream Tasks fan out via Tekton's `matrix:` field.
  * The default-matrix fallback for branches without a `matrix.yaml`.

For the higher-level "where does this fit in the build pipeline" view,
see `docs/architecture.md` § "Build matrix". For the issue tracking
this work, see [#15](https://github.com/mmgaggle/ceph-tekton/issues/15).

---

## `matrix.yaml` schema

`matrix.yaml` lives at the **root of the ceph/ceph source tree**, on the
branch being built. It is a simple YAML document with one top-level key,
`cells`, holding a list of `{distro, arch, gating}` objects.

```yaml
# matrix.yaml at the ceph/ceph source root (main branch, illustrative)
cells:
  - distro: centos9
    arch: x86_64
    gating: true
  - distro: centos9
    arch: aarch64
    gating: true
  - distro: centos10
    arch: x86_64
    gating: true
  - distro: centos10
    arch: aarch64
    gating: true
  - distro: ubuntu-jammy
    arch: x86_64
    gating: true
  - distro: ubuntu-jammy
    arch: aarch64
    gating: true
  - distro: ubuntu-noble
    arch: x86_64
    gating: true
  - distro: ubuntu-noble
    arch: aarch64
    gating: true
  - distro: fedora-rawhide
    arch: x86_64
    gating: false
  - distro: fedora-rawhide
    arch: aarch64
    gating: false
```

### Cell fields

| Field    | Type      | Meaning                                                                                                                                       |
|----------|-----------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| `distro` | string    | Distro slug. Matches builder-image tag suffixes (see `docs/builder-images.md`). Examples: `centos9`, `centos10`, `ubuntu-jammy`, `ubuntu-noble`, `fedora-rawhide`. |
| `arch`   | string    | CPU architecture. `x86_64` or `aarch64`. Selects the worker-node pool the build pod is scheduled to — no qemu emulation.                       |
| `gating` | bool      | YAML `true`/`false`. Whether a failure of this cell should fail the gating GitHub Check on a PR. `compute-matrix` coerces this to the string `"true"`/`"false"` in its JSON output (Tekton matrix params are strings — see below). |

### Why these three keys and only these three

The matrix is intentionally minimal. If a future Pipeline needs more
dimensions (e.g. a `compiler-version` axis for testing GCC 13 vs 14),
that is a separate matrix and a follow-up issue. Don't bolt new keys
onto `matrix.yaml` speculatively — adding a fourth key per cell
multiplies the cell count and forces every existing branch's
`matrix.yaml` to ship the new key.

---

## The `compute-matrix` Task

`tasks/compute-matrix/task.yaml` is a one-step Task that reads
`matrix.yaml` from a source workspace and emits the cells as a JSON
Tekton Result.

### Params

| Name          | Type   | Default                                | Notes                                                                                                                              |
|---------------|--------|----------------------------------------|------------------------------------------------------------------------------------------------------------------------------------|
| `source-ref`  | string | `""`                                   | The git ref the workspace was populated with. Only used in log + error messages so a reader can find the bad ref quickly.          |
| `matrix-file` | string | `matrix.yaml`                          | Path to the matrix YAML, relative to the source workspace root. Override only if your source tree puts it somewhere non-standard.   |
| `tools-image` | string | `docker.io/mikefarah/yq:4.40.7`        | Alpine-based yq image with `/bin/sh` (Tekton's `script:` shim requires a real shell — distroless images don't work).               |

### Workspaces

| Name     | Mount path             | Notes                                                                                                                                                |
|----------|------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| `source` | `/workspace/source`    | Mounted read-only. Populated by an upstream Task (usually the Tekton catalog `git-clone`). The Task reads `${source}/${matrix-file}` and nothing else. |

### Results

| Name           | Shape         | Notes                                                                                                                                                                                                                                                       |
|----------------|---------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `matrix`       | JSON string   | The JSON array of `{distro, arch, gating}` objects. Consumed by downstream Tasks via `matrix: { include: $(tasks.compute-matrix.results.matrix[*]) }`.                                                                                                       |
| `cell-count`   | integer string | Total cell count. Lets a Pipeline log "fanning out across N cells" or a downstream assert step sanity-check `len(matrix) == cell-count`.                                                                                                                    |
| `gating-count` | integer string | Count of cells whose `gating == "true"`. Pipelines can assert "at least N gating cells" as a sanity check before fanning out — catches a `matrix.yaml` that accidentally marks every cell as non-gating.                                                     |

### Locked JSON-array shape

```json
[
  {"distro": "centos9",        "arch": "x86_64",  "gating": "true"},
  {"distro": "centos9",        "arch": "aarch64", "gating": "true"},
  {"distro": "centos10",       "arch": "x86_64",  "gating": "true"},
  {"distro": "centos10",       "arch": "aarch64", "gating": "true"},
  {"distro": "ubuntu-jammy",   "arch": "x86_64",  "gating": "true"},
  {"distro": "ubuntu-jammy",   "arch": "aarch64", "gating": "true"},
  {"distro": "ubuntu-noble",   "arch": "x86_64",  "gating": "true"},
  {"distro": "ubuntu-noble",   "arch": "aarch64", "gating": "true"},
  {"distro": "fedora-rawhide", "arch": "x86_64",  "gating": "false"},
  {"distro": "fedora-rawhide", "arch": "aarch64", "gating": "false"}
]
```

**The `gating` field is a string, not a bool.** Tekton's `matrix:`
field passes each cell's object keys as param values, and Tekton params
are typed `string | array | object` — there is no `bool`. The Task
coerces YAML `true`/`false` into the literal strings `"true"`/`"false"`
via `yq tostring`. Downstream Tasks read `$(params.gating)` and decide
gating behaviour with:

```sh
case "${gating}" in
  true)  echo "[build] gating cell; failure fails the PipelineRun" ;;
  false) echo "[build] non-gating cell; failure is informational"  ;;
  *)     echo "[build] unrecognised gating='${gating}'" >&2; exit 1 ;;
esac
```

---

## Downstream fan-out via Tekton's `matrix:` field

Downstream Tasks (`build-package` / #17, `publish-repo` / #22,
`build-container` / #24) read the `matrix` Result and expand into one
TaskRun per cell using Tekton's `matrix.include` field:

```yaml
spec:
  tasks:
    - name: compute-matrix
      taskRef:
        name: compute-matrix
      params:
        - name: source-ref
          value: $(params.git-revision)
      workspaces:
        - name: source
          workspace: source
    - name: build
      runAfter: [compute-matrix]
      taskRef:
        name: build-package
      matrix:
        include: $(tasks.compute-matrix.results.matrix[*])
      params:
        - name: distro
          value: $(matrix.distro)
        - name: arch
          value: $(matrix.arch)
        - name: gating
          value: $(matrix.gating)
      workspaces:
        - name: source
          workspace: source
```

Tekton expands `matrix.include` to one TaskRun per array element, each
with `params.distro` / `params.arch` / `params.gating` set from the
element's object keys. The TaskRuns are scheduled in parallel; the
PipelineRun completes when every cell completes (or, for non-gating
cells, completes regardless of outcome).

Requires Tekton Pipelines ≥ v0.50 for Result-driven matrix fan-out.
ceph-tekton ships v1.6.0 (see `kustomize/base/tekton-pipelines/`).

---

## Default-matrix fallback

If `matrix.yaml` is **absent** at the source ref, `compute-matrix`
emits a documented default matrix and logs a warning to stderr:

```json
[
  {"distro": "centos10",     "arch": "x86_64",  "gating": "true"},
  {"distro": "centos10",     "arch": "aarch64", "gating": "true"},
  {"distro": "ubuntu-noble", "arch": "x86_64",  "gating": "true"},
  {"distro": "ubuntu-noble", "arch": "aarch64", "gating": "true"}
]
```

### Rationale

Old release branches (anything before this work landed) don't have a
`matrix.yaml` and won't get one — back-porting infra config to every
historical branch is a make-work tax we'd rather not pay. Failing the
PipelineRun loudly would make every CI run on those branches red until
someone hand-backports a YAML file.

Instead, the Task picks "the modern long-term-support cell set" as a
graceful default: centos10 + ubuntu-noble cover the actively-supported
RPM and DEB distros, on both arches, all gating. That gets a sensible
build out the door without requiring a backport.

When a release branch backports an explicit `matrix.yaml`, it
overrides the default — same code path either way.

If `matrix.yaml` exists but is malformed (no `cells:` key, empty
list, or a cell missing one of `distro`/`arch`/`gating`), the Task
fails loud. A broken file is a misconfiguration to fix, not something
to silently paper over with the default.

---

## Smoke test

`pipelines/pipelines/compute-matrix-smoke-test.yaml` exercises the Task end-to-end
without depending on a real source clone. Three Tasks:

  1. `seed`           — writes a synthetic `matrix.yaml` (3 cells, 2
                        gating, 1 non-gating) into a shared emptyDir
                        workspace.
  2. `compute-matrix` — the real Task, against the seeded workspace.
  3. `assert-results` — re-parses the JSON Result and asserts shape +
                        counts match the seeded values.

The e2e harness in `hack/e2e/assert-compute-matrix-smoke.sh` runs this
PipelineRun, waits for `Succeeded`, then re-pulls the `matrix` Result
off the TaskRun from the test host and re-validates the JSON shape with
`jq` as a defensive double-check.

---

## See also

* `tasks/compute-matrix/task.yaml`   — the Task itself, with per-step rationale.
* `pipelines/pipelines/compute-matrix-smoke-test.yaml` — the smoke pipeline.
* `hack/e2e/assert-compute-matrix-smoke.sh`  — the e2e assertion script.
* `docs/architecture.md` § "Build matrix"    — high-level overview.
* `docs/builder-images.md`                   — what each `distro` slug names.
* [#15](https://github.com/mmgaggle/ceph-tekton/issues/15) — the issue this Task closes.
* [#11](https://github.com/mmgaggle/ceph-tekton/issues/11), [#17](https://github.com/mmgaggle/ceph-tekton/issues/17), [#22](https://github.com/mmgaggle/ceph-tekton/issues/22), [#24](https://github.com/mmgaggle/ceph-tekton/issues/24) — downstream Pipelines that consume the `matrix` Result.

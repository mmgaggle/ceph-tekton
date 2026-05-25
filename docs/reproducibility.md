# Reproducible builds — harness + roadmap

A build is **reproducible** when re-running it on a different host, at a
different time, by a different user produces byte-identical output. The
goal is verifiable provenance: a third party can independently rebuild
a release and check that the bytes they got match the bytes Sepia
signed.

`ceph-tekton` ships a reproducibility-check harness so we can track this
as a *metric over time* — even before the underlying builds are 100%
reproducible. ~95% is the realistic ceiling for a 7M-line C++ codebase
based on Debian's multi-year experience. Chasing the last 5% is
upstream-community work and is explicitly out of scope for phase 1.

> Related but separate: cryptographic provenance (who built it, when,
> from what source) lives in [`provenance.md`](provenance.md). Provenance
> tells you *who* built an artifact; reproducibility tells you whether
> *anyone else* can produce the same bytes.

---

## What "reproducible" actually requires

A build pipeline emits non-deterministic bytes for predictable reasons.
Almost all of them collapse to a small set of environment variables and
tool flags — no source patching, no toolchain swap.

| Source of non-determinism | Fix |
|---|---|
| Embedded build timestamps (`__DATE__`, `__TIME__`, package build-dates) | `SOURCE_DATE_EPOCH` — honoured by gcc, dpkg-buildpackage, rpmbuild, tar, gzip, ar |
| Build-host absolute paths embedded in DWARF debug info / `__FILE__` | `-ffile-prefix-map=$PWD=.` in CFLAGS/CXXFLAGS |
| Locale-sensitive sort order (filenames in tar, symbol order in archives) | `LC_ALL=C` |
| Timezone-dependent timestamps in logs/changelog entries | `TZ=UTC` |
| Umask leaking host policy into output file modes | `umask 022` |
| tar capturing host uid/gid + FS iteration order | `tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@$SOURCE_DATE_EPOCH` |
| Random suffixes in temp dirs / PGO profile names | Bind a fixed `TMPDIR` per build, set `PYTHONHASHSEED=0` for python helpers |
| Parallel-make non-determinism (rare; usually a Makefile bug) | Treat as an upstream fix; do **not** serialise by setting `-j1` — that masks the bug for one build but doesn't fix it |

We are NOT switching off cmake, swapping compilers, vendoring deps,
freezing the kernel, or doing anything else that would diverge the
build from upstream practice. The harness measures, the env hygiene
fixes the easy wins, and the remaining %-points get filed as
upstream-ceph issues with diffoscope evidence attached.

---

## The harness

`tasks/reproducibility-check/task.yaml` is a self-contained Tekton Task:

1. Clones the source twice into two clean workspaces.
2. Exports the env stanza (`SOURCE_DATE_EPOCH`, `LC_ALL=C`, `TZ=UTC`,
   `umask 022`, `CFLAGS += -ffile-prefix-map=$PWD=.`).
3. Runs the build command in each clone.
4. Collects matching outputs via a glob into `staging-{a,b}/`.
5. Runs `diffoscope --html-dir … --json …` between the two staging dirs.
6. Computes a size-weighted reproducibility percentage and emits four
   Tekton Results:
   - `reproducible_bytes` — bytes that hashed identically in both builds
   - `total_bytes` — total bytes of build-A output
   - `pct_match` — `reproducible_bytes / total_bytes × 100`
   - `report_url` — S3 URL of the uploaded diffoscope HTML (empty if
     upload was skipped)
   - `source_date_epoch` — the timestamp actually used (for audit)
7. Uploads the HTML + JSON reports to S3 at
   `<branch>/<sha>/reproducibility/diffoscope.{html,json}`.

### Failure semantics

**First-run posture is informational** (per issue #48): a non-empty
diffoscope output emits the report and a low `pct_match` Result but
does **not** fail the PipelineRun. Tracking is via the Results +
dashboard. The goal is "watch the % trend up" — gating on 100%
reproducibility from day one would block every PipelineRun.

To gate (once a target is known-reproducible and regressions should
fail the build), pass `fail-on-diff: "true"` to the Task.

---

## Running the harness

### Against the bundled smoke target

The `pipelines/reproducibility-check.yaml` Pipeline defaults to the
cheapest possible "build" that still proves the harness mechanism
end-to-end — a deterministic tar of `/etc/os-release`:

```sh
kubectl apply -f tasks/reproducibility-check/task.yaml
kubectl apply -f pipelines/reproducibility-check.yaml

cat <<'EOF' | kubectl create -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: reproducibility-check-smoke-
spec:
  pipelineRef:
    name: reproducibility-check
  workspaces:
    - name: scratch
      emptyDir: {}
    - name: s3-credentials
      emptyDir: {}        # skip upload in dev
EOF
```

Expected Results: `pct_match=100.000`, `reproducible_bytes` matches the
tar size, `report_url` empty (upload skipped). If this is anything
other than 100%, the harness itself is broken.

### Against an arbitrary cmake target

```yaml
spec:
  pipelineRef:
    name: reproducibility-check
  params:
    - name: source-repo
      value: https://github.com/example/hello-cmake.git
    - name: build-command
      value: "cmake -B build -S . && cmake --build build"
    - name: output-glob
      value: "build/**/*"
    - name: builder-image
      value: docker.io/library/gcc:13-bookworm
```

### Against a deb build

```yaml
params:
  - name: source-repo
    value: https://github.com/ceph/ceph.git
  - name: source-ref
    value: v19.2.0
  - name: build-command
    value: "dpkg-buildpackage -us -uc -b -j$(nproc)"
  - name: output-glob
    value: "../*.deb"   # dpkg-buildpackage writes one dir up
  - name: builder-image
    value: registry.example.com/ceph-builder:ubuntu-noble-x86_64
```

### Against an rpm build

```yaml
params:
  - name: build-command
    value: "rpmbuild -bb --define '_topdir $PWD/rpmbuild' ceph.spec"
  - name: output-glob
    value: "rpmbuild/RPMS/**/*.rpm"
  - name: builder-image
    value: registry.example.com/ceph-builder:centos10-x86_64
```

### Standalone (without Tekton, for local debugging)

The env stanza is portable. To repro a build locally:

```sh
# Clone twice into clean dirs
git clone https://github.com/ceph/ceph.git /tmp/a
git clone https://github.com/ceph/ceph.git /tmp/b

for d in /tmp/a /tmp/b; do
  cd "$d"
  export SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
  export LC_ALL=C TZ=UTC
  umask 022
  export CFLAGS="${CFLAGS:-} -ffile-prefix-map=$PWD=."
  export CXXFLAGS="${CXXFLAGS:-} -ffile-prefix-map=$PWD=."
  # ... your build command here ...
done

diffoscope --html-dir /tmp/diff/ /tmp/a/build/ /tmp/b/build/
```

---

## Interpreting diffoscope output

Diffoscope produces a nested diff that "peels" archives, packages, and
binaries down to the bytes that actually differ. The most common
patterns and what they mean:

| Pattern in the HTML report | Root cause | Fix |
|---|---|---|
| `Mtime: Fri Jan  1 …` vs `Mtime: Tue May 25 …` differs on most files | `SOURCE_DATE_EPOCH` not propagated into the build (CMake `configure_file`, custom scripts) | Set `SOURCE_DATE_EPOCH` before invoking the build; for cmake, ensure `set(CMAKE_BUILD_TYPE …)` doesn't strip it |
| `DW_AT_comp_dir` / debug info paths differ (`/build/abc123/src/foo.cc` vs `/build/def456/src/foo.cc`) | Build dir embedded in DWARF | `-ffile-prefix-map=$PWD=.` (Task already sets this) |
| `Build-ID` differs but every other byte matches | Build-ID is hashed from input bytes; this means the input bytes already match — usually a compiler bug or `__TIME__` macro | Grep source for `__TIME__`/`__DATE__`, replace with constants; file upstream |
| Symbol order differs in a `.a` archive | `ar` ran without `D` flag or with locale-dependent sort | `ARFLAGS=Dcr` or `ar -D` (deterministic mode) |
| File count differs between A and B | Glob matched temporary files (`.tmp`, `.swp`) — bug in `output-glob`, not the build | Tighten the glob |
| Identical files but different sha256 in JSON report | Filesystem-level extended-attribute (xattr) or ACL diff that tar captured | Add `--no-xattrs --no-acls` to tar; for cp, `cp -p` is fine but `cp --preserve=all` is not |

When in doubt, the JSON report (`diffoscope.json`) has machine-readable
details suitable for grep / jq.

---

## Wiring into `build-package` (issue #16)

The env-prep stanza below is the canonical block to paste into the
`build-package` Task once #16 lands. It is intentionally identical to
the stanza inside the reproducibility-check Task so that what the
harness measures and what the real builds do can never drift.

```bash
# --- BEGIN reproducible-build env stanza ----------------------
# Pinned by issue #48. Keep in sync with tasks/reproducibility-check/.
export SOURCE_DATE_EPOCH="$(git log -1 --pretty=%ct)"
export LC_ALL=C
export TZ=UTC
umask 022
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=$PWD=."
export CXXFLAGS="${CXXFLAGS:-} -ffile-prefix-map=$PWD=."
# --- END reproducible-build env stanza ------------------------
```

That stanza covers ~80% of common non-determinism without changing any
upstream source. The remaining %-points are tracked as upstream issues
with diffoscope evidence — file them, don't paper over them in the
build script.

The `build-package` Task should ALSO be configured so its outputs are
the inputs to a follow-up `reproducibility-check` Task in the same
PipelineRun, so we get a `pct_match` Result on every real build, not
just on the smoke-test cadence. The reuse pattern is straightforward
once both Tasks exist:

```yaml
tasks:
  - name: build
    taskRef:
      name: build-package    # provided by #16
    params: [ ... ]
  - name: repro-check
    runAfter: [build]
    taskRef:
      name: reproducibility-check
    params:
      - name: source-repo
        value: $(params.source-repo)
      - name: build-command
        value: $(params.build-command)
      - name: output-glob
        value: "$(tasks.build.results.output-dir)/**/*"
      - name: fail-on-diff
        value: "false"       # informational; flip to true post-bring-up
```

---

## Promoting S3 upload to OIDC for production

The Task accepts S3 credentials two ways:

1. **Dev** — static creds mounted from a k8s Secret into the
   `s3-credentials` workspace. Files `AWS_ACCESS_KEY_ID`,
   `AWS_SECRET_ACCESS_KEY`, optionally `AWS_SESSION_TOKEN` are read at
   upload time.
2. **Sepia (production)** — workspace is empty; the calling Pipeline
   wires `AssumeRoleWithWebIdentity` via the build pod's projected SA
   token against RGW's OIDC trust. The `aws` CLI auto-resolves these
   via the standard SDK env vars (`AWS_ROLE_ARN`,
   `AWS_WEB_IDENTITY_TOKEN_FILE`) that the Tekton SA-token projection
   sets. See `docs/architecture.md` "Provenance & trust model" for the
   STS trust chain.

The Task itself doesn't need to know which mode it's in — both paths
land the same `s3://bucket/branch/sha/reproducibility/diffoscope.*`
objects.

---

## Dashboard

`charts/ceph-tekton-stack/dashboards/reproducibility.json` is a one-panel
Grafana dashboard tracking the `pct_match` Result over time. It will
auto-provision once #42 (Grafana stack) lands; until then the JSON is
documented forward-compat.

---

## Caveats and honest limits

- **The ceiling is ~95% for ceph itself.** Debian's reproducible-builds
  project has been iterating since 2014 and across all of Debian sits
  at ~96% reproducible. Ceph's surface area (Python, C++, Cython,
  Rust, generated protos) means we should plan for years of
  incremental improvement, not a single sprint.
- **The harness is the start, not the goal.** Emitting `pct_match` as
  a Result + dashboard makes regressions visible. Fixing them is
  upstream-ceph work and lives outside this repo.
- **Diffoscope CAN be slow on large RPM/DEB packages** (minutes per
  diff for a multi-GB debuginfo package). The Task does not time-box
  diffoscope by default; if a real-build wiring trips this, add
  `--max-text-report-size 0 --timeout 600` to the diffoscope invocation
  in the Task.
- **`-ffile-prefix-map` requires gcc >= 8 / clang >= 10.** Older
  toolchains in the matrix (centos-stream-9 etc) all satisfy this; if
  a new target distro doesn't, the env stanza needs a fallback to
  `-fdebug-prefix-map`.
- **Reproducibility != security.** A reproducible build is verifiable;
  it is not automatically safe. Sigstore + SLSA (see
  [`provenance.md`](provenance.md)) handle the trust side. The two are
  complementary, not substitutes.

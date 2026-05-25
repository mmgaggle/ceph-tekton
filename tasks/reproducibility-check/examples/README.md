# Reproducibility-check synthetic examples

Small, deliberately non-reproducible build targets used to exercise the
`reproducibility-check` Task end-to-end without needing the full ceph
builder image (issue #10).

Each subdirectory pairs a **broken** target (surfaces a real diffoscope
finding) with a **fixed** target (the same code with the canonical fix
applied). The pair is the "Round 1" demonstration of the iteration loop
documented in [`docs/reproducibility-status.md`](../../../docs/reproducibility-status.md):

> read latest diffoscope report → identify top non-determinism source →
> patch → re-verify → track % match trend.

## Examples

| Directory | Non-determinism category | Canonical fix |
|---|---|---|
| [`timestamps/`](timestamps/) | `__DATE__` / `__TIME__` preprocessor macros embedded in `.rodata` | Override the macros from `SOURCE_DATE_EPOCH` via `-D__DATE__=...` |

More examples will be added as we exercise additional categories
(build-path leakage, archive symbol order, hash-table iteration, etc.)
before the real ceph builder image lands.

## How to use these from the Tekton Task

The `reproducibility-check` Task accepts an arbitrary build-command and
output-glob. Point them at one of these examples to reproduce a known
diffoscope finding without needing the ceph source tree:

```yaml
spec:
  pipelineRef:
    name: reproducibility-check
  params:
    - name: source-repo
      value: https://github.com/mmgaggle/ceph-tekton.git
    - name: build-command
      value: "cd tasks/reproducibility-check/examples/timestamps && make broken"
    - name: output-glob
      value: "tasks/reproducibility-check/examples/timestamps/hello-broken"
    - name: builder-image
      value: docker.io/library/gcc:13-bookworm
```

Run again with `make fixed` / `hello-fixed` to watch `pct_match` jump
from <100 to 100.

## How to use these locally (no Tekton)

Each example's Makefile exposes a `demo-broken` and `demo-fixed` target
that builds twice, one second apart, and prints whether the two
binaries' sha256 match:

```sh
cd tasks/reproducibility-check/examples/timestamps
make demo-broken    # prints two different sha256s — NON-REPRODUCIBLE (expected)
make demo-fixed     # prints two identical sha256s   — REPRODUCIBLE (expected)
```

For a full byte-level diff (the same view diffoscope produces in CI),
build manually then point diffoscope at the two binaries:

```sh
cd tasks/reproducibility-check/examples/timestamps
make broken; cp hello-broken /tmp/a
sleep 1
make clean; make broken; cp hello-broken /tmp/b
diffoscope /tmp/a /tmp/b
```

### Platform note: macOS

The `demo-fixed` helper expects a Linux GNU toolchain (which is what
the `reproducibility-check` Task uses inside its build container). On
macOS the demo surfaces ld64's `LC_UUID` Mach-O load command, which is
computed from the binary's contents plus a random nonce by default and
does not honor `SOURCE_DATE_EPOCH`. Even with the `__DATE__`/`__TIME__`
override applied, `make demo-fixed` on macOS will report
`NON-REPRODUCIBLE`.

To verify the "fixed" pattern actually works as documented, run in a
Linux container (or on a remote Linux build host):

```sh
podman run --rm -v "$(pwd)":/work -w /work \
    docker.io/library/gcc:13-bookworm \
    make demo-fixed
# expected: REPRODUCIBLE (expected)
```

The Tekton harness always runs in a Linux container, so the production
path is unaffected by this macOS-only quirk.

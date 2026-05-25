# Running ceph-tekton locally

The Tekton manifests in this repo are designed to run on **Sepia OpenShift**
*and* on a contributor's laptop via **kind**. This page walks through the
laptop side: bootstrap a single-node kind cluster, install Tekton Pipelines,
and run the smoke-test pipeline.

## Prerequisites

| Tool                       | Install (macOS / Linux)               |
|----------------------------|---------------------------------------|
| kubectl ≥ 1.30             | `brew install kubectl`                |
| kind ≥ 0.24                | `brew install kind`                   |
| tkn (Tekton CLI) ≥ 0.39    | `brew install tektoncd-cli`           |
| docker **or** podman       | `brew install --cask docker` *or* `brew install podman` |
| GNU make                   | preinstalled on macOS; `apt install make` on Debian/Ubuntu |

The `make dev-up` target detects whether you have docker or podman and
sets `KIND_EXPERIMENTAL_PROVIDER=podman` automatically when needed. On
macOS with podman you also need `podman machine start` (the script will
attempt this for you).

## Bootstrap

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

## Troubleshooting

### `make dev-up` fails to start podman machine

If you're on macOS with podman and have never initialized the VM:

```sh
podman machine init
podman machine start
```

Then re-run `make dev-up`.

### `tekton-pipelines` controller stuck in `ImagePullBackOff`

kind sometimes hits Docker Hub rate limits on first pull. Wait a minute and
re-run `make dev-up` — it's idempotent and will only re-apply the manifests.
Authenticated pulls (`kind load docker-image`) sidestep the rate limit if
this is recurrent.

### Renderingwithout applying

You can render the manifests without touching a cluster:

```sh
make kustomize-validate           # validates every overlay renders cleanly
kubectl kustomize kustomize/overlays/dev-local/   # print the rendered YAML
```

## Iterating on a Task

Edit a Task or Pipeline YAML under `tasks/` or `pipelines/`, then:

```sh
kubectl apply -f pipelines/<your-file>.yaml
tkn pipeline start <pipeline-name> --showlog
```

For the full PaC-driven dev loop (pointing Pipelines-as-Code at a personal
fork of `ceph/ceph` so PRs trigger your local pipelines), see the PaC
section once issue #3 lands.

## What's not in the dev cluster yet

The dev overlay only installs Tekton Pipelines itself. Components that get
added in later issues:

- Pipelines-as-Code (#3) — GitHub webhook ingress + per-PR pipelines
- Tekton Chains (#4) — SLSA attestations + signing
- Vault (#5) — repo-metadata GPG signing via transit
- ceph-builds-api (#29) — shaman API shim

Each will be added to the `dev-local` overlay as its issue lands. Until
then, the laptop cluster is intentionally minimal — enough to develop
Tasks and Pipelines against, not a full production replica.

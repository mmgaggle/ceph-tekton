# charts/kyverno

Wrapper around the official **Kyverno** helm chart for the ceph-tekton
stack.

This directory does **not** vendor the upstream chart; it only ships the
two values files (`values-dev.yaml`, `values-sepia.yaml`) and pins the
chart version that the dev-up script installs.

| File                  | Used by                          | Scope                                   |
|-----------------------|----------------------------------|-----------------------------------------|
| `values-dev.yaml`     | `hack/dev-kyverno-up.sh`         | Local kind cluster, single-replica      |
| `values-sepia.yaml`   | *stub* (not deployed yet)        | Sepia production HA install, future     |
| `README.md`           | humans                           | install + ClusterPolicy companion notes |

## Pinned chart version

```
kyverno/kyverno   chart 3.3.7   (Kyverno v1.13.4 appVersion)
```

The pin lives in `hack/dev-kyverno-up.sh` as `KYVERNO_CHART_VERSION`.
Bump it in a PR after testing the new chart against the smoke-test
pipeline (`pipelines/pipelines/kyverno-smoke-test.yaml`).

The Kyverno API surface this code consumes — `ClusterPolicy` with a
`verifyImages` rule and `attestors.entries.keys` / `.keyless` — is
stable since chart 3.0 / Kyverno 1.10. Bumps within the 3.x line
should not require ClusterPolicy edits; if they do, the chart's
release notes will say so.

## What this install gives you

- Kyverno admission controller, background controller, cleanup
  controller, and reports controller.
- The cluster admission webhook is the enforcement point for the
  `verifyImages` rule in
  `kustomize/base/kyverno-policies/verify-ceph-image-signatures-dev.yaml`.
- Excludes the namespaces that host the Tekton stack itself
  (`tekton-pipelines`, `tekton-chains`, `vault`, `pipelines-as-code`,
  `kyverno`, all `kube-*`) so a policy outage cannot brick the stack
  it sits next to.

## Install (dev)

The smoke path is the script — `helm install` + wait + a status print:

```sh
./hack/dev-kyverno-up.sh
```

Manual equivalent, if you want to step through it:

```sh
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version 3.3.7 \
  --values charts/kyverno/values-dev.yaml

kubectl -n kyverno wait --for=condition=ready pod \
  -l app.kubernetes.io/component=admission-controller \
  --timeout=180s

# Apply the ClusterPolicies the dev cluster should enforce.
kubectl apply -k kustomize/base/kyverno-policies/

# Run the smoke test. Issue #68 split the smoke pipeline into
# single-resource files; apply the setup, Task, then Pipeline.
kubectl apply -f pipelines/setup/kyverno-smoke-rbac.yaml
kubectl apply -f pipelines/tasks/try-pod-admit.yaml
kubectl apply -f pipelines/pipelines/kyverno-smoke-test.yaml
tkn pipeline start kyverno-smoke-test --showlog
```

See `docs/deploy-verification.md` for the end-to-end story (what the
policy enforces, how to extend it, common failure modes).

## Day-2 ops

### Inspecting policy reports

Kyverno records every admission decision as a `PolicyReport`:

```sh
kubectl get policyreport -A
kubectl describe policyreport -n default <name>
```

The `kyverno-smoke-test` pipeline reads these to confirm the expected
admit/reject outcome.

### Listing active policies

```sh
kubectl get clusterpolicy
kubectl describe clusterpolicy verify-ceph-image-signatures-dev
```

The `.status.conditions` show whether the policy was successfully
loaded; `.status.ready` is true once Kyverno's policy controller has
synced.

### Watching the admission controller

```sh
kubectl -n kyverno logs -l app.kubernetes.io/component=admission-controller -f
```

A failed verifyImages decision logs the cosign error reason, which the
smoke-test asserts on.

## Sepia (production) — stub only

`values-sepia.yaml` is a *stub*: it captures the production stance
(HA, `failurePolicy: Fail`, PDBs, anti-affinity, ServiceMonitor wiring,
OpenShift namespace exclusions) but is **not installed by any script
in this repo**. The Sepia install is tracked separately and will land
once the Chains Fulcio overlay is in place — the verifyImages policy
needs Sepia's SA-token issuer URL hard-coded into the
`certificate-identity-regexp`.

The matching policy file is
`kustomize/base/kyverno-policies/verify-ceph-image-signatures-sepia.yaml`;
the placeholder identity it uses must be replaced with the real
issuer at install time. See the TODO block at the bottom of
`values-sepia.yaml` for the full list of decisions pending before that
stub is production-ready.

## Why dev mode for local

The kind dev cluster is throwaway state for an individual developer's
laptop. Single-replica controllers and `failurePolicy: Ignore` trade
robustness for an install-in-30-seconds experience: a wedged Kyverno
doesn't block `kubectl apply`, and there's no PDB to fight with when
you `make dev-down`.

This trade-off is **never acceptable on Sepia**. See `values-sepia.yaml`
for the production stance and the TODOs that must be resolved before
that stub becomes a real install.

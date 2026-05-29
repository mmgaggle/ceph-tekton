# charts/ceph-tekton-stack/dashboards

Grafana dashboard JSON for the ceph-tekton stack. These files are the
artifact; the chart that mounts them into Grafana's sidecar-discovered
ConfigMaps is the remainder of issue #41 (kube-prometheus-stack
install) and is not yet in this repo.

## Inventory

| File                      | Title              | UID                            | Issue |
|---------------------------|--------------------|--------------------------------|-------|
| `build-health.json`       | Ceph Build Health  | `ceph-tekton-build-health`     | #42   |
| `reproducibility.json`    | Reproducibility    | `ceph-tekton-reproducibility`  | #48   |

## Data source

All panels target a Prometheus datasource via the `${DS_PROMETHEUS}`
template variable that Grafana wires up at import time. Tekton metrics
land in Prometheus through the `ServiceMonitor` shipped in the sepia
overlay (`kustomize/overlays/sepia/servicemonitor-tekton-pipelines.yaml`,
issue #41). PromQL selectors pin to
`{job="tekton-pipelines-controller", namespace="openshift-pipelines"}`
to match what that ServiceMonitor produces.

## Provisional panels

Some panels query metrics that the standard Tekton controller does not
emit — `ceph_builds_pipelinerun_total{distro, arch, ...}`, sccache hit
rate, etc. Those come from the `ceph-builds-api` custom exporter that
is the other half of issue #41. Until that exporter is wired, the
affected panels are empty (no series). Each such panel is titled
`PROVISIONAL` and its description names the issue tracking the missing
metric.

This mirrors the posture taken by `reproducibility.json`: ship the
panel JSON forward-compat with the documented metric inventory so the
dashboard layout is stable across the cutover, and let the panels
populate as their sources land.

## Local preview (until the Grafana sidecar lands)

The dashboards are valid Grafana v9/v10 JSON and can be imported into
any Grafana instance:

```sh
# Bring up a throwaway Grafana pointed at your local Prometheus,
# then Dashboards -> Import -> paste the JSON.
podman run --rm -p 3000:3000 grafana/grafana:10.4.1
# open http://localhost:3000 (admin / admin)
```

On a kind dev cluster with kube-prometheus-stack already installed
(future state, post-#41) the same JSON is auto-provisioned by the
Grafana sidecar via a `ConfigMap` labeled `grafana_dashboard=1`. The
chart that produces that ConfigMap from these files lives with the
kube-prometheus-stack install and is **not** in this directory.

## OpenShift posture

On Sepia the on-call view goes through OpenShift's platform Grafana
(or its replacement once OpenShift's deprecated Grafana operator
posture settles). The same JSON imports cleanly there; the panels just
need Prometheus to actually be scraping the targets the ServiceMonitor
declares. See `docs/architecture.md` §"Observability" for the
phase-1 vs platform-monitoring trade-off.

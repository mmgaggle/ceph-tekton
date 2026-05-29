# Build archive — Tekton CloudEvents → S3 (phase 1 slice)

ceph-tekton archives every PipelineRun + TaskRun lifecycle transition
to S3 as JSON-Lines, partitioned by date. This is the
analytics / audit surface that closes the continuous-verification
loop the SSDF posture table in
[`../README.md`](../README.md#supply-chain-compliance-posture) calls
out for issue
[#63](https://github.com/mmgaggle/ceph-tekton/issues/63).

This page covers what's shipped in the **phase-1 minimal slice**:
the S3 bucket, the sink service, and how to enable Tekton's
CloudEvents controller. The fuller analytics surface (DuckDB query
recipes, Parquet promotion, the replay-from-archive procedure,
schema documentation) is queued in #63's acceptance criteria but
not in this slice — see
[§"Out of scope for the minimal slice"](#out-of-scope-for-the-minimal-slice).

## Why CloudEvents, not Tekton Results

Tekton Results stores PipelineRun + TaskRun history in postgres
behind a gRPC API. That's a database we'd own — backups,
schema migrations, patching, monitoring. Issue
[#59](https://github.com/mmgaggle/ceph-tekton/issues/59) was filed
for that path; it was closed in favor of #63 because ceph-tekton's
posture is **stateless preference**: state lives in S3 or Vault,
never a project-owned DB.

Tekton's `cloud-events` controller emits the same lifecycle
information as a stream of CloudEvents 1.0 messages. Catching those
at a small stateless HTTP sink and writing them to S3 as JSON-Lines
gives us the audit + analytics coverage without the database. Issue
[#58](https://github.com/mmgaggle/ceph-tekton/issues/58) — the
per-PipelineRun-finally-task Parquet writer — was also superseded
because catching at the event boundary needs no per-Pipeline wiring.

## Architecture

```
  GitHub event           Tekton on OpenShift                       Sepia RGW
  ─────────────          ───────────────────                       ─────────
                         ┌──────────────────┐
  PR / branch / tag ───▶ │ PipelineRun runs │
                         └────────┬─────────┘
                                  │ lifecycle transitions
                                  ▼
                         ┌──────────────────┐
                         │ cloud-events     │  CloudEvents 1.0
                         │ controller       │  binary-mode HTTP POST
                         └────────┬─────────┘
                                  │ default-cloud-events-sink URL
                                  ▼
                         ┌──────────────────────────┐
                         │ cloudevents-sink Service │
                         │ (Flask, in-memory buffer)│
                         └────────┬─────────────────┘
                                  │ batched JSONL flush
                                  │ via boto3 + STS-OIDC
                                  ▼               s3://ceph-tekton-events/
                         ┌─────────────────────┐  events/dt=YYYY-MM-DD/
                         │ Ceph RGW            │       hr=HH/
                         │ ceph-tekton-events  │       <uuid>.jsonl
                         │ bucket (private)    │
                         └─────────────────────┘
                                  ▲
                                  │ operator-cred read only
                                  │
                         ┌─────────────────────┐
                         │ DuckDB / Athena     │  analytics queries
                         │ (operator laptop)   │  over the JSONL
                         └─────────────────────┘
```

The bucket is **private** — PipelineRun payloads include step logs,
internal URLs, and occasionally leaked secrets. This is the first
ceph-tekton S3 bucket without `*_public_read = true`; see
[`terraform/modules/s3-buckets/main.tf`](../terraform/modules/s3-buckets/main.tf)
§"ceph-tekton-events" for the bucket definition and
[`variables.tf`](../terraform/modules/s3-buckets/variables.tf)
§"events bucket" for the rationale.

## What ships in the phase-1 slice

| Component | Where it lives |
|---|---|
| `ceph-tekton-events` S3 bucket (private, no versioning, default 0d = never expire) | [`terraform/modules/s3-buckets/`](../terraform/modules/s3-buckets/) |
| Bucket wired into dev / dev-rgw / sepia envs | `terraform/environments/{dev,dev-rgw,sepia}/main.tf` |
| `cloudevents-sink` Flask service (single file) | [`services/cloudevents-sink/`](../services/cloudevents-sink/) |
| Container image (Dockerfile, requirements.txt) | `services/cloudevents-sink/Dockerfile` |
| `cloudevents-sink` Deployment + Service + SA + Role | [`kustomize/base/cloudevents-sink/`](../kustomize/base/cloudevents-sink/) |
| This doc | `docs/build-archive.md` |

### What landed in the follow-up slice

The Sepia TektonConfig wiring + e2e assertion shipped after the
initial minimal slice (still under #63):

| Component | Where it lives |
|---|---|
| `spec.pipeline.send-cloudevents-for-runs` + `default-cloud-events-sink` on Sepia TektonConfig | [`kustomize/overlays/sepia/tektonconfig-pruner.yaml`](../kustomize/overlays/sepia/tektonconfig-pruner.yaml) |
| `cloudevents-sink` base added to Sepia overlay (ordered before the TektonConfig so the Service resolves before the flag flips) | [`kustomize/overlays/sepia/kustomization.yaml`](../kustomize/overlays/sepia/kustomization.yaml) |
| e2e assertion driving a synthetic CloudEvent against the sink and verifying the JSONL lands in zgw-posix | [`hack/e2e/assert-cloudevents-sink.sh`](../hack/e2e/assert-cloudevents-sink.sh) |

### Out of scope for the current slice

The acceptance-criteria list in
[#63](https://github.com/mmgaggle/ceph-tekton/issues/63) is broader
than what's shipped to date. What is **not** in this slice and is
tracked in #63's open acceptance criteria for a future PR:

- The Parquet-row analytics columns described in
  [#63](https://github.com/mmgaggle/ceph-tekton/issues/63) §"Parquet
  schema". The sink stores raw JSON-Lines; Parquet promotion (with
  the denormalised columns: pipeline, branch, sha, distro, arch,
  status, duration, taskruns, artifacts, rekor_uuids) is a separate
  transform that can run as a Tekton CronJob over the JSONL.
- A `ceph-tekton-events` RGW role + OIDC trust policy. The kustomize
  Deployment is ready for the projected SA token + AWS_ROLE_ARN
  pattern (see deployment.yaml comments) but the trust policy lives
  in a terraform `rgw-roles` module that doesn't exist in-repo yet
  — same gap [`README.md`](../README.md) §"Repo layout" already
  flags. **Open question**: deploying to Sepia requires this module
  to exist; for now, dev-rgw + dev paths use static creds via Secret.
- DuckDB recipe page (long pole task by distro, queue-time trend,
  signed-Rekor latency, build success rate by branch) and the
  replay-from-archive procedure. The minimum query that confirms
  the sink is landing data is in
  [§"Reading the JSONL with DuckDB"](#reading-the-jsonl-with-duckdb)
  below; the recipe page is queued.

## Enabling Tekton CloudEvents

Tekton's `cloud-events` controller is off by default. Two settings
turn it on, both in the `feature-flags` ConfigMap (or the equivalent
`TektonConfig.spec.pipeline` field on OpenShift Pipelines):

| Setting | Default | What we set |
|---|---|---|
| `send-cloudevents-for-runs` | `false` | `true` |
| `default-cloud-events-sink` | (empty) | `http://cloudevents-sink.cloudevents-sink.svc.cluster.local` |

References:
- [Tekton Pipelines: Events](https://tekton.dev/docs/pipelines/events/)
- [Customizing the Pipelines controller behavior](https://tekton.dev/docs/pipelines/install/#customizing-the-pipelines-controller-behavior)

### On vanilla Tekton (kind / dev)

```sh
kubectl -n tekton-pipelines patch configmap feature-flags --type=merge \
  -p '{"data":{"send-cloudevents-for-runs":"true","default-cloud-events-sink":"http://cloudevents-sink.cloudevents-sink.svc.cluster.local"}}'
```

### On OpenShift Pipelines (Sepia)

The `TektonConfig` CR carries the same settings under
`spec.pipeline`. The operator reconciles them into the
`feature-flags` ConfigMap. Shipped in
[`kustomize/overlays/sepia/tektonconfig-pruner.yaml`](../kustomize/overlays/sepia/tektonconfig-pruner.yaml):

```yaml
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonConfig
metadata:
  name: config
spec:
  pipeline:
    send-cloudevents-for-runs: "true"
    default-cloud-events-sink: "http://cloudevents-sink.cloudevents-sink.svc.cluster.local"
```

**Caution**: enabling `send-cloudevents-for-runs` on a cluster where
the sink Service does not resolve will pile up retries in the
controller's log; the Sepia overlay's `resources:` list orders
`kustomize/base/cloudevents-sink` before this TektonConfig
specifically to make `kubectl apply -k` create the Service before
the operator reconciles the feature-flags flip.

## Event payload shape

Tekton emits in CloudEvents 1.0 binary-mode: the envelope fields live
in `Ce-*` HTTP headers and the body is the `data` payload (JSON, in
Tekton's case — typically the full PipelineRun or TaskRun status
object).

The sink writes one JSON object per line. The object shape is:

```json
{
  "specversion": "1.0",
  "id": "...",
  "source": "/apis/tekton.dev/v1beta1/namespaces/.../pipelineruns/...",
  "type": "dev.tekton.event.pipelinerun.successful.v1",
  "subject": "<pipelinerun-name>",
  "time": "2026-05-25T17:42:00Z",
  "datacontenttype": "application/json",
  "data": { /* the PipelineRun / TaskRun status object */ },
  "_headers":          { /* the raw Ce-* HTTP headers, lower-cased */ },
  "_sink_received_at": "2026-05-25T17:42:00.123Z",
  "_sink_id":          "<uuid the sink minted on receive>"
}
```

`_sink_received_at` + `_sink_id` are the sink's own bookkeeping —
they let an operator distinguish the same `id` arriving via two
separate paths (Tekton CloudEvents controller does not deduplicate
on retry).

Terminal PipelineRun event types are:

- `dev.tekton.event.pipelinerun.successful.v1`
- `dev.tekton.event.pipelinerun.failed.v1`
- `dev.tekton.event.pipelinerun.cancelled.v1`

…plus the per-TaskRun lifecycle equivalents, and the
`.started.v1` / `.running.v1` non-terminal events. The sink writes
**all** of them — filtering for terminal-only happens at query time
on the JSONL.

## Operations

### Reading the JSONL with DuckDB

```sh
duckdb -c "
SELECT type, COUNT(*) AS n
FROM read_json_auto('s3://ceph-tekton-events/events/**/*.jsonl',
                    format='newline_delimited')
WHERE dt = '2026-05-25'
GROUP BY 1 ORDER BY 2 DESC
"
```

Full recipe page (long pole task by distro, queue time trend, signed-
Rekor latency, build success rate by branch) is queued in #63 §"5.
Documentation". The above is the minimum query that confirms the
sink is landing data.

### Tail the sink

```sh
kubectl -n cloudevents-sink logs -f deploy/cloudevents-sink
```

The sink logs one line per flush:

```
INFO cloudevents-sink flushed n=37 key=s3://ceph-tekton-events/events/dt=2026-05-25/hr=17/<uuid>.jsonl reason=interval
```

`reason=size` means the 50-event threshold tripped; `reason=interval`
means the 30s wall-clock threshold tripped; `reason=shutdown` means
the pod received SIGTERM and did the final flush before exiting.

## Decisions

- **Single-file Flask** rather than Go. The repo has no `go.mod` yet
  (`services/ceph-builds-api/` is planned but unbuilt); introducing
  a Go module + build chain for a 200-line HTTP service is heavier
  than a single Python file the existing python image base
  (`python:3.12-slim`) already covers. If the rate ever justifies it,
  the Go rewrite is a self-contained swap that doesn't touch the
  contract.
- **In-memory buffer, no durable queue** (no Kafka, no Knative
  Eventing, no pre-S3 file spool). State stays in S3 only; a crash
  before flush loses up to `FLUSH_MAX_EVENTS` events. Explicit trade
  per the issue brief — Tekton's emission rate is low enough that
  this is acceptable for phase 1 analytics. A durable pre-S3 queue
  re-adds the stateful infra we're avoiding.
- **One Deployment replica + `strategy: Recreate`** rather than
  HA / rolling. Multi-replica defeats batching (each replica
  buffers separately); the in-memory buffer makes RollingUpdate
  unsafe (two pods sharing a Service would double-deliver during
  the overlap). If throughput becomes a bottleneck, the answer is
  `gunicorn -w 1` (single process, many threads) in front, not
  horizontal scale.
- **Private bucket** with no public-read knob in the module. Even
  the analytics path goes through operator creds. Step logs and
  occasional leaked secrets in PipelineRun payloads make the public
  posture the wrong default.
- **Default never-expire retention** (`events_expiration_days = 0`
  on the module). Long-window trend queries want as much history as
  storage budget allows; operators can set a finite ceiling per env.

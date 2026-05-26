# cloudevents-sink

HTTP receiver for Tekton PipelineRun + TaskRun CloudEvents, batched and
flushed to S3 as JSON-Lines (issue
[#63](https://github.com/mmgaggle/ceph-tekton/issues/63)).

Single-file Flask app. Stateless — buffer is in-memory only, flushes
to S3 on size threshold OR interval. No postgres, no PVC, no Kafka.
That tradeoff (a crash before flush loses up to `FLUSH_MAX_EVENTS`
events) is the explicit "stateless preference" called out in issue
#63 §"Why".

See [`../../docs/build-archive.md`](../../docs/build-archive.md) for
the architectural shape and where the sink fits in the broader
PipelineRun → CloudEvent → S3 → DuckDB flow.

## Configuration (env vars)

| Var | Default | Purpose |
|---|---|---|
| `EVENTS_BUCKET` | `ceph-tekton-events` | Destination bucket. |
| `EVENTS_KEY_PREFIX` | `events` | Key prefix under the bucket. |
| `S3_ENDPOINT_URL` | (unset → AWS default) | RGW / zgw-posix endpoint URL. |
| `AWS_REGION` | `default` | Region. RGW uses `default` (or its zonegroup name). |
| `FLUSH_MAX_EVENTS` | `50` | Flush when buffer hits this size. |
| `FLUSH_MAX_INTERVAL_SECONDS` | `30` | Flush after this much wall-clock since the last flush. |
| `LOG_LEVEL` | `INFO` | Python logging level. |

Credentials: standard boto3 chain. The Sepia deployment will set
`AWS_ROLE_ARN` + project a SA token at
`AWS_WEB_IDENTITY_TOKEN_FILE` — boto3 does `AssumeRoleWithWebIdentity`
natively. Dev / kind path: mount a Secret with
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` into the pod env.

## HTTP surface

- `POST /cloudevents` — receive a CloudEvent (binary or structured
  mode); response `202` with the current buffer size.
- `GET /healthz` — liveness; process is up.
- `GET /readyz` — readiness; S3 reachable (HEAD bucket).

## Run locally

```sh
pip install -r requirements.txt
EVENTS_BUCKET=ceph-tekton-events \
S3_ENDPOINT_URL=http://127.0.0.1:8000 \
AWS_ACCESS_KEY_ID=cephtekton AWS_SECRET_ACCESS_KEY=cephtekton \
python sink.py
```

`hack/verify-s3-module.sh` brings up a zgw-posix container with those
credentials; the sink will write to whatever bucket is named in
`EVENTS_BUCKET` (must already exist — terraform creates it).

## Build the image

```sh
docker build -t ceph-tekton/cloudevents-sink:dev .
```

In-cluster registry path is wired by the kustomize base
(`kustomize/base/cloudevents-sink/`). Production image production
(via a PipelineRun with Chains provenance) is follow-up work tracked
under the broader build-archive umbrella — for phase 1 the image is
built ad-hoc and pushed to the registry.

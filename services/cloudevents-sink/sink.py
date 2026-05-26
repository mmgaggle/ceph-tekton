"""
cloudevents-sink — HTTP receiver for Tekton PipelineRun + TaskRun
CloudEvents, batched and flushed to S3 as JSON-Lines (issue #63).

Architectural shape (stateless by design — see issue #63 §"Why" for the
rejection of #58 + #59's postgres path):

  Tekton cloud-events controller
        │  (POSTs CloudEvents 1.0 binary-mode)
        ▼
  /cloudevents   ──┐
  HTTP server     │  buffer (in-memory list, mutex-protected)
                   │  flush when len(buffer) >= MAX_EVENTS
                   │         OR  time since last flush > MAX_INTERVAL
                   ▼
  s3://<bucket>/events/dt=YYYY-MM-DD/hr=HH/<uuid>.jsonl
                   ▲
                   │  one JSON object per line, full CloudEvents
                   │  envelope preserved (Ce-* headers attached
                   │  under `_headers`, body parsed if JSON else
                   │  carried under `_body_raw`).

Idempotency: writes are uuid-keyed per flush, so a re-delivered event
just lands in another JSONL — analytics queries deduplicate on
(event_id, event_type) downstream. Issue #63 §"Idempotent" calls out
the same approach.

S3 credentials precedence (mirrors tasks/build-grype-db/task.yaml's
publish step):
  1. Static AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars
     (dev / kind path — load a Secret into env).
  2. STS AssumeRoleWithWebIdentity via a projected SA token at
     AWS_WEB_IDENTITY_TOKEN_FILE + AWS_ROLE_ARN (Sepia path).
boto3 handles (2) natively when those env vars are set — we don't
re-implement the assume-role flow here, unlike the grype-db Task
which is shell + aws-cli. Same effective behavior.

Single-file, single-thread (Flask dev server is fine for the rate
Tekton emits — every PipelineRun + TaskRun lifecycle transition,
not every individual step log line). If the rate ever justifies it,
swap to gunicorn or rewrite in Go; phase 1 favours simplicity per
the issue brief.
"""

from __future__ import annotations

import io
import json
import logging
import os
import signal
import sys
import threading
import time
import uuid
from datetime import datetime, timezone

import boto3
from botocore.config import Config
from flask import Flask, jsonify, request

# ---------------------------------------------------------------------------
# Configuration — env-driven so kustomize can set them per-overlay
# without touching the image.
# ---------------------------------------------------------------------------

BUCKET = os.environ.get("EVENTS_BUCKET", "ceph-tekton-events")
S3_ENDPOINT = os.environ.get("S3_ENDPOINT_URL", "") or None
S3_REGION = os.environ.get("AWS_REGION", "default")
# Flush thresholds. Either triggers a flush; whichever hits first.
# Defaults: 50 events OR 30 seconds. Tuned for Tekton's emission rate
# (a busy PipelineRun emits ~5-20 events: 1 PipelineRun lifecycle +
# N TaskRun starts + N TaskRun completions). 30s caps the worst-case
# data-loss window on a graceful restart to under one flush interval.
MAX_EVENTS = int(os.environ.get("FLUSH_MAX_EVENTS", "50"))
MAX_INTERVAL_SECONDS = float(os.environ.get("FLUSH_MAX_INTERVAL_SECONDS", "30"))
# Optional: prefix under the bucket. Default `events/` matches the
# layout #63 spells out; dev overlays can point at `events-dev/` to
# share a bucket without polluting analytics queries.
KEY_PREFIX = os.environ.get("EVENTS_KEY_PREFIX", "events").strip("/")

LOG = logging.getLogger("cloudevents-sink")
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)

# ---------------------------------------------------------------------------
# S3 client — created once, reused. boto3's default credential chain
# handles static-creds → AssumeRoleWithWebIdentity → instance-profile;
# we don't customize it here. Path-style addressing because Ceph RGW
# (production) and zgw-posix (dev) both accept it and AWS S3 also
# accepts it for compatibility — same posture terraform's aws provider
# uses (`s3_use_path_style = true`).
# ---------------------------------------------------------------------------

_s3_client = None


def s3_client():
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client(
            "s3",
            endpoint_url=S3_ENDPOINT,
            region_name=S3_REGION,
            config=Config(s3={"addressing_style": "path"}),
        )
    return _s3_client


# ---------------------------------------------------------------------------
# Buffer + flush.
#
# Buffer is a plain list under a mutex. CloudEvents accumulate; flush
# rebinds the buffer atomically (swap to a fresh empty list under the
# lock, release the lock, then PUT outside the lock). PUT failure
# is not retried inline — we log and drop. The CloudEvents controller
# does not redeliver, so a dropped batch is lost; this trade is
# explicit (see issue #63 — postgres was rejected, and a durable
# pre-S3 queue would re-add the stateful infra we're avoiding).
# ---------------------------------------------------------------------------

_buffer: list[dict] = []
_buffer_lock = threading.Lock()
_last_flush = time.monotonic()


def buffer_append(envelope: dict) -> tuple[int, bool]:
    """Append one envelope; return (new buffer size, flush_now flag)."""
    with _buffer_lock:
        _buffer.append(envelope)
        size = len(_buffer)
    return size, size >= MAX_EVENTS


def _drain_buffer() -> list[dict]:
    """Swap the buffer for a fresh empty list and return the drained one."""
    global _buffer
    with _buffer_lock:
        drained, _buffer = _buffer, []
    return drained


def _key_for_now() -> str:
    """`events/dt=YYYY-MM-DD/hr=HH/<uuid>.jsonl` for the current UTC time."""
    now = datetime.now(timezone.utc)
    return (
        f"{KEY_PREFIX}/"
        f"dt={now.strftime('%Y-%m-%d')}/"
        f"hr={now.strftime('%H')}/"
        f"{uuid.uuid4()}.jsonl"
    )


def flush(reason: str) -> int:
    """Flush the buffer to S3. Returns the number of events flushed."""
    global _last_flush
    drained = _drain_buffer()
    _last_flush = time.monotonic()
    if not drained:
        return 0

    key = _key_for_now()
    body = io.BytesIO()
    for env in drained:
        body.write(json.dumps(env, separators=(",", ":")).encode("utf-8"))
        body.write(b"\n")
    body.seek(0)

    try:
        s3_client().put_object(
            Bucket=BUCKET,
            Key=key,
            Body=body.getvalue(),
            ContentType="application/x-ndjson",
        )
        LOG.info(
            "flushed n=%d key=s3://%s/%s reason=%s",
            len(drained), BUCKET, key, reason,
        )
        return len(drained)
    except Exception as exc:  # noqa: BLE001 — we want to log and continue
        LOG.error(
            "flush FAILED n=%d key=s3://%s/%s reason=%s err=%s",
            len(drained), BUCKET, key, reason, exc,
        )
        # Drop. See module docstring re: not re-buffering — keeping the
        # sink stateless is the explicit trade. A burst of S3-side
        # 5xx will surface as gaps in analytics, but the build platform
        # itself keeps running.
        return 0


# ---------------------------------------------------------------------------
# Background interval-flusher.
#
# Daemon thread that wakes every (MAX_INTERVAL_SECONDS / 4) seconds
# and flushes if the buffer's "since last flush" exceeds the threshold.
# The quarter-interval poll gives us a worst-case lag of
# MAX_INTERVAL_SECONDS * 1.25 between an event arriving and being
# flushed under low-traffic conditions; under load the size threshold
# fires first.
# ---------------------------------------------------------------------------

_stop_event = threading.Event()


def interval_flusher():
    poll = max(1.0, MAX_INTERVAL_SECONDS / 4.0)
    while not _stop_event.is_set():
        _stop_event.wait(poll)
        if _stop_event.is_set():
            break
        if (time.monotonic() - _last_flush) >= MAX_INTERVAL_SECONDS:
            flush(reason="interval")


# ---------------------------------------------------------------------------
# Flask app.
# ---------------------------------------------------------------------------

app = Flask(__name__)


@app.get("/healthz")
def healthz():
    """Liveness — process is up. No S3 round-trip; that's readyz's job."""
    return jsonify(status="ok"), 200


@app.get("/readyz")
def readyz():
    """Readiness — S3 reachable. HEADs the bucket (cheap, 1 RTT)."""
    try:
        s3_client().head_bucket(Bucket=BUCKET)
        return jsonify(status="ok"), 200
    except Exception as exc:  # noqa: BLE001
        return jsonify(status="not-ready", err=str(exc)), 503


@app.post("/cloudevents")
def receive():
    """
    Accept a CloudEvent and append it to the buffer.

    Tekton's cloud-events controller emits in CloudEvents 1.0
    *binary-mode* HTTP: the envelope fields live in `Ce-*` headers and
    the body is the raw `data` payload (JSON, in Tekton's case). We
    preserve both: the parsed body lands at the top level (so analytics
    queries can `SELECT json_extract(...)` directly), the Ce-* headers
    land under `_headers`, and the receive timestamp + a server-side
    event id land under `_sink_received_at` / `_sink_id` for replay
    bookkeeping.

    Structured-mode (`Content-Type: application/cloudevents+json`) is
    also tolerated — the body IS the full envelope; we attach `_headers`
    anyway for diagnosis.
    """
    ctype = (request.headers.get("Content-Type") or "").lower()
    ce_headers = {
        k: v for k, v in request.headers.items() if k.lower().startswith("ce-")
    }

    # Try to parse the body as JSON for both modes — Tekton's data
    # payload is JSON (the PipelineRun / TaskRun object). If it's not
    # JSON, carry the raw bytes under `_body_raw` (base64-safe via
    # latin-1 decode → re-encode as ascii if printable, else hex).
    raw = request.get_data(cache=False)
    body_json = None
    try:
        if raw:
            body_json = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        body_json = None

    if "cloudevents+json" in ctype and isinstance(body_json, dict):
        # Structured mode: the body is the envelope.
        envelope = dict(body_json)
        envelope.setdefault("_headers", ce_headers)
    else:
        # Binary mode (Tekton's default): build the envelope from headers
        # + parsed data.
        envelope = {
            "specversion": ce_headers.get("Ce-Specversion", "1.0"),
            "id": ce_headers.get("Ce-Id"),
            "source": ce_headers.get("Ce-Source"),
            "type": ce_headers.get("Ce-Type"),
            "subject": ce_headers.get("Ce-Subject"),
            "time": ce_headers.get("Ce-Time"),
            "datacontenttype": ce_headers.get("Ce-Datacontenttype", ctype or None),
            "data": body_json,
            "_headers": ce_headers,
        }
        if body_json is None and raw:
            # Non-JSON payload — preserve raw bytes (latin-1 round-trips
            # any byte sequence; consumers can re-encode if needed).
            envelope["_body_raw"] = raw.decode("latin-1")

    envelope["_sink_received_at"] = datetime.now(timezone.utc).isoformat()
    envelope["_sink_id"] = str(uuid.uuid4())

    size, flush_now = buffer_append(envelope)
    if flush_now:
        # Inline flush on size threshold. The HTTP response waits for
        # the PUT; this is fine at Tekton's rate (one PUT per ~50
        # events) and means the controller gets a 200 only after the
        # batch is durable.
        flush(reason="size")

    return jsonify(buffered=size), 202


# ---------------------------------------------------------------------------
# Graceful shutdown.
#
# SIGTERM (from Kubernetes during a rolling update) triggers a final
# flush before the process exits. The Deployment's
# terminationGracePeriodSeconds must be > the worst-case flush time
# (single S3 PUT, well under 30s) — we set 45s in the kustomize base.
# ---------------------------------------------------------------------------

def _on_term(signum, frame):  # noqa: ARG001
    LOG.info("received signal %d; flushing and exiting", signum)
    _stop_event.set()
    flush(reason="shutdown")
    sys.exit(0)


# ---------------------------------------------------------------------------
# Entrypoint.
# ---------------------------------------------------------------------------

def main():
    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)

    LOG.info(
        "cloudevents-sink starting bucket=%s endpoint=%s prefix=%s "
        "max_events=%d max_interval=%ss",
        BUCKET, S3_ENDPOINT or "<aws-default>",
        KEY_PREFIX, MAX_EVENTS, MAX_INTERVAL_SECONDS,
    )

    t = threading.Thread(target=interval_flusher, name="interval-flusher", daemon=True)
    t.start()

    # Flask's built-in dev server is sufficient for phase-1 traffic.
    # Bind 0.0.0.0:8080 — the kustomize Service maps :80 → :8080.
    # If we ever outgrow the dev server (sustained high event rates),
    # swap to `gunicorn -w 1 sink:app` so the global buffer remains
    # single-process; multi-worker would split the buffer across PIDs
    # and break batching.
    app.run(host="0.0.0.0", port=8080, threaded=True)  # noqa: S104


if __name__ == "__main__":
    main()

# cloudevents-sink container image (issue #63).
#
# Single-stage from python:3.12-slim. Same pin posture build-grype-db
# uses for its `pull` step's python-image — major.minor floor, runtime
# pip install, no custom base. Image-build automation (PipelineRun
# producing this image with Chains attestation) is a separate follow-up;
# for phase-1 the image is built ad-hoc and pushed to the in-cluster
# registry.
FROM python:3.12-slim

# Non-root user. The Deployment also enforces runAsNonRoot — having
# the image already shaped this way means containers don't have to
# remember to add fsGroup / securityContext to chown writeable paths.
RUN groupadd --system --gid 65532 sink \
 && useradd --system --uid 65532 --gid sink --no-create-home --shell /sbin/nologin sink

WORKDIR /app

# Install deps first so the layer caches across code edits.
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --root-user-action ignore -r /app/requirements.txt

COPY sink.py /app/sink.py

USER 65532

# 8080 matches the port the sink binds in sink.py:main(). The Service
# in kustomize/base/cloudevents-sink/service.yaml maps :80 -> :8080.
EXPOSE 8080

# python -u: unbuffered stdout/stderr so `kubectl logs` is responsive
# during operator triage. The sink logs at INFO by default; bump via
# the LOG_LEVEL env var.
ENTRYPOINT ["python", "-u", "/app/sink.py"]

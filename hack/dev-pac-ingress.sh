#!/usr/bin/env bash
# Render and apply the pac-ingress kustomize base (Caddy +
# Let's Encrypt) into the dev cluster, with the public hostname and
# ACME contact email substituted in.
#
# This script is *not* the cutover. After it runs, the GitHub App
# still has its webhook URL pointed at smee.io and the in-cluster
# gosmee Deployment still forwards events. The cutover (flip the App's
# webhook URL, then tear down gosmee) is a HITL step documented in
# docs/pipelines-as-code.md under "Public ingress (replacing smee.io)".
#
# Inputs (via env or flags):
#   PAC_HOSTNAME   public DNS name that points at the cluster's
#                  external IP (e.g. pac.example.com). Required.
#   ACME_EMAIL     contact address for Let's Encrypt expiry warnings
#                  and ToS acceptance. Required by ACME.
#   KUBECONTEXT    kubectl context to apply to. Defaults to the kind
#                  dev cluster; override when applying to the EC2 k3s
#                  cluster.
#
# What it does:
#   1. Validate required inputs.
#   2. Render kustomize/base/pac-ingress/, substitute hostname +
#      email, pipe to kubectl apply.
#   3. Wait for the Caddy Deployment to become ready.
#   4. Print next-step instructions for DNS A record, EC2 SG rule,
#      GitHub App webhook URL change, and gosmee retirement.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_DIR="$REPO_ROOT/kustomize/base/pac-ingress"

PAC_HOSTNAME="${PAC_HOSTNAME:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
KUBECONTEXT="${KUBECONTEXT:-kind-ceph-tekton-dev}"

usage() {
  cat >&2 <<EOF
usage: PAC_HOSTNAME=pac.example.com ACME_EMAIL=you@example.com \\
       [KUBECONTEXT=<ctx>] $(basename "$0")

Required env vars:
  PAC_HOSTNAME    public DNS name pointing at the cluster's external IP
  ACME_EMAIL      Let's Encrypt contact address

Optional:
  KUBECONTEXT     kubectl context (default: kind-ceph-tekton-dev)
EOF
  exit 2
}

if [[ -z "$PAC_HOSTNAME" || -z "$ACME_EMAIL" ]]; then
  usage
fi

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required tool '$1' not found on PATH (install: $2)" >&2
    exit 1
  fi
}

require kubectl   "brew install kubectl"
require kustomize "brew install kustomize"

# Confirm the context exists *before* doing anything destructive.
if ! kubectl config get-contexts -o name | grep -qx "$KUBECONTEXT"; then
  echo "error: kubectl context '$KUBECONTEXT' not found" >&2
  echo "       available contexts:" >&2
  kubectl config get-contexts -o name | sed 's/^/         /' >&2
  exit 1
fi

echo "rendering $BASE_DIR with hostname '$PAC_HOSTNAME' and acme email '$ACME_EMAIL'..."

# `kustomize build` -> sed -> kubectl apply. We intentionally do the
# placeholder substitution in a pipeline rather than authoring an
# overlay; keeps the base self-contained and avoids generating
# overlay scaffolding on the user's machine. Anyone who wants a
# checked-in overlay can capture the rendered output and add it under
# kustomize/overlays/<env>/.
rendered="$(
  kustomize build "$BASE_DIR" \
    | sed \
        -e "s|PAC_HOSTNAME_PLACEHOLDER|$PAC_HOSTNAME|g" \
        -e "s|ACME_EMAIL_PLACEHOLDER|$ACME_EMAIL|g"
)"

if echo "$rendered" | grep -q PAC_HOSTNAME_PLACEHOLDER; then
  echo "error: PAC_HOSTNAME_PLACEHOLDER still present after substitution" >&2
  exit 1
fi
if echo "$rendered" | grep -q ACME_EMAIL_PLACEHOLDER; then
  echo "error: ACME_EMAIL_PLACEHOLDER still present after substitution" >&2
  exit 1
fi

echo "applying to context '$KUBECONTEXT'..."
echo "$rendered" | kubectl --context "$KUBECONTEXT" apply -f -

echo "waiting for caddy deployment to become available..."
kubectl --context "$KUBECONTEXT" -n pipelines-as-code \
  rollout status deploy/pac-ingress-caddy --timeout=180s

EXTERNAL_IP="$(
  kubectl --context "$KUBECONTEXT" -n pipelines-as-code \
    get svc pac-ingress \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
)"

cat <<EOF

pac-ingress is up.
  hostname:     $PAC_HOSTNAME
  acme email:   $ACME_EMAIL
  context:      $KUBECONTEXT
  external ip:  ${EXTERNAL_IP:-<pending — k3s klipper-lb may bind to node IP, see kubectl get svc>}

next steps (HITL):

  1. DNS — add an A record so GitHub can resolve the webhook URL:

       $PAC_HOSTNAME   IN   A   <cluster external IP>

     For the EC2 k3s cluster that's 54.90.98.182.

  2. EC2 security group — allow inbound from 0.0.0.0/0 on:

       tcp/443  (webhook deliveries)
       tcp/80   (Let's Encrypt HTTP-01 ACME challenge)

     The :80 rule is required only during initial issuance + renewals;
     it's safe to leave open since Caddy auto-redirects :80 -> :443
     for everything else.

  3. Wait ~30s, then confirm Caddy issued a cert:

       kubectl --context $KUBECONTEXT -n pipelines-as-code \\
         logs deploy/pac-ingress-caddy | grep -i "certificate obtained"

     and check the endpoint serves over HTTPS:

       curl -sSI https://$PAC_HOSTNAME/

  4. Flip the GitHub App ('ceph-tekton PaC dev') webhook URL to:

       https://$PAC_HOSTNAME/

     Send a test delivery from the App's Advanced tab and watch:

       kubectl --context $KUBECONTEXT -n pipelines-as-code \\
         logs deploy/pac-ingress-caddy -f

  5. Retire gosmee — only after the App is flipped and a smoke-test
     PR fires successfully:

       kubectl --context $KUBECONTEXT -n pipelines-as-code \\
         delete deployment gosmee

rollback:
  Re-point the GitHub App webhook URL back at the smee.io channel
  and bring the gosmee Deployment back (see docs/pipelines-as-code.md
  "Webhook ingress via smee.io"). The pac-ingress kustomize stays
  applied — it's harmless when nothing's pointed at it.

EOF

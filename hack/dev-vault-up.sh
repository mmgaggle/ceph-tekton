#!/usr/bin/env bash
# Bootstrap Vault into the local kind dev cluster (created by
# `hack/dev-up.sh`) and wire it up so a pod can sign a payload via the
# transit engine using a Kubernetes-auth-bound ServiceAccount.
#
# What this script does (idempotent — safe to re-run):
#   1. Add/refresh the hashicorp helm repo.
#   2. Install the vault chart with charts/vault/values-dev.yaml into
#      the `vault` namespace (dev-mode, single replica, root token =
#      "root", in-memory storage).
#   3. Wait for vault-0 to become ready.
#   4. Inside the pod: enable the transit secrets engine, create a
#      test ed25519 signing key, enable the Kubernetes auth method
#      pointed at this cluster's SA-token issuer, and create a
#      `ceph-test-signer` Vault role bound to
#      vault-test/ceph-test-signer (namespace/serviceaccount).
#   5. Create the matching ServiceAccount in the `vault-test`
#      namespace.
#   6. Print next-step instructions for running the smoke-test
#      pipeline.
#
# DO NOT use this script (or values-dev.yaml) on a shared or
# production cluster. Dev mode means "all keys live in RAM and the
# root token is the literal string `root`".

set -euo pipefail

CLUSTER="${KIND_CLUSTER_NAME:-ceph-tekton-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- pins (bump in PRs after testing against the smoke-test pipeline) ----
VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-0.28.1}"   # hashicorp/vault chart
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_TEST_NAMESPACE="${VAULT_TEST_NAMESPACE:-vault-test}"
VAULT_TEST_SA="${VAULT_TEST_SA:-ceph-test-signer}"
VAULT_TEST_ROLE="${VAULT_TEST_ROLE:-ceph-test-signer}"
VAULT_TEST_KEY="${VAULT_TEST_KEY:-ceph-test-key}"
VAULT_TEST_POLICY="${VAULT_TEST_POLICY:-ceph-test-signer}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    cat >&2 <<EOF
error: required tool '$1' not found on PATH.
       install: $2
EOF
    exit 1
  fi
}

require kubectl "brew install kubectl"
require helm    "brew install helm"

kubectl config use-context "kind-$CLUSTER" >/dev/null

# ---- 1. helm repo ----
if ! helm repo list -o json 2>/dev/null | grep -q '"name":"hashicorp"'; then
  echo "adding hashicorp helm repo..."
  helm repo add hashicorp https://helm.releases.hashicorp.com
fi
helm repo update hashicorp >/dev/null

# ---- 2. install/upgrade the chart ----
echo "installing vault helm chart $VAULT_CHART_VERSION into namespace '$VAULT_NAMESPACE'..."
helm upgrade --install vault hashicorp/vault \
  --namespace "$VAULT_NAMESPACE" --create-namespace \
  --version "$VAULT_CHART_VERSION" \
  --values "$REPO_ROOT/charts/vault/values-dev.yaml" \
  --wait --timeout 5m

# ---- 3. wait for vault-0 ----
echo "waiting for vault-0 to become ready..."
kubectl -n "$VAULT_NAMESPACE" wait --for=condition=ready pod/vault-0 --timeout=180s

# ---- 4. configure transit + k8s auth inside the pod ----
# `vault server -dev` autostart-unseals and sets the root token. We
# shell into the pod and run the bootstrap as VAULT_TOKEN=root against
# the loopback address. Every step is idempotent — failures are
# tolerated only for the specific "already exists" / "already enabled"
# cases the chart can land in on a re-run.
echo "bootstrapping transit engine, signing key, and Kubernetes auth..."

# The Kubernetes auth method needs the SA-token issuer URL and the
# kube-apiserver CA. We read both from in-pod (the vault SA's
# projected token already mounts a CA bundle), then point Vault at
# the in-cluster API endpoint.
kubectl -n "$VAULT_NAMESPACE" exec vault-0 -- sh -eu -c "
  export VAULT_ADDR='http://127.0.0.1:8200'
  export VAULT_TOKEN='root'

  # transit
  if ! vault secrets list -format=json | grep -q '\"transit/\"'; then
    vault secrets enable transit
  fi

  # test signing key (ed25519; the real GPG key gets created in #19)
  if ! vault read -format=json transit/keys/${VAULT_TEST_KEY} >/dev/null 2>&1; then
    vault write -f transit/keys/${VAULT_TEST_KEY} type=ed25519
  fi

  # policy granting sign capability on that one key
  cat <<POLICY | vault policy write ${VAULT_TEST_POLICY} -
path \"transit/sign/${VAULT_TEST_KEY}\" {
  capabilities = [\"update\"]
}
path \"transit/verify/${VAULT_TEST_KEY}\" {
  capabilities = [\"update\"]
}
path \"transit/keys/${VAULT_TEST_KEY}\" {
  capabilities = [\"read\"]
}
POLICY

  # kubernetes auth method
  if ! vault auth list -format=json | grep -q '\"kubernetes/\"'; then
    vault auth enable kubernetes
  fi

  # configure the k8s auth method to trust this cluster's SA-token
  # issuer. The vault pod's own SA token + CA are mounted at the
  # standard projected path; kube-apiserver is reachable via the
  # in-cluster KUBERNETES_SERVICE_HOST/PORT envs.
  vault write auth/kubernetes/config \
    kubernetes_host=\"https://\${KUBERNETES_SERVICE_HOST}:\${KUBERNETES_SERVICE_PORT_HTTPS}\" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    disable_iss_validation=true

  # role binding (namespace, serviceaccount) → policy
  vault write auth/kubernetes/role/${VAULT_TEST_ROLE} \
    bound_service_account_names=${VAULT_TEST_SA} \
    bound_service_account_namespaces=${VAULT_TEST_NAMESPACE} \
    policies=${VAULT_TEST_POLICY} \
    ttl=1h
"

# ---- 5. create the test namespace + ServiceAccount ----
echo "creating namespace '$VAULT_TEST_NAMESPACE' and ServiceAccount '$VAULT_TEST_SA'..."
kubectl create namespace "$VAULT_TEST_NAMESPACE" --dry-run=client -o yaml \
  | kubectl apply -f -
kubectl -n "$VAULT_TEST_NAMESPACE" create serviceaccount "$VAULT_TEST_SA" \
  --dry-run=client -o yaml \
  | kubectl apply -f -

# ---- 6. next steps ----
cat <<EOF

vault is up in the dev cluster.
  chart:       hashicorp/vault $VAULT_CHART_VERSION (dev mode)
  namespace:   $VAULT_NAMESPACE
  address:     http://vault.$VAULT_NAMESPACE.svc.cluster.local:8200
  root token:  root   (dev mode — do not use this token pattern anywhere real)

transit configured:
  key:         transit/keys/$VAULT_TEST_KEY (ed25519)
  policy:      $VAULT_TEST_POLICY  (sign+verify+read on that one key)
  k8s role:    auth/kubernetes/role/$VAULT_TEST_ROLE
               bound to $VAULT_TEST_NAMESPACE/$VAULT_TEST_SA

next:
  # run the smoke-test pipeline — authenticates via SA token, signs
  # a known payload, asserts the response contains a signature.
  kubectl -n $VAULT_TEST_NAMESPACE apply -f pipelines/tasks/vault-sign-smoke.yaml
  kubectl -n $VAULT_TEST_NAMESPACE apply -f pipelines/pipelines/vault-smoke-test.yaml
  tkn pipeline start vault-smoke-test \\
    --serviceaccount $VAULT_TEST_SA \\
    -n $VAULT_TEST_NAMESPACE \\
    --showlog

teardown of just vault (leaves the kind cluster + tekton in place):
  helm -n $VAULT_NAMESPACE uninstall vault
  kubectl delete namespace $VAULT_NAMESPACE $VAULT_TEST_NAMESPACE

EOF

# charts/vault

Wrapper around the official **HashiCorp Vault** helm chart for the
ceph-tekton stack.

This directory does **not** vendor the upstream chart; it only ships the
two values files (`values-dev.yaml`, `values-sepia.yaml`) and pins the
chart version that the dev-up script installs.

| File                  | Used by                          | Scope                                   |
|-----------------------|----------------------------------|-----------------------------------------|
| `values-dev.yaml`     | `hack/dev-vault-up.sh`           | Local kind cluster, dev-mode Vault      |
| `values-sepia.yaml`   | *stub* (not deployed yet)        | Sepia production HA install, future     |
| `README.md`           | humans                           | install + day-2 ops + sealed recovery   |

## Pinned chart version

```
hashicorp/vault   chart 0.28.1   (Vault 1.17.2 appVersion)
```

The pin lives in `hack/dev-vault-up.sh` as `VAULT_CHART_VERSION`.
Bump it in a PR after testing the new chart against the smoke-test
pipeline (`pipelines/pipelines/vault-smoke-test.yaml`).

## Install (dev)

The smoke path is the script — it does the helm install, the post-
install transit/k8s-auth/role bootstrap, and the service-account
creation in one shot:

```sh
./hack/dev-vault-up.sh
```

Manual equivalent, if you want to step through it:

```sh
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm upgrade --install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --version 0.28.1 \
  --values charts/vault/values-dev.yaml

kubectl -n vault wait --for=condition=ready pod/vault-0 --timeout=180s

# from inside the vault-0 pod (dev mode → root token is `root`):
kubectl -n vault exec -it vault-0 -- sh -c '
  export VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200
  vault secrets enable transit
  vault write -f transit/keys/ceph-test-key type=ed25519
'
```

## Day-2 ops

### Inspecting signing operations

Dev mode logs every API call to stdout because the audit device is
attached to stderr by default:

```sh
kubectl -n vault logs -f vault-0
```

For production (sepia), audit goes to a file sink under `/vault/audit`
and is shipped by a sidecar — see `docs/vault.md` for the runbook.

### Listing transit keys

```sh
kubectl -n vault exec vault-0 -- sh -c '
  VAULT_TOKEN=root vault list transit/keys
'
```

### Rotating the test key

```sh
kubectl -n vault exec vault-0 -- sh -c '
  VAULT_TOKEN=root vault write -f transit/keys/ceph-test-key/rotate
'
```

The transit engine versions keys: old signatures keep verifying, new
signatures use the latest version. **Do not rotate the production GPG
key without coordinating with the publish-repo pipeline** — that's
tracked under issue #19, not here.

## Sealed-state recovery

**Dev mode never seals.** A `vault-0` pod restart in dev means the
whole transit engine is wiped (in-memory storage), so the recovery
procedure is simply: rerun `hack/dev-vault-up.sh`.

**Production (sepia) recovery**, summarized:

1. Detect seal: `vault status` shows `Sealed: true`. The chart's
   readiness probe will fail and the Service will stop routing.
2. If auto-unseal (cloud KMS or HSM) is configured, the pod should
   unseal itself on restart. If it cannot reach the KMS, fix
   connectivity and let the controller restart the pod.
3. If PGP-split recovery shares are used instead of auto-unseal, the
   operator on call gathers `threshold` shareholders and runs
   `vault operator unseal` once per share.
4. After unseal, validate transit: `vault read transit/keys/ceph-repo-signing-key`
   should return key metadata without error.
5. If raft quorum was lost (e.g. all three replicas restarted at
   once and storage was wiped), restore from the most recent raft
   snapshot: `vault operator raft snapshot restore <file>`.

The Sepia runbook in `docs/vault.md` has the full sequence with
commands. This README is intentionally a quickstart, not the operator
manual.

## Why dev mode for local

The kind dev cluster is throwaway state for an individual developer's
laptop. Dev mode trades durability for an install-in-30-seconds
experience: in-memory storage, no seal lifecycle, a known root token.
A pod restart loses every key, role, and audit entry — that's
acceptable here because the script that brought Vault up will bring
it back up the same way.

This trade-off is **never acceptable on Sepia**. See `values-sepia.yaml`
for the production stance and the TODOs that must be resolved before
that stub becomes a real install.

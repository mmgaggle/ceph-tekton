# Vault in ceph-tekton

Vault is the home for the **GPG repo-signing key** that the publish-repo
Tasks use to sign yum/apt repository metadata. The key lives in Vault's
**transit secrets engine** and never leaves Vault — publish tasks call
the sign API over HTTP. Even a fully compromised publish pod cannot
exfiltrate the key.

This document covers:

- [Phase-1 dev install](#phase-1-dev-install) — local kind cluster
- [What's stubbed for sepia](#whats-stubbed-for-sepia)
- [Trust model](#trust-model)
- [Inspecting signing operations](#inspecting-signing-operations)
- [Recovering from a sealed state](#recovering-from-a-sealed-state)

> **Scope note.** Issue #5 only stands up Vault + the transit engine
> with an ed25519 *test* key, and proves a pod can sign through it.
> Real GPG key import + publish-repo integration is issue #19.

---

## Phase-1 dev install

Prerequisites: the local kind cluster from `docs/contributing-locally.md`
must already be running (`make dev-up`). You also need `helm` on
`PATH` — install with `brew install helm`.

From the repo root:

```sh
./hack/dev-vault-up.sh
```

What that does, in order:

1. Adds the `hashicorp` helm repo and refreshes it.
2. `helm upgrade --install vault hashicorp/vault` with
   `charts/vault/values-dev.yaml` (chart pinned to `0.28.1`, Vault
   appVersion `1.17.2`) into the `vault` namespace, creating the
   namespace if absent.
3. Waits up to 3 minutes for the `vault-0` pod to become ready.
4. `kubectl exec`s into `vault-0` (as `VAULT_TOKEN=root` — dev mode)
   and:
   - enables the `transit` secrets engine
   - creates `transit/keys/ceph-test-key` (ed25519)
   - writes a `ceph-test-signer` policy granting `update` on
     `transit/sign/ceph-test-key` and `transit/verify/ceph-test-key`
     and `read` on `transit/keys/ceph-test-key`
   - enables the `kubernetes` auth method and points it at the
     in-cluster API endpoint, using the vault pod's own SA token + CA
     bundle as the credential it presents to the kube-apiserver
   - creates Vault role `auth/kubernetes/role/ceph-test-signer`,
     bound to ServiceAccount `vault-test/ceph-test-signer`, granting
     the `ceph-test-signer` policy with a 1-hour TTL
5. Creates the `vault-test` namespace and the `ceph-test-signer`
   ServiceAccount in it.

The script is idempotent. Re-running it on a live cluster only
reconciles missing pieces.

Run the smoke-test pipeline to prove the chain works end-to-end:

```sh
kubectl apply -f pipelines/vault-smoke-test.yaml
tkn pipeline start vault-smoke-test \
  --serviceaccount ceph-test-signer \
  -n vault-test \
  --showlog
```

You should see three step logs ending in `OK: vault verified the
signature — smoke test passed`. If any step prints `FAIL: ...` the
pipeline returns non-zero and the corresponding link in the trust
chain (SA token, k8s-auth config, role binding, transit key, sign
capability) is the one to investigate first.

### Teardown

```sh
helm -n vault uninstall vault
kubectl delete namespace vault vault-test
```

Or nuke the whole dev cluster: `make dev-down`.

---

## What's stubbed for sepia

`charts/vault/values-sepia.yaml` encodes the production stance but is
**not deployed yet** — it lives in the repo so that the dev↔prod diff
stays auditable. The values-sepia stub already locks in:

- 3-replica HA with integrated raft storage (no external Consul)
- Pod anti-affinity across nodes
- TLS on the API listener (cert sourced from a Secret named
  `vault-tls`)
- Dev mode explicitly disabled (`server.dev.enabled: false`)
- File audit sink on a 10 GiB PV at `/vault/audit`
- Resource requests sized for a real workload

What is still **missing** before the stub becomes a real install (each
must be resolved before any sepia rollout):

1. **Seal stanza.** Pick one of AWS KMS / GCP KMS / HSM (pkcs11) /
   PGP-split recovery shares. The seal block is commented out in the
   raft config — fill it in via a sealed Secret, not in plaintext git.
2. **TLS source.** Either cert-manager with a sepia internal CA, or
   a sealed Secret containing the cert/key — populate the `vault-tls`
   Secret referenced under `server.extraVolumes`.
3. **Audit log forwarder.** A sidecar (fluent-bit, vector, etc.) to
   tail `/vault/audit` and ship to the sepia log aggregator. Not yet
   chosen.
4. **Network exposure.** UI behind an OpenShift Route or Ingress; the
   API stays in-cluster.
5. **Backup.** Raft snapshot schedule, retention policy, and a
   tested restore procedure.
6. **Initial unseal handoff.** If PGP-split recovery shares are used,
   the operator manual must document who holds which share and the
   threshold required to recombine.

When sepia rollout is scheduled, these resolve into a dedicated
issue. They are deliberately not part of issue #5.

---

## Trust model

The chain that ends with a build pod able to sign through Vault:

```
ServiceAccount  (vault-test/ceph-test-signer)
      │
      │ kube-apiserver mounts a projected SA JWT into pods that use the SA
      ▼
projected SA token   (short-lived, audience = "https://kubernetes.default.svc")
      │
      │ POST /v1/auth/kubernetes/login  {role: "ceph-test-signer", jwt: "<JWT>"}
      ▼
Vault k8s auth method
      │ verifies the JWT signature against the cluster's SA-token issuer
      │ (vault pod's own SA token + ca.crt teach Vault how to reach the
      │ kube-apiserver for TokenReview validation)
      │ looks up role "ceph-test-signer"
      │ confirms the JWT's (namespace, serviceaccount) claim is in the
      │ role's bound_service_account_{namespaces,names}
      │ issues a short-lived Vault client_token bearing policy
      │   "ceph-test-signer"
      ▼
Vault client_token   (TTL 1h)
      │
      │ POST /v1/transit/sign/ceph-test-key  {input: "<base64>"}
      │ X-Vault-Token: <client_token>
      ▼
transit engine
      │ policy check: "ceph-test-signer" allows update on
      │   transit/sign/ceph-test-key  → permitted
      │ signs with ed25519 key (key material never leaves the
      │   transit backend)
      ▼
{ "data": { "signature": "vault:v1:<base64-sig>" } }
```

**Properties that fall out of this chain:**

- **No long-lived secrets in the build pod.** The SA token is rotated
  by the kubelet (default 1h projected lifetime); the Vault client
  token is also short-lived (1h in dev). Both are obtained at runtime,
  neither is committed to git or kept in a Secret.
- **Identity-bound capability.** The role grants signing capability
  only to a specific `(namespace, serviceaccount)` pair. Stealing the
  Vault role name is useless without also being scheduled as that SA.
- **Key never leaves Vault.** The signing key material is generated
  inside the transit backend and only ever exported as derived public
  data (a `vault:v<n>:<sig>` string). The publish pod gets signatures,
  not keys.
- **Auditable per-operation.** Every sign call lands in the audit
  device with the requesting client token, role, source IP, and the
  exact key path — sufficient to attribute any signature to a specific
  TaskRun.

For the production GPG-signing flow (issue #19) the same chain
applies, swapping `ceph-test-key` (ed25519) for the actual GPG
signing key configured as a transit key with type `rsa-4096` or
similar and bound to the `publish-repo` Task's ServiceAccount instead
of `ceph-test-signer`.

---

## Inspecting signing operations

### Dev cluster

Dev-mode Vault writes audit events to stderr by default; tail the
pod:

```sh
kubectl -n vault logs -f vault-0
```

Each sign request shows up as an audit JSON line with the path
(`transit/sign/<key>`), the client token (hashed), the role used to
mint that token, and the request timestamp. Filter to just sign
events:

```sh
kubectl -n vault logs vault-0 | grep '"path":"transit/sign/'
```

You can also confirm the most recent successful operation against the
key:

```sh
kubectl -n vault exec vault-0 -- sh -c '
  VAULT_TOKEN=root vault read transit/keys/ceph-test-key
'
```

The `latest_version` field bumps each time the key rotates;
`min_decryption_version` and `min_encryption_version` show which key
versions are still considered valid.

### Sepia (future)

Production audit goes to a file sink under `/vault/audit/audit.log`
(see `values-sepia.yaml`). A sidecar forwarder ships those lines to
the sepia log aggregator. Operators query by:

- requesting role (filter on `auth.metadata.role`)
- key path (filter on `request.path`)
- service-account claim (filter on
  `auth.metadata.service_account_name` /
  `auth.metadata.service_account_namespace`)

This is also how you spot anomalies — e.g. a sign call against the
real GPG key from anything other than the publish-repo SA is a
correctness/security alarm.

---

## Recovering from a sealed state

### Dev cluster

Dev-mode Vault never seals — but it also has no persistent storage.
A pod restart wipes the transit engine, all keys, all roles, and the
audit history. Recovery is trivial: rerun the bootstrap.

```sh
./hack/dev-vault-up.sh
```

The smoke-test pipeline confirms the cluster is back to a working
state.

### Sepia (future, by chain of events)

A real Vault that has sealed itself is not handling requests. The
chart's readiness probe will fail, the Service will stop routing,
and downstream pipelines blocked on signing will fail fast. Recovery
sequence:

1. **Confirm seal state.**
   ```sh
   kubectl -n vault exec vault-0 -- vault status
   ```
   Look for `Sealed: true` and `Initialized: true`. If
   `Initialized: false`, the cluster was never bootstrapped — that's
   an install failure, not a seal recovery.

2. **Check auto-unseal connectivity, if configured.** If the seal
   stanza in raft config uses cloud KMS or HSM, the pod should
   unseal itself within seconds of becoming ready. If it cannot,
   the most common cause is loss of network connectivity to the
   KMS endpoint or a credential rotation that the Vault pod has
   not picked up. Fix the underlying connectivity issue and the
   pod will unseal on its next restart.

3. **PGP-split recovery shares, if used instead of auto-unseal.**
   The operator on call gathers `threshold` shareholders (each
   holds an encrypted share of the master key) and runs:
   ```sh
   kubectl -n vault exec -it vault-0 -- vault operator unseal
   ```
   once per share. Each unseal call returns progress
   (`Unseal Progress: N/threshold`). When the threshold is met the
   pod unseals.

4. **Validate transit is intact.**
   ```sh
   kubectl -n vault exec vault-0 -- \
     vault read transit/keys/ceph-repo-signing-key
   ```
   Should return the key metadata. If the key is missing, raft
   storage was lost or rolled back — proceed to step 5.

5. **Raft snapshot restore, if storage was lost.**
   ```sh
   kubectl -n vault exec -it vault-0 -- \
     vault operator raft snapshot restore /backups/<latest>.snap
   ```
   This requires the operator to have already mounted (or `kubectl
   cp`'d) the most recent backup snapshot into the pod. After
   restore, re-run step 4 to confirm transit is back.

6. **Resume signing.** Once `vault status` shows `Sealed: false` and
   the readiness probe is passing, the Service starts routing again
   and the publish-repo pipelines that were blocked will retry
   successfully on their next attempt.

A live drill of steps 1–5 happens on every sepia operator
on-call rotation handoff. The runbook in `charts/vault/README.md`
holds the quickstart; this section is the full sequence with the
reasoning attached.

---

## Related files

| File                                       | Purpose                                          |
|--------------------------------------------|--------------------------------------------------|
| `charts/vault/values-dev.yaml`             | Dev-mode helm values (in-memory, root token)     |
| `charts/vault/values-sepia.yaml`           | Production HA stub (raft, TLS, no dev mode)      |
| `charts/vault/README.md`                   | Install + day-2 ops quickstart                   |
| `hack/dev-vault-up.sh`                     | Bootstrap script for local kind                  |
| `pipelines/vault-smoke-test.yaml`          | SA-token → k8s auth → transit sign smoke test    |
| `docs/vault.md`                            | This document                                    |

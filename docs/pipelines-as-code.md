# Pipelines-as-Code on the dev cluster

[Pipelines-as-Code](https://pipelinesascode.com) (PaC) is the GitHub →
Tekton glue layer for ceph-tekton: a GitHub App posts webhooks to a PaC
controller running in the cluster; the controller resolves PipelineRun
templates from the repo under test (or, in phase 1, from this repo) and
launches them with parameters filled in from the webhook payload.

This page covers:

1. [What gets installed](#what-gets-installed)
2. [Install PaC into the dev cluster](#install-pac-into-the-dev-cluster)
3. [Webhook ingress via smee.io](#webhook-ingress-via-smeeio)
4. [Create a GitHub App for your dev cluster](#create-a-github-app-for-your-dev-cluster)
5. [Wire the GitHub App to PaC](#wire-the-github-app-to-pac)
6. [Smoke-test with the noop pipeline](#smoke-test-with-the-noop-pipeline)
7. [Troubleshooting](#troubleshooting)
8. [Bumping the pinned PaC version](#bumping-the-pinned-pac-version)

> The "real" GitHub App for `ceph/ceph` is tracked separately in #9 and
> is a human-in-the-loop task. The walkthrough below is for a
> **personal-fork-scoped** dev app — you create it, you own it, you
> delete it. It exists only so contributors can iterate on PaC pipelines
> against a small test fork before touching the production app.

---

## What gets installed

`kustomize/base/pipelines-as-code/kustomization.yaml` pins PaC to a
specific release manifest:

| Component                  | Version                                 |
|----------------------------|-----------------------------------------|
| Pipelines-as-Code          | `v0.27.0` (vanilla-k8s `release.k8s.yaml`) |
| Compatible Tekton Pipelines| `v1.6.0` (the version pinned by `kustomize/base/tekton-pipelines/`) |

PaC publishes two release manifests per tag:

- `release.yaml` — OpenShift (adds Routes + SCCs).
- `release.k8s.yaml` — vanilla Kubernetes; webhook ingress is the
  deployer's responsibility.

We pin `release.k8s.yaml` because the canonical phase-1 install target
is a kind cluster. A future `kustomize/overlays/sepia/` overlay can swap
to `release.yaml` for the OpenShift install.

The PaC manifest creates:

- Namespace `pipelines-as-code`.
- A controller Deployment (handles webhook routing + PipelineRun
  creation), a webhook-validation Deployment, and a watcher Deployment
  (reports run status back to GitHub).
- A `pipelines-as-code-controller` Service (ClusterIP, port 8080) —
  this is what we point smee.io at.
- CRDs: `Repository`, plus the PaC-internal types.

PaC is **not** yet wired into the `dev-local` overlay — adding it
there is a separate step the operator does once they have a GitHub App
to point at it (the install needs the App's secrets, so blanket-applying
the overlay without secrets present would leave the controller crash-
looping). See [Wire the GitHub App to PaC](#wire-the-github-app-to-pac).

---

## Install PaC into the dev cluster

Bring up the dev cluster first (see [contributing-locally.md](contributing-locally.md)):

```sh
make dev-up
```

Render and apply just the PaC base:

```sh
# Sanity-check the render without applying.
kubectl kustomize kustomize/base/pipelines-as-code/ | less

# Apply it.
kubectl --context kind-ceph-tekton-dev apply -k kustomize/base/pipelines-as-code/

# Wait for the controller to come up.
kubectl --context kind-ceph-tekton-dev -n pipelines-as-code \
  wait --for=condition=ready pod \
  -l app.kubernetes.io/part-of=pipelines-as-code \
  --timeout=300s
```

You should see three Deployments running:

```sh
kubectl --context kind-ceph-tekton-dev -n pipelines-as-code get deploy
# NAME                                READY
# pipelines-as-code-controller        1/1
# pipelines-as-code-webhook           1/1
# pipelines-as-code-watcher           1/1
```

---

## Webhook ingress via smee.io

kind doesn't ship a LoadBalancer and contributors' laptops aren't
reachable from the public internet — so GitHub can't talk to the PaC
controller directly. PaC's documented answer is
[smee.io](https://smee.io/) (a.k.a. gosmee): a public relay URL takes
the inbound GitHub webhook and tunnels it down a long-lived HTTP
connection to a `gosmee` client running anywhere with outbound network
access.

We run the gosmee client **as a Pod inside the dev cluster** so it can
reach the in-cluster PaC controller Service over its ClusterIP and
contributors don't have to keep a terminal open.

### 1. Create a smee.io channel

Open <https://smee.io/> in a browser and click **Start a new channel**.
Copy the URL — it'll look like `https://smee.io/AbCdEfGhIjKlMnOp`. Keep
this tab open; you'll paste this URL into the GitHub App's webhook URL
field below.

### 2. Run a gosmee forwarder Pod

Create a one-off Deployment in the `pipelines-as-code` namespace that
forwards your smee channel to the PaC controller Service. Replace the
`--saw-url` value with your channel URL.

```sh
SMEE_URL="https://smee.io/AbCdEfGhIjKlMnOp"  # <- yours from step 1

kubectl --context kind-ceph-tekton-dev -n pipelines-as-code \
  create deployment gosmee \
  --image=ghcr.io/chmouel/gosmee:latest \
  -- /ko-app/gosmee client \
     --saw-url "$SMEE_URL" \
     http://pipelines-as-code-controller.pipelines-as-code.svc.cluster.local:8080
```

Verify the forwarder is connected:

```sh
kubectl --context kind-ceph-tekton-dev -n pipelines-as-code logs deploy/gosmee
# expect:  "Forwarding https://smee.io/... to http://pipelines-as-code-controller..."
```

> When ceph-tekton grows a proper `dev-local` PaC overlay, this gosmee
> Deployment becomes a kustomize resource with the channel URL pulled
> from an env var or ConfigMapGenerator. For now it's a one-liner you
> run manually — keeps secrets (the smee URL is one) out of git.

---

## Create a GitHub App for your dev cluster

These steps create a personal GitHub App scoped to a **single test
fork** of any small repo (the Ceph project's `ceph/ceph` is huge —
fork something small like `ceph/ceph-csi-docs` or your own throwaway
repo). The App never touches production.

1. Open <https://github.com/settings/apps/new> (or
   `https://github.com/organizations/<your-org>/settings/apps/new` if
   you'd rather scope the App to a personal org).

2. Fill in:

   | Field                       | Value                                                                |
   |-----------------------------|----------------------------------------------------------------------|
   | GitHub App name             | `ceph-tekton-dev-<your-handle>` (must be globally unique)            |
   | Homepage URL                | URL of this repo, or any placeholder                                 |
   | Webhook → Active            | checked                                                              |
   | Webhook URL                 | the smee.io channel URL from above                                   |
   | Webhook secret              | generate one (`openssl rand -hex 20`) — save it, you'll need it      |

3. Under **Permissions → Repository permissions**, grant:

   | Permission              | Access         | Why                                                              |
   |-------------------------|----------------|------------------------------------------------------------------|
   | Checks                  | Read & write   | Post per-PR check runs                                           |
   | Contents                | Read-only      | Fetch the PR head + resolve `.tekton/` files                     |
   | Issues                  | Read & write   | React to `/test`, `/retest` comments                             |
   | Metadata                | Read-only      | Required by GitHub for any App                                   |
   | Pull requests           | Read & write   | Read PRs; post the rich check status                             |

   Under **Permissions → Organization permissions**, leave everything
   `No access`.

   Under **Permissions → Account permissions**, leave everything
   `No access`.

4. Under **Subscribe to events**, check:

   - Check run
   - Check suite
   - Commit comment
   - Issue comment
   - Pull request
   - Push

5. Under **Where can this GitHub App be installed?**, select **Only on
   this account**.

6. Click **Create GitHub App**. On the next page:

   - Note the **App ID** (numeric, near the top).
   - Scroll to **Private keys** → **Generate a private key**. A `.pem`
     downloads to your machine. Treat it like an SSH private key.

7. In the App's left-nav, click **Install App**, then **Install** next
   to your account. On the install screen, choose **Only select
   repositories** and pick the single test fork you'll use as the
   smoke-test repo.

You should now have, locally:

- App ID (number)
- Webhook secret (the hex string from step 2)
- Private key (`*.pem` file)
- A test fork the App is installed on

---

## Wire the GitHub App to PaC

PaC reads the App credentials out of a single Secret named
`pipelines-as-code-secret` in its own namespace. Create it:

```sh
APP_ID="<app id from step 6>"
WEBHOOK_SECRET="<the hex secret from step 2>"
PRIVATE_KEY_PEM="$HOME/Downloads/ceph-tekton-dev-<your-handle>.YYYY-MM-DD.private-key.pem"

kubectl --context kind-ceph-tekton-dev -n pipelines-as-code \
  create secret generic pipelines-as-code-secret \
    --from-literal=github-application-id="$APP_ID" \
    --from-literal=webhook.secret="$WEBHOOK_SECRET" \
    --from-file=github-private-key="$PRIVATE_KEY_PEM"
```

Restart the controller so it picks up the new secret:

```sh
kubectl --context kind-ceph-tekton-dev -n pipelines-as-code \
  rollout restart deploy/pipelines-as-code-controller
```

Then tell PaC which Git repo this cluster is responsible for. PaC needs
a `Repository` CR per fork; create one for your test fork in the
namespace where you want PipelineRuns to land (we use `default` on dev):

```sh
TEST_REPO_URL="https://github.com/<your-handle>/<your-test-fork>"

cat <<EOF | kubectl --context kind-ceph-tekton-dev apply -f -
apiVersion: pipelinesascode.tekton.dev/v1alpha1
kind: Repository
metadata:
  name: dev-test-fork
  namespace: default
spec:
  url: "$TEST_REPO_URL"
EOF
```

---

## Smoke-test with the noop pipeline

`pipelines/noop-pull-request.yaml` in this repo is the PipelineRun
template PaC will instantiate on every `pull_request` event against
your test fork. It runs a single Task that echoes the event payload —
just enough to prove the round trip works.

You have two ways to feed it to PaC:

### Option A — copy the template into the test fork's `.tekton/`

Simplest. PaC always reads `.tekton/*.yaml` from the PR head, so just
commit the file there:

```sh
# in your test fork's checkout
mkdir -p .tekton
cp /path/to/ceph-tekton/pipelines/noop-pull-request.yaml .tekton/
git add .tekton/noop-pull-request.yaml
git commit -m "ci: add noop PaC pipeline"
git push
```

### Option B — remote-resolve from this repo (phase-1 model)

In the test fork's `.tekton/` directory, drop a tiny stub that points
PaC at the canonical file in `mmgaggle/ceph-tekton`:

```yaml
# .tekton/noop-pull-request.yaml in the test fork
---
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: noop-pull-request-
  annotations:
    pipelinesascode.tekton.dev/on-event: "[pull_request]"
    pipelinesascode.tekton.dev/on-target-branch: "[**]"
    pipelinesascode.tekton.dev/pipeline: "https://raw.githubusercontent.com/mmgaggle/ceph-tekton/main/pipelines/noop-pull-request.yaml"
spec:
  pipelineRef:
    name: noop-pull-request
```

Option B matches the phase-1 PLAN.md decision ("PaC files live in
`ceph-tekton/pipelines/`, remote-resolved by PaC. Lets us iterate
without ceph/ceph review cycles").

### Trigger it

Open a PR against your test fork:

```sh
git checkout -b test-pac-trigger
echo "trigger" >> README.md
git commit -am "test: trigger PaC"
git push -u origin test-pac-trigger
gh pr create --fill
```

Within a few seconds:

- The smee.io channel page (in your browser) shows the webhook delivery.
- `kubectl -n pipelines-as-code logs deploy/gosmee` shows the forward.
- `kubectl -n pipelines-as-code logs deploy/pipelines-as-code-controller`
  shows PaC matching the template and creating a PipelineRun.
- `kubectl -n default get pipelinerun` shows a new run named
  `noop-pull-request-XXXXX`.
- The PR grows a GitHub Check named after your pipeline. Click into it
  to see the noop Task's output (the echoed `repo_url`, PR number,
  source/target branches, head SHA).

Stream logs:

```sh
tkn -n default pipelinerun logs -L -f
```

Re-trigger from the PR with a comment:

```
/retest
```

PaC matches on issue_comment events too — you should see a fresh
PipelineRun start.

---

## Troubleshooting

### Webhook fires on GitHub but never reaches the cluster

- Open the smee.io channel page in a browser — incoming webhooks
  appear there in real time. If GitHub sends but smee doesn't show it,
  the App's webhook URL is wrong (check **Settings → Advanced** under
  the App for recent delivery attempts; click "Redeliver" to retry).
- If smee shows the delivery but the cluster doesn't react,
  `kubectl -n pipelines-as-code logs deploy/gosmee` will show why
  (usually: the in-cluster Service name is wrong, or the gosmee Pod
  can't resolve cluster DNS).

### PaC sees the webhook but no PipelineRun appears

- Check the controller log:
  `kubectl -n pipelines-as-code logs deploy/pipelines-as-code-controller`.
- Common causes:
  - No `Repository` CR matches the PR's repo URL (PaC ignores events
    for repos it doesn't recognize). Re-check the `spec.url` on your
    `Repository`.
  - The `.tekton/` file's annotations don't match the event. The noop
    template uses `on-event: "[pull_request]"` and
    `on-target-branch: "[**]"`; verify your stub matches.
  - The App's installation doesn't include the test fork. Reinstall
    from the App's **Install App** page.

### Controller pod is `CrashLoopBackOff`

Almost always the `pipelines-as-code-secret` is missing or malformed:

```sh
kubectl -n pipelines-as-code describe secret pipelines-as-code-secret
# must show keys: github-application-id, webhook.secret, github-private-key
```

The private key file must be PEM with the standard
`-----BEGIN RSA PRIVATE KEY-----` header.

### PipelineRun starts but the GitHub Check never updates

Check the watcher deployment, not the controller:

```sh
kubectl -n pipelines-as-code logs deploy/pipelines-as-code-watcher
```

The watcher is the component that calls back into the GitHub API. A
401/403 here means the App's permissions are wrong — re-check the
"Checks: Read & write" and "Pull requests: Read & write" entries from
the App-creation step.

### Pipeline references the wrong commit

PaC dynamic variables (`{{ revision }}`, `{{ pull_request_number }}`,
etc.) are documented at
<https://pipelinesascode.com/docs/guide/authoringprs/#dynamic-variables>.
If a template echoes the wrong value, double-check you're using the
documented variable name and not a typo.

---

## Bumping the pinned PaC version

PaC and Tekton Pipelines must stay version-compatible — PaC's release
notes call out the minimum supported Pipelines version for each tag.

1. Pick the new release from
   <https://github.com/openshift-pipelines/pipelines-as-code/releases>.
2. Confirm the new tag still works against the Pipelines version pinned
   in `kustomize/base/tekton-pipelines/kustomization.yaml`. Bump both
   if PaC requires a newer Pipelines release.
3. Update the URL in `kustomize/base/pipelines-as-code/kustomization.yaml`
   to the new `release-vX.Y.Z/release.k8s.yaml` path.
4. Render and diff:

   ```sh
   kubectl kustomize kustomize/base/pipelines-as-code/ > /tmp/pac-new.yaml
   # diff vs. old render captured before the bump
   ```

5. `make dev-up && kubectl apply -k kustomize/base/pipelines-as-code/`
   on a clean dev cluster, then re-run the smoke-test in this page.
6. Update the version table at the top of this doc in the same PR.

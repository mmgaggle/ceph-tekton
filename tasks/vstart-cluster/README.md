# vstart-cluster — port-forward recipes

The `vstart-cluster` Task brings up a small ceph cluster inside a
single Task pod. Once the pod reports the cluster is healthy
(`ceph -s` returns `HEALTH_OK` or `HEALTH_WARN`), it sleeps for
`keep-alive-seconds` so you can poke at the cluster from outside the
OpenShift namespace — typically with `oc port-forward`.

Three dev-cluster shapes are documented below, one per common
workload. Pick the one that matches what you're testing; pass the
matching daemon-count params to `pipelines/dev-vstart.yaml`. The
shape selector is just the count params (`rgw_count`, `mds_count`)
— there's no separate "mode" flag.

## Finding the pod

All three recipes assume you've found the running `vstart-cluster`
TaskRun's pod. The shortest path:

```sh
# In whichever namespace your PipelineRun lives in.
POD="$(oc get pods -l tekton.dev/task=vstart-cluster \
  -o jsonpath='{.items[0].metadata.name}')"
echo "vstart pod: $POD"
```

If you have multiple PipelineRuns active, narrow by PipelineRun name:

```sh
POD="$(oc get pods \
  -l tekton.dev/pipelineRun=my-vstart-run-abcde \
  -l tekton.dev/task=vstart-cluster \
  -o jsonpath='{.items[0].metadata.name}')"
```

`port-forward` keeps a TCP tunnel open from `localhost:<port>` on
your laptop to the pod's port — the connection lives as long as the
`oc port-forward` process. Open one terminal per port you need, or
chain ports on one invocation (`oc port-forward POD 3300 6789 8000`).

---

## Shape 1: RGW-only — object storage dev shell

**When to use it.** You're hacking on radosgw — S3/Swift APIs, lifecycle
rules, multi-site sync, IAM, the cls_rgw OSD class. CephFS is dead
weight; mds_count=0 saves you ~1GB RSS and the MDS startup time.

**Pipeline params.**

```sh
tkn pipeline start dev-vstart \
  -p git_ref=wip-rgw-foo \
  -p rgw_count=1 \
  -p mds_count=0 \
  -p keep_alive_seconds=14400 \
  --workspace name=source,volumeClaimTemplateFile=workspace-pvc.yaml
```

**Port-forward.** RGW listens on `:8000` inside the pod (vstart.sh's
default). The mon is also handy if you want to talk to the cluster
directly with the `s3cmd` / `aws` CLI's signature requirements
satisfied by the in-cluster MON addresses; mon msgr2 is `:3300`,
legacy msgr1 is `:6789`.

```sh
# RGW S3 endpoint on http://localhost:8000
oc port-forward "$POD" 8000:8000

# In another terminal, point an S3 client at it:
export AWS_ACCESS_KEY_ID="$(oc exec "$POD" -- \
  cat ceph/build/dev/rgw.0/rgw_user_keys | head -1)"
# or use radosgw-admin user create from inside the pod and copy
# the keys back out — vstart wires a default test user.
aws --endpoint-url http://localhost:8000 s3 ls
```

If you also need direct librados access (e.g. running rgw object
upload tests that talk to the OSDs directly), add the mon ports:

```sh
oc port-forward "$POD" 8000:8000 3300:3300 6789:6789
```

---

## Shape 2: CephFS-only — filesystem dev shell

**When to use it.** You're hacking on the MDS — directory fragmentation,
quotas, snapshots, the kclient/fuse mount paths, multi-active MDS
behaviour. RGW would just sit idle; rgw_count=0 saves ~1GB RSS and
skips the radosgw daemon startup.

**Pipeline params.**

```sh
tkn pipeline start dev-vstart \
  -p git_ref=wip-mds-foo \
  -p rgw_count=0 \
  -p mds_count=1 \
  -p keep_alive_seconds=14400 \
  --workspace name=source,volumeClaimTemplateFile=workspace-pvc.yaml
```

**Port-forward.** The MDS daemon binds an ephemeral port that the mons
hand out via the mdsmap — you don't connect to the MDS directly,
you connect to the **mons** and the kernel/fuse client picks up the
MDS address from the mdsmap. Forward the mon ports:

```sh
# MON msgr2 (:3300) + legacy msgr1 (:6789).
oc port-forward "$POD" 3300:3300 6789:6789
```

To mount CephFS locally from your laptop you also need the cluster's
ceph.conf + admin keyring; the easiest path is to copy them out of
the pod:

```sh
mkdir -p /tmp/vstart-conf
oc cp "$POD":ceph/build/ceph.conf /tmp/vstart-conf/ceph.conf
oc cp "$POD":ceph/build/keyring    /tmp/vstart-conf/keyring

# Mount with the kernel client (Linux):
sudo mount -t ceph \
  127.0.0.1:6789:/ /mnt/cephfs \
  -o name=admin,secretfile=/tmp/vstart-conf/keyring,conf=/tmp/vstart-conf/ceph.conf

# Or ceph-fuse from inside the pod (no port-forward gymnastics):
oc exec -it "$POD" -- bash -c \
  'cd ceph/build && source ../src/vstart_environment.sh && \
   ceph-fuse /mnt/cephfs'
```

On macOS the kernel CephFS client doesn't exist; use `ceph-fuse`
from inside the pod, or run a Linux VM. For most dev cycles
exec-ing into the pod (`oc rsh "$POD"`) and running `ceph fs ls`,
`mkdir -p /mnt/cephfs && ceph-fuse /mnt/cephfs` is the path of
least friction.

---

## Shape 3: Combined — RGW + CephFS dev shell

**When to use it.** Cross-component work — RGW-on-CephFS pointer files
(see #64 zgw-pointer), the cephadm orchestrator's multi-daemon
placement story, end-to-end smoke tests that exercise both APIs in
one PipelineRun.

**Pipeline params.**

```sh
tkn pipeline start dev-vstart \
  -p git_ref=wip-combined-foo \
  -p rgw_count=1 \
  -p mds_count=1 \
  -p osd_count=3 \
  -p keep_alive_seconds=14400 \
  --workspace name=source,volumeClaimTemplateFile=workspace-pvc.yaml
```

The default `osd_count=3` covers both daemons' data pools; bump to
4-5 if you're testing pool placement under failure-domain pressure.

**Port-forward.** Both shapes' ports at once:

```sh
# RGW S3 (:8000) + mon msgr2 (:3300) + legacy msgr1 (:6789).
# MDS rides on the mon ports — no separate forward needed.
oc port-forward "$POD" 8000:8000 3300:3300 6789:6789
```

If you're running multiple RGWs (`rgw_count=2`), each binds
`8000+i`: `oc port-forward "$POD" 8000:8000 8001:8001`.

---

## Tearing down early

The Task holds the cluster alive until `keep_alive_seconds` expires,
or until you write a non-empty value to the sentinel file:

```sh
# Asks the Task to wind down cleanly (runs stop.sh, releases the
# pod). Same workspace binding the Task was started with.
oc exec "$POD" -- sh -c 'echo done > /workspace/source/.shutdown'
```

This is the path CI test substrates use — the test Task writes
`.shutdown` after its assertions pass, and the vstart-cluster pod
shuts down inside seconds rather than waiting out the TTL.

## Notes

- Forwarded ports are TCP only. If you need UDP (none of these
  daemons use UDP by default), you'd need an in-cluster client.
- `port-forward` reconnects automatically on transient network
  blips but does NOT survive the pod being killed (cluster
  shutdown). Re-run `oc get pods` to find the new pod if you
  start a second PipelineRun.
- The pod's `securityContext` is non-privileged with no host
  mounts (per the issue acceptance criteria) — the daemons run
  as the builder image's `builder` UID. This is why memstore is
  the default OSD backend; bluestore on loop devices needs
  capabilities the pod doesn't have.

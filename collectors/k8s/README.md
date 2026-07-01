# collectors/k8s — STUB

> **Status: NOT IMPLEMENTED.** This directory describes what a Kubernetes
> collector will gather and how it will be delivered. No collection code exists
> here yet. It is owned by the k8s domain team (CONTRACT rule 4).

## (a) Hidden facts to collect

The facts a remote WhaTap agent developer repeatedly asks a field engineer for
about a node/cluster:

- **Container log real path** — resolve `/var/log/containers/*.log` symlinks to
  their actual target (standard `/var/log/pods/...` vs. platform-specific paths
  such as CCE's `/mnt/paas/runtime/container_logs`). See
  [../../docs/coverage-kb/k8s-huawei-cce.md](../../docs/coverage-kb/k8s-huawei-cce.md).
- **Container runtime** — which runtime and version (detect the runtime socket:
  `/run/containerd/containerd.sock`, `/var/run/docker.sock`, `/run/crio/crio.sock`).
- **kubelet root-dir** — discovered from the kubelet process arguments, not
  assumed to be `/var/lib/kubelet`.
- **cgroup version** — v1 vs. v2 (`stat -fc %T /sys/fs/cgroup`).
- **Node OS / kernel / arch**.
- **WhaTap node agent** — presence, version, and config on the node.

Everything is **discovered** (symlinks/mounts/process args resolved), never
hardcoded, so a new platform needs no code change (CONTRACT rule 2).

## (b) Delivery mechanism

Two ways to reach the "one command → paste" goal (CONTRACT rule 3):

- **On-node**: a shell script run directly on the node.
- **In-cluster**: a Kubernetes `Job` manifest that mounts the host read-only
  (`/var/log`, `/sys/fs/cgroup`, `/var/run`) and runs the script; the field
  engineer applies it and pastes `kubectl logs job/...`.

## (c) How to implement

Copy [../../templates/collector-skeleton/](../../templates/collector-skeleton/),
follow [../../docs/authoring-guide.md](../../docs/authoring-guide.md), and keep
to facts only. Validate with `tools/validate.sh`.

# collectors/k8s — SEEDED v0

> **Status: SEEDED v0** (`collect-k8s.sh` 0.4.1). Owned by the k8s domain team
> (CONTRACT rule 4); until handover it is managed by the Global team.
> Verified end-to-end against one live kubeadm cluster (v1.32, containerd,
> whatap-operator 2.9.7 + node-agent DaemonSet + APM auto-instrumented app).
> Not yet run on OpenShift / CCE / EKS / RBAC-restricted profiles.

## (a) What it collects

Runs **wherever kubectl (or oc) reaches the cluster** — a bastion or engineer
workstation, not on the node. One report, MECE sections:

| Section | Facts |
|---|---|
| [1] Collection environment | tool presence, CLI in use (kubectl→oc fallback), context name, discovered namespace + how |
| [2] A. Cluster & API server | client+server version, /readyz, node/ns counts, platform markers (providerID, platform labels, OpenShift api groups → clusterversion/SCC) |
| [3] B. Nodes | kubelet/OS/kernel/runtime/arch table (cap 50 + total), distinct runtimes, Ready summary, **control-plane nodes with their InternalIP** (roles read from labels, current and pre-1.24 `master` both covered) — an admission webhook is called *by* the API server, so these are the hosts whose path to the webhook backend matters |
| [4] C. WhaTap CRDs & CR | whatap CRDs (group name = install generation hint), install-generation markers, full WhatapAgent CR yaml (verbatim), pod-level vs container-level env placement, APM instrumentation targets (selectors/mode/configMapRef), ConfigMap inventory |
| [5] D. Operator, RBAC & webhooks | operator deploy yaml + ReplicaSet image history, mutating/validating webhooks (yaml, verbatim), ServiceAccounts + the SA referenced by DS/operator, whatap clusterroles/bindings **plus their rules** (apiGroups/resources/verbs — the pod-mutating path reads the Pod's Namespace object while matching a namespaceSelector), **admission call counters from the API server's own `/metrics`** (`request_total` per HTTP code, `fail_open_count`, `admission_duration_seconds_count`, keyed by per-hook name — these come from the CALLER, so they state whether the API server reached the webhook at all, independently of anything the operator logs; available on managed control planes too), secret names/types only |
| [6] E. Agent workloads | DaemonSet status + yaml, container names (discovered, covers operator vs legacy v2 naming), pod table by restart count, describe of top-2 restart pods, other whatap deployments |
| [7] F. Events & quotas | namespace events (last 60), resourcequota/limitrange, ns labels |
| [8] G. Logs | bounded tails: operator, master-agent, up to 3 sample node-agent pods × both containers, `--previous` when restarted | Plus **kube-apiserver logs filtered to webhook call outcomes** (tail 2000 × up to 3 control-plane pods): the API server warns on every failed webhook call *including* when `failurePolicy: Ignore` then admits the request, and that line carries the reason (timeout / x509 / refused) which the counters do not. Reasoned absence on managed control planes.
| [9] H. Helm & images | helm releases/history/values (verbatim); without the helm binary degrades to `sh.helm.release.v1.*` secret names; all deployed whatap image:tags |
| [10] I. In-pod node facts | `kubectl exec` into up to 2 running node-agent pods: container-log symlink real target (standard `/var/log/pods` vs CCE `/mnt/paas/...`), log roots & runtime sockets (candidate paths derived from the DS's declared mounts, e.g. `/rootfs`), cgroup fs type, node-helper health endpoint, kubelet cmdline (only when hostPID) |
| [11] J. APM auto-instrumentation | **always**: name-mapping inputs (WhatapAgent CR names + whether one is named `whatap`, per-target namespaceSelector/podSelector, every namespace's labels) and a cluster-wide inventory of instrumented pods by **two** markers (whatap init container **or** the `whatap-apm-injected` annotation), with the mismatch list. With `--apm-target NS[/NAME]`: workload template env **as declared** vs pod env **as admitted** (per container, in API order, with repeated-name detection, **including `envFrom` ConfigMap/Secret sources** — a container with an empty `.env[]` is not a container without environment), init-container state (waiting reason/message), volumes/mounts, securityContext, every pod's labels + injection markers, init-container log and app-container log **head**, namespace events. Pods named by a CR target's `podSelector` are detailed first, so a per-target cap never skips the workloads the CR actually asks for. With `--apm-exec` (Tier 2): `/proc/1/environ` and cmdline, agent home, `whatap.conf`, agent logs, `/tmp/whatap-*.lock`, runtime version |

Everything is **discovered** (CRD group, namespace, DS/container names, mount
prefixes), never hardcoded, so a new platform or install generation needs no
code change (CONTRACT rule 2). A value that cannot be obtained is reported as
`n/a (<classified reason>)`.

**Verbatim output:** framework policy (authoring-guide step 3) — no masking;
a value has to be readable to be verified or refuted. This applies to the report and every
bundle artifact. Secret **values are never fetched** (`get secret -o yaml|json`
is not used anywhere); secrets appear as name/type tables only. The bundle
still contains real logs — move it over a trusted channel and delete it when
the case closes.

## (b) Delivery — what the field engineer runs

```sh
./collect-k8s.sh --file                   # -> whatap-k8s-<host>-<UTC>.txt   (attach this)
./collect-k8s.sh --bundle                 # -> whatap-k8s-<host>-<UTC>.tar.gz (report + yaml/logs)
./collect-k8s.sh --file --namespace <ns>  # RBAC-scoped kubeconfig: name the whatap namespace
./collect-k8s.sh --file --context <ctx>   # multi-cluster bastion
./collect-k8s.sh                          # no arguments -> help only (does not collect)

# APM auto-instrumentation case ("the agent is not being injected"):
./collect-k8s.sh --file --apm-target <app-ns>            # + the app namespace
./collect-k8s.sh --file --apm-target <app-ns>/<workload> # narrow it to one workload
./collect-k8s.sh --bundle --apm-target <app-ns> --apm-exec
```

Load tiers:

| Tier | Flags | Behavior |
|---|---|---|
| 0 (default) | `--file` / `--stdout` | read-only API GETs, bounded log tails (`--tail`, default 200), exec into at most 2 agent pods; every call double-bounded (`--request-timeout=15s` + `timeout 20`) |
| 1 | `--bundle` | Tier 0 report + full CR/DS/operator/webhook yaml, per-container logs for **all** whatap pods (tail 2000 / 5 MB caps), events, nodes, helm values — all verbatim |
| 2 (opt-in) | `--exec-per-node` | in-pod probes on every running node-agent pod (cap 30); announces the fan-out on stderr first |
| 2 (opt-in) | `--apm-exec` | read-only probes **inside** the `--apm-target` application containers (up to 3 pods per target): pid 1 cmdline + environ, agent home, `whatap.conf`, agent logs, port registry, runtime version |
| opt-in | `--apm-target NS[/NAME]` | reads an **application** namespace: workloads, pods, env tables, logs, events (explicit opt-in because it leaves the whatap namespace); repeatable, cap 5. Section J's name-mapping and cluster-wide inventory run without it |

The old idea of an in-cluster `Job` manifest delivery (host mounted read-only)
remains future work; v0 is bastion-run by decision.

## (c) Maintenance

- Validate: `../../tools/validate.sh collect-k8s.sh` (must PASS).
- Discovery order for the namespace: `--namespace` flag → pods labeled
  `name=whatap-node-agent` → pods labeled `app.kubernetes.io/name=whatap-operator`
  → one cluster-wide `whatap-*` pod-name scan.
- Install generations covered: operator (CRD `whatapagents.monitoring.whatap.com`,
  containers `whatap-node-agent`/`whatap-node-helper`) and legacy v2
  (`whatap/kube` chart, containers `nodeAgent`/`nodeHelper`, no CRD) — container
  names are read from the DS, so both resolve without code changes.
- Open items: OpenShift oc-only run, CCE node verification of section [10],
  distroless agent images (no `sh` → exec probes degrade to n/a), RBAC-restricted
  profile matrix, in-cluster Job delivery.

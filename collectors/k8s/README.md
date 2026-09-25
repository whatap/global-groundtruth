# collectors/k8s — SEEDED v0

> **Status: SEEDED v0** (validated at `collect-k8s.sh` 0.4.4; the script's own
> `VERSION` is the current one). Owned by the k8s domain team
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
| [4] C. WhaTap CRDs & CR | whatap CRDs (group name = install generation hint), install-generation markers, full WhatapAgent CR yaml (verbatim), **CR write history** (managedFields manager/operation/time — settles whether a given block was present when a pod was created, which `generation` alone cannot), pod-level vs container-level env placement, APM instrumentation targets (selectors/mode/configMapRef), ConfigMap inventory |
| [5] D. Operator, RBAC & webhooks | operator deploy yaml + ReplicaSet image history, mutating/validating webhooks (yaml, verbatim), ServiceAccounts + the SA referenced by DS/operator, whatap clusterroles/bindings **plus their rules** (apiGroups/resources/verbs — the pod-mutating path reads the Pod's Namespace object while matching a namespaceSelector), **the webhook serving certificate vs the registered caBundle** — the same openssl fingerprint taken three ways (caBundle in the configuration / the operator's `whatap-webhook-certificate` Secret, public `cert.pem` field only / the running pod's `/etc/webhook/certs/ca.crt`, read out and fingerprinted locally) plus the times each side was produced. The operator mints a fresh CA on every process start into an emptyDir, so these can disagree and the API server then rejects the call with `x509 … "whatap-webhook-ca"` — silently, under `failurePolicy: Ignore`. Private key fields are never requested or printed. Also **every admission webhook in the cluster** (config -> hook names, deliberately not whatap-filtered: a third-party mutating webhook on the same pods is part of the injection path, and a reused hook name shares whatap's metric series), **admission call counters from the API server's own `/metrics`** (`request_total` per HTTP code, `fail_open_count`, `admission_duration_seconds_count`, keyed by per-hook name, with a check for hook names carried by more than one configuration since the metrics have no configuration label and kubebuilder scaffolds generic names like `mpod.kb.io` — these come from the CALLER, so they state whether the API server reached the webhook at all, independently of anything the operator logs; available on managed control planes too), secret names/types only |
| [6] E. Agent workloads | DaemonSet status + yaml, container names (discovered, covers operator vs legacy v2 naming), pod table by restart count, describe of top-2 restart pods, other whatap deployments |
| [7] F. Events & quotas | namespace events (last 60), resourcequota/limitrange, ns labels |
| [8] G. Logs | bounded tails: operator, master-agent, up to 3 sample node-agent pods × both containers, `--previous` when restarted | Plus **kube-apiserver logs filtered to webhook call outcomes** (tail 2000 × up to 3 control-plane pods): the API server warns on every failed webhook call *including* when `failurePolicy: Ignore` then admits the request, and that line carries the reason (timeout / x509 / refused) which the counters do not. Reasoned absence on managed control planes.
| [9] H. Helm & images | helm releases/history/values (verbatim); without the helm binary degrades to `sh.helm.release.v1.*` secret names; all deployed whatap image:tags |
| [10] I. In-pod node facts | `kubectl exec` into up to 2 running node-agent pods: container-log symlink real target (standard `/var/log/pods` vs CCE `/mnt/paas/...`), log roots & runtime sockets (candidate paths derived from the DS's declared mounts, e.g. `/rootfs`), cgroup fs type, node-helper health endpoint, kubelet cmdline (only when hostPID) |
| [11] J. APM auto-instrumentation | **always**: name-mapping inputs (WhatapAgent CR names + whether one is named `whatap`, per-target namespaceSelector/podSelector, every namespace's labels) and a cluster-wide inventory of instrumented pods by **two** markers (whatap init container **or** the `whatap-apm-injected` annotation), with the mismatch list. With `--apm-target NS[/NAME]`: workload template env **as declared** vs pod env **as admitted** (per container, in API order, with repeated-name detection, **including `envFrom` ConfigMap/Secret sources** — a container with an empty `.env[]` is not a container without environment), init-container state (waiting reason/message), volumes/mounts, securityContext, every pod's labels + injection markers, init-container log and app-container log **head**, namespace events. Pods named by a CR target's `podSelector` are detailed first, so a per-target cap never skips the workloads the CR actually asks for. With `--apm-exec` (Tier 2): `/proc/1/environ` and cmdline, agent home, `whatap.conf`, agent logs, `/tmp/whatap-*.lock`, runtime version |

Before any of this, one reachability call (`kubectl get --raw /version`,
5 s). When it fails (unreachable API server, a context that does not exist,
bad credentials) every API section is printed with that one reason, the API
and CR goals are `missed`, and the run reaches its footer in seconds instead of
timing out call by call.

The `cr` goal is `na` only when the lists behind it answered: the cluster-wide
CRD list carries no `whatapagents.*` CRD, or the WhatapAgent list (across all
namespaces for a namespaced CRD) answered with no items. A forbidden, failed or
timed-out CRD or CR list is `missed` with the call's reason.

Everything is **discovered** (CRD group, namespace, DS/container names, mount
prefixes), never hardcoded, so a new platform or install generation needs no
code change (CONTRACT rule 2). A value that cannot be obtained is reported as
`n/a (<classified reason>)`.

**Verbatim output:** framework policy (authoring-guide step 3) — no masking;
a value has to be readable to be verified or refuted. This applies to the report and every
bundle artifact. See "What the report can contain" below.

### Reading the report (explanations kept out of the report)

- **Admission timing.** The whatap mutating webhook acts on pods at CREATE
  (see the webhook rules in section D). A pod created before the operator or
  the CR existed carries no injection until it is recreated. Section J reports
  three states: declared (workload template), admitted (pod spec), running
  (`--apm-exec` only, `/proc/1/environ`).
- **CR name.** In whatap-operator (`internal/webhook/v2alpha1/whatapagent_webhook.go`)
  the pod-mutating path resolves one cluster-scoped WhatapAgent by the fixed
  name `whatap`; section J states whether a CR by that name is present.
- **Admission counters** (section D, kube-apiserver `/metrics`):
  `request_total` = calls made, per HTTP code; `fail_open_count` = calls
  admitted without the webhook after a failed call; `admission_duration_seconds_count`
  = calls attempted. They are keyed by hook name only, so a hook name carried
  by two configurations shares one series; no series for a whatap hook name
  means the API server has recorded no call under that name.
- **Webhook CA.** The operator generates a self-signed CA on every process
  start (`cmd/main.go generateSelfSignedCert`) into an emptyDir, so a restart
  produces a new CA; the three fingerprints and their production times in
  section D are what to compare. No webhook-cert Secret in the namespace is
  consistent with a CA kept only in the emptyDir.
- **No kube-apiserver pods** in kube-system: a managed control plane, or an
  API server that does not run as a pod. The control-plane host's own log is
  then the only source for webhook call failures; the section D counters still
  apply. The kube-apiserver tail is 2000 lines, and a failure older than that
  is still counted by the section D counters.
- **CR targets line.** `apm instrumentation targets declared per cr` prints
  `cr=target,target,...`; nothing after `=` means that CR declares no target.
- **Absence lines.** A list that answered empty prints `none ...`; a list whose
  call failed or was refused prints `n/a (<reason>)` instead.
- **Repeated env names.** Kubernetes applies the first occurrence of a
  duplicated env name in a container.
- **Registries.** External registry tag listings are out of scope (clusters are
  often air-gapped); section H lists the images in use.

## What the report can contain

The report and the bundle are not masked. A secret can arrive from:

- **Pod and workload env values** — section J env tables (`--apm-target`),
  the operator container env (section D, `operator container command/args`),
  the full operator Deployment, DaemonSet, WhatapAgent CR yaml (section C/D/E),
  target `envs` in the CR, and in the bundle every pod/workload yaml under
  `apm-targets/`. Whatever a customer put in `.env[].value` (license keys,
  passwords, tokens) is printed as is. `valueFrom`/`envFrom` references are
  printed as names only; the referenced Secret is not read.
- **Helm values** — `helm get values` per whatap release (section H and
  `helm/values-*.yaml` in the bundle).
- **In-container files** (`--apm-exec` only) — `whatap.conf` as present in the
  application container (license key), `/proc/1/environ` filtered to
  whatap/loader/license keys, agent log lines.
- **Logs** — operator, master-agent, node-agent, init-container and
  application log heads/tails; the bundle carries up to 2 MB per container.
- **Secrets** — `get secret -o yaml|json` is not used. Secrets appear as
  name/type/data-count tables. The one Secret field read is `cert.pem` of the
  webhook-certificate Secret (a public certificate); only its fingerprint and
  subject are printed. The operator pod's `/etc/webhook/certs/ca.crt` is read
  and fingerprinted the same way; key files are never read.

Move the report and bundle over a trusted channel and delete them when the
case closes.

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
| 0 (default) | `--file` / `--stdout` | read-only API GETs, bounded log tails (`--tail`, default 200), exec into at most 2 agent pods; every call double-bounded (kubectl `--request-timeout=15s` + the shared `_bounded` cap, 20 s, inside the 300 s run deadline); helm calls bounded the same way |
| 1 | `--bundle` | Tier 0 report + full CR/DS/operator/webhook yaml, per-container logs of the whatap namespace pods (caps: 20 pods, tail 2000 lines and 2 MB per file, 60 MB in total across `logs/` and the `--apm-target` logs; `--previous` only for containers with restarts; `logs/CAPS.txt` states the caps and what was left out), events, nodes, helm values — all verbatim |
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

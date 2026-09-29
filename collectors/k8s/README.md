# collectors/k8s: Kubernetes collector

> **Status:** validated at `collect-k8s.sh` 0.12.2 on 2026-09-28, against the lab `k8s-lab`
> kubeadm cluster (v1.32.13, containerd, cilium, operator-injected APM pods) and the `k8sproxy`
> MEA webhook-fail-open repro, from a bastion-shaped `KUBECONFIG` and from inside the cluster VM.
> Not yet run on: OpenShift, CCE, EKS, RBAC-restricted profiles. Owner: Global team until
> handover to the k8s domain team (CONTRACT rule 4).

## (a) What it collects

Runs **wherever kubectl (or oc) reaches the cluster**: a bastion or engineer
workstation, not on the node. One report, MECE sections:

| Section | Facts |
|---|---|
| [1] Collection environment | tool presence, CLI in use (kubectl→oc fallback), context name, discovered namespace + how |
| [2] A. Cluster & API server | client+server version, /readyz, node/ns counts, platform markers (providerID, platform labels, OpenShift api groups → clusterversion/SCC) |
| [3] B. Nodes | kubelet/OS/kernel/runtime/arch table (cap 50 + total), distinct runtimes, Ready summary, **control-plane nodes with their InternalIP** (an admission webhook is called *by* the API server, so these are the hosts whose path to the webhook backend matters) |
| [4] C. WhaTap CRDs & CR | whatap CRDs, install-generation markers, **every** listed WhatapAgent CR's name / targets / selectors, the full CR yaml (verbatim, first 3, the one named `whatap` first), **CR write history** (managedFields manager/operation/time: settles whether a block was present when a pod was created, which `generation` cannot), ConfigMap inventory |
| [5] D. Operator, RBAC & webhooks | operator deploy yaml + ReplicaSet image history; mutating/validating webhooks (yaml, verbatim) with backend Service and Endpoints; ServiceAccounts, whatap clusterroles/bindings and their rules; **the webhook serving certificate vs the registered caBundle** (one openssl fingerprint taken three ways: configuration caBundle, the operator's `whatap-webhook-certificate` Secret `cert.pem` only, the running pod's `/etc/webhook/certs/ca.crt`, plus the time each side was produced; private key fields are never requested); **the serving chain as presented** (`openssl s_client -showcerts` from the collector host to the first 2 ready endpoint addresses and the Service ClusterIP: subject / issuer / notAfter / sha256 / SANs and `Verify return code`, raw, min(CMD_TIMEOUT, 3) s per address); **the kube-apiserver proxy environment** (`http_proxy` / `https_proxy` / `no_proxy` env entries in any case, envFrom sources, env count); **every admission webhook in the cluster** (deliberately not whatap-filtered: a third-party mutating webhook on the same pods is part of the injection path); **admission call counters from the API server's `/metrics`** (`request_total` per HTTP code, `fail_open_count`, `admission_duration_seconds_count`, per hook name, with a check for hook names shared by more than one configuration; available on managed control planes too); secret names/types and the decoded `WHATAP_*` keys of the WhaTap credential Secrets (other keys by name only) |
| [6] E. Agent workloads | DaemonSet status + yaml, container names (discovered, covers operator vs legacy v2 naming), pod table by restart count (with not-ready containers and node), describe of the first 2 pods with restarts or a container not ready (else one line: none qualified), other whatap deployments |
| [7] F. Events & quotas | namespace events (last 60), resourcequota/limitrange, ns labels |
| [8] G. Logs | bounded tails: operator (a deeper 4000-line read filtered to injection-marker lines, so the admission decision written at pod CREATE survives on a long-lived operator), master-agent, up to 3 sample node-agent pods × both containers, `--previous` when restarted. Plus **kube-apiserver logs filtered to webhook call outcomes** (tail 2000 × up to 3 control-plane pods): the API server warns on every failed webhook call *including* when `failurePolicy: Ignore` admits the request, and that line carries the reason (timeout / x509 / refused) which the counters do not. Reasoned absence on managed control planes. |
| [9] H. Helm & images | helm releases/history/values (verbatim); without the helm binary degrades to `sh.helm.release.v1.*` secret names; all deployed whatap image:tags, and the `image imageID` (digest) of every container of the whatap namespace pods |
| [10] I. In-pod node facts | `kubectl exec` into up to 2 running node-agent pods: container-log symlink real target (standard `/var/log/pods` vs CCE `/mnt/paas/...`), log roots & runtime sockets (candidate paths derived from the DS's declared mounts, e.g. `/rootfs`), cgroup fs type, node-helper health endpoint, kubelet cmdline (only when hostPID), **the proxy lines of `<host root>/etc/kubernetes/manifests/kube-apiserver.yaml`** (`grep -i -A1`, only on a node running a kube-apiserver pod and when the exec container mounts the host root; the without-restarts sample is taken on such a node when one runs a node-agent pod, so no exec is added) |
| [11] J. APM auto-instrumentation | **always**: the namespace side of the name mapping (every namespace's labels) and a cluster-wide inventory of instrumented pods by **two** markers (whatap init container **or** the `whatap-apm-injected` annotation) with the mismatch list. Per `--apm-target` pod: init-container command/args, container `imageID`, and each app-container log head followed by its `WhaTap version lines`. With `--apm-target NS[/NAME]`: workload template env **as declared** vs pod env **as admitted** (per container, API order, repeated names flagged, **including `envFrom` sources**), init-container state, volumes/mounts, securityContext, every pod's labels + injection markers, init-container and app-container log **head**, namespace events. Pods named by a CR target's `podSelector` are detailed first, so a per-target cap never skips the workloads the CR asks for. With `--apm-exec` (Tier 2): `/proc/1/environ` and cmdline, agent home, agent `package.json` version, `whatap.conf`, agent logs (first 5 and last 40 lines each), `/tmp/whatap-*.lock`, runtime version |

### Collection status (goals)

The status section rolls up five goals. A `missed` goal makes the run
INCOMPLETE: change what its reason names and run again. `na` is an answer
(every list behind it answered) and the report is fine to send.

| Goal | Obtained when | `na` when | `missed` when |
|---|---|---|---|
| Kubernetes API reachable | `get --raw /version` (5 s) answered, a refusal included | never | the call failed or timed out, or no kubectl/oc |
| WhatapAgent CR | a WhatapAgent is listed | the cluster-wide CRD list has no `whatapagents.*` CRD, or the WhatapAgent list (all namespaces for a namespaced CRD) answered with no items | the CRD or CR list was refused, failed or timed out |
| whatap namespace | `--namespace` given, or a whatap pod found by the discovery lists (see (c)) | all three cluster-wide pod lists answered with no whatap pod | a discovery list failed and no later one found a whatap pod |
| whatap workloads (daemonset, deployments) | a whatap DaemonSet or Deployment is listed in the namespace and neither list failed | both lists answered with nothing named whatap, or there is no whatap namespace (`na` above) | the DaemonSet or Deployment list was refused, failed or timed out, or the namespace was not located |
| node-agent pods | node-agent pods are listed (label `name=whatap-node-agent`, then pods named after the DaemonSet) | the lists answered with no pod, or there is no whatap namespace | a pod list was refused, failed or timed out; the label list answered empty and the DaemonSet list behind the name fallback failed; or the namespace was not located |

A refusal of an inventory list (`forbidden: ...`, quoting kubectl's message with the user and the
resource) carries an `(RBAC: ...)` hint: the grant that would obtain the read,
or `--namespace` for a namespace-scoped identity. The kubeconfig identity is
this collector's privilege, so it plays the part `_priv_hint` plays for a uid.
The three inventory goals are separate because each rests on its own list and
its own RBAC rule. Other n/a facts (node table, events, logs, helm) stay fact
lines and do not change the status.

Before any of this, one reachability call (`kubectl get --raw /version`,
5 s). When it fails (unreachable API server, a context that does not exist,
bad credentials) every API section is printed with that one reason, every
goal is `missed` with it, and the run reaches its footer in seconds instead of
timing out call by call.

See "What the report can contain" for what is printed verbatim.

### Reading the report (explanations kept out of the report)

- **Admission timing.** The whatap mutating webhook acts on pods at CREATE
  (see the webhook rules in section D). A pod created before the operator or
  the CR existed carries no injection until it is recreated. Section J reports
  three states: declared (workload template), admitted (pod spec), running
  (`--apm-exec` only, `/proc/1/environ`).
- **CR name.** In whatap-operator (`internal/webhook/v2alpha1/whatapagent_webhook.go`)
  the pod-mutating path resolves one cluster-scoped WhatapAgent by the fixed
  name `whatap`; the CR names are in section C (subsection titles and yaml).
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
- **kube-apiserver proxy environment** (section D). The API server calls a
  webhook as an HTTPS client that honours `https_proxy` / `no_proxy` from its
  environment; a `no_proxy` without `.svc` (or the service CIDR) sends the
  call to the proxy, and a proxy that presents its own certificate fails
  x509 whatever the caBundle. A static-pod API server's
  environment is its manifest's `env`, which the mirror pod spec carries. A
  managed control plane (GKE/EKS/AKS) runs no kube-apiserver pod the API can
  list, so its environment is not visible from the cluster; the section then
  says so.
- **Serving chain** (section D). `openssl s_client` reads no proxy variable:
  the chain is what the backend presents on a direct connection from the
  collector host, not what a proxy on the API server's path would present.
  From a bastion outside the pod network the endpoint address usually times
  out; run from a control-plane node to reach both addresses.
- **API round trip** (section [1]) is the wall time of the one reachability
  call, in ms: kubectl start-up, kubeconfig and auth-plugin work, and one
  request to the API server. Multiply by the kubectl call count in the status
  section's time table to see how much of a slow run the API accounts for.

## What the report can contain

The report and the bundle are not masked. A secret can arrive from:

- **kube-apiserver proxy variables**: section D (pod spec) and section I
  (manifest lines): a proxy URL can carry `user:password@`.
- **Init container command/args**: section J init-container table
  (`--apm-target`): whatever the command line carries, printed as is.
- **Pod and workload env values**: section J env tables (`--apm-target`),
  the operator container env (section D, `operator container command/args`),
  the full operator Deployment, DaemonSet, WhatapAgent CR yaml (section C/D/E),
  target `envs` in the CR, and in the bundle every pod/workload yaml under
  `apm-targets/`. Whatever a customer put in `.env[].value` (license keys,
  passwords, tokens) is printed as is. `valueFrom`/`envFrom` references are
  printed as names only; the referenced Secret is not read.
- **Helm values**: `helm get values` per whatap release (section H and
  `helm/values-*.yaml` in the bundle).
- **In-container files** (`--apm-exec` only): `whatap.conf` as present in the
  application container (license key), `/proc/1/environ` filtered to
  whatap/loader/license keys, agent log lines.
- **Logs**: operator, master-agent, node-agent, init-container and
  application log heads/tails; the bundle carries up to 2 MB per container.
- **WhaTap credential Secrets: values printed** (section D): `whatap-credentials`
  in the whatap namespace and the Secrets the WhatapAgent CR spec names (a field
  ending in `secretName`, or the `name` of a field ending in `secretRef`). Only
  `WHATAP_*` keys (any case) are decoded, as `secret <name> <key>=<value>`; other
  keys are listed by name only, and a key ending in `.key` or `.pem` is never
  decoded. Pod env/envFrom references are not followed.
- **Other Secrets**: `get secret -o yaml|json` is not used; Secrets appear as
  name/type/data-count tables. The only other Secret field read is `cert.pem` of
  the webhook-certificate Secret (a public certificate, fingerprint and subject
  printed); key files are never read.

Move the report and bundle over a trusted channel and delete them when the
case closes.

## (b) Delivery: what the field engineer runs

```sh
./collect-k8s.sh --file                   # -> whatap-k8s-<host>-<UTC>.txt   (attach this)
./collect-k8s.sh --bundle                 # -> whatap-k8s-<host>-<UTC>.tar.gz (report + yaml/logs)
./collect-k8s.sh --file --namespace <ns>  # RBAC-scoped kubeconfig: name the whatap namespace
./collect-k8s.sh --file --context <ctx>   # multi-cluster bastion
KUBECONFIG=/path/to/config ./collect-k8s.sh --file  # non-default kubeconfig (kubectl/oc/helm all read it)
./collect-k8s.sh --file --out /var/tmp     # the .txt / .tar.gz in /var/tmp (default: current dir)
LOG_TAIL_LINES=1000 ./collect-k8s.sh --file  # 1000 Tier 0 log lines per container (default 200)
./collect-k8s.sh                          # no arguments -> help only (does not collect)

# APM auto-instrumentation case ("the agent is not being injected"):
./collect-k8s.sh --file --apm-target <app-ns>            # + the app namespace
./collect-k8s.sh --file --apm-target <app-ns>/<workload> # narrow it to one workload
./collect-k8s.sh --bundle --apm-target <app-ns> --apm-exec
```

Load tiers:

| Tier | Flags | Behavior |
|---|---|---|
| 0 (default) | `--file` / `--stdout` | read-only API GETs, bounded log tails (env `LOG_TAIL_LINES`, default 200; `--tail` is refused, naming `LOG_TAIL_LINES`), exec into at most 2 agent pods; every call is bounded (kubectl `--request-timeout=15s` plus the shared 20 s cap, inside the 300 s run deadline), helm calls too |
| 1 | `--bundle` | Tier 0 report + what the report does not carry: the WhatapAgent CRD yaml, the whatap namespace pod and replicaset tables (`-o wide`), describe of the top-2 restart node-agent pods (image digest, start time, container ids), per-container logs of the whatap namespace pods (caps: 20 pods, tail 2000 lines and 2 MB per file, 60 MB in total across `logs/` and the `--apm-target` logs; `--previous` only for containers with restarts; `logs/CAPS.txt` states the caps and what was left out), events, nodes, helm values, the `--apm-target` originals: all verbatim. The CR, operator, webhook and DaemonSet yaml and the sa/secret tables are in the report and not repeated |
| 2 (opt-in) | `--exec-per-node` | in-pod probes on every running node-agent pod (cap 30); announces the fan-out on stderr first |
| 2 (opt-in) | `--apm-exec` | read-only probes **inside** the `--apm-target` application containers (up to 3 pods per target): pid 1 cmdline + environ, agent home, `whatap.conf`, agent logs, port registry, runtime version |
| opt-in | `--apm-target NS[/NAME]` | reads an **application** namespace: workloads, pods, env tables, logs, events (explicit opt-in because it leaves the whatap namespace); repeatable, cap 5. Section J's name-mapping and cluster-wide inventory run without it |

## Design notes

**Merged calls** (`# ---- merged calls` in `collect-k8s.sh`): per-object jsonpath
reads are asked in ONE call (`km_get GROUP ARGS...`) and split back afterwards,
because many small kubectl calls dominate a run's time. Each template carries a
random per-run marker, and a marker line counts only when it is the one expected
next, so a value that holds marker-like text stays part of the value. The
`KM_*` arrays hold one group record plus contiguous segments per group (a new
call of a group replaces the old range).

**Deep operator-log tail** (`_rep_logs`): the admission decision is written when
a pod is CREATED, far behind a 200-line tail on a long-lived operator, so section
[8] reads `--tail=4000 --limit-bytes=4000000` and keeps only the injector's lines
(agent injection, env assembly, webhook admission); the same read also supplies
the plain `--tail` lines when they fit.

## (c) Maintenance

- Validate: `../../tools/validate.sh collect-k8s.sh` (must PASS).
- Discovery order for the namespace: `--namespace` flag → pods labeled
  `name=whatap-node-agent` → pods labeled `app.kubernetes.io/name=whatap-operator`
  → one cluster-wide `whatap-*` pod-name scan.
- Install generations covered: operator (CRD `whatapagents.monitoring.whatap.com`,
  containers `whatap-node-agent`/`whatap-node-helper`) and legacy v2
  (`whatap/kube` chart, containers `nodeAgent`/`nodeHelper`, no CRD), container
  names are read from the DS, so both resolve without code changes.
